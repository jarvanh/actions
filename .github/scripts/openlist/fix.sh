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
#   A. 即时校验（_confirm_raw_persist）: 方法返回成功后，对比 wopan176 裸路径
#      密文计数是否增长（裸存储缓存独立，不受 crypt 幽灵文件污染）。
#      未增长 = 假成功 → 该方法加入黑名单，立即尝试下一种方式。
#   B. 失败记忆（FIX_METHOD_BLACKLIST + marker fix_blacklist 字段）:
#      持久化每文件已判定假成功的方法（marker 存方法全名，| 分隔）。
#      sync.sh 持久化验证发现假成功后，本轮立即换方法重试（黑名单让
#      try_fix_failed_file 直接跳过失效方法）；跨轮修复同样跳过，避免
#      方法1 每轮都白白"成功"一次再被发现。
#
# 工件清理（TRY_FIX_ARTIFACTS）: 每个方法尝试失败（rc≠0 或假成功）后，
# 立即删除该方法已上传到目标端的文件（含分卷前缀展开），只保留最终
# 胜出方法的工件——否则换方法会让同一源文件在目标端累积多个垃圾
# "修复文件"（run 31928671112 实测一个文件留下 ~10 个候选）。
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
  [ -f "$db_src" ] || return 1
  local db_local="/tmp/ol_data_$$.db"
  cp "$db_src" "$db_local" 2>/dev/null || return 1
  cp "${db_src}-wal" "${db_local}-wal" 2>/dev/null || true
  cp "${db_src}-shm" "${db_local}-shm" 2>/dev/null || true

  python3 - "$db_local" "$mount" <<'PY' 2>/dev/null
import sqlite3, sys
db, mount = sys.argv[1], sys.argv[2]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
try:
    rows = con.execute("SELECT mount_path, addition FROM x_storages").fetchall()
finally:
    con.close()
for mp, add in rows:
    if mp and mp.rstrip('/') == mount.rstrip('/'):
        if add:
            print(add)
        break
PY
  local rc=$?
  rm -f "$db_local" "${db_local}-wal" "${db_local}-shm" 2>/dev/null || true
  return $rc
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
  local ol_token
  ol_token=$(_get_openlist_token) || return 1
  local resp
  resp=$(curl -s "http://127.0.0.1:5244/api/admin/storage/list" \
    -H "Authorization: $ol_token" --max-time 15 2>/dev/null) || return 1

  local addition
  addition=$(echo "$resp" | jq -r --arg m "$mount" \
    '(.data.content // .data // [])[]? | select(.mount_path == $m or .mount_path == ($m + "/")) | .addition // empty' 2>/dev/null | head -1)

  # API 拿不到（401 无数据/挂载名不匹配等）→ 本地 data.db 兜底
  if [ -z "$addition" ] || [ "$addition" = "null" ]; then
    addition=$(_get_addition_from_db "$mount") || addition=""
  fi
  [ -n "$addition" ] && [ "$addition" != "null" ] || return 1

  # addition 可能是 JSON 编码字符串 → 解码为对象后再取字段
  if printf '%s' "$addition" | jq -e 'type == "string"' >/dev/null 2>&1; then
    addition=$(printf '%s' "$addition" | jq -c 'fromjson' 2>/dev/null)
  fi
  echo "$addition" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1

  local pass fne dne upath
  pass=$(echo "$addition" | jq -r '.password // empty' 2>/dev/null)
  [ -n "$pass" ] || return 1
  fne=$(echo "$addition" | jq -r '.filename_encryption // "standard"' 2>/dev/null)
  dne=$(echo "$addition" | jq -r 'if (.directory_name_encryption // null) == null then "true" else (.directory_name_encryption | tostring) end' 2>/dev/null)
  upath=$(echo "$addition" | jq -r '.path // empty' 2>/dev/null)

  local underlying
  if [ -n "$upath" ] && [ "$upath" != "null" ]; then
    underlying="openlist:${upath#/}"
  else
    # 推导: /wopan176Crypt → openlist:wopan176（去掉 Crypt 后缀）
    local base="${mount#/}"
    base="${base%Crypt}"
    underlying="openlist:${base}"
  fi
  echo "${pass} ${fne} ${dne} ${underlying}"
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
  local pass fne dne remote
  read -r pass fne dne remote <<< "$conf"
  if [ -z "$pass" ] || [ -z "$remote" ]; then
    _CRYPT_ONTHEFLY=""
    return 1
  fi
  _CRYPT_MOUNT="$mount"
  _CRYPT_PASS="$pass"
  _CRYPT_FNE="$fne"
  _CRYPT_DNE="$dne"
  _CRYPT_REMOTE="$remote"
  _CRYPT_ONTHEFLY=":crypt,remote=\"${remote}\",filename_encryption=${fne:-standard},directory_name_encryption=${dne:-true},password=\"${pass}\":"
  return 0
}

# 由 Crypt dest_path 推导裸存储远程路径（供名长诊断等需要"真实密文名"的场景）
# API 权威优先（crypt addition.path 指向的真实存储），失败时退化为字符串替换
# 用法: _raw_remote_for <dest_path>  → stdout: openlist:wopan176[/子路径]
_raw_remote_for() {
  local dest_path="$1"
  local rel="${dest_path#openlist:}"
  local sub=""
  [[ "$rel" == */* ]] && sub="/${rel#*/}"
  if _ensure_crypt_config "$dest_path" 2>/dev/null; then
    echo "${_CRYPT_REMOTE}${sub}"
    return 0
  fi
  local base="${rel%%/*}"
  base="${base%Crypt}"
  echo "openlist:${base}${sub}"
}

# raw 计数视图（供 raw-vs-crypt 校验 / A 层即时检测的文件数对比）
# dne=true（目录名加密）时裸路径没有字面子目录（run 31918439043 实测
# openlist:wopan176/backup rc=3 not found——"backup" 在裸存储是密文名），
# 字面路径计数必然失败。改用 crypt 即时远程：rclone 按配置逐段加密路径
# 后在裸存储查找，列出再解密，计数口径与 crypt 视图完全一致。
# 配置不可用时退化为字面裸路径（dne=false 场景仍正确）。
# 用法: _raw_count_view_for <dest_path>  → stdout: 计数用远程路径
_raw_count_view_for() {
  local dest_path="$1"
  local rel="${dest_path#openlist:}"
  local sub=""
  [[ "$rel" == */* ]] && sub="${rel#*/}"
  if _ensure_crypt_config "$dest_path" 2>/dev/null; then
    echo "${_CRYPT_ONTHEFLY}${sub}"
  else
    local base="${rel%%/*}"
    base="${base%Crypt}"
    echo "openlist:${base}${sub:+/${sub}}"
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

# 清理目标端单个修复工件（尽力而为）: 单文件 deletefile；
# 分卷类（.zip.NNN 结尾）按前缀列出全部编号分卷逐个删除。
# ghost 文件（仅存在于 OpenList 缓存）删除会失败——忽略即可，容器重启后自然消失。
# 用法: _cleanup_remote_artifact <full_remote_path>
_cleanup_remote_artifact() {
  local full="$1"
  [ -n "$full" ] || return 0
  if echo "$full" | grep -qE '\.zip\.[0-9]{3}$'; then
    local dir base prefix p
    dir="$(dirname -- "$full")"
    base="$(basename -- "$full")"
    prefix="${base%.[0-9]*}"   # foo.zip.001 → foo.zip（前缀已含 .zip）
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      rclone deletefile "${dir}/${p}" >/dev/null 2>&1 || true
    done < <(rclone lsf "$dir" --files-only 2>/dev/null | grep -F "${prefix}." || true)
  else
    rclone deletefile "$full" >/dev/null 2>&1 || true
  fi
}

# 清理目标端替代路径工件（相对 dest_path），带日志
# 用法: _cleanup_fix_artifact <dest_path> <alt_rel> <log_file>
_cleanup_fix_artifact() {
  local dest_path="$1" alt_rel="$2" log_file="${3:-/dev/null}"
  [ -n "$alt_rel" ] || return 0
  _cleanup_remote_artifact "${dest_path}/${alt_rel}"
  log_fix "$log_file" "  🧹 已清理未持久化的修复工件: ${alt_rel}"
}

# 本次 try_fix_failed_file 调用已上传的工件（目标端完整远程路径）
# 每个方法尝试失败（rc≠0 或假成功）后立即清理，避免换方法时同一个
# 源文件在目标端累积多个垃圾"修复文件"（run 31928671112 实测一文件留 ~10 个）
declare -a TRY_FIX_ARTIFACTS=()

_artifact_add() {
  [ -n "$1" ] && TRY_FIX_ARTIFACTS+=("$1")
}

# 尽力清理全部已记录工件并清空清单（成功方法的不调用——胜者工件保留）
# 用法: _artifacts_cleanup <log_file>
_artifacts_cleanup() {
  local log_file="${1:-/dev/null}" a
  for a in "${TRY_FIX_ARTIFACTS[@]}"; do
    _cleanup_remote_artifact "$a"
  done
  if [ "${#TRY_FIX_ARTIFACTS[@]}" -gt 0 ]; then
    log_fix "$log_file" "  🧹 已清理 ${#TRY_FIX_ARTIFACTS[@]} 个未持久化候选工件（防止同一文件累积多个修复文件）"
  fi
  TRY_FIX_ARTIFACTS=()
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
  if echo "$merged" | rclone rcat "$marker_path" >/dev/null 2>&1; then
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

# 假成功即时校验（方案 A，仅 wopan176Crypt 目标启用）
# 在方法返回成功（rc=0 / HTTP 2xx）后调用：刷新并统计 wopan176 裸路径密文数，
# 与运行基准（_RAW_VERIFY_LAST，由 sync.sh 修复管线初始化并随真实落盘递增）比较。
#   计数增长   → 真实持久化，返回 0
#   计数未增长 → 假成功：记日志、加入黑名单，返回 1（调用方落到下一种方式）
#   预算耗尽/计数失败 → 无法判定，信任原结果返回 0（不误伤）
# 用法: _confirm_raw_persist <method_id> <file_rel> <log_file>
_confirm_raw_persist() {
  local method_id="$1" rel_path="$2" log_file="$3"
  # 仅 wopan176Crypt 目标启用（由 sync.sh 修复管线初始化）
  [[ "${_RAW_VERIFY_DEST:-}" == openlist:wopan176Crypt/* ]] || return 0
  # 校验预算耗尽 → 退化为信任 rc（避免大目录反复全量计数拖垮同步）
  if [ "${_RAW_VERIFY_BUDGET:-0}" -le 0 ]; then
    return 0
  fi
  _RAW_VERIFY_BUDGET=$((_RAW_VERIFY_BUDGET - 1))
  local count=0
  local m_desc
  m_desc=$(_method_desc "$method_id")
  count=$(_raw_dir_count "$_RAW_VERIFY_DIR" "${_RAW_VERIFY_REFRESH:-}") || {
    log_fix "$log_file" "  ⚠️ raw 计数失败，无法判定落盘，信任 ${m_desc} 的返回结果"
    return 0
  }
  if [ "$count" -gt "${_RAW_VERIFY_LAST:--1}" ]; then
    _RAW_VERIFY_LAST=$count
    log_fix "$log_file" "  ✅ raw 落盘确认: 密文数 ${_RAW_VERIFY_LAST}（${m_desc} 真实持久化）"
    return 0
  fi
  log_fix "$log_file" "  🔴 假成功: rc=0 但 wopan176 裸路径密文数未增长（${_RAW_VERIFY_LAST} → ${count}），${m_desc} 拉黑并尝试下一种方式"
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
  TRY_FIX_ARTIFACTS=()

  log_fix "$fix_log" "=== 尝试修复失败文件: $failed_file_rel ==="
  log_fix "$fix_log" "源文件: $src_file"
  log_fix "$fix_log" "原始目标: $dst_file"

  # 下载源文件到本地临时目录
  local temp_dir="temp_fix_$(date +%s)_$$"
  mkdir -p "$temp_dir"
  local local_file="$temp_dir/$file_name"

  log_fix "$fix_log" "下载源文件到本地..."
  rclone copyto "$src_file" "$local_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "rclone copy: $line"; done
  local copy_status=${PIPESTATUS[0]}

  if [ "$copy_status" -ne 0 ] || [ ! -f "$local_file" ]; then
    log_fix "$fix_log" "下载源文件失败，跳过修复"
    TRY_FIX_MESSAGE="无法从源端下载文件"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 1
  fi

  local file_size
  file_size=$(stat -c%s "$local_file" 2>/dev/null || echo 0)
  log_fix "$fix_log" "源文件已下载，大小: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "${file_size}B")"

  # ===== Step 1: 创建/确认目标目录 =====
  local dir_ok=0
  local used_base64_dir=0
  local actual_dst_dir="$dst_dir"
  local actual_ol_dir="/${ol_dst_base}/${file_dir_rel}"

  # 尝试 rclone mkdir
  log_fix "$fix_log" "尝试创建目标目录: $dst_dir"
  rclone mkdir "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "rclone mkdir: $line"; done
  local mkdir_status=${PIPESTATUS[0]}

  # rclone mkdir 退出码为 0 时仍需验证目录是否实际存在（WebDAV 可能静默失败）
  if [ "$mkdir_status" -eq 0 ]; then
    log_fix "$fix_log" "rclone mkdir 退出码 0，用 rclone lsd 验证目录是否实际存在..."
    rclone lsd "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s >/dev/null 2>&1
    local verify_status=$?
    if [ "$verify_status" -eq 0 ]; then
      dir_ok=1
      log_fix "$fix_log" "rclone lsd 验证成功，目录已确认存在"
    else
      log_fix "$fix_log" "rclone lsd 验证失败 (exit=$verify_status)，目录未实际创建，降级处理"
    fi
  else
    log_fix "$fix_log" "rclone mkdir 失败 (exit=$mkdir_status)，尝试 OpenList API mkdir..."
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
        while IFS= read -r line; do log_fix "$fix_log" "rclone mkdir (base64URL): $line"; done
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
    log_fix "$fix_log" "$(_method_desc m1) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 1: 直接 rclone copyto"
  _artifact_add "$dst_file"
  rclone copyto "$src_file" "$dst_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m1: $line"; done
  local m1_status=${PIPESTATUS[0]}
  if [ "$m1_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m1)" "$failed_file_rel" "$fix_log"; then
    log_fix "$fix_log" "方法 1 成功"
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
  log_fix "$fix_log" "方法 1 失败 (exit=$m1_status)"
  _artifacts_cleanup "$fix_log"
  fi

  # 方法 2（第 2 顺位）：rclone crypt 直写裸存储
  # 通过 rclone :crypt: 即时远程（与 OpenList crypt 驱动同格式）把密文直接写入
  # 裸存储 → 文件以原名原路径出现在 wopan176Crypt，绕过 OpenList crypt→后端
  # 驱动链路（假成功最可疑环节），无需替代名/还原映射
  if _method_blocked m2; then
    log_fix "$fix_log" "$(_method_desc m2) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 2: rclone crypt 直写裸存储"
  local _c_rel_root="" _c_rel _c_dst
  local _c_mount_rel="${dest_path#openlist:}"
  [[ "$_c_mount_rel" == */* ]] && _c_rel_root="${_c_mount_rel#*/}"
  if _ensure_crypt_config "$dest_path"; then
    _c_rel="${_c_rel_root:+${_c_rel_root}/}${failed_file_rel}"
    _c_dst="${_CRYPT_ONTHEFLY}${_c_rel}"
    log_fix "$fix_log" "  crypt 直写: ${_CRYPT_REMOTE} ← ${_c_rel}（加密名由 rclone 本地生成）"
    _artifact_add "$_c_dst"
    rclone copyto "$local_file" "$_c_dst" --retries 1 --low-level-retries 3 --timeout 15m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m2: $line"; done
    local m2_status=${PIPESTATUS[0]}
    if [ "$m2_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m2)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 2 成功"
      TRY_FIX_METHOD_ID="方法2: rclone crypt 直写裸存储（原名原路径，绕过 OpenList crypt 驱动）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone crypt 直写（:crypt: → ${_CRYPT_REMOTE}，原名原路径）"
      TRY_FIX_ALTERNATIVE="$failed_file_rel"
      TRY_FIX_RESTORE="无需还原（文件已以原名原路径存在，经 rclone crypt 直写裸存储）"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 2 失败 (exit=$m2_status)"
    _artifacts_cleanup "$fix_log"
  else
    log_fix "$fix_log" "方法 2 跳过（未能从 OpenList API 获取 crypt 配置/密码）"
  fi
  fi

  # 方法 3（第 3 顺位）：短哈希文件名直传
  # <md5前8位>.<扩展名> — 密文名必然远低于 255 字节上限，对症"加密后文件名超长"
  # 根因（base64URL 编码反而让名字更长）；内容不变，还原仅需改名
  if _method_blocked m3; then
    log_fix "$fix_log" "$(_method_desc m3) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 3: 短哈希文件名直传"
  local sh_hash sh_name m3sh_dst m3sh_status
  sh_hash=$(printf '%s' "$failed_file_rel" | md5sum | cut -c1-8)
  if [[ "$file_name" == *.* ]]; then
    sh_name="${sh_hash}.${file_name##*.}"
  else
    sh_name="$sh_hash"
  fi
  m3sh_dst="${actual_dst_dir}/${sh_name}"
  log_fix "$fix_log" "  文件名: ${file_name} → ${sh_name}"
  _artifact_add "$m3sh_dst"
  rclone copyto "$local_file" "$m3sh_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m3: $line"; done
  m3sh_status=${PIPESTATUS[0]}
  if [ "$m3sh_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m3)" "$failed_file_rel" "$fix_log"; then
    log_fix "$fix_log" "方法 3 成功"
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
  log_fix "$fix_log" "方法 3 失败 (exit=$m3sh_status)"
  _artifacts_cleanup "$fix_log"
  fi

  # 方法 4：zip 压缩后上传
  if _method_blocked m4; then
    log_fix "$fix_log" "$(_method_desc m4) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 4: zip 压缩后上传"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${file_name}.zip" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m4 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.zip" ]; then
    local m4z_dst m4z_status
    m4z_dst="${actual_dst_dir}/${file_name}.zip"
    _artifact_add "$m4z_dst"
    rclone copyto "$temp_dir/${file_name}.zip" "$m4z_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m4: $line"; done
    m4z_status=${PIPESTATUS[0]}
    if [ "$m4z_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m4)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 4 成功"
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
    log_fix "$fix_log" "方法 4 失败 (exit=$m4z_status)"
    _artifacts_cleanup "$fix_log"
  else
    log_fix "$fix_log" "方法 4 zip 未生成"
  fi
  fi

  # 方法 5：7z 压缩后上传
  if _method_blocked m5; then
    log_fix "$fix_log" "$(_method_desc m5) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 5: 7z 压缩后上传"
  (cd "$temp_dir" && 7z a -t7z -mx=0 "${file_name}.7z" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m5 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.7z" ]; then
    local m5z_dst m5z_status
    m5z_dst="${actual_dst_dir}/${file_name}.7z"
    _artifact_add "$m5z_dst"
    rclone copyto "$temp_dir/${file_name}.7z" "$m5z_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m5: $line"; done
    m5z_status=${PIPESTATUS[0]}
    if [ "$m5z_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m5)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 5 成功"
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
    log_fix "$fix_log" "方法 5 失败 (exit=$m5z_status)"
    _artifacts_cleanup "$fix_log"
  else
    log_fix "$fix_log" "方法 5 7z 未生成"
  fi
  fi

  # ============================================================
  # 方法 6：压缩并分卷上传（粒度默认 1GB——正常 sync 多 GB 单文件可直传，
  # 100MB 粒度白白放大分卷数与 API 调用；OPENLIST_SPLIT_PART_BYTES 可调）
  local SPLIT_LIMIT_BYTES="${OPENLIST_SPLIT_PART_BYTES:-1073741824}"
  local SPLIT_PART_HUMAN
  SPLIT_PART_HUMAN=$(numfmt --to=iec-i --suffix=B "$SPLIT_LIMIT_BYTES" 2>/dev/null || echo "${SPLIT_LIMIT_BYTES}B")
  if _method_blocked m6; then
    log_fix "$fix_log" "$(_method_desc m6) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 6: 压缩并分卷上传（粒度 ${SPLIT_PART_HUMAN}）"
  local m6_split_dir="${temp_dir}/split_m6"
  mkdir -p "$m6_split_dir"
  local m6_zip_base="${file_name}.zip"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${m6_zip_base}" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m6 7z: $line"; done
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
        while IFS= read -r line; do log_fix "$fix_log" "m6 split: $line"; done
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
        while IFS= read -r line; do log_fix "$fix_log" "m6 upload[$m6_total_parts]: $line"; done
      local m6_part_rc=${PIPESTATUS[0]}
      local m6_part_expected
      m6_part_expected=$(stat -c%s "$m6_part_file" 2>/dev/null || stat -f%z "$m6_part_file" 2>/dev/null || echo 0)
      local m6_part_dst_size
      m6_part_dst_size=$(rclone size --json "$m6_dst_part" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
      if [ "$m6_part_rc" -eq 0 ] && [ "$m6_part_dst_size" = "$m6_part_expected" ] && [ "$m6_part_dst_size" -gt 0 ]; then
        m6_uploaded_count=$((m6_uploaded_count + 1))
        local m6_alt_rel="${m6_dst_part#${dest_path}/}"
        m6_alt_files+=("$m6_alt_rel")
        _artifact_add "$m6_dst_part"
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
    if [ "$m6_all_uploaded" -eq 1 ] && [ "$m6_uploaded_count" -gt 0 ] && _confirm_raw_persist "$(_method_desc m6)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 6 成功（${m6_uploaded_count} 个分卷）"
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
    log_fix "$fix_log" "方法 6 失败（全部分卷上传未成功）"
    _artifacts_cleanup "$fix_log"
    rm -rf "$m6_split_dir" 2>/dev/null || true
  else
    log_fix "$fix_log" "方法 6 zip 未生成，跳过"
  fi
  fi

  # ============================================================
  # 方法 7：压缩并 base64URL 编码文件名，切割为 100MB 以下的分卷再进行同步
  # ============================================================
  if _method_blocked m7; then
    log_fix "$fix_log" "$(_method_desc m7) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 7: 压缩+base64URL编码文件名+分卷切割上传"
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
    while IFS= read -r line; do log_fix "$fix_log" "m7 7z: $line"; done
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
        while IFS= read -r line; do log_fix "$fix_log" "m7 split: $line"; done
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
        while IFS= read -r line; do log_fix "$fix_log" "m7 upload[$m7_total_parts]: $line"; done
      local m7_part_rc=${PIPESTATUS[0]}
      local m7_part_expected
      m7_part_expected=$(stat -c%s "$m7_part_file" 2>/dev/null || stat -f%z "$m7_part_file" 2>/dev/null || echo 0)
      local m7_part_dst_size
      m7_part_dst_size=$(rclone size --json "$m7_dst_part" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
      if [ "$m7_part_rc" -eq 0 ] && [ "$m7_part_dst_size" = "$m7_part_expected" ] && [ "$m7_part_dst_size" -gt 0 ]; then
        m7_uploaded_count=$((m7_uploaded_count + 1))
        local m7_alt_rel="${m7_dst_part#${dest_path}/}"
        m7_alt_files+=("$m7_alt_rel")
        _artifact_add "$m7_dst_part"
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
    if [ "$m7_all_uploaded" -eq 1 ] && [ "$m7_uploaded_count" -gt 0 ] && _confirm_raw_persist "$(_method_desc m7)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 7 成功（${m7_uploaded_count} 个分卷）"
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
    log_fix "$fix_log" "方法 7 失败（全部分卷上传未成功）"
    _artifacts_cleanup "$fix_log"
    rm -rf "$m7_split_dir" 2>/dev/null || true
  else
    log_fix "$fix_log" "方法 7 zip 未生成，跳过"
  fi
  fi

  # 方法 8：OpenList API 直传
  if _method_blocked m8; then
    log_fix "$fix_log" "$(_method_desc m8) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 8: OpenList API 直传"
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
    _artifact_add "${actual_dst_dir}/${api_name}"
    if echo "$upload_http" | grep -qE 'HTTP_CODE:(200|201|204)' && _confirm_raw_persist "$(_method_desc m8)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 8 成功"
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
    log_fix "$fix_log" "方法 8 失败 (${upload_http})"
    _artifacts_cleanup "$fix_log"
  else
    log_fix "$fix_log" "方法 8 跳过（无法读取 OpenList token）"
  fi
  fi


  # 方法 9：上传到父目录（跳过有问题的目录层级）
  # 如果当前目录写操作被 wopan176 拒绝，尝试上传到上级目录
  # 文件名编码原始目录信息，便于后续还原
  if _method_blocked m9; then
    log_fix "$fix_log" "$(_method_desc m9) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  if [ "$file_dir_rel" != "." ] && [ "$file_dir_rel" != "" ]; then
    log_fix "$fix_log" "方法 9: 上传到父目录（跳过有问题的目录层级）"
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
      while IFS= read -r line; do log_fix "$fix_log" "m9 mkdir: $line"; done

    rclone copyto "$local_file" "$m9_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m9: $line"; done
    local m9_status=${PIPESTATUS[0]}
    _artifact_add "$m9_dst"
    if [ "$m9_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m9)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 9 成功"
      TRY_FIX_METHOD_ID="方法9: 上传到父目录（跳过有问题的目录层级）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（父目录 + 编码原始目录名的文件名）"
      TRY_FIX_ALTERNATIVE="${m9_dst#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${m9_dst}' '${dest_path}/${failed_file_rel}'"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 9 失败 (exit=$m9_status)"
    _artifacts_cleanup "$fix_log"
  fi
  fi




  # 方法 10：加密 zip 后上传（改变二进制特征 + 密码保护）
  if _method_blocked m10; then
    log_fix "$fix_log" "$(_method_desc m10) — 跳过（已判定该方法假成功，黑名单生效）"
  else
  log_fix "$fix_log" "方法 10: 加密 zip 后上传（改变二进制特征）"
  local zip_password="OpenList$(date +%s)"
  (cd "$temp_dir" && 7z a -tzip -p"$zip_password" -mem=AES256 "${file_name}.enc.zip" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m10 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.enc.zip" ]; then
    local m10_dst="${actual_dst_dir}/${file_name}.enc.zip"
    _artifact_add "$m10_dst"
    rclone copyto "$temp_dir/${file_name}.enc.zip" "$m10_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m10: $line"; done
    local m10_status=${PIPESTATUS[0]}
    if [ "$m10_status" -eq 0 ] && _confirm_raw_persist "$(_method_desc m10)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 10 成功"
      TRY_FIX_METHOD_ID="方法10: AES256 加密 zip 后上传（改变二进制特征）"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（AES256 加密 zip + .enc.zip 扩展名）"
      TRY_FIX_ALTERNATIVE="${m10_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m10_dst} 后解压: 7z x -p${zip_password} ${file_name}.enc.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 10 失败 (exit=$m10_status)"
    _artifacts_cleanup "$fix_log"
  else
    log_fix "$fix_log" "方法 10 加密 zip 未生成"
  fi
  fi

  # 方法 11：上传到临时目录后用 OpenList API move 移动
  # 在 backup 根目录创建临时目录，上传文件，然后用 API move 到目标路径
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    if _method_blocked m11; then
      log_fix "$fix_log" "$(_method_desc m11) — 跳过（已判定该方法假成功，黑名单生效）"
    else
    log_fix "$fix_log" "方法 11: 上传到临时目录后用 OpenList API move 移动"
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
    _artifact_add "${dest_path}/${tmp_dir_name}/${file_name}"
    if echo "$m11_upload_http" | grep -qE 'HTTP_CODE:(200|201|204)' && _confirm_raw_persist "$(_method_desc m11)" "$failed_file_rel" "$fix_log"; then
      log_fix "$fix_log" "方法 11 临时目录上传成功，尝试 move 到目标路径..."
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
        log_fix "$fix_log" "方法 11 move 成功"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传 + OpenList API move（原路径 + 原文件名）"
        TRY_FIX_ALTERNATIVE="$failed_file_rel"
        TRY_FIX_RESTORE="无需还原（文件已在正确路径）"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      else
        log_fix "$fix_log" "方法 11 move 失败，文件保留在临时目录: ${tmp_ol_dir}/${file_name}"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传（move 失败，文件保留在 ${tmp_dir_name}/）"
        TRY_FIX_ALTERNATIVE="${tmp_dir_name}/${file_name}"
        TRY_FIX_RESTORE="OpenList API: POST /api/fs/move {src_dir:'${tmp_ol_dir}/${file_name}', dst_dir:'/${ol_dst_base}/${failed_file_rel}'}"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      fi
    fi
    log_fix "$fix_log" "方法 11 临时目录上传失败 (${m11_upload_http})"
    _artifacts_cleanup "$fix_log"
    rclone rmdir "${dest_path}/${tmp_dir_name}" >/dev/null 2>&1 || true
  fi
  fi

  # 所有方法均失败 — 清理本次调用遗留的全部未持久化工件
  log_fix "$fix_log" "所有修复方法均失败"
  _artifacts_cleanup "$fix_log"
  TRY_FIX_MESSAGE="所有修复方法均失败"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 1
}
