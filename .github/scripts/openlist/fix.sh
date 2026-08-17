#!/bin/bash
# ===== OpenList 同步工具 — 失败文件修复函数 =====
# 处理 OpenList/WebDAV 无法同步的文件（同步报错、diff 缺失、假成功未持久化等），尝试多种修复方式：
#   1. 创建目标目录（rclone mkdir → OpenList API mkdir → base64URL 编码目录名）
#   2. 多种方式同步文件（按对症优先级执行，首个真实成功即止）:
#      方法1:  直接 rclone copyto（原路径 + 原文件名）
#      方法2:  rclone crypt 直写裸存储（:crypt: 即时远程，文件以原名原路径
#              出现在 wopan176Crypt，绕过 OpenList crypt→后端驱动链路）
#      方法3:  短哈希文件名直传（<md5前8位>.<扩展名>，密文名必然不超长）
#      方法4:  zip 压缩后上传（存储模式）
#      方法5:  7z 压缩后上传（存储模式）
#      方法6:  zip 压缩 + 分卷上传（粒度默认 1GB，OPENLIST_SPLIT_PART_BYTES 可调）
#      方法7:  zip 压缩 + base64URL 文件名 + 分卷上传
#      方法8:  OpenList API /fs/form 直传（API 自动生成文件名）
#      方法9:  上传到父目录（跳过有问题的目录层级）
#      方法10: AES256 加密 zip 后上传（改变二进制特征）
#      方法11: 临时目录上传 + OpenList API move 移动
#   历史版本已删除的冗余/低效方法（编号已重新连续分配，旧 marker 不兼容）:
#      base64URL 文件名单传 / 重命名 .bak — 编码让名字更长，对"密文名超长"根因
#      反向加压（被方法3 短哈希名取代）
#      /fs/put 到根目录、根目录+hash 名 — 与方法8 同机制的冗余变体
#      base64 编码内容 — crypt 目标内容本就是密文，33% 膨胀纯浪费
#
# 假成功防护（两层）:
#   1. 落盘即时校验（_confirm_persist_by_count）: 修复方法返回成功后，对比
#      目标侧（裸存储计数视图）文件计数是否增长。未增长 = 假成功 → 该方法
#      加入黑名单，立即尝试下一种方式。属于快速筛查层；"缓存有条目但后端
#      无数据"的深层假成功可能漏检，由第 2 层重启复核兜底。
#   2. 失败记忆（FIX_METHOD_BLACKLIST + marker fix_blacklist 字段）:
#      持久化每文件已判定假成功的方法（marker 存方法全名，| 分隔）。
#      sync.sh 持久化验证（_persist_verify_entries，重启容器后逐文件复核）
#      发现假成功后，本轮立即换方法重试（黑名单让 try_fix_failed_file
#      直接跳过失效方法）；跨轮修复同样跳过，避免方法1 每轮都白白"成功"
#      一次再被发现。
#
# 依赖: utils.sh (log_fix, _get_openlist_token), telegram.sh (间接)
# 结果写入全局变量:
#   TRY_FIX_STATUS       — "success" 或 "failed"
#   TRY_FIX_ORIGINAL     — 原始文件相对路径
#   TRY_FIX_ALTERNATIVE  — 实际上传后的文件相对路径
#   TRY_FIX_METHOD       — 使用的修复方法描述
#   TRY_FIX_METHOD_ID    — 使用的修复方法全名（供黑名单/marker 记录，即 _method_desc 输出）
#   TRY_FIX_RESTORE      — 还原方法描述（如何从 ALTERNATIVE 还原到 ORIGINAL）
#   TRY_FIX_MESSAGE      — 失败原因（仅 status=failed 时）

# 从 OpenList 数据库（sqlite）读取指定挂载的 addition JSON（API 失败时的兜底）
# 数据库本地化后 data.db 在 runner 本地 /opt/openlist-data/ 下（旧路径保留兜底）
# 先拷贝到 /tmp 避免与运行中容器的文件锁冲突（WAL 一并拷贝）
# 用法: _get_addition_from_db <mount_path 如 /wopan176Crypt>
_get_addition_from_db() {
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
  python3 - "$db_local" "$mount" <<'PY'
import sqlite3, sys
db, mount = sys.argv[1], sys.argv[2]
def norm(p):
    return (p or "").strip().strip("/")
def dump(con):
    rows = con.execute("SELECT mount_path, addition FROM x_storages").fetchall()
    for mp, add in rows:
        if norm(mp) == norm(mount):
            if add:
                print(add)
                sys.exit(0)
            print(f"目标 {mount} 的 addition 为空", file=sys.stderr)
            sys.exit(3)
    names = ", ".join(norm(mp) or "?" for mp, _ in rows) or "(空表)"
    print(f"x_storages 中无 {mount}; 现有: {names}", file=sys.stderr)
    sys.exit(4)
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    dump(con)
except sqlite3.Error as e:
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
        dump(con)
    except sqlite3.Error as e2:
        print(f"sqlite 读取失败: {e}; immutable 重试: {e2}", file=sys.stderr)
        sys.exit(5)
PY
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

# 从 OpenList API 提取 crypt 存储配置（供方法2 rclone crypt 直写使用）
# OpenList crypt 驱动与 rclone crypt 格式兼容，addition.password 即 rclone obscure 格式
# 输出: "<obscured_password> <filename_encryption> <directory_name_encryption> <underlying_remote>"
# underlying_remote 形如 openlist:wopan176（addition.path 优先，缺失时按 Crypt 后缀名推导）
# 注意: admin API 的 addition 是 JSON 编码字符串（run 31918439043 实测 .password 直接
#       取值为空 → 方法2 crypt 直写一直被跳过），必须 fromjson 解码；API 401/无数据时
#       从本地 data.db 兜底
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
    why="token 不可用（config.json 无 token/jwt_secret）"
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
    addition=$(_get_addition_from_db "$mount" 2>"$db_err") || addition=""
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

# 确保 crypt 配置已缓存到全局（方法2 直写与名长诊断共用，每任务只拉取一次）
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
  # 不能复用彼此的配置（否则方法2 会把密文写进错误的后端）
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
# rclone 没有 cryptencode 命令（sync.sh 旧代码调用它一直静默失败，名长诊断
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
# 用法: _method_desc <method_id 如 m2>  → stdout: "方法2: rclone crypt 直写裸存储（...）"
_method_desc() {
  case "$1" in
    m1)  echo "方法1: 直接 rclone copyto（原路径 + 原文件名）" ;;
    m2)  echo "方法2: rclone crypt 直写裸存储（原名原路径，绕过 OpenList crypt 驱动）" ;;
    m3)  echo "方法3: 短哈希文件名直传（<md5前8位>.<扩展名>）" ;;
    m4)  echo "方法4: zip 压缩后上传（存储模式）" ;;
    m5)  echo "方法5: 7z 压缩后上传（存储模式）" ;;
    m6)  echo "方法6: zip 压缩 + 分卷上传（默认 1GB 分卷）" ;;
    m7)  echo "方法7: zip 压缩 + base64URL 文件名 + 分卷上传" ;;
    m8)  echo "方法8: OpenList API /fs/form 直传（API 自动生成文件名）" ;;
    m9)  echo "方法9: 上传到父目录（跳过有问题的目录层级）" ;;
    m10) echo "方法10: AES256 加密 zip 后上传（改变二进制特征）" ;;
    m11) echo "方法11: 临时目录上传 + OpenList API move 移动" ;;
    *)   echo "$1" ;;
  esac
}

# 方法短标签（仅日志展示用；marker/黑名单仍存 _method_desc 全名）
# 输入短 ID（m1）或全名（方法1: ...）均可，注意 m10/m11 要在 m1 之前匹配
_method_short() {
  case "$1" in
    m10|方法10:*) echo "方法10·AES zip" ;;
    m11|方法11:*) echo "方法11·临时目录+move" ;;
    m1|方法1:*)   echo "方法1·copyto 原名" ;;
    m2|方法2:*)   echo "方法2·crypt 直写" ;;
    m3|方法3:*)   echo "方法3·短哈希名" ;;
    m4|方法4:*)   echo "方法4·zip 打包" ;;
    m5|方法5:*)   echo "方法5·7z 打包" ;;
    m6|方法6:*)   echo "方法6·zip 分卷" ;;
    m7|方法7:*)   echo "方法7·b64名分卷" ;;
    m8|方法8:*)   echo "方法8·API form" ;;
    m9|方法9:*)   echo "方法9·上传父目录" ;;
    "") echo "未知方法" ;;
    *) _method_desc "$1" ;;
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

# 方法假成功黑名单: <文件相对路径> -> "方法1: ...|方法3: ..."（| 分隔的方法全名集合，
# 全名含空格所以不能用空格分隔）
# 由 sync.sh 修复管线每轮从 marker 加载/重建，并在轮内即时检测时追加
declare -A FIX_METHOD_BLACKLIST=()
# 本轮已修复文件: <原始路径> -> <替代路径>（同一轮内避免 auto-split 子任务与最终
# 完整同步重复修复同一文件）
declare -A FIXED_THIS_RUN=()

# 向黑名单追加方法（参数可以是短 ID 或全名，统一转全名存储）
# 用法: _blacklist_add <file_rel> <method_id_or_full_name>
_blacklist_add() {
  local entry
  entry=$(_method_desc "$2")
  local cur="${FIX_METHOD_BLACKLIST[$1]:-}"
  case "|$cur|" in
    *"|$entry|"*) return 0 ;;
  esac
  FIX_METHOD_BLACKLIST["$1"]="${cur:+$cur|}${entry}"
}

# 判断当前文件（TRY_FIX_ORIGINAL）的某方法是否被黑名单
# 用法: _method_blocked <method_id>  返回 0=被拉黑应跳过
_method_blocked() {
  local entry
  entry=$(_method_desc "$1")
  case "|${FIX_METHOD_BLACKLIST[${TRY_FIX_ORIGINAL:-}]:-}|" in
    *"|$entry|"*) return 0 ;;
    *) return 1 ;;
  esac
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
  bl_json="{}"
  local f
  for f in "${!FIX_METHOD_BLACKLIST[@]}"; do
    bl_json=$(jq -cn --argjson j "$bl_json" --arg k "$f" --arg v "${FIX_METHOD_BLACKLIST[$f]}" \
      '$j + {($k): $v}' 2>/dev/null) || bl_json="{}"
  done

  local old_marker merged
  old_marker=$(rclone cat "$marker_path" 2>/dev/null) || true
  if [ -n "$old_marker" ] && echo "$old_marker" | jq -e 'type == "object"' >/dev/null 2>&1; then
    merged=$(echo "$old_marker" | jq -c --argjson bl "$bl_json" \
      '. + {fix_blacklist: ((.fix_blacklist // {}) * $bl)}' 2>/dev/null) || return 1
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

# wopan176 裸路径密文计数（刷新缓存后统计）
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
# 由 sync.sh 修复管线初始化 _RAW_VERIFY_* 全局后启用（未初始化 = 未启用，
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
#   成功可能漏检（计数随缓存条目一起增长）——权威兜底是 sync.sh 持久化
#   验证 _persist_verify_entries（重启容器后逐文件复核大小）。
#
# 用法: _confirm_persist_by_count <method_id> <file_rel> <log_file>
# 示例:
#   if [ "$m1_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m1)" "$rel" "$log"; then
#     echo "方法1 真实落盘"      # 计数增长（或计数不可用已信任放行）
#   else
#     echo "换下一方法"          # 假成功（方法1 已拉黑）或校验未启用
#   fi
_confirm_persist_by_count() {
  local method_id="$1" rel_path="$2" log_file="$3"
  # 未初始化即未启用（sync.sh 修复管线仅对 openlist: 目标初始化）
  [[ -n "${_RAW_VERIFY_DEST:-}" ]] || return 0
  # 校验预算耗尽 → 退化为信任 rc（避免大目录反复全量计数拖垮同步）
  if [ "${_RAW_VERIFY_BUDGET:-0}" -le 0 ]; then
    return 0
  fi
  _RAW_VERIFY_BUDGET=$((_RAW_VERIFY_BUDGET - 1))
  local count=0
  local m_short
  m_short=$(_method_short "$method_id")
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

  log_fix "$fix_log" "── 修复 $(_short_path "$failed_file_rel")"
  log_fix "$fix_log" "   源: $(_short_path "$src_file")"
  log_fix "$fix_log" "   目标: $(_short_path "$dst_file")"

  # 下载源文件到本地临时目录
  local temp_dir="temp_fix_$(date +%s)_$$"
  mkdir -p "$temp_dir"
  local local_file="$temp_dir/$file_name"

  log_fix "$fix_log" "⬇ 下载源文件到本地..."
  rclone copyto "$src_file" "$local_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
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
  log_fix "$fix_log" "✅ 已下载 $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "${file_size}B")"

  # ===== Step 1: 创建/确认目标目录 =====
  local dir_ok=0
  local used_base64_dir=0
  local actual_dst_dir="$dst_dir"
  local actual_ol_dir="/${ol_dst_base}/${file_dir_rel}"

  # 尝试 rclone mkdir
  log_fix "$fix_log" "📁 确保目标目录存在: $(_short_path "$dst_dir")"
  rclone mkdir "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
    _cmd_log mkdir "$fix_log"
  local mkdir_status=${PIPESTATUS[0]}

  # rclone mkdir 退出码为 0 时仍需验证目录是否实际存在（WebDAV 可能静默失败）
  if [ "$mkdir_status" -eq 0 ]; then
    rclone lsd "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s >/dev/null 2>&1
    local verify_status=$?
    if [ "$verify_status" -eq 0 ]; then
      dir_ok=1
      log_fix "$fix_log" "✅ 目录已确认存在"
    else
      log_fix "$fix_log" "⚠ lsd 验证失败 exit=$verify_status，目录未实际创建，降级处理"
    fi
  else
    log_fix "$fix_log" "⚠ mkdir 失败 exit=$mkdir_status，尝试 OpenList API..."
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
      encoded_leaf=$(printf '%s' "$leaf_dir" | base64 | tr '+/' '-_' | tr -d '=')

      if [ "$parent_dir" = "." ]; then
        new_file_dir_rel="$encoded_leaf"
      else
        new_file_dir_rel="${parent_dir}/${encoded_leaf}"
      fi

      actual_dst_dir="${dest_path}/${new_file_dir_rel}"
      actual_ol_dir="/${ol_dst_base}/${new_file_dir_rel}"

      log_fix "$fix_log" "原始目录: $file_dir_rel"
      log_fix "$fix_log" "base64URL 编码目录: $new_file_dir_rel"

      rclone mkdir "$actual_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
        _cmd_log mkdir+b64 "$fix_log"
      mkdir_status=${PIPESTATUS[0]}

      if [ "$mkdir_status" -eq 0 ]; then
        log_fix "$fix_log" "rclone mkdir (base64URL) 退出码 0，用 rclone lsd 验证目录..."
        rclone lsd "$actual_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s >/dev/null 2>&1
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

  # ===== Step 2: 目录已就绪，尝试多种方式同步文件 =====
  log_fix "$fix_log" "目录已就绪，开始尝试多种方式同步到: $dst_file"

  local ol_dst_dir
  ol_dst_dir="${dst_file#openlist:}"
  ol_dst_dir="/$(dirname -- "$ol_dst_dir")"

  local ol_token
  ol_token=$(_get_openlist_token)

  # 方法 1：直接 rclone copyto
  if _method_blocked m1; then
    log_fix "$fix_log" "⏭  $(_method_short m1)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m1)"
  rclone copyto "$src_file" "$dst_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    _cmd_log m1 "$fix_log"
  local m1_status=${PIPESTATUS[0]}
  if [ "$m1_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m1)" "$failed_file_rel" "$fix_log"; then
    log_fix "$fix_log" "  ✅ 方法1 成功"
    TRY_FIX_METHOD_ID="方法1: 直接 rclone copyto（原路径 + 原文件名）"
    TRY_FIX_STATUS="success"
    if [ "$used_base64_dir" -eq 1 ]; then
      TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 原文件名）"
      TRY_FIX_ALTERNATIVE="${dst_file#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${dst_file}' '${dest_path}/${failed_file_rel}'"
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + 原文件名）"
      TRY_FIX_ALTERNATIVE="$failed_file_rel"
      TRY_FIX_RESTORE="无需还原（文件已在正确路径）"
    fi
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi
  log_fix "$fix_log" "  ❌ 方法1 失败 exit=$m1_status"
  fi

  # 方法 2（第 2 顺位）：rclone crypt 直写裸存储
  # 通过 rclone :crypt: 即时远程（与 OpenList crypt 驱动同格式）把密文直接写入
  # 裸存储 → 文件以原名原路径出现在 wopan176Crypt，绕过 OpenList crypt→后端
  # 驱动链路（假成功最可疑环节），无需替代名/还原映射
  if _method_blocked m2; then
    log_fix "$fix_log" "⏭  $(_method_short m2)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m2)"
  local _c_rel_root="" _c_rel _c_dst
  local _c_mount_rel="${dest_path#openlist:}"
  [[ "$_c_mount_rel" == */* ]] && _c_rel_root="${_c_mount_rel#*/}"
  if _ensure_crypt_config "$dest_path"; then
    _c_rel="${_c_rel_root:+${_c_rel_root}/}${failed_file_rel}"
    _c_dst="${_CRYPT_ONTHEFLY}${_c_rel}"
    log_fix "$fix_log" "  crypt 直写: ${_CRYPT_REMOTE} ← ${_c_rel}（加密名由 rclone 本地生成）"
    rclone copyto "$local_file" "$_c_dst" --retries 1 --low-level-retries 3 --timeout 15m --contimeout 30s 2>&1 | \
      _cmd_log m2 "$fix_log"
    local m2_status=${PIPESTATUS[0]}
    if [ "$m2_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m2)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法2 成功"
      TRY_FIX_METHOD_ID="方法2: rclone crypt 直写裸存储（原名原路径，绕过 OpenList crypt 驱动）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone crypt 直写（:crypt: → ${_CRYPT_REMOTE}，原名原路径）"
      TRY_FIX_ALTERNATIVE="$failed_file_rel"
      TRY_FIX_RESTORE="无需还原（文件已以原名原路径存在，经 rclone crypt 直写裸存储）"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法2 失败 exit=$m2_status"
  else
    log_fix "$fix_log" "  ⏭ 方法2 跳过（无 crypt 配置/密码）"
  fi
  fi

  # 方法 3（第 3 顺位）：短哈希文件名直传
  # <md5前8位>.<扩展名> — 密文名必然远低于 255 字节上限，对症"加密后文件名超长"
  # 根因（base64URL 编码反而让名字更长）；内容不变，还原仅需改名
  if _method_blocked m3; then
    log_fix "$fix_log" "⏭  $(_method_short m3)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m3)"
  local sh_hash sh_name m3sh_dst m3sh_status
  sh_hash=$(printf '%s' "$failed_file_rel" | md5sum | cut -c1-8)
  if [[ "$file_name" == *.* ]]; then
    sh_name="${sh_hash}.${file_name##*.}"
  else
    sh_name="$sh_hash"
  fi
  m3sh_dst="${actual_dst_dir}/${sh_name}"
  log_fix "$fix_log" "  文件名: ${file_name} → ${sh_name}"
  rclone copyto "$local_file" "$m3sh_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    _cmd_log m3 "$fix_log"
  m3sh_status=${PIPESTATUS[0]}
  if [ "$m3sh_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m3)" "$failed_file_rel" "$fix_log"; then
    log_fix "$fix_log" "  ✅ 方法3 成功"
    TRY_FIX_METHOD_ID="方法3: 短哈希文件名直传（<md5前8位>.<扩展名>）"
    TRY_FIX_STATUS="success"
    if [ "$used_base64_dir" -eq 1 ]; then
      TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 短哈希文件名 ${sh_hash}）"
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + 短哈希文件名 ${sh_hash}）"
    fi
    TRY_FIX_ALTERNATIVE="${m3sh_dst#${dest_path}/}"
    TRY_FIX_RESTORE="rclone move '${m3sh_dst}' '${dest_path}/${failed_file_rel}'  # 原文件名: ${file_name}"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi
  log_fix "$fix_log" "  ❌ 方法3 失败 exit=$m3sh_status"
  fi

  # 方法 4：zip 压缩后上传
  if _method_blocked m4; then
    log_fix "$fix_log" "⏭  $(_method_short m4)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m4)"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${file_name}.zip" "$file_name") 2>&1 | \
    _cmd_log m4·zip "$fix_log"
  if [ -f "$temp_dir/${file_name}.zip" ]; then
    local m4z_dst m4z_status
    m4z_dst="${actual_dst_dir}/${file_name}.zip"
    rclone copyto "$temp_dir/${file_name}.zip" "$m4z_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      _cmd_log m4 "$fix_log"
    m4z_status=${PIPESTATUS[0]}
    if [ "$m4z_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m4)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法4 成功"
      TRY_FIX_METHOD_ID="方法4: zip 压缩后上传（存储模式）"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + zip 压缩包）"
      else
        TRY_FIX_METHOD="rclone copyto（原路径 + zip 压缩包）"
      fi
      TRY_FIX_ALTERNATIVE="${m4z_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m4z_dst} 后解压: 7z x ${file_name}.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法4 失败 exit=$m4z_status"
  else
    log_fix "$fix_log" "  ⚠ 方法4 zip 未生成"
  fi
  fi

  # 方法 5：7z 压缩后上传
  if _method_blocked m5; then
    log_fix "$fix_log" "⏭  $(_method_short m5)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m5)"
  (cd "$temp_dir" && 7z a -t7z -mx=0 "${file_name}.7z" "$file_name") 2>&1 | \
    _cmd_log m5·7z "$fix_log"
  if [ -f "$temp_dir/${file_name}.7z" ]; then
    local m5z_dst m5z_status
    m5z_dst="${actual_dst_dir}/${file_name}.7z"
    rclone copyto "$temp_dir/${file_name}.7z" "$m5z_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      _cmd_log m5 "$fix_log"
    m5z_status=${PIPESTATUS[0]}
    if [ "$m5z_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m5)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法5 成功"
      TRY_FIX_METHOD_ID="方法5: 7z 压缩后上传（存储模式）"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 7z 压缩包）"
      else
        TRY_FIX_METHOD="rclone copyto（原路径 + 7z 压缩包）"
      fi
      TRY_FIX_ALTERNATIVE="${m5z_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m5z_dst} 后解压: 7z x ${file_name}.7z"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法5 失败 exit=$m5z_status"
  else
    log_fix "$fix_log" "  ⚠ 方法5 7z 未生成"
  fi
  fi

  # ============================================================
  # 方法 6：压缩并分卷上传（粒度默认 1GB——正常 sync 多 GB 单文件可直传，
  # 100MB 粒度白白放大分卷数与 API 调用；OPENLIST_SPLIT_PART_BYTES 可调）
  local SPLIT_LIMIT_BYTES="${OPENLIST_SPLIT_PART_BYTES:-1073741824}"
  local SPLIT_PART_HUMAN
  SPLIT_PART_HUMAN=$(numfmt --to=iec-i --suffix=B "$SPLIT_LIMIT_BYTES" 2>/dev/null || echo "${SPLIT_LIMIT_BYTES}B")
  if _method_blocked m6; then
    log_fix "$fix_log" "⏭  $(_method_short m6)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m6)（粒度 ${SPLIT_PART_HUMAN}）"
  local m6_split_dir="${temp_dir}/split_m6"
  mkdir -p "$m6_split_dir"
  local m6_zip_base="${file_name}.zip"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${m6_zip_base}" "$file_name") 2>&1 | \
    _cmd_log m6·zip "$fix_log"
  local m6_zip_path="${temp_dir}/${m6_zip_base}"
  if [ -f "$m6_zip_path" ]; then
    local m6_zip_size
    m6_zip_size=$(stat -c%s "$m6_zip_path" 2>/dev/null || stat -f%z "$m6_zip_path" 2>/dev/null || echo 0)
    log_fix "$fix_log" "  m6 zip 生成: ${m6_zip_base} (${m6_zip_size} bytes)"
    local m6_all_uploaded=1
    local m6_alt_files=()
    if [ "$m6_zip_size" -gt "$SPLIT_LIMIT_BYTES" ]; then
      log_fix "$fix_log" "  m6 单 zip >${SPLIT_PART_HUMAN}，切割分卷..."
      (cd "$m6_split_dir" && split -b "$SPLIT_LIMIT_BYTES" -d -a 3 "$m6_zip_path" "${m6_zip_base}.") 2>&1 | \
        _cmd_log m6·切 "$fix_log"
      local -a m6_parts=("${m6_split_dir}/"*)
      if [ ${#m6_parts[@]} -gt 0 ]; then
        for ((m6_i = ${#m6_parts[@]} - 1; m6_i >= 0; m6_i--)); do
          local m6_old="${m6_parts[$m6_i]}"
          local m6_bname
          m6_bname=$(basename -- "$m6_old")
          local m6_num_suffix="${m6_bname##*.}"
          local m6_prefix="${m6_bname%.*}"
          if [[ "$m6_num_suffix" =~ ^[0-9]+$ ]]; then
            local m6_new_num=$((10#$m6_num_suffix + 1))
            local m6_new_suffix=$(printf '%03d' "$m6_new_num")
            mv "$m6_old" "${m6_split_dir}/${m6_prefix}.${m6_new_suffix}" 2>/dev/null || true
          fi
        done
      fi
    else
      log_fix "$fix_log" "  m6 单 zip <=${SPLIT_PART_HUMAN}，无需切割"
      cp "$m6_zip_path" "${m6_split_dir}/${m6_zip_base}.001"
    fi
    local m6_uploaded_count=0
    local m6_total_parts=0
    for m6_part_file in "${m6_split_dir}/"*; do
      [ -f "$m6_part_file" ] || continue
      m6_total_parts=$((m6_total_parts + 1))
      local m6_part_bname
      m6_part_bname=$(basename -- "$m6_part_file")
      local m6_dst_part="${actual_dst_dir}/${m6_part_bname}"
      rclone copyto "$m6_part_file" "$m6_dst_part" --retries 1 --low-level-retries 3 --timeout 10m --contimeout 30s 2>&1 | \
        _cmd_log "m6·传${m6_total_parts}" "$fix_log"
      local m6_part_rc=${PIPESTATUS[0]}
      local m6_part_expected
      m6_part_expected=$(stat -c%s "$m6_part_file" 2>/dev/null || stat -f%z "$m6_part_file" 2>/dev/null || echo 0)
      local m6_part_dst_size
      m6_part_dst_size=$(rclone size --json "$m6_dst_part" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
      if [ "$m6_part_rc" -eq 0 ] && [ "$m6_part_dst_size" = "$m6_part_expected" ] && [ "$m6_part_dst_size" -gt 0 ]; then
        m6_uploaded_count=$((m6_uploaded_count + 1))
        local m6_alt_rel="${m6_dst_part#${dest_path}/}"
        m6_alt_files+=("$m6_alt_rel")
        log_fix "$fix_log" "  m6 分卷 ${m6_total_parts} 上传成功 (${m6_part_bname}, ${m6_part_expected} bytes)"
      else
        log_fix "$fix_log" "  m6 分卷 ${m6_total_parts} 上传失败 (rc=$m6_part_rc, size=$m6_part_dst_size, expected=$m6_part_expected)"
        m6_all_uploaded=0
        for m6_clean in "${m6_alt_files[@]}"; do
          rclone deletefile "${dest_path}/${m6_clean}" 2>/dev/null || true
        done
        m6_alt_files=()
        break
      fi
    done
    log_fix "$fix_log" "  m6 分卷上传汇总: $m6_uploaded_count / $m6_total_parts"
    if [ "$m6_all_uploaded" -eq 1 ] && [ "$m6_uploaded_count" -gt 0 ] && _confirm_persist_by_count "$(_method_desc m6)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法6 成功（${m6_uploaded_count} 分卷）"
      TRY_FIX_METHOD_ID="方法6: zip 压缩 + 分卷上传（默认 1GB 分卷）"
      TRY_FIX_STATUS="success"
      local m6_first_alt="${m6_alt_files[0]}"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="分卷 zip（base64URL 编码目录 + ${SPLIT_PART_HUMAN} 分卷切割，共 ${m6_uploaded_count} 卷）"
      else
        TRY_FIX_METHOD="分卷 zip（原路径 + ${SPLIT_PART_HUMAN} 分卷切割，共 ${m6_uploaded_count} 卷）"
      fi
      TRY_FIX_ALTERNATIVE="$m6_first_alt"
      TRY_FIX_RESTORE="下载所有分卷 ${m6_zip_base}.001~.00${m6_uploaded_count} 后 cat 合并再解压: cat ${m6_zip_base}.0* > merged.zip && 7z x merged.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法6 失败（分卷未全部上传）"
    rm -rf "$m6_split_dir" 2>/dev/null || true
  else
    log_fix "$fix_log" "  ⚠ 方法6 zip 未生成"
  fi
  fi

  # ============================================================
  # 方法 7：压缩并 base64URL 编码文件名，切割为 100MB 以下的分卷再进行同步
  # ============================================================
  if _method_blocked m7; then
    log_fix "$fix_log" "⏭  $(_method_short m7)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m7)"
  local m7_encoded_name
  if [[ "$file_name" == *.* ]]; then
    local m7_name_base="${file_name%.*}"
    local m7_name_ext="${file_name##*.}"
    m7_encoded_name="$(printf '%s' "$m7_name_base" | base64 | tr '+/' '-_' | tr -d '=').${m7_name_ext}"
  else
    m7_encoded_name="$(printf '%s' "$file_name" | base64 | tr '+/' '-_' | tr -d '=')"
  fi
  local m7_split_dir="${temp_dir}/split_m7"
  mkdir -p "$m7_split_dir"
  local m7_zip_base="${m7_encoded_name}.zip"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${m7_zip_base}" "$file_name") 2>&1 | \
    _cmd_log m7·zip "$fix_log"
  local m7_zip_path="${temp_dir}/${m7_zip_base}"
  if [ -f "$m7_zip_path" ]; then
    local m7_zip_size
    m7_zip_size=$(stat -c%s "$m7_zip_path" 2>/dev/null || stat -f%z "$m7_zip_path" 2>/dev/null || echo 0)
    log_fix "$fix_log" "  m7 zip 生成: ${m7_zip_base} (${m7_zip_size} bytes), 文件名编码: $file_name -> $m7_encoded_name"
    local m7_all_uploaded=1
    local m7_alt_files=()
    if [ "$m7_zip_size" -gt "$SPLIT_LIMIT_BYTES" ]; then
      log_fix "$fix_log" "  m7 单 zip >${SPLIT_PART_HUMAN}，切割分卷..."
      (cd "$m7_split_dir" && split -b "$SPLIT_LIMIT_BYTES" -d -a 3 "$m7_zip_path" "${m7_zip_base}.") 2>&1 | \
        _cmd_log m7·切 "$fix_log"
      local -a m7_parts=("${m7_split_dir}/"*)
      if [ ${#m7_parts[@]} -gt 0 ]; then
        for ((m7_i = ${#m7_parts[@]} - 1; m7_i >= 0; m7_i--)); do
          local m7_old="${m7_parts[$m7_i]}"
          local m7_bname
          m7_bname=$(basename -- "$m7_old")
          local m7_num_suffix="${m7_bname##*.}"
          if [[ "$m7_num_suffix" =~ ^[0-9]+$ ]]; then
            local m7_new_num=$((10#$m7_num_suffix + 1))
            local m7_new_suffix=$(printf '%03d' "$m7_new_num")
            local m7_prefix="${m7_bname%.*}"
            mv "$m7_old" "${m7_split_dir}/${m7_prefix}.${m7_new_suffix}" 2>/dev/null || true
          fi
        done
      fi
    else
      log_fix "$fix_log" "  m7 单 zip <=${SPLIT_PART_HUMAN}，无需切割"
      cp "$m7_zip_path" "${m7_split_dir}/${m7_zip_base}.001"
    fi
    local m7_uploaded_count=0
    local m7_total_parts=0
    for m7_part_file in "${m7_split_dir}/"*; do
      [ -f "$m7_part_file" ] || continue
      m7_total_parts=$((m7_total_parts + 1))
      local m7_part_bname
      m7_part_bname=$(basename -- "$m7_part_file")
      local m7_dst_part="${actual_dst_dir}/${m7_part_bname}"
      rclone copyto "$m7_part_file" "$m7_dst_part" --retries 1 --low-level-retries 3 --timeout 10m --contimeout 30s 2>&1 | \
        _cmd_log "m7·传${m7_total_parts}" "$fix_log"
      local m7_part_rc=${PIPESTATUS[0]}
      local m7_part_expected
      m7_part_expected=$(stat -c%s "$m7_part_file" 2>/dev/null || stat -f%z "$m7_part_file" 2>/dev/null || echo 0)
      local m7_part_dst_size
      m7_part_dst_size=$(rclone size --json "$m7_dst_part" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
      if [ "$m7_part_rc" -eq 0 ] && [ "$m7_part_dst_size" = "$m7_part_expected" ] && [ "$m7_part_dst_size" -gt 0 ]; then
        m7_uploaded_count=$((m7_uploaded_count + 1))
        local m7_alt_rel="${m7_dst_part#${dest_path}/}"
        m7_alt_files+=("$m7_alt_rel")
        log_fix "$fix_log" "  m7 分卷 ${m7_total_parts} 上传成功 (${m7_part_bname}, ${m7_part_expected} bytes)"
      else
        log_fix "$fix_log" "  m7 分卷 ${m7_total_parts} 上传失败 (rc=$m7_part_rc, size=$m7_part_dst_size, expected=$m7_part_expected)"
        m7_all_uploaded=0
        for m7_clean in "${m7_alt_files[@]}"; do
          rclone deletefile "${dest_path}/${m7_clean}" 2>/dev/null || true
        done
        m7_alt_files=()
        break
      fi
    done
    log_fix "$fix_log" "  m7 分卷上传汇总: $m7_uploaded_count / $m7_total_parts"
    if [ "$m7_all_uploaded" -eq 1 ] && [ "$m7_uploaded_count" -gt 0 ] && _confirm_persist_by_count "$(_method_desc m7)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法7 成功（${m7_uploaded_count} 分卷）"
      TRY_FIX_METHOD_ID="方法7: zip 压缩 + base64URL 文件名 + 分卷上传"
      TRY_FIX_STATUS="success"
      local m7_first_alt="${m7_alt_files[0]}"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="分卷 zip（base64URL 编码目录 + base64URL 编码文件名 + ${SPLIT_PART_HUMAN} 分卷切割，共 ${m7_uploaded_count} 卷）"
      else
        TRY_FIX_METHOD="分卷 zip（原路径 + base64URL 编码文件名 + ${SPLIT_PART_HUMAN} 分卷切割，共 ${m7_uploaded_count} 卷）"
      fi
      TRY_FIX_ALTERNATIVE="$m7_first_alt"
      TRY_FIX_RESTORE="下载所有分卷 ${m7_zip_base}.001~.00${m7_uploaded_count} 后 cat 合并再解压: cat ${m7_zip_base}.0* > merged.zip && 7z x merged.zip，原文件名恢复: base64URL 解码编码部分得到 $file_name"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法7 失败（分卷未全部上传）"
    rm -rf "$m7_split_dir" 2>/dev/null || true
  else
    log_fix "$fix_log" "  ⚠ 方法7 zip 未生成"
  fi
  fi

  # 方法 8：OpenList API 直传
  if _method_blocked m8; then
    log_fix "$fix_log" "⏭  $(_method_short m8)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m8)"
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg path "$ol_dst_dir" '{path:$path,recursive:true}')" >/dev/null 2>&1 || true
    sleep 3
    local api_name upload_resp upload_http
    if [[ "$file_name" == *.* ]]; then
      api_name="file_$(date +%s)_$$_api.${file_name##*.}"
    else
      api_name="file_$(date +%s)_$$_api"
    fi
    upload_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$ol_dst_dir" \
      -F "name=$api_name" 2>&1)
    upload_http=$(echo "$upload_resp" | tail -n 1)
    log_fix "$fix_log" "OpenList API 上传响应: ${upload_http}"
    if echo "$upload_http" | grep -qE 'HTTP_CODE:(200|201|204)' && _confirm_persist_by_count "$(_method_desc m8)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法8 成功"
      TRY_FIX_METHOD_ID="方法8: OpenList API /fs/form 直传（API 自动生成文件名）"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="OpenList API /fs/form（base64URL 编码目录 + API 自动生成文件名）"
      else
        TRY_FIX_METHOD="OpenList API /fs/form（原路径 + API 自动生成文件名）"
      fi
      local alt_rel_base
      alt_rel_base="${actual_dst_dir#${dest_path}/}"
      TRY_FIX_ALTERNATIVE="${alt_rel_base}/${api_name}"
      TRY_FIX_RESTORE="rclone move '${dest_path}/${alt_rel_base}/${api_name}' '${dest_path}/${failed_file_rel}'"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法8 失败 http=${upload_http}"
  else
    log_fix "$fix_log" "  ⏭ 方法8 跳过（无 OpenList token）"
  fi
  fi


  # 方法 9：上传到父目录（跳过有问题的目录层级）
  # 如果当前目录写操作被 wopan176 拒绝，尝试上传到上级目录
  # 文件名编码原始目录信息，便于后续还原
  if _method_blocked m9; then
    log_fix "$fix_log" "⏭  $(_method_short m9)（已拉黑，跳过）"
  else
  if [ "$file_dir_rel" != "." ] && [ "$file_dir_rel" != "" ]; then
    log_fix "$fix_log" "▶ $(_method_short m9)"
    local parent_dst_dir
    parent_dst_dir="$(dirname -- "$actual_dst_dir")"
    local parent_ol_dir
    parent_ol_dir="$(dirname -- "$actual_ol_dir")"

    # 编码原始目录名到文件名中，格式: __fixed__<base64_原始目录>__<原文件名>
    local encoded_orig_dir
    encoded_orig_dir=$(printf '%s' "$(basename -- "$file_dir_rel")" | base64 | tr '+/' '-_' | tr -d '=')
    local fixed_name="__fixed__${encoded_orig_dir}__${file_name}"
    local m9_dst="${parent_dst_dir}/${fixed_name}"

    log_fix "$fix_log" "  父目录: $parent_dst_dir"
    log_fix "$fix_log" "  编码文件名: $fixed_name"

    # 确保父目录存在
    rclone mkdir "$parent_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
      _cmd_log m9·mkdir "$fix_log"

    rclone copyto "$local_file" "$m9_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      _cmd_log m9 "$fix_log"
    local m9_status=${PIPESTATUS[0]}
    if [ "$m9_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m9)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法9 成功"
      TRY_FIX_METHOD_ID="方法9: 上传到父目录（跳过有问题的目录层级）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（父目录 + 编码原始目录名的文件名）"
      TRY_FIX_ALTERNATIVE="${m9_dst#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${m9_dst}' '${dest_path}/${failed_file_rel}'"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法9 失败 exit=$m9_status"
  fi
  fi




  # 方法 10：加密 zip 后上传（改变二进制特征 + 密码保护）
  if _method_blocked m10; then
    log_fix "$fix_log" "⏭  $(_method_short m10)（已拉黑，跳过）"
  else
  log_fix "$fix_log" "▶ $(_method_short m10)"
  local zip_password="OpenList$(date +%s)"
  (cd "$temp_dir" && 7z a -tzip -p"$zip_password" -mem=AES256 "${file_name}.enc.zip" "$file_name") 2>&1 | \
    _cmd_log m10·zip "$fix_log"
  if [ -f "$temp_dir/${file_name}.enc.zip" ]; then
    local m10_dst="${actual_dst_dir}/${file_name}.enc.zip"
    rclone copyto "$temp_dir/${file_name}.enc.zip" "$m10_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      _cmd_log m10 "$fix_log"
    local m10_status=${PIPESTATUS[0]}
    if [ "$m10_status" -eq 0 ] && _confirm_persist_by_count "$(_method_desc m10)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ✅ 方法10 成功"
      TRY_FIX_METHOD_ID="方法10: AES256 加密 zip 后上传（改变二进制特征）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（AES256 加密 zip + .enc.zip 扩展名）"
      TRY_FIX_ALTERNATIVE="${m10_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m10_dst} 后解压: 7z x -p${zip_password} ${file_name}.enc.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "  ❌ 方法10 失败 exit=$m10_status"
  else
    log_fix "$fix_log" "  ⚠ 方法10 zip 未生成"
  fi
  fi

  # 方法 11：上传到临时目录后用 OpenList API move 移动
  # 在 backup 根目录创建临时目录，上传文件，然后用 API move 到目标路径
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    if _method_blocked m11; then
      log_fix "$fix_log" "⏭  $(_method_short m11)（已拉黑，跳过）"
    else
    log_fix "$fix_log" "▶ $(_method_short m11)"
    local tmp_dir_name="_tmp_fix_$(date +%s)_$$"
    local tmp_ol_dir="/${ol_dst_base}/${tmp_dir_name}"
    # 通过 API 创建临时目录
    curl -s -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg path "$tmp_ol_dir" '{path:$path}')" >/dev/null 2>&1 || true
    sleep 1
    # 上传文件到临时目录
    local m11_upload_name="${file_name}"
    local m11_upload_resp m11_upload_http
    m11_upload_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$tmp_ol_dir" \
      -F "name=$m11_upload_name" \
      --max-time 300 2>&1)
    m11_upload_http=$(echo "$m11_upload_resp" | tail -n 1)
    log_fix "$fix_log" "  临时目录上传响应: ${m11_upload_http}"
    if echo "$m11_upload_http" | grep -qE 'HTTP_CODE:(200|201|204)' && _confirm_persist_by_count "$(_method_desc m11)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "  ⬆ 方法11 临时目录上传成功，move 到目标路径..."
      TRY_FIX_METHOD_ID="方法11: 临时目录上传 + OpenList API move 移动"
      # 确保目标目录存在
      local target_ol_dir="/${ol_dst_base}/${file_dir_rel}"
      curl -s -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "$target_ol_dir" '{path:$path}')" >/dev/null 2>&1 || true
      sleep 1
      # 用 OpenList API move 移动文件
      local src_move="${tmp_ol_dir}/${file_name}"
      local dst_move="/${ol_dst_base}/${failed_file_rel}"
      local move_resp move_http
      move_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/move" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg src "$src_move" --arg dst "$dst_move" '{src_dir:$src,dst_dir:$dst}')")
      move_http=$(echo "$move_resp" | tail -n 1)
      log_fix "$fix_log" "  API move 响应: ${move_http}"
      if echo "$move_resp" | grep -q '"code":200'; then
        log_fix "$fix_log" "  ✅ 方法11 成功（move 完成）"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传 + OpenList API move（原路径 + 原文件名）"
        TRY_FIX_ALTERNATIVE="$failed_file_rel"
        TRY_FIX_RESTORE="无需还原（文件已在正确路径）"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      else
        log_fix "$fix_log" "  ❌ 方法11 move 失败，文件留在 ${tmp_ol_dir}/${file_name}"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传（move 失败，文件保留在 ${tmp_dir_name}/）"
        TRY_FIX_ALTERNATIVE="${tmp_dir_name}/${file_name}"
        TRY_FIX_RESTORE="OpenList API: POST /api/fs/move {src_dir:'${tmp_ol_dir}/${file_name}', dst_dir:'/${ol_dst_base}/${failed_file_rel}'}"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      fi
    fi
    log_fix "$fix_log" "  ❌ 方法11 上传失败 http=${m11_upload_http}"
  fi
  fi

  # 所有方法均失败
  log_fix "$fix_log" "❌ 全部修复方法（1-11）均失败"
  TRY_FIX_MESSAGE="所有修复方法均失败"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 1
}
