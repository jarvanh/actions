#!/bin/bash
# ===== OpenList 同步工具 — 失败文件修复函数 =====
# 处理 OpenList/WebDAV 无法同步的文件（同步报错、diff 缺失、假成功未持久化等），尝试多种修复方式：
#   1. 创建目标目录（rclone mkdir → OpenList API mkdir → base64URL 编码目录名）
#   2. 多种方式同步文件（按对症优先级执行，首个真实成功即止，ID 以 _fix_method_desc 为准）:
#      目录先过可写性预检（探测失败则重启容器复核），不可写直接切短哈希目录
#      —— 避免在同一条死路上白跑"整文件下载 + 4 次上传"；
#      可写目录跑一轮全败后再兜底切一次（见 _fix_probe_dir_writable /
#      _fix_switch_to_hash_dir 头部注释）
#      文件修复方法1 copyto_original:      直接 rclone copyto（原路径 + 原文件名）
#      文件修复方法2 copyto_shorthash:     短哈希文件名直传（<md5前8位>.<扩展名>，
#                                          密文名必然不超长，对症"加密后文件名
#                                          超长"/敏感字符根因）
#      文件修复方法3 zip_split_original:   zip 压缩 + 分卷上传（原文件名作基底名，
#                                          粒度默认 1GB，OPENLIST_SPLIT_PART_BYTES 可调）
#      文件修复方法4 zip_split_shorthash:  zip 压缩 + 短哈希文件名 + 分卷上传
#   历史版本的低效冗余方法已全部下线，现行仅上述 4 种。
#   方法 ID 用语义名（copyto_original 等）而非 m1/m2 序号: 序号在代码里无法
#   自解释，且方法增删时会漂移。
# 命名口径: 全名带"文件修复"限定词——仓库里另有多处独立的"方法N"编号体系
#   （最易混的是 sync_engine.sh _refresh_ol_drivers 的驱动刷新三招），不带限定词
#   无法区分。本文件内部的"方法1/2/3/4"简写均指上述文件修复方法。
#
# 假成功防护（两层）:
#   1. 落盘即时校验（_confirm_persist_by_count）: 修复方法返回成功后，对比
#      目标侧（裸存储计数视图）文件计数是否增长。未增长 = 假成功 → 该方法
#      加入黑名单，立即尝试下一种方式。属于快速筛查层；"缓存有条目但后端
#      无数据"的深层假成功可能漏检，由第 2 层重启复核兜底。
#   2. 失败记忆（FIX_METHOD_BLACKLIST + marker fix_blacklist 字段）:
#      持久化每文件已判定假成功的方法（marker 存方法全名，| 分隔）。
#      sync_engine.sh 持久化验证（_persist_verify_entries，重启容器后逐文件复核）
#      发现假成功后，本轮立即换方法重试（黑名单让 try_fix_failed_file
#      直接跳过失效方法）；跨轮修复同样跳过，避免方法1 每轮都白白"成功"
#      一次再被发现。
#
# 依赖: utils.sh (log_fix, _get_openlist_token), telegram.sh (间接),
#       openlist_driver.sh (_restart_openlist_for_truth — 目录可写性预检的复核手段)
#       注: openlist_driver.sh 属 L4 且反向依赖本文件（L3），bash 函数在调用时
#       才解析，循环依赖不影响正确性（分层只为可读性，见 README 加载机制）
# 结果写入全局变量:
#   TRY_FIX_STATUS       — "success" 或 "failed"
#   TRY_FIX_ORIGINAL     — 原始文件相对路径
#   TRY_FIX_ALTERNATIVE  — 实际上传后的文件相对路径
#   TRY_FIX_METHOD       — 使用的修复方法描述
#   TRY_FIX_METHOD_ID    — 使用的修复方法全名（供黑名单/marker 记录，即 _fix_method_desc 输出）
#   TRY_FIX_RESTORE      — 还原方法描述（如何从 ALTERNATIVE 还原到 ORIGINAL）
#   TRY_FIX_MESSAGE      — 失败原因（仅 status=failed 时）

# 从 OpenList 数据库（sqlite）读取指定挂载的 addition JSON（API 失败时的兜底）
# 数据库本地化后 data.db 在 runner 本地 /opt/openlist-data/ 下（旧路径保留兜底）
# 先拷贝到 /tmp 避免与运行中容器的文件锁冲突（WAL 一并拷贝）
# 用法: _get_storage_addition_from_db <mount_path 如 /wopan176Crypt>
_get_storage_addition_from_db() {
  local mount="$1"
  local db_src="/opt/openlist-data/data.db"
  [ -f "$db_src" ] || db_src="/dropbox/self-hosted/openlist/data/data.db"
  [ -f "$db_src" ] || { echo "db 文件不存在: /opt/openlist-data/data.db 与 /dropbox/.../data.db 均缺失" >&2; return 1; }
  local db_local="/tmp/ol_data_$$.db"
  cp "$db_src" "$db_local" || return 1
  cp "${db_src}-wal" "${db_local}-wal" 2>/dev/null || true
  cp "${db_src}-shm" "${db_local}-shm" 2>/dev/null || true

  # 失败原因打到 stderr（由 _get_crypt_config 捕获进诊断日志）;
  # 常规 mode=ro 打不开（WAL/-shm 锁等）时用 immutable=1 重试（私有副本，安全）
  python3 "$GITHUB_WORKSPACE/.github/scripts/openlist/get_storage_addition.py" "$db_local" "$mount"
  local rc=$?
  rm -f "$db_local" "${db_local}-wal" "${db_local}-shm" 2>/dev/null || true
  return $rc
}

# crypt 配置获取失败诊断: 原因写入 /tmp/openlist_crypt_diag.log 并打到 stderr
# （不含任何密钥值，只含状态码/字段名/挂载名表）; 同一挂载每进程只记一次。
# _openlist_truth_check 及修复管线诊断配置问题时会参考该文件
_crypt_diag() {
  local mount="$1" msg="$2"
  [ -n "${_CRYPT_DIAG_MOUNT:-}" ] && [ "$_CRYPT_DIAG_MOUNT" = "$mount" ] && return 0
  _CRYPT_DIAG_MOUNT="$mount"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] crypt 配置获取失败 (${mount}): ${msg}" >> /tmp/openlist_crypt_diag.log 2>/dev/null || true
  echo "  ↳ crypt 配置获取失败 (${mount}): ${msg}" >&2
}

# 从 OpenList API 提取 crypt 存储配置
# OpenList crypt 驱动与 rclone crypt 格式兼容，addition.password 即 rclone obscure 格式
# 输出: "<obscured_password> <filename_encryption> <directory_name_encryption> <underlying_remote>"
# underlying_remote 形如 openlist:wopan176（addition.path 优先，缺失时按 Crypt 后缀名推导）
# 注意: admin API 的 addition 是 JSON 编码字符串（run 31918439043 实测 .password 直接
#       取值为空 → crypt 直写一直被跳过），必须 fromjson 解码；API 401/无数据时
#       从本地 data.db 兜底
# 注: 本函数现供名长诊断 / raw 计数视图使用。早期版本曾有一种"rclone crypt
#     直写裸存储"的修复方法（当时的编号也是方法2），已随方法精简下线；
#     本文件里"方法2"若出现在旧 run 实锤的注释中，指的可能是那个已下线的
#     方法，而非现行文件修复方法2 copyto_shorthash。
# 用法: _get_crypt_config <mount_path 如 /wopan176Crypt>
_get_crypt_config() {
  local mount="$1"
  local ol_token="" resp="" addition="" why=""
  local db_err="/tmp/ol_db_err_$$.log"

  # admin API 优先; token 不可用 / curl 失败不能直接判死——
  # data.db 兜底不依赖 token，必须继续尝试（run 31931752797 实测:
  # 此处早退导致 _ensure_crypt_config 全程失败 → raw 计数退化为字面裸路径）
  ol_token=$(_get_openlist_token) || ol_token=""
  local http_code="" api_code="" api_msg=""
  if [ -z "$ol_token" ]; then
    why="token 获取失败（管理面账密登录失败或 OPENLIST_ADMIN_PASSWORD 未注入）"
  else
    resp=$(curl -s -w '\n%{http_code}' "http://127.0.0.1:5244/api/admin/storage/list" \
      -H "Authorization: $ol_token" --max-time 15 2>/dev/null) || resp=""
    if [ -n "$resp" ]; then
      http_code=$(printf '%s\n' "$resp" | tail -n1)
      resp=$(printf '%s\n' "$resp" | sed '$d')
    fi
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
      why="API 请求失败（curl 无响应/超时）"
    else
      api_code=$(printf '%s' "$resp" | jq -r '.code // empty' 2>/dev/null)
      api_msg=$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null)
      if [ "$http_code" = "200" ] && [ "$api_code" = "200" ]; then
        # 匹配容忍有无前导斜杠两种存法
        addition=$(printf '%s' "$resp" | jq -r --arg m "${mount#/}" \
          '(.data.content // .data // [])[]? | select(((.mount_path // "") | ltrimstr("/")) == $m) | .addition // empty' 2>/dev/null | head -1)
        if [ -z "$addition" ] || [ "$addition" = "null" ]; then
          why="API 200 但无 ${mount} 条目; 现有挂载: $(printf '%s' "$resp" | jq -r '(.data.content // .data // [])[]? | "\(.mount_path)[\(.driver)]"' 2>/dev/null | tr '\n' ' ')"
        fi
      else
        why="API http=${http_code} code=${api_code:-?} msg=${api_msg:-?}"
      fi
    fi
  fi

  # API 拿不到（401 无数据/挂载名不匹配/curl 失败等）→ 本地 data.db 兜底
  if [ -z "${addition:-}" ] || [ "$addition" = "null" ]; then
    addition=$(_get_storage_addition_from_db "$mount" 2>"$db_err") || addition=""
    if [ -z "$addition" ]; then
      why="${why:+$why; }db 兜底失败: $(tail -n 1 "$db_err" 2>/dev/null | head -c 300)"
    fi
  fi
  rm -f "$db_err"
  [ -n "$addition" ] && [ "$addition" != "null" ] || { _crypt_diag "$mount" "${why:-addition 为空}"; return 1; }

  # addition 可能是 JSON 编码字符串 → 解码为对象后再取字段
  if printf '%s' "$addition" | jq -e 'type == "string"' >/dev/null 2>&1; then
    addition=$(printf '%s' "$addition" | jq -c 'fromjson' 2>/dev/null)
  fi
  if ! printf '%s' "$addition" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _crypt_diag "$mount" "addition 解析后非 JSON 对象; ${why}"
    return 1
  fi

  # OpenList v4 Crypt 驱动（字段 remote_path/salt/filename_encoding/encrypted_suffix）
  # 底层就是 rclone crypt 库（driver.go 直接 rcCrypt.NewCipher，字段一一映射:
  # password→password, salt→password2, filename_encryption/directory_name_encryption
  # 同名, filename_encoding→filename_encoding, encrypted_suffix→suffix），
  # 与 v3（AList 风格 path/password）都按 rclone 兼容格式处理，字段名双兼容
  local pass pass2 fne dne enc suf upath
  pass=$(printf '%s' "$addition" | jq -r '.password // empty' 2>/dev/null)
  if [ -z "$pass" ]; then
    _crypt_diag "$mount" "addition 无 password 字段（现有字段: $(printf '%s' "$addition" | jq -r 'keys | join(",")' 2>/dev/null)）; ${why}"
    return 1
  fi
  # v4 存的是 ___Obfuscated___<obscure>（Init 时 updateObfusParm 回写）——剥前缀后
  # 正是 rclone 要的 obscure 格式; 无前缀则可能是明文，用 rclone reveal 探测，
  # 非 obscure 时本地 obscure 转换（rclone 连接串 password 只认 obscure 格式）
  pass="${pass#___Obfuscated___}"
  if ! rclone reveal "$pass" >/dev/null 2>&1; then
    local obscured
    obscured=$(rclone obscure "$pass" 2>/dev/null) && [ -n "$obscured" ] && pass="$obscured"
  fi
  pass2=$(printf '%s' "$addition" | jq -r '.salt // empty' 2>/dev/null)
  if [ -n "$pass2" ] && [ "$pass2" != "null" ]; then
    pass2="${pass2#___Obfuscated___}"
    rclone reveal "$pass2" >/dev/null 2>&1 || { local o2; o2=$(rclone obscure "$pass2" 2>/dev/null) && [ -n "$o2" ] && pass2="$o2"; }
  else
    pass2=""
  fi
  # v3 字段名两种拼写都接受（filename_encryption / file_name_encryption）
  fne=$(printf '%s' "$addition" | jq -r '.filename_encryption // .file_name_encryption // "standard"' 2>/dev/null)
  dne=$(printf '%s' "$addition" | jq -r 'if (.directory_name_encryption // .dir_name_encryption // null) == null then "true" else ((.directory_name_encryption // .dir_name_encryption) | tostring) end' 2>/dev/null)
  enc=$(printf '%s' "$addition" | jq -r '.filename_encoding // empty' 2>/dev/null)
  [ "$enc" = "null" ] && enc=""
  suf=$(printf '%s' "$addition" | jq -r '.encrypted_suffix // empty' 2>/dev/null)
  [ "$suf" = "null" ] && suf=""
  upath=$(printf '%s' "$addition" | jq -r '.path // .remote_path // empty' 2>/dev/null)

  local underlying
  if [ -n "$upath" ] && [ "$upath" != "null" ]; then
    underlying="openlist:${upath#/}"
  else
    # 推导: /wopan176Crypt → openlist:wopan176（去掉 Crypt 后缀）
    local base="${mount#/}"
    base="${base%Crypt}"
    underlying="openlist:${base}"
  fi
  # 7 字段定长输出（pass pass2 fne dne enc suffix remote），空值用 "-" 占位
  echo "${pass} ${pass2:--} ${fne} ${dne} ${enc:--} ${suf:--} ${underlying}"
}

# 确保 crypt 配置已缓存到全局（名长诊断与 raw 计数视图共用，每任务只拉取一次）
# 设置全局: _CRYPT_MOUNT/_CRYPT_PASS/_CRYPT_FNE/_CRYPT_DNE/_CRYPT_REMOTE/_CRYPT_ONTHEFLY
# _CRYPT_ONTHEFLY 形如 ":crypt,remote=\"openlist:wopan176\",...password=\"...\":"
# 用法: _ensure_crypt_config <dest_path 如 openlist:wopan176Crypt/backup>
# 返回: 0=配置就绪, 1=非 Crypt 目标或获取失败（失败时 _CRYPT_ONTHEFLY 置空）
_ensure_crypt_config() {
  local dest_path="$1"
  [[ "$dest_path" == openlist:*Crypt/* ]] || return 1
  local rel="${dest_path#openlist:}"
  local mount="/${rel%%/*}"
  # 缓存按挂载点键控: 多个 Crypt 目标（wopan176/baidupan/aliyundrive）并存时
  # 不能复用彼此的配置（否则会把密文写进错误的后端）
  if [ -n "${_CRYPT_ONTHEFLY:-}" ] && [ "${_CRYPT_MOUNT:-}" = "$mount" ]; then
    return 0
  fi
  local conf
  conf=$(_get_crypt_config "$mount") || { _CRYPT_ONTHEFLY=""; return 1; }
  local pass pass2 fne dne enc suf remote
  read -r pass pass2 fne dne enc suf remote <<< "$conf"
  if [ -z "$pass" ] || [ -z "$remote" ]; then
    _CRYPT_ONTHEFLY=""
    return 1
  fi
  # "-" 占位归一为空
  [ "$pass2" = "-" ] && pass2=""
  [ "$enc" = "-" ] && enc=""
  [ "$suf" = "-" ] && suf=""
  _CRYPT_MOUNT="$mount"
  _CRYPT_PASS="$pass"
  _CRYPT_PASS2="$pass2"
  _CRYPT_FNE="$fne"
  _CRYPT_DNE="$dne"
  _CRYPT_ENC="$enc"
  _CRYPT_SUFFIX="$suf"
  _CRYPT_REMOTE="$remote"
  # 可选参数仅非空时附加（password2/filename_encoding/suffix 为 v4 字段;
  # rclone 老版本不认的 key 在连接串里会报错，故不能盲传）
  _CRYPT_ONTHEFLY=":crypt,remote=\"${remote}\",filename_encryption=${fne:-standard},directory_name_encryption=${dne:-true},password=\"${pass}\""
  [ -n "$pass2" ] && _CRYPT_ONTHEFLY="${_CRYPT_ONTHEFLY},password2=\"${pass2}\""
  [ -n "$enc" ] && _CRYPT_ONTHEFLY="${_CRYPT_ONTHEFLY},filename_encoding=${enc}"
  [ -n "$suf" ] && _CRYPT_ONTHEFLY="${_CRYPT_ONTHEFLY},suffix=\"${suf}\""
  _CRYPT_ONTHEFLY="${_CRYPT_ONTHEFLY}:"
  return 0
}

# 实测单个文件名的 crypt 密文名长度（字节）——纯本地探针，不碰真实后端
# rclone 没有 cryptencode 命令（sync_engine.sh 旧代码调用它一直静默失败，名长诊断
# 从未生效过）。权威替代: 用相同加密参数构建 remote 指向本地临时目录的
# :crypt: 远程，copyto 空文件后读底层真实密文名。密文名只由加密参数+原文名
# 决定，与 remote 指向无关 → 本地探针结果与真实后端密文名完全等长
# （rclone ≥1.71 文件名加密为 AES-EME 确定性: PKCS7 填充到 16B 块 → EME →
#  base64/base32 定长展开; OpenList 内置 rclone 1.74.4 与 runner 最新版
#  格式一致，同名恒等密文; 注意 suffix 仅 filename_encryption=off 时追加）
# 依赖: _ensure_crypt_config 已成功（_CRYPT_* 全局就绪）
# 用法: _crypt_name_len_probe <filename>  → stdout: 密文名字节数（失败无输出）
_crypt_name_len_probe() {
  local fn="$1"
  [ -n "${_CRYPT_ONTHEFLY:-}" ] || return 1
  local srcdir dstdir
  srcdir=$(mktemp -d 2>/dev/null) || return 1
  dstdir=$(mktemp -d 2>/dev/null) || { rm -rf "$srcdir"; return 1; }
  : > "${srcdir}/${fn}" 2>/dev/null || { rm -rf "$srcdir" "$dstdir"; return 1; }
  local probe=":crypt,remote=\"${dstdir}\",filename_encryption=${_CRYPT_FNE:-standard},directory_name_encryption=${_CRYPT_DNE:-true},password=\"${_CRYPT_PASS}\""
  [ -n "${_CRYPT_PASS2:-}" ] && probe="${probe},password2=\"${_CRYPT_PASS2}\""
  [ -n "${_CRYPT_ENC:-}" ] && probe="${probe},filename_encoding=${_CRYPT_ENC}"
  [ -n "${_CRYPT_SUFFIX:-}" ] && probe="${probe},suffix=\"${_CRYPT_SUFFIX}\""
  probe="${probe}:"
  rclone copyto "${srcdir}/${fn}" "${probe}/${fn}" >/dev/null 2>&1 || { rm -rf "$srcdir" "$dstdir"; return 1; }
  local enc
  enc=$(find "$dstdir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | head -1)
  rm -rf "$srcdir" "$dstdir"
  [ -n "$enc" ] || return 1
  printf '%s' "$enc" | wc -c | tr -d ' '
}

# 由 Crypt dest_path 推导裸存储远程路径（供名长诊断等需要"真实密文名"的场景）
# API 权威优先（crypt addition.path 指向的真实存储），失败时退化为字符串替换
# 用法: _raw_remote_for <dest_path>  → stdout: openlist:wopan176[/子路径]
_raw_remote_for() {
  local dest_path="$1"
  local rel="${dest_path#openlist:}"
  local sub=""
  [[ "$rel" == */* ]] && sub="/${rel#*/}"
  # 不吞 stderr: _crypt_diag 的失败原因要能在 Actions 日志里看到
  if _ensure_crypt_config "$dest_path"; then
    echo "${_CRYPT_REMOTE}${sub}"
    return 0
  fi
  local base="${rel%%/*}"
  base="${base%Crypt}"
  echo "openlist:${base}${sub}"
}

# raw 计数视图（供落盘即时校验 _confirm_persist_by_count / raw 基准重建的文件数对比）
# dne=true（目录名加密）时裸路径没有字面子目录（run 31918439043 实测
# openlist:wopan176/backup rc=3 not found——"backup" 在裸存储是密文名），
# 字面路径计数必然失败。改用 crypt 即时远程：rclone 按配置逐段加密路径
# 后在裸存储查找，列出再解密，计数口径与 crypt 视图完全一致。
# 配置不可用时退化为裸挂载根（绝不能拼字面子路径: dne 未知时子目录名
# 是密文，openlist:wopan176/backup 这类字面路径必然列空 → 计数恒 0，
# run 31931752797 实测。裸根计数口径偏大但增量检测——比较计数是否增长
# ——仍然成立）。
# 用法: _raw_count_view_for <dest_path>  → stdout: 计数用远程路径
_raw_count_view_for() {
  local dest_path="$1"
  local rel="${dest_path#openlist:}"
  local sub=""
  [[ "$rel" == */* ]] && sub="${rel#*/}"
  # 不吞 stderr: _crypt_diag 的失败原因要能在 Actions 日志里看到
  if _ensure_crypt_config "$dest_path"; then
    echo "${_CRYPT_ONTHEFLY}${sub}"
  else
    local base="${rel%%/*}"
    base="${base%Crypt}"
    echo "openlist:${base}"
  fi
}

# 方法 ID → 可读描述（单一事实源: 日志显示 / marker 记录 / 黑名单均用此全名）
# 保持与各方法实现处的描述一致；已是全名或未知 ID 原样返回（幂等）
#
# ID 用语义名而非 m1/m2 这类序号: 序号在代码里无法自解释（读
#   _fix_method_gate zip_split_original 一眼可辨，换成 m3 就得回查本表），
#   且方法增删时序号会漂移。
#   文件修复方法1 copyto_original      — 原路径 + 原文件名直接 copyto
#   文件修复方法2 copyto_shorthash     — 短哈希文件名（<md5前8位>.<扩展名>）直传
#   文件修复方法3 zip_split_original   — zip 压缩 + 分卷上传（原文件名作基底名）
#   文件修复方法4 zip_split_shorthash  — zip 压缩 + 分卷上传（短哈希名作基底名）
#
# 全名必须带"文件修复"限定词: 仓库里另有多处独立的"方法N"编号体系，
#   同名会让人误以为是一套东西——最易混的是 sync_engine.sh _refresh_ol_drivers 的
#   驱动刷新三招（方法1 load_all / 方法2 重启容器 / 方法3 storage 探测），
#   它与文件修复毫无关系。限定词让 marker/日志里的全名自带领域归属。
# 不兼容历史全名: marker 里旧写法（"方法1: ..."、"m1"）不再被识别，按未知
#   方法原样保留——其黑名单条目因此失效，对应文件最多重跑一轮已判定的方法
#   即会重新拉黑，不修复的代价可控；换来的是命名不再背历史包袱。
# 用法: _fix_method_desc <method_id 如 copyto_shorthash>
_fix_method_desc() {
  case "$1" in
    copyto_original)     echo "文件修复方法1 copyto_original: 直接 rclone copyto（原路径 + 原文件名）" ;;
    copyto_shorthash)    echo "文件修复方法2 copyto_shorthash: 短哈希文件名直传（<md5前8位>.<扩展名>）" ;;
    zip_split_original)  echo "文件修复方法3 zip_split_original: zip 压缩 + 分卷上传（原文件名基底，默认 1GB 分卷）" ;;
    zip_split_shorthash) echo "文件修复方法4 zip_split_shorthash: zip 压缩 + 短哈希文件名 + 分卷上传" ;;
    "")  echo "未知方法" ;;
    *)   echo "$1" ;;
  esac
}

# 方法短标签（仅日志展示用；marker/黑名单仍存 _fix_method_desc 全名）
# 输入语义 ID 或全名均可
_fix_method_short() {
  case "$1" in
    copyto_original|文件修复方法1*)      echo "修复方法1·copyto 原名" ;;
    copyto_shorthash|文件修复方法2*)     echo "修复方法2·短哈希名" ;;
    zip_split_original|文件修复方法3*)   echo "修复方法3·zip 分卷" ;;
    zip_split_shorthash|文件修复方法4*)  echo "修复方法4·短哈希分卷" ;;
    "") echo "未知方法" ;;
    *) _fix_method_desc "$1" ;;
  esac
}

# 命令输出分级日志（管道末端的消费者）:
#   错误/失败行 → 控制台 + 文件（决策相关）
#   常规输出（7z 横幅、Scanning、Everything is Ok、进度等）→ 仅落文件
# 控制台只保留影响判断的行，长日志不再被刷屏。rc 仍由调用方 PIPESTATUS[0] 取。
# 用法: rclone ... 2>&1 | _cmd_log <标签> <log_file>
_cmd_log() {
  local prefix="$1" log_file="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *ERROR*|*Error*|*error*|*Failed*|*failed*|*Fatal*|*cannot*|*Cannot*|*denied*)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ⚠ ${prefix} | $line" >> "$log_file" 2>/dev/null || true
        echo "   ⚠ ${prefix} | $line"
        ;;
      *)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ${prefix} | $line" >> "$log_file" 2>/dev/null || true
        ;;
    esac
  done
}

# 文件修复方法假成功黑名单: <文件相对路径> -> 全名集合（| 分隔，形如
# "文件修复方法1 copyto_original: ...|文件修复方法3 zip_split_original: ..."；
# 全名含空格所以不能用空格分隔）
# 由 sync_engine.sh 修复管线每轮从 marker 加载/重建，并在轮内即时检测时追加
declare -A FIX_METHOD_BLACKLIST=()
# 本轮已修复文件: <原始路径> -> <替代路径>（同一轮内避免 auto-split 子任务与最终
# 完整同步重复修复同一文件）
declare -A FIXED_THIS_RUN=()
# 本轮目录可写性结论: <目录远端路径> -> 1 可写 / 0 不可写
# （_fix_probe_dir_writable 的结论缓存: 同一目录整轮只探一次，避免同一目录下
#  的多个缺失文件各自触发一次 2 分钟的容器重启）
declare -A _DIR_WRITE_CACHE=()
# 本轮目录探测已用掉的容器重启次数（预算 OPENLIST_DIR_PROBE_MAX_RESTART）
_DIR_PROBE_RESTARTS=0

# 向黑名单追加方法（参数可以是短 ID 或全名，统一转全名存储）
# 用法: _blacklist_add <file_rel> <method_id_or_full_name>
_blacklist_add() {
  local entry
  entry=$(_fix_method_desc "$2")
  local cur="${FIX_METHOD_BLACKLIST[$1]:-}"
  case "|$cur|" in
    *"|$entry|"*) return 0 ;;
  esac
  FIX_METHOD_BLACKLIST["$1"]="${cur:+$cur|}${entry}"
}

# 判断当前文件（TRY_FIX_ORIGINAL）的某方法是否被黑名单
# 用法: _fix_method_blocked <method_id>  返回 0=被拉黑应跳过
_fix_method_blocked() {
  local entry
  entry=$(_fix_method_desc "$1")
  case "|${FIX_METHOD_BLACKLIST[${TRY_FIX_ORIGINAL:-}]:-}|" in
    *"|$entry|"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ===== 修复方法表驱动框架 =====
# 4 个方法共享同一骨架: 门禁（拉黑跳过）→ 执行 → 落盘校验 → 成功收尾。
# 以下函数与 try_fix_failed_file 通过 bash 动态作用域共享变量
# （fix_log / temp_dir / file_name / actual_dst_dir / used_base64_dir /
#   dest_path / failed_file_rel / SPLIT_LIMIT_BYTES 等）。

# 方法门禁: 未拉黑输出开始日志并返回 0；已拉黑输出跳过日志并返回 1
# 用法: _fix_method_gate <method_id> [开始日志附加文本] && { 方法体; }
_fix_method_gate() {
  local mid="$1" extra="${2:-}"
  if _fix_method_blocked "$mid"; then
    log_fix "$fix_log" "⏭  $(_fix_method_short "$mid")（已拉黑，跳过）"
    return 1
  fi
  log_fix "$fix_log" "▶ $(_fix_method_short "$mid")${extra}"
  return 0
}

# 修复方法成功收尾：写入 TRY_FIX_* 结果变量并清理临时目录
# 用法: _fix_succeed <method_id> <method_text> <alternative> <restore_text> [md5]
#   md5: 原文件内容指纹（try_fix 下载阶段统一计算，供还原时内容级校验；空=不可用）
_fix_succeed() {
  TRY_FIX_METHOD_ID="$(_fix_method_desc "$1")"
  TRY_FIX_STATUS="success"
  TRY_FIX_METHOD="$2"
  TRY_FIX_ALTERNATIVE="$3"
  TRY_FIX_RESTORE="$4"
  TRY_FIX_MD5="${5:-}"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 0
}

# 文件修复方法 3/4：zip 压缩 + 分卷上传（encode_name=1 时基底名改用短哈希，即方法4）
# 成功时完成 _fix_succeed 并返回 0；失败仅记日志返回 1
_try_fix_split_archive() {
  local mid="$1" encode_name="${2:-0}"
  local zip_base_name="$file_name"
  if [ "$encode_name" = "1" ]; then
    local sh_hash
    sh_hash=$(printf '%s' "$failed_file_rel" | md5sum | cut -c1-8)
    if [[ "$file_name" == *.* ]]; then
      zip_base_name="${sh_hash}.${file_name##*.}"
    else
      zip_base_name="${sh_hash}"
    fi
  fi
  local split_dir_local="${temp_dir}/split_${mid}"
  mkdir -p "$split_dir_local"
  local zip_base="${zip_base_name}.zip"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${zip_base}" "$file_name") 2>&1 | \
    _cmd_log "${mid}·zip" "$fix_log"
  local zip_path="${temp_dir}/${zip_base}"
  if [ ! -f "$zip_path" ]; then
    log_fix "$fix_log" "  ⚠ $(_fix_method_short "$mid") zip 未生成"
    return 1
  fi
  local zip_size
  zip_size=$(stat -c%s "$zip_path" 2>/dev/null || stat -f%z "$zip_path" 2>/dev/null || echo 0)
  local encode_note=""
  [ "$encode_name" = "1" ] && encode_note=", 文件名编码: $file_name -> $zip_base_name"
  log_fix "$fix_log" "  ${mid} zip 生成: ${zip_base} (${zip_size} bytes)${encode_note}"
  local all_uploaded=1
  local -a alt_files=()
  if [ "$zip_size" -gt "$SPLIT_LIMIT_BYTES" ]; then
    log_fix "$fix_log" "  ${mid} 单 zip >${SPLIT_PART_HUMAN}，切割分卷..."
    (cd "$split_dir_local" && split -b "$SPLIT_LIMIT_BYTES" -d -a 3 "$zip_path" "${zip_base}.") 2>&1 | \
      _cmd_log "${mid}·切" "$fix_log"
    local -a parts=("${split_dir_local}/"*)
    if [ ${#parts[@]} -gt 0 ]; then
      local i old bname num_suffix new_suffix prefix
      for ((i = ${#parts[@]} - 1; i >= 0; i--)); do
        old="${parts[$i]}"
        bname=$(basename -- "$old")
        num_suffix="${bname##*.}"
        if [[ "$num_suffix" =~ ^[0-9]+$ ]]; then
          new_suffix=$(printf '%03d' "$((10#$num_suffix + 1))")
          prefix="${bname%.*}"
          mv "$old" "${split_dir_local}/${prefix}.${new_suffix}" 2>/dev/null || true
        fi
      done
    fi
  else
    log_fix "$fix_log" "  ${mid} 单 zip <=${SPLIT_PART_HUMAN}，无需切割"
    cp "$zip_path" "${split_dir_local}/${zip_base}.001"
  fi
  local uploaded_count=0 total_parts=0
  local part_file part_bname dst_part part_rc part_expected part_dst_size alt_rel clean
  for part_file in "${split_dir_local}/"*; do
    [ -f "$part_file" ] || continue
    total_parts=$((total_parts + 1))
    part_bname=$(basename -- "$part_file")
    dst_part="${actual_dst_dir}/${part_bname}"
    rclone copyto "$part_file" "$dst_part" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_UPLOAD_TIMEOUT:-300}s" 2>&1 | \
      _cmd_log "${mid}·传${total_parts}" "$fix_log"
    part_rc=${PIPESTATUS[0]}
    part_expected=$(stat -c%s "$part_file" 2>/dev/null || stat -f%z "$part_file" 2>/dev/null || echo 0)
    part_dst_size=$(rclone size --json "$dst_part" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
    if [ "$part_rc" -eq 0 ] && [ "$part_dst_size" = "$part_expected" ] && [ "$part_dst_size" -gt 0 ]; then
      uploaded_count=$((uploaded_count + 1))
      alt_rel="${dst_part#${dest_path}/}"
      alt_files+=("$alt_rel")
      log_fix "$fix_log" "  ${mid} 分卷 ${total_parts} 上传成功 (${part_bname}, ${part_expected} bytes)"
    else
      log_fix "$fix_log" "  ${mid} 分卷 ${total_parts} 上传失败 (rc=$part_rc, size=$part_dst_size, expected=$part_expected)"
      all_uploaded=0
      for clean in "${alt_files[@]}"; do
        rclone deletefile "${dest_path}/${clean}" 2>/dev/null || true
      done
      alt_files=()
      break
    fi
  done
  log_fix "$fix_log" "  ${mid} 分卷上传汇总: $uploaded_count / $total_parts"
  if [ "$all_uploaded" -eq 1 ] && [ "$uploaded_count" -gt 0 ] && _confirm_persist_by_count "$(_fix_method_desc "$mid")" "$failed_file_rel" "$fix_log"; then
    log_fix "$fix_log" "  ✅ $(_fix_method_short "$mid") 成功（${uploaded_count} 分卷）"
    local dir_desc name_desc=""
    dir_desc=$(_fix_dir_desc)
    [ "$encode_name" = "1" ] && name_desc="短哈希文件名 + "
    local method_text="分卷 zip（${dir_desc} + ${name_desc}${SPLIT_PART_HUMAN} 分卷切割，共 ${uploaded_count} 卷）"
    local restore_text="下载所有分卷 ${zip_base}.001~$(printf '%03d' "$uploaded_count") 后 cat 合并再解压: cat ${zip_base}.0* > merged.zip && 7z x merged.zip"
    [ "$encode_name" = "1" ] && restore_text+="，原文件名恢复: 将解压后的文件重命名回 $file_name"
    _fix_succeed "$mid" "$method_text" "${alt_files[0]}" "$restore_text" "$file_md5"
    return 0
  fi
  log_fix "$fix_log" "  ❌ $(_fix_method_short "$mid") 失败（分卷未全部上传）"
  rm -rf "$split_dir_local" 2>/dev/null || true
  return 1
}

# 把当前 FIX_METHOD_BLACKLIST 数组即时合并写回 marker 的 fix_blacklist 字段
# 为什么不等任务结束统一保存: 持久化验证（重启容器复核）在修复循环之后执行，
# 其拉黑结论若只存于进程内变量，异常路径（子 shell/中断/变量丢失）下会丢——
# 实测 run 31917285452 拉黑 5 条最终保存 0 条。在事实发生的点位直接落盘。
# 用法: _flush_blacklist_to_marker <task_name> <dest_path> [log_file]
_flush_blacklist_to_marker() {
  local task_name="$1"
  local dest_path="$2"
  local log_file="${3:-/dev/null}"
  [ "${#FIX_METHOD_BLACKLIST[@]}" -gt 0 ] || return 0

  local marker_path bl_json
  marker_path=$(get_marker_path "$task_name" "$dest_path")
  bl_json=$(fix_blacklist_to_json)

  local old_marker merged
  old_marker=$(rclone cat "$marker_path" 2>/dev/null) || true
  if [ -n "$old_marker" ] && echo "$old_marker" | jq -e 'type == "object"' >/dev/null 2>&1; then
    merged=$(echo "$old_marker" | marker_merge_blacklist "$bl_json") || return 1
    [ -n "$merged" ] || return 1
  else
    merged=$(jq -cn --arg sp "" --arg dp "$dest_path" --argjson bl "$bl_json" \
      '{dest_path: $dp, fix_blacklist: $bl}')
  fi
  if _marker_write "$merged" "$marker_path" >/dev/null 2>&1; then
    echo "  ↳ 黑名单已即时写入 marker ($(echo "$bl_json" | jq 'length') 条)" | tee -a "$log_file"
  else
    echo "  ↳ ⚠️ 黑名单即时写入 marker 失败（任务结束的统一保存会兜底）" | tee -a "$log_file"
  fi
}

# OpenList 裸路径密文计数（刷新缓存后统计，任意 Crypt 挂载通用）
# count_dest 两种形态:
#   openlist:wopan176/...     —— 字面裸路径（dne=false 时有效）
#   :crypt,remote=...,...:sub —— crypt 即时远程（dne=true 时唯一正确口径，rclone
#                               自动按段加密路径查找并解密列出）
# refresh_path 为 OpenList 内部路径（如 /wopan176），用于计数前刷新后端缓存；
# 对 :crypt 形态必须传（无法从规格推导），对 openlist: 形态可省略（自动取）
# 用法: _raw_dir_count <count_dest> [refresh_ol_path]  → stdout 计数；失败返回非零
_raw_dir_count() {
  local raw_dest="$1"
  local refresh_path="${2:-}"
  if [[ "$raw_dest" == openlist:* ]]; then
    refresh_path="${refresh_path:-${raw_dest#openlist:}}"
  fi
  local ol_token
  ol_token=$(_get_openlist_token) || true
  if [ -n "$ol_token" ] && [ -n "$refresh_path" ]; then
    curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/json" \
      -d "{\"path\":\"/${refresh_path#/}\",\"recursive\":true}" \
      >/dev/null 2>&1 || true
    sleep 5
  fi
  local json count
  json=$(timeout "${OPENLIST_RAW_COUNT_TIMEOUT:-240}" rclone size "$raw_dest" --json 2>/dev/null) || return 1
  count=$(echo "$json" | jq -r '.count // empty' 2>/dev/null)
  [ -n "$count" ] && [[ "$count" =~ ^[0-9]+$ ]] || return 1
  echo "$count"
}

# 落盘即时校验（裸存储计数增量口径，openlist: 目标通用）
# 由 sync_engine.sh 修复管线初始化 _RAW_VERIFY_* 全局后启用（未初始化 = 未启用，
# 每次 return 0 纯直通）；Crypt 目标计数视图为裸存储解密口径（见
# _raw_count_view_for），普通挂载目标即目标路径自身。
#
# 功能: 修复方法返回成功（rc=0 / HTTP 2xx）后，立即确认数据是否真实落盘:
#   计数增长   → 真实持久化，返回 0
#   计数未增长 → 假成功：记日志、加入方法黑名单，返回 1（调用方落到
#               下一种修复方式，同轮不再复用失效方法）
#   预算耗尽 / 计数失败 → 无法判定，信任原结果返回 0（不误伤）
#   计数异常为 0（基准却 > 0）→ 列表未就绪（容器重启后驱动初始化中），
#     同样信任返回 0——绝不能据此判假成功，否则真实落盘的方法会被级联
#     误判、同一文件被换方法重复上传多份（run 31928671112 实测一轮内
#     同文件连传 9 个方法，全部真实落盘又全部被误判）
#
# 原理: 写入真实落盘 → 计数视图文件数必然 +1；计数不增长可断定数据
#   未进后端。基准 _RAW_VERIFY_LAST 由 _rebuild_raw_baseline 初始化、
#   随每次确认通过递增；_RAW_VERIFY_BUDGET 限制全量计数次数（大目录
#   rclone size 代价高，耗尽后退化为信任 rc，OPENLIST_RAW_CHECK_BUDGET
#   可调）。本层是当轮快速筛查，对"缓存有条目、后端无数据"的深层假
#   成功可能漏检（计数随缓存条目一起增长）——权威兜底是 sync_engine.sh 持久化
#   验证 _persist_verify_entries（重启容器后逐文件复核大小）。
#
# 用法: _confirm_persist_by_count <method_id> <file_rel> <log_file>
# 示例:
#   if [ "$m1_status" -eq 0 ] && _confirm_persist_by_count copyto_original "$rel" "$log"; then
#     echo "文件修复方法1 真实落盘"   # 计数增长（或计数不可用已信任放行）
#   else
#     echo "换下一方法"               # 假成功（文件修复方法1 已拉黑）或校验未启用
#   fi
_confirm_persist_by_count() {
  local method_id="$1" rel_path="$2" log_file="$3"
  # 未初始化即未启用（sync_engine.sh 修复管线仅对 openlist: 目标初始化）
  [[ -n "${_RAW_VERIFY_DEST:-}" ]] || return 0
  # 校验预算耗尽 → 退化为信任 rc（避免大目录反复全量计数拖垮同步）
  if [ "${_RAW_VERIFY_BUDGET:-0}" -le 0 ]; then
    return 0
  fi
  _RAW_VERIFY_BUDGET=$((_RAW_VERIFY_BUDGET - 1))
  local count=0
  local m_short
  m_short=$(_fix_method_short "$method_id")
  count=$(_raw_dir_count "$_RAW_VERIFY_DIR" "${_RAW_VERIFY_REFRESH:-}") || {
    log_fix "$log_file" "  ⚠️ raw 计数失败 → 信任返回值（${m_short}）"
    return 0
  }
  # 基准 > 0 而计数返回 0 → 不是"未增长"，是目录列表异常（驱动未就绪）
  if [ "$count" -eq 0 ] && [ "${_RAW_VERIFY_LAST:-0}" -gt 0 ]; then
    log_fix "$log_file" "  ⚠️ raw 计数异常为 0（基准 ${_RAW_VERIFY_LAST}，列表未就绪）→ 信任返回值（${m_short}）"
    return 0
  fi
  if [ "$count" -gt "${_RAW_VERIFY_LAST:--1}" ]; then
    _RAW_VERIFY_LAST=$count
    log_fix "$log_file" "  ✅ 落盘确认 raw=${_RAW_VERIFY_LAST}（${m_short}）"
    return 0
  fi
  log_fix "$log_file" "  🔴 假成功 raw 未增长 ${_RAW_VERIFY_LAST}→${count} → 拉黑 ${m_short}，换下一方法"
  _blacklist_add "$rel_path" "$method_id"
  return 1
}

# ===== 目录可写性预检（跑文件修复方法之前的定性步骤）=====
#
# 为什么必须在跑 4 种方法之前:
#   4 种方法（整文件下载 + copyto / zip 打包 + 分卷上传）全在同一目录里轮换，
#   若目录本身就是拒收根因（目录名过长/敏感词/整条加密路径超后端上限），
#   这 4 种方法连同整文件下载全是白跑——顽固文件每轮都要在同一条死路上
#   重付一次代价（大文件还要 7z 打包 + 逐卷上传）。先花几字节探针定性，
#   不可写就直接换短哈希目录。
#
# 为什么必须在重启后定论（缓存口径两个方向都不可信）:
#   OpenList 的 PUT 结果只存在于驱动内存缓存，不重启读到的永远是同一份被
#   污染的缓存（run 31951008332 实锤: 缓存计数与真值差 19 个假成功）。
#     - "写完 lsf 看得到" 证明不了可写: 目录若是假成功创建的，重启后
#       连目录带探针一起消失
#     - "看不到" 也证明不了不可写: 可能只是驱动未就绪的临时失败
#   故两个方向都以"重启容器 + 刷新路径缓存后探针是否仍可见"定论，
#   与 openlist_driver.sh 的结论一致: 唯一可靠口径 = 重启后从后端重拉。
#   缓存口径只用于诊断，以及预算耗尽/容器不可重启时的兜底（并明确标注）。
#
# 探针: 往目录写 olprobe_<8hex>.txt（几字节）→ 重启 → lsf 复核 → 删除。
#
# 判据只能是"重启后探针仍可见"，缓存口径一律不作数:
#   PUT 假成功在缓存里与真文件无异（run 31951008332 实锤缓存计数与真值差
#   19 个），所以"写完 lsf 看得到"什么都证明不了——目录本身若是假成功创建
#   的，重启后连目录带探针一起消失。反过来，缓存口径的"看不到"同样不作数
#   （可能只是驱动未就绪）。两个方向都必须以重启后的真值口径定论，
#   与 openlist_driver.sh 的结论一致: 唯一可靠口径 = 重启后从后端重拉。
#
# 成本控制（重启约 2 分钟/次，不可滥用）:
#   - 目录结论全局缓存 _DIR_WRITE_CACHE: 同一目录整轮只探一次
#   - 每轮重启预算 OPENLIST_DIR_PROBE_MAX_RESTART（默认 3）; 预算耗尽或容器
#     不可重启 → 退回缓存口径，并在结论里标注"未经重启确认"，
#     此时保守取缓存口径（无硬失败信号即按可写放行: 宁可白跑 4 种方法，
#     不可误判目录不可用而放弃原路径）
#   - 探针删除失败会永久抬高 raw 计数基准 → 补偿 _RAW_VERIFY_LAST，
#     否则下一个真实落盘的方法会被 _confirm_persist_by_count 判成假成功
#   - 重启会打乱 _RAW_VERIFY_LAST 基准 → _fix_rebase_after_restart 重建
#
# 依赖: utils.sh (log_fix) / openlist_driver.sh (_restart_openlist_for_truth)
# 用法: _fix_probe_dir_writable <dir_remote> <ol_dir 以 / 开头>
#   返回 0=可写，1=不可写
_fix_probe_dir_writable() {
  local dir_remote="$1" ol_dir="${2:-}"
  local probe_timeout="${OPENLIST_DIR_PROBE_TIMEOUT:-120}s"

  # 整轮缓存: 同一目录只探一次（同一目录的结论不会在几分钟内翻转）
  local cached="${_DIR_WRITE_CACHE[$dir_remote]:-}"
  if [ -n "$cached" ]; then
    log_fix "$fix_log" "   🔎 目录可写性（沿用本轮结论 ${cached%%|*}，${cached#*|}）"
    [ "${cached%%|*}" = "1" ]
    return $?
  fi

  local probe_name probe_local probe_dst
  probe_name="olprobe_$(printf '%s' "${dir_remote}$$" | md5sum | cut -c1-8).txt"
  probe_local="${temp_dir}/${probe_name}"
  probe_dst="${dir_remote}/${probe_name}"
  printf '%s' "openlist dir probe" > "$probe_local" 2>/dev/null || true

  log_fix "$fix_log" "   🔎 预检目录可写性: $(_short_path "$dir_remote")"

  # 第一次探测（缓存口径）: 只用于诊断与"预算耗尽时的兜底判据"，不作定论
  rclone copyto "$probe_local" "$probe_dst" "${RCLONE_RETRY_FLAGS[@]}" --timeout "$probe_timeout" 2>&1 | \
    _cmd_log 目录探测 "$fix_log"
  local prc=${PIPESTATUS[0]}
  local seen_cache=0
  if [ "$prc" -eq 0 ]; then
    if rclone lsf "$dir_remote" --files-only --retries 1 --timeout "$probe_timeout" 2>/dev/null \
       | grep -qxF "$probe_name"; then
      seen_cache=1
    fi
  fi
  log_fix "$fix_log" "   缓存口径: rc=${prc}, 探针可见=${seen_cache}（不作判据）"

  local writable="$seen_cache"
  local note="未经重启确认（缓存口径，不可信）"
  if [ "${_DIR_PROBE_RESTARTS:-0}" -ge "${OPENLIST_DIR_PROBE_MAX_RESTART:-3}" ]; then
    log_fix "$fix_log" "   ⚠️ 本轮目录探测重启预算已耗尽（${OPENLIST_DIR_PROBE_MAX_RESTART:-3} 次），退回缓存口径"
  elif _restart_openlist_for_truth "${ol_dir#/}" "$fix_log"; then
    _DIR_PROBE_RESTARTS=$((_DIR_PROBE_RESTARTS + 1))
    # 重启会让假成功条目从计数视图消失（计数下降），重启前建立的基准随之
    # 虚高 → 后续真实落盘的方法全被判"未增长"级联拉黑，必须重建
    _fix_rebase_after_restart "$fix_log"
    local seen_truth=0
    if rclone lsf "$dir_remote" --files-only --retries 1 --timeout "$probe_timeout" 2>/dev/null \
       | grep -qxF "$probe_name"; then
      seen_truth=1
    fi
    writable="$seen_truth"
    note="已重启确认"
    if [ "$seen_truth" -eq 1 ]; then
      log_fix "$fix_log" "   ✅ 目录可写（重启后探针仍在）"
    else
      # 目录是假成功创建的、或写入根本没落盘——都是"这个目录写不进去"
      log_fix "$fix_log" "   ❌ 目录不可写（重启后探针消失: 写入未真正落盘）"
    fi
  else
    log_fix "$fix_log" "   ⚠️ 容器重启不可用，退回缓存口径"
  fi

  # 探针清理: 残留会污染目标端，且会永久抬高 raw 计数基准
  rclone deletefile "$probe_dst" "${RCLONE_RETRY_FLAGS[@]}" --timeout "$probe_timeout" >/dev/null 2>&1
  if rclone lsf "$dir_remote" --files-only --retries 1 --timeout "$probe_timeout" 2>/dev/null \
     | grep -qxF "$probe_name"; then
    log_fix "$fix_log" "   ⚠️ 探测文件删除失败，raw 计数基准 +1 补偿（避免真实落盘被误判假成功）"
    [ "${_RAW_VERIFY_LAST:-0}" -gt 0 ] && _RAW_VERIFY_LAST=$((_RAW_VERIFY_LAST + 1))
  fi

  # 结论带上可信度标注: 排查时一眼能看出这条判定是否经过重启确认，
  # 避免把缓存口径的结论当真值用
  log_fix "$fix_log" "   结论: 可写=${writable}（${note}）"
  _DIR_WRITE_CACHE["$dir_remote"]="${writable}|${note}"
  [ "$writable" -eq 1 ]
  return $?
}

# 目录预检重启后，重建落盘即时校验（_confirm_persist_by_count）的计数基准
# 为什么必须重建: 基准 _RAW_VERIFY_LAST 是重启前建立的，重启后假成功条目
#   从计数视图消失（计数下降），基准随之虚高于实际 → 之后每一个真实落盘的
#   方法都会被判"计数未增长"→ 拉黑 → 换方法 → 再拉黑，一轮内同文件连传
#   多个方法全被误判（run 31928671112 实锤一轮 9 个方法全是这个下场）。
# 预算不因重建而回满: 取重建前后的较小值（重建只是取基准，不该把已消耗的
#   全量计数次数补满）
# 用法: _fix_rebase_after_restart <log_file>
_fix_rebase_after_restart() {
  local log_file="$1"
  # 未启用落盘即时校验时无需重建；部分测试只 source file_fix.sh，
  # file_fix_pipeline.sh 的重建函数可能不存在——两种都直接放行
  [ -n "${_RAW_VERIFY_DIR:-}" ] || return 0
  if ! declare -F _rebuild_raw_baseline >/dev/null 2>&1; then
    return 0
  fi
  local budget_before="${_RAW_VERIFY_BUDGET:-0}"
  _rebuild_raw_baseline "$log_file" || true
  if [ "$budget_before" -gt 0 ] && [ "${_RAW_VERIFY_BUDGET:-0}" -gt "$budget_before" ]; then
    _RAW_VERIFY_BUDGET="$budget_before"
  fi
}

# ===== 目录级兜底: 短哈希目录 =====
# 产出短哈希目录名: 整条相对目录路径的 md5 前 8 位（定长 8 字符）
# 折叠整条路径而非只替换末层的理由见 _fix_switch_to_hash_dir 头部注释
# 用法: _hash_dir_rel_for <file_dir_rel>  → stdout: 8 位 hex
_hash_dir_rel_for() {
  printf '%s' "$1" | md5sum | cut -c1-8
}

# 本轮所在目录的可读描述（三态，供方法文案与还原说明统一取用——
# 各方法里各写一套 if/else 文案，迟早与实际落盘目录不一致）
# 依赖调用方作用域: used_hash_dir / HASH_DIR_REL / used_base64_dir
# 用法: _fix_dir_desc → stdout: 原路径 | base64URL 编码目录 | 短哈希目录 <hash>
_fix_dir_desc() {
  if [ "${used_hash_dir:-0}" -eq 1 ]; then
    echo "短哈希目录 ${HASH_DIR_REL}"
  elif [ "${used_base64_dir:-0}" -eq 1 ]; then
    echo "base64URL 编码目录"
  else
    echo "原路径"
  fi
}

# ===== 目录内的方法轮换（一轮 = 4 种文件修复方法各试一次）=====
# try_fix_failed_file 最多调用两次: 先在 Step 1 定下的目录跑一轮，全败后由
# _fix_switch_to_hash_dir 换到短哈希目录再跑一轮。抽成函数保证两轮的行为与
# 文案完全一致（两条路径各自演化必然漂移，历史已多次吃过这个亏）。
# 依赖调用方作用域（bash 动态作用域）: fix_log / src_file / local_file /
#   file_name / actual_dst_dir / used_base64_dir / used_hash_dir / HASH_DIR_REL /
#   dest_path / failed_file_rel / file_md5 / temp_dir
# 用法: _try_fix_methods_round
#   返回 0=某方法成功（TRY_FIX_* 已由 _fix_succeed 就绪），1=本轮全败
_try_fix_methods_round() {
  # 目标一律由 actual_dst_dir 推导: base64URL 降级时 dst_file 已被改写，
  # 短哈希目录轮更是只改 actual_dst_dir，直接用 dst_file 会写回旧目录
  local round_file="${actual_dst_dir}/${file_name}"

  # 方法 1 copyto_original：直接 rclone copyto（当前目录 + 原文件名）
  if _fix_method_gate copyto_original; then
    local m1_status
    rclone copyto "$src_file" "$round_file" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_UPLOAD_TIMEOUT:-300}s" 2>&1 | \
      _cmd_log copyto_original "$fix_log"
    m1_status=${PIPESTATUS[0]}
    if [ "$m1_status" -eq 0 ] && _confirm_persist_by_count copyto_original "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 文件修复方法1 成功"
      local m1_alt m1_restore
      if [ "${used_hash_dir:-0}" -eq 1 ] || [ "$used_base64_dir" -eq 1 ]; then
        m1_alt="${round_file#${dest_path}/}"
        m1_restore="rclone move '${round_file}' '${dest_path}/${failed_file_rel}'"
      else
        m1_alt="$failed_file_rel"
        m1_restore="无需还原（文件已在正确路径）"
      fi
      _fix_succeed copyto_original "rclone copyto（$(_fix_dir_desc) + 原文件名）" \
        "$m1_alt" "$m1_restore" "$file_md5"
      return 0
    fi
    log_fix "$fix_log" "  ❌ 文件修复方法1 失败 exit=$m1_status"
  fi

  # 方法 2 copyto_shorthash：短哈希文件名直传
  # <md5前8位>.<扩展名> — 密文名必然远低于 255 字节上限，对症"加密后文件名超长" 或敏感字符
  if _fix_method_gate copyto_shorthash; then
    local sh_hash sh_name m2sh_dst m2sh_status
    sh_hash=$(printf '%s' "$failed_file_rel" | md5sum | cut -c1-8)
    if [[ "$file_name" == *.* ]]; then
      sh_name="${sh_hash}.${file_name##*.}"
    else
      sh_name="$sh_hash"
    fi
    m2sh_dst="${actual_dst_dir}/${sh_name}"
    log_fix "$fix_log" "  文件名: ${file_name} → ${sh_name}"
    rclone copyto "$local_file" "$m2sh_dst" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_UPLOAD_TIMEOUT:-300}s" 2>&1 | \
      _cmd_log copyto_shorthash "$fix_log"
    m2sh_status=${PIPESTATUS[0]}
    if [ "$m2sh_status" -eq 0 ] && _confirm_persist_by_count copyto_shorthash "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 文件修复方法2 成功"
      _fix_succeed copyto_shorthash \
        "rclone copyto（$(_fix_dir_desc) + 短哈希文件名 ${sh_hash}）" \
        "${m2sh_dst#${dest_path}/}" \
        "rclone move '${m2sh_dst}' '${dest_path}/${failed_file_rel}'  # 原文件名: ${file_name}" \
        "$file_md5"
      return 0
    fi
    log_fix "$fix_log" "  ❌ 文件修复方法2 失败 exit=$m2sh_status"
  fi

  # ============================================================
  # 方法 3/4：压缩并分卷上传（粒度默认 1GB）
  #   文件修复方法3 zip_split_original  — 基底名用原文件名
  #   文件修复方法4 zip_split_shorthash — 基底名用短哈希名（encode_name=1）
  # ============================================================
  local SPLIT_LIMIT_BYTES="${OPENLIST_SPLIT_PART_BYTES:-1073741824}"
  local SPLIT_PART_HUMAN
  SPLIT_PART_HUMAN=$(format_bytes_iec "$SPLIT_LIMIT_BYTES")
  _fix_method_gate zip_split_original "（粒度 ${SPLIT_PART_HUMAN}）" && { _try_fix_split_archive zip_split_original 0 && return 0; }
  _fix_method_gate zip_split_shorthash && { _try_fix_split_archive zip_split_shorthash 1 && return 0; }

  log_fix "$fix_log" "  ❌ 本轮 4 种方法全部失败（目录: $(_fix_dir_desc)）"
  return 1
}

# ===== 目录切换: 整条目录折叠为短哈希目录 =====
# 两个调用入口（都在 try_fix_failed_file 里）:
#   1. Step 2 预检判定原目录不可写 → 立刻切换，连整文件下载都省掉
#   2. Step 5 原目录 4 种方法全败 → 兜底切换（预检只能证明几字节探针能写，
#      证明不了这个文件能写: 内容级拒收、文件名/密文名超限等都可能）
# 两个入口共用本函数，切换后一律对新目录做可写性预检
# 不适用: file_dir_rel = "." （目标端根目录的文件无目录可换）
#
# 为什么必须有这一级（既有链路的死角）:
#   Step 1 的 base64URL 编码目录只在"目录创建失败"时降级，是被动兜底。
#   目录已存在（同目录其余文件都同步成功）但写入被拒时 mkdir/lsd 双双返回 0
#   → used_base64_dir=0，4 种方法全在原目录里重试，整条链路没有任何
#   "换目录"的分支。于是"目录名过长 / 目录名含敏感词 / 整条加密路径超后端
#   上限"这类根因永远无法自愈（backup 任务的 options.xml 即此形态）。
#
# 为什么折叠整条目录路径，而不是像 base64URL 那样只替换末层:
#   - 敏感词可能出现在任一层，只换末层无效
#   - base64URL 编码对"名长"是反向的（编码后比原名更长，crypt 加密后更甚），
#     只有定长 8 字符的哈希目录能真正压短整条路径
#   代价: 目标端根目录出现 8 位十六进制目录、目录结构丢失。哈希不可逆，
#   原目录名只能从 marker 的 original 字段取——还原必须走 marker 的
#   original/alternative 映射，不能像 base64URL 那样就地解码
#   （restore_info.jq 的 hash_dir 分支据此编写）。
#
# 目录换了，该文件的方法黑名单必须清空:
#   黑名单记的是"某方法在某目录下失败/假成功"，换目录后结论失效；沿用会让
#   本轮所有方法被 _fix_method_gate 直接跳过，兜底白跑一趟。
# 开关: OPENLIST_HASH_DIR_FALLBACK=0 关闭
# 依赖调用方作用域: fix_log / dest_path / ol_dst_base / failed_file_rel /
#   file_dir_rel / temp_dir；成功时改写 actual_dst_dir / used_hash_dir / HASH_DIR_REL
# 用法: _fix_switch_to_hash_dir → 0=已切到可写的短哈希目录，1=未能切换
_fix_switch_to_hash_dir() {
  [ "${OPENLIST_HASH_DIR_FALLBACK:-1}" = "0" ] && return 1
  if [ "$file_dir_rel" = "." ] || [ -z "$file_dir_rel" ]; then
    log_fix "$fix_log" "⏭ 文件位于目标端根目录，无目录可换，跳过短哈希目录兜底"
    return 1
  fi
  if [ "${used_base64_dir:-0}" -eq 1 ]; then
    log_fix "$fix_log" "⏭ 已降级到 base64URL 编码目录，不再叠加短哈希目录"
    return 1
  fi

  HASH_DIR_REL=$(_hash_dir_rel_for "$file_dir_rel")
  if [ -z "$HASH_DIR_REL" ]; then
    log_fix "$fix_log" "⚠ 短哈希目录名计算失败，跳过兜底"
    return 1
  fi
  local hash_dst_dir="${dest_path}/${HASH_DIR_REL}"
  local hash_ol_dir="/${ol_dst_base}/${HASH_DIR_REL}"
  log_fix "$fix_log" "🔀 目录级兜底: 整条目录折叠为短哈希目录 ${HASH_DIR_REL}"
  log_fix "$fix_log" "   原目录: ${file_dir_rel}"

  # 创建 + lsd 复核（同 Step 1 口径: mkdir 返回 0 也必须复核，防 WebDAV 静默失败）
  local hash_dir_ok=0
  rclone mkdir "$hash_dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" 2>&1 | \
    _cmd_log mkdir+hash "$fix_log"
  local mkdir_status=${PIPESTATUS[0]}
  if [ "$mkdir_status" -eq 0 ]; then
    rclone lsd "$hash_dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      hash_dir_ok=1
      log_fix "$fix_log" "   ✅ 短哈希目录已确认存在"
    else
      log_fix "$fix_log" "   ⚠ 短哈希目录 lsd 复核失败，尝试 OpenList API..."
    fi
  else
    log_fix "$fix_log" "   ⚠ rclone mkdir 失败 exit=${mkdir_status}，尝试 OpenList API..."
  fi

  if [ "$hash_dir_ok" -ne 1 ]; then
    local ol_token
    ol_token=$(_get_openlist_token 2>/dev/null) || ol_token=""
    if [ -n "$ol_token" ]; then
      local mkdir_resp mkdir_http
      mkdir_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "$hash_ol_dir" '{path:$path}')" 2>&1)
      mkdir_http=$(echo "$mkdir_resp" | tail -n 1)
      log_fix "$fix_log" "   OpenList API mkdir (短哈希) 响应: ${mkdir_http}"
      if echo "$mkdir_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
        hash_dir_ok=1
        log_fix "$fix_log" "   ✅ 短哈希目录创建成功 (API)"
      fi
    fi
  fi

  if [ "$hash_dir_ok" -ne 1 ]; then
    log_fix "$fix_log" "   ❌ 短哈希目录创建失败，兜底终止"
    return 1
  fi

  # 改写本轮落盘目录（不加 local: 写回 try_fix_failed_file 作用域）
  actual_dst_dir="$hash_dst_dir"
  actual_ol_dir="$hash_ol_dir"
  used_hash_dir=1

  # 目录已换 → 原目录下的方法结论作废（黑名单记的是"某方法在某目录下
  # 失败/假成功"，沿用会让本轮所有方法被门禁直接跳过）
  if [ -n "${FIX_METHOD_BLACKLIST[$failed_file_rel]+x}" ]; then
    log_fix "$fix_log" "   ♻ 目录已换，清空方法黑名单（原目录下的失败/假成功结论不再适用）"
    unset "FIX_METHOD_BLACKLIST[$failed_file_rel]"
  fi

  # 短哈希目录同样要先过可写性预检: 建得出目录 ≠ 写得进文件。
  # 不过就立刻返回失败，省掉一趟整文件下载 + 4 次上传
  log_fix "$fix_log" "   🔎 预检短哈希目录可写性..."
  if ! _fix_probe_dir_writable "$actual_dst_dir" "$actual_ol_dir"; then
    log_fix "$fix_log" "   ❌ 短哈希目录不可写（已重启容器复核），兜底终止"
    return 1
  fi
  log_fix "$fix_log" "   ✅ 短哈希目录可写，4 种文件修复方法将在此目录执行"
  return 0
}

try_fix_failed_file() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  local failed_file_rel="$4"
  local fix_log="$5"

  local src_file="${source_path}/${failed_file_rel}"
  local dst_file="${dest_path}/${failed_file_rel}"

  local file_name
  file_name="$(basename -- "$failed_file_rel")"
  local file_dir_rel
  file_dir_rel="$(dirname -- "$failed_file_rel")"
  local dst_dir="${dest_path}/${file_dir_rel}"

  # OpenList 内部路径（去掉 openlist: 前缀）
  local ol_dst_base="${dest_path#openlist:}"
  ol_dst_base="${ol_dst_base#/}"

  # 初始化结果变量
  TRY_FIX_STATUS="failed"
  TRY_FIX_ORIGINAL="$failed_file_rel"
  TRY_FIX_ALTERNATIVE=""
  TRY_FIX_METHOD=""
  TRY_FIX_METHOD_ID=""
  TRY_FIX_RESTORE=""
  TRY_FIX_MESSAGE=""
  TRY_FIX_MD5=""

  # 区段头（sync_notify.sh 按它切出每个文件的"修复过程"展示在通知里）:
  # 必须写完整相对路径——通知侧手里只有完整路径，若写成 _short_path 的截断值
  # 就对不上，提取结果恒为空 → 通知里只剩"修复过程：无记录"。
  # 该头部在 4e43120 日志美化时随旧写法一起消失，消费端 awk 自此空转:
  # 每个失败文件的 4 种方法到底报了什么错，通知里一行都看不到，
  # 只能回 Actions 翻原始日志。
  log_fix "$fix_log" "=== 尝试修复失败文件: ${failed_file_rel} ==="
  log_fix "$fix_log" "── 修复 $(_short_path "$failed_file_rel")"
  log_fix "$fix_log" "   源: $(_short_path "$src_file")"
  log_fix "$fix_log" "   目标: $(_short_path "$dst_file")"

  # 临时目录: 目录可写性探测（探针）必须先于下载完成，故在此创建
  # （顺序很重要——目录若不可写，整文件下载连同 4 种方法全是白跑）
  local temp_dir="temp_fix_$(date +%s)_$$"
  mkdir -p "$temp_dir"

  # ===== Step 1: 创建/确认目标目录 =====
  local dir_ok=0
  local used_base64_dir=0
  local actual_dst_dir="$dst_dir"
  local actual_ol_dir="/${ol_dst_base}/${file_dir_rel}"

  # 尝试 rclone mkdir
  log_fix "$fix_log" "📁 确保目标目录存在: $(_short_path "$dst_dir")"
  rclone mkdir "$dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" 2>&1 | \
    _cmd_log mkdir "$fix_log"
  local mkdir_status=${PIPESTATUS[0]}

  # rclone mkdir 退出码为 0 时仍需验证目录是否实际存在（WebDAV 可能静默失败）
  if [ "$mkdir_status" -eq 0 ]; then
    rclone lsd "$dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" >/dev/null 2>&1
    local verify_status=$?
    if [ "$verify_status" -eq 0 ]; then
      dir_ok=1
      log_fix "$fix_log" "✅ 目录已确认存在"
    else
      log_fix "$fix_log" "⚠ lsd 验证失败 exit=${verify_status}，目录未实际创建，降级处理"
    fi
  else
    log_fix "$fix_log" "⚠ mkdir 失败 exit=${mkdir_status}，尝试 OpenList API..."
  fi

  # 降级处理：mkdir 失败或 lsd 验证失败时执行（OpenList API + base64URL）
  if [ "$dir_ok" -ne 1 ]; then
    local ol_token
    ol_token=$(_get_openlist_token)
    if [ -n "$ol_token" ]; then
      local mkdir_resp mkdir_http
      mkdir_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "$actual_ol_dir" '{path:$path}')" 2>&1)
      mkdir_http=$(echo "$mkdir_resp" | tail -n 1)
      log_fix "$fix_log" "OpenList API mkdir 响应: ${mkdir_http}"
      if echo "$mkdir_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
        dir_ok=1
        log_fix "$fix_log" "OpenList API mkdir 成功"
      fi
    fi

    # 目录创建仍失败 → base64URL 编码最底层文件夹名后重试
    if [ "$dir_ok" -ne 1 ] && [ "$file_dir_rel" != "." ] && [ -n "$file_dir_rel" ]; then
      log_fix "$fix_log" "目录创建失败，尝试 base64URL 编码文件夹名..."

      local parent_dir leaf_dir encoded_leaf new_file_dir_rel
      parent_dir="$(dirname -- "$file_dir_rel")"
      leaf_dir="$(basename -- "$file_dir_rel")"
      encoded_leaf=$(b64url_encode "$leaf_dir")

      if [ "$parent_dir" = "." ]; then
        new_file_dir_rel="$encoded_leaf"
      else
        new_file_dir_rel="${parent_dir}/${encoded_leaf}"
      fi

      actual_dst_dir="${dest_path}/${new_file_dir_rel}"
      actual_ol_dir="/${ol_dst_base}/${new_file_dir_rel}"

      log_fix "$fix_log" "原始目录: $file_dir_rel"
      log_fix "$fix_log" "base64URL 编码目录: $new_file_dir_rel"

      rclone mkdir "$actual_dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" 2>&1 | \
        _cmd_log mkdir+b64 "$fix_log"
      mkdir_status=${PIPESTATUS[0]}

      if [ "$mkdir_status" -eq 0 ]; then
        log_fix "$fix_log" "rclone mkdir (base64URL) 退出码 0，用 rclone lsd 验证目录..."
        rclone lsd "$actual_dst_dir" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" >/dev/null 2>&1
        local b64_verify_status=$?
        if [ "$b64_verify_status" -eq 0 ]; then
          dir_ok=1
          used_base64_dir=1
          dst_file="${actual_dst_dir}/${file_name}"
          log_fix "$fix_log" "rclone lsd 验证成功 (base64URL)，目录已确认存在"
        else
          log_fix "$fix_log" "rclone lsd 验证失败 (base64URL, exit=$b64_verify_status)"
        fi
      fi

      if [ "$dir_ok" -ne 1 ] && [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
        mkdir_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
          -H "Authorization: $ol_token" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg path "$actual_ol_dir" '{path:$path}')" 2>&1)
        mkdir_http=$(echo "$mkdir_resp" | tail -n 1)
        log_fix "$fix_log" "OpenList API mkdir (base64URL) 响应: ${mkdir_http}"
        if echo "$mkdir_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
          dir_ok=1
          used_base64_dir=1
          dst_file="${actual_dst_dir}/${file_name}"
          log_fix "$fix_log" "base64URL 目录创建成功 (API)"
        fi
      fi
    fi
  fi

  if [ "$dir_ok" -ne 1 ]; then
    log_fix "$fix_log" "目录创建最终失败（含 base64URL 编码后），无法修复文件"
    TRY_FIX_MESSAGE="目录创建失败，base64URL 编码后仍失败"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 1
  fi

  # ===== Step 2: 目录可写性预检（跑 4 种方法之前先给目录定性）=====
  # 目录不可写时直接在下方换短哈希目录，连整文件下载都省掉——
  # 否则每个顽固文件都要在同一条死路上白跑"下载 + 4 次上传/打包"
  local used_hash_dir=0
  local HASH_DIR_REL=""
  log_fix "$fix_log" "📁 目标目录已就绪: $(_short_path "$actual_dst_dir")"

  if ! _fix_probe_dir_writable "$actual_dst_dir" "$actual_ol_dir"; then
    log_fix "$fix_log" "🔀 原目录不可写（已重启容器复核）→ 直接切短哈希目录，跳过原目录的 4 种方法"
    if ! _fix_switch_to_hash_dir; then
      log_fix "$fix_log" "❌ 短哈希目录同样不可写，无法修复文件"
      TRY_FIX_MESSAGE="目标目录不可写（原目录与短哈希目录均未通过可写性预检）"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 1
    fi
  fi

  # ===== Step 3: 目录已定性，下载源文件到本地 =====
  local local_file="$temp_dir/$file_name"
  log_fix "$fix_log" "⬇ 下载源文件到本地..."
  rclone copyto "$src_file" "$local_file" "${RCLONE_RETRY_FLAGS[@]}" --timeout "${OPENLIST_UPLOAD_TIMEOUT:-300}s" 2>&1 | \
    _cmd_log 下载 "$fix_log"
  local copy_status=${PIPESTATUS[0]}

  if [ "$copy_status" -ne 0 ] || [ ! -f "$local_file" ]; then
    log_fix "$fix_log" "❌ 下载源文件失败，跳过修复"
    TRY_FIX_MESSAGE="无法从源端下载文件"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 1
  fi

  local file_size
  file_size=$(stat -c%s "$local_file" 2>/dev/null || echo 0)
  log_fix "$fix_log" "✅ 已下载 $(format_bytes_iec "$file_size")"

  # 原文件内容指纹: 本地副本在此统一计算一次（下载失败早已短路），
  # 四种方法共享；写进 marker 后供还原时做内容级硬校验。
  # temp_dir 会被 _fix_succeed 清理，但 md5 值已捕获，不受影响。
  local file_md5
  file_md5=$(md5sum "$local_file" 2>/dev/null | awk '{print $1}')
  [[ "$file_md5" =~ ^[0-9a-f]{32}$ ]] || file_md5=""
  [ -n "$file_md5" ] && log_fix "$fix_log" "  md5: $file_md5"

  # ===== Step 4: 在已定性的目录跑 4 种方法 =====
  log_fix "$fix_log" "开始尝试多种方式同步到: ${actual_dst_dir}/${file_name}"
  if _try_fix_methods_round; then
    return 0
  fi

  # ===== Step 5: 兜底 —— 方法全败后再换一次短哈希目录 =====
  # 预检只能证明"几字节探针能写"，证明不了"这个文件能写"（内容级拒收、
  # 文件名/密文名超限等）。故保留这条兜底: 预检未切换过目录时才走
  if [ "$used_hash_dir" -eq 0 ] && [ "${OPENLIST_HASH_DIR_FALLBACK:-1}" != "0" ] \
     && [ "$file_dir_rel" != "." ] && [ -n "$file_dir_rel" ]; then
    log_fix "$fix_log" "🔀 4 种方法全败，兜底换短哈希目录再试一轮"
    if _fix_switch_to_hash_dir; then
      _try_fix_methods_round && return 0
    fi
  fi

  # 所有方法均失败
  log_fix "$fix_log" "❌ 全部修复方法（1-4）均失败（含短哈希目录兜底）"
  TRY_FIX_MESSAGE="所有修复方法均失败"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 1
}
