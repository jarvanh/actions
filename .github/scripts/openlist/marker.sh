#!/bin/bash
# ===== OpenList 同步工具 — 同步标记系统 =====
# 通过在 OneDrive 上保存 JSON 标记文件来跟踪每个 task 的同步状态。
# 功能:
#   - 跳过短期内已成功同步的 task（默认 24 小时）
#   - 检测源端大小异常减小（可能数据丢失），发送警告并跳过
#
# 标记存储路径: onedrive:/logs/sync_state/<task_name>_<dest_hash>.json
# JSON 字段: last_success, source_path, dest_path, source_bytes, source_count, top_dirs
#
# 依赖: utils.sh (escape_html, format_bytes), telegram.sh (send_telegram_message)
# 依赖环境变量: FORCE_SYNC — 为 "true" 时跳过所有标记检查

# 标记存储目录
SYNC_STATE_DIR="onedrive:/logs/sync_state"
# 默认跳过时间窗口（24 小时，可被 SYNC_SKIP_SECONDS 覆盖）
SYNC_SKIP_SECONDS=$((24 * 60 * 60))

# 生成标记文件路径（每个 task+dest 组合唯一）
# 用法: get_marker_path <task_name> <dest_path>
get_marker_path() {
  local task_name="$1"
  local dest_path="$2"
  local dest_hash
  dest_hash=$(echo -n "${task_name}_${dest_path}" | md5sum | cut -c1-8)
  echo "${SYNC_STATE_DIR}/${task_name}_${dest_hash}.json"
}

# 保存同步标记（同步成功后调用）
# 记录: 时间戳、源端路径、目标路径、源端大小/文件数、顶层目录列表、已修复文件列表
# 已修复文件列表 (fixed_files): 通过 405/409 修复机制以非原名上传的文件
#   预览时从差异中扣减这部分，避免显示"虚假缺失"
# 用法: save_sync_marker <source_path> <dest_path> <task_name>
save_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 获取源端大小和文件数
  local size_json source_bytes source_count
  size_json=$(rclone size "$source_path" --json 2>/dev/null || true)
  source_bytes=$(echo "$size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  source_count=$(echo "$size_json" | jq -r '.count // 0' 2>/dev/null || echo 0)

  # 获取顶层目录列表（用于检测目录变化）
  local top_dirs
  top_dirs=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||' | sort)

  # 读取本任务（含 auto-split 子目录）累计的修复文件列表
  # sync_with_logging 每次执行后会把 fix_list 累计到 GLOBAL_FIXED_FILES_JSON
  local new_fixed_json="${GLOBAL_FIXED_FILES_JSON:-[]}"

  # ===== Carry-Forward 机制 =====
  # 重新同步如果没触发 405/409，new_fixed_json 会是空数组，但旧 marker 里的修复记录
  # 仍然有效（目标端以替代名存在、源端原名路径仍未对齐）。这里从旧 marker 继承：
  #   - 目标端 <dest_path>/<original> 仍不存在的修复记录 → 保留
  #   - 目标端已经出现原名文件 → 说明这次同步已正常对齐，不再继承
  local carried_json="[]"
  local carried_count=0
  local old_marker
  old_marker=$(rclone cat "$marker_path" 2>/dev/null || echo "")
  if [ -n "$old_marker" ]; then
    local old_fixed_count
    old_fixed_count=$(echo "$old_marker" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    if [ "${old_fixed_count:-0}" -gt 0 ]; then
      # 取每条旧修复记录，检查目标端是否已出现原名文件
      local carried_entries=()
      local idx total carried_flag orig_size
      total=$old_fixed_count
      # 用 jq 一次把所有 original / alternative 拉成 tsv 便于 shell 逐行处理
      local tsv
      tsv=$(echo "$old_marker" | jq -r '
        (.fixed_files // []) | to_entries[]
        | [.key, (.value.original // ""), (.value.alternative // ""), (.value.size_bytes // 0)]
        | @tsv' 2>/dev/null || echo "")

      local old_fixed_json
      old_fixed_json=$(echo "$old_marker" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

      while IFS=$'\t' read -r idx orig _dummy size_bytes; do
        [ -z "$orig" ] && continue
        # 检查目标端是否已存在原名文件（已存在则无需再继承，本次同步已正常完成）
        # rclone lsjson 快速探测，取第一个条目即可
        local probe
        probe=$(timeout 20 rclone lsjson "${dest_path}/${orig}" --max-depth 1 2>/dev/null || echo "[]")
        local exists
        exists=$(echo "$probe" | jq -r 'length // 0' 2>/dev/null || echo 0)
        if [ "${exists:-0}" -eq 0 ]; then
          # 原名仍不存在 → 此修复记录仍有效，继承
          carried_entries+=("$idx")
          carried_count=$((carried_count + 1))
        fi
      done <<< "$tsv"

      if [ "${#carried_entries[@]}" -gt 0 ]; then
        # 按 idx 把 carried 的条目从 old_fixed_json 里抽出来
        local idx_args
        idx_args=$(printf ', .[%s]' "${carried_entries[@]}")
        idx_args=${idx_args#, }  # 去掉第一个逗号
        carried_json=$(echo "$old_fixed_json" | jq -c "[ $idx_args ]" 2>/dev/null || echo "[]")
      fi
      echo "旧标记修复记录: ${old_fixed_count} 条，继承有效 ${carried_count} 条，已对齐自动剔除 $((old_fixed_count - carried_count)) 条"
    fi
  fi

  # ===== Fallback: marker 被删除或首次同步时，从目标端扫描"修复特征"文件 =====
  # 只在顶级调用（current_depth=0 或未定义）时扫描，避免 auto-split 子目录重复扫描
  local fallback_json="[]"
  local fallback_count=0
  local total_new total_carried depth="${current_depth:-0}"
  total_new=$(echo "$new_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  total_carried=$(echo "$carried_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "${total_new:-0}" -eq 0 ] && [ "${total_carried:-0}" -eq 0 ] && [ "${depth:-0}" -eq 0 ]; then
    echo "未发现修复记录（marker 可能被删），尝试从目标端扫描特征文件反推..."

    local _tmp_out _tmp_py
    _tmp_out=$(mktemp)
    _tmp_py=$(mktemp).py
    # 把扫描脚本写进临时文件（Python 内用 subprocess.run(list) 传参，安全）
    cat > "$_tmp_py" << 'PYEOF'
import sys, os, re, base64, subprocess

def main():
    if len(sys.argv) < 4:
        return
    src_remote = sys.argv[1]
    dst_remote = sys.argv[2]
    out_path   = sys.argv[3]
    timeout_s  = int(sys.argv[4]) if len(sys.argv) > 4 else 300

    def b64url_decode(s):
        s = s.replace('-', '+').replace('_', '/')
        pad = (-len(s)) % 4
        try:
            return base64.b64decode(s + '=' * pad).decode('utf-8', errors='replace')
        except Exception:
            return None

    def rclone_lsf(remote, files_only=False, with_size=False, timeout_s=timeout_s):
        args = ["rclone", "lsf", remote, "-R"]
        if files_only:
            args.append("--files-only")
        if with_size:
            args += ["--format", "ps", "--separator", ";"]
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=timeout_s)
            return r.stdout
        except Exception:
            return ""

    src_listing = rclone_lsf(src_remote)
    src_by_basename = {}
    src_full_set = set()
    src_dir_leaf_set = set()
    for line in src_listing.splitlines():
        line = line.rstrip('/').strip()
        if not line:
            continue
        src_full_set.add(line)
        parts = line.split('/')
        for i, p in enumerate(parts):
            if i == len(parts) - 1:
                src_by_basename.setdefault(p, []).append(line)
            else:
                src_dir_leaf_set.add(p)

    dst_listing = rclone_lsf(dst_remote, files_only=True, with_size=True)

    results = []
    API_RE = re.compile(r'^file_(\d+)_(\d+)_api(\..+)?$')

    for line in dst_listing.splitlines():
        if ';' not in line:
            continue
        path, _, s = line.rpartition(';')
        try:
            size_bytes = int(s)
        except ValueError:
            size_bytes = 0
        if not path:
            continue
        parts = path.split('/')
        fname = parts[-1]
        dir_parts = parts[:-1]
        matched = False

        # === 特征 1: .zip / .7z 包，去掉后缀文件名在源端存在 ===
        if fname.lower().endswith('.zip') or fname.lower().endswith('.7z'):
            ext_len = 4 if fname.lower().endswith('.zip') else 3
            orig_fname = fname[:-ext_len]
            if orig_fname in src_by_basename:
                used_b64_dir = False
                matched_dir_rel = '/'.join(dir_parts)
                if dir_parts:
                    dl = b64url_decode(dir_parts[-1])
                    if dl and dl in src_dir_leaf_set:
                        used_b64_dir = True
                        nd = dir_parts[:-1] + [dl]
                        cand = '/'.join(nd + [orig_fname])
                        if cand in src_full_set:
                            matched_dir_rel = '/'.join(nd)
                zip_tag = "zip" if fname.lower().endswith('.zip') else "7z"
                dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                method = f"rclone copyto（{dp}{zip_tag} 压缩包）"
                original = f"{matched_dir_rel}/{orig_fname}" if matched_dir_rel else orig_fname
                if original in src_full_set:
                    results.append((original, path, method, size_bytes))
                    matched = True

        # === 特征 2: API 自动生成文件名 file_<ts>_<pid>_api.<ext> ===
        if not matched:
            m = API_RE.match(fname)
            if m:
                ext = m.group(3) or ''
                candidates = []
                if dir_parts:
                    dl = b64url_decode(dir_parts[-1]) if dir_parts else None
                    probe_dirs = ['/'.join(dir_parts)]
                    if dl and dl in src_dir_leaf_set:
                        probe_dirs.append('/'.join(dir_parts[:-1] + [dl]))
                    for d in probe_dirs:
                        for _, fulls in src_by_basename.items():
                            for full in fulls:
                                if full.startswith(d + '/') and full.endswith(ext):
                                    candidates.append(full)
                    if not candidates and ext:
                        for _, fulls in src_by_basename.items():
                            for full in fulls:
                                if full.endswith(ext):
                                    candidates.append(full)
                if candidates:
                    original = sorted(set(candidates))[0]
                    used_b64_dir = False
                    if dir_parts:
                        dl = b64url_decode(dir_parts[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                    dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                    method = f"OpenList API /fs/form（{dp}API 自动生成文件名）"
                    results.append((original, path, method, size_bytes))
                    matched = True

        # === 特征 3: 文件名是 base64URL，解码后出现在源端同目录同扩展名 ===
        if not matched:
            if '.' in fname:
                nb, ext = fname.rsplit('.', 1)
                decoded = b64url_decode(nb)
                if decoded:
                    orig_name = decoded + '.' + ext
                    pp = list(dir_parts)
                    used_b64_dir = False
                    if pp:
                        dl = b64url_decode(pp[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                            pp[-1] = dl
                    cand = '/'.join(pp + [orig_name]) if pp else orig_name
                    if cand in src_full_set:
                        dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                        method = f"rclone copyto（{dp}base64URL 编码文件名）"
                        results.append((cand, path, method, size_bytes))
                        matched = True
            else:
                decoded = b64url_decode(fname)
                if decoded:
                    pp = list(dir_parts)
                    used_b64_dir = False
                    if pp:
                        dl = b64url_decode(pp[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                            pp[-1] = dl
                    cand = '/'.join(pp + [decoded]) if pp else decoded
                    if cand in src_full_set:
                        dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                        method = f"rclone copyto（{dp}base64URL 编码文件名）"
                        results.append((cand, path, method, size_bytes))
                        matched = True

        # === 特征 4: 只有目录最末段是 base64URL，文件名和源端相同 ===
        if not matched and dir_parts:
            dl = b64url_decode(dir_parts[-1])
            if dl and dl in src_dir_leaf_set:
                nd = dir_parts[:-1] + [dl]
                cand = '/'.join(nd + [fname])
                if cand in src_full_set:
                    method = "rclone copyto（base64URL 编码目录 + 原文件名）"
                    results.append((cand, path, method, size_bytes))

    # 去重：按 original，保留 size 更大条目
    seen = {}
    for orig, alt, method, sz in results:
        if orig not in seen or sz > seen[orig][3]:
            seen[orig] = (orig, alt, method, sz)
    with open(out_path, 'w', encoding='utf-8') as f:
        for orig, (_, alt, method, sz) in seen.items():
            esc_tab = lambda s: s.replace('\t', ' ').replace('\n', ' ')
            f.write(f"{esc_tab(orig)}\t{esc_tab(alt)}\t{esc_tab(method)}\t{sz}\n")

main()
PYEOF

    if timeout 600 python3 "$_tmp_py" "$source_path" "$dest_path" "$_tmp_out" 300 </dev/null 2>/dev/null; then
      :
    else
      echo "扫描超时或出错（忽略 fallback）"
      : > "$_tmp_out"
    fi

    if [ -s "$_tmp_out" ]; then
      fallback_count=$(wc -l < "$_tmp_out" | tr -d ' ')
      if [ "${fallback_count:-0}" -gt 0 ]; then
        echo "目标端扫描命中修复特征文件: ${fallback_count} 个，写入 fixed_files"
        local fb_entries=()
        while IFS=$'\t' read -r fb_orig fb_alt fb_method fb_sz; do
          [ -z "$fb_orig" ] && continue
          local fb_shuman
          fb_shuman=$(format_bytes "$fb_sz" 2>/dev/null || echo "${fb_sz} B")
          local fb_script tmpl
          tmpl="此条目为 fallback 扫描生成，请参考 method 字段手动还原：original=${fb_orig} alternative=${fb_alt} method=${fb_method}"
          fb_entries+=("$(jq -cn \
            --arg o "$fb_orig" --arg a "$fb_alt" --arg m "$fb_method" \
            --arg sh "$fb_shuman" --argjson sb "${fb_sz:-0}" \
            --arg scr "$tmpl" \
            '{original:$o, alternative:$a, method:$m,
              size_human:$sh, size_bytes:$sb,
              restore:{kind:"scanned",
                       summary:"从目标端特征扫描反推（非修复时直接记录的精确信息）",
                       steps:["下载目标端 alternative 路径文件",
                              "根据 method 字段对应方式还原：base64URL 解码目录名/文件名、unzip/7z x 解压、重命名 API 文件"],
                       script: ("# " + $scr)}}')")
        done < "$_tmp_out"
        if [ "${#fb_entries[@]}" -gt 0 ]; then
          local _tmp_json
          _tmp_json=$(mktemp)
          printf '%s\n' "${fb_entries[@]}" | jq -sc '.' > "$_tmp_json" 2>/dev/null || echo "[]" > "$_tmp_json"
          fallback_json=$(cat "$_tmp_json")
          fallback_count=$(echo "$fallback_json" | jq 'length' 2>/dev/null || echo 0)
          rm -f "$_tmp_json"
        fi
      fi
    fi
    rm -f "$_tmp_out" "$_tmp_py"
  fi

  # 合并: 本轮新修复 ∪ 继承修复 ∪ fallback 扫描修复，以 original 为 key 去重
  # 优先级: 新修复 > 继承 > fallback（新修复信息更精确）
  local merged_fixed_json
  merged_fixed_json=$(jq -sc --argjson new "$new_fixed_json" \
                           --argjson carried "$carried_json" \
                           --argjson fb "$fallback_json" '
    def without_originals($arr; $orig_set):
      [$arr[] | select(.original as $o | ($orig_set | map(.original) | index($o) | not))];
    $new as $N
    | (without_originals($carried; $N)) as $C
    | (without_originals($fb; ($N + $C))) as $F
    | $N + $C + $F
  ' 2>/dev/null)
  # 上面 jq 写法较复杂容易错，失败时降级为 new ∪ carried
  if [ -z "$merged_fixed_json" ]; then
    merged_fixed_json=$(jq -sc --argjson new "$new_fixed_json" --argjson carried "$carried_json" '
      $new + ([$carried[] | select((.original as $o | $new | map(.original == $o) | any) | not)])
    ' 2>/dev/null || echo "[]")
  fi

  local fixed_count fixed_bytes
  fixed_count=$(echo "$merged_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$merged_fixed_json" | jq '[.[].size_bytes] | add // 0' 2>/dev/null || echo 0)

  # 构建 JSON 标记
  local marker_json
  marker_json=$(jq -n \
    --arg last_success "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_path "$source_path" \
    --arg dest_path "$dest_path" \
    --argjson source_bytes "$source_bytes" \
    --argjson source_count "$source_count" \
    --arg top_dirs "$top_dirs" \
    --argjson fixed_files "$merged_fixed_json" \
    --argjson fixed_count "$fixed_count" \
    --argjson fixed_bytes "$fixed_bytes" \
    '{last_success: $last_success, source_path: $source_path, dest_path: $dest_path, source_bytes: $source_bytes, source_count: $source_count, top_dirs: $top_dirs, fixed_files: $fixed_files, fixed_count: $fixed_count, fixed_bytes: $fixed_bytes}')

  # 上传标记到 OneDrive
  rclone mkdir "$SYNC_STATE_DIR" >/dev/null 2>&1 || true
  echo "$marker_json" | rclone rcat "$marker_path" 2>/dev/null
  local summary=""
  local new_count fb_count
  new_count=$(echo "$new_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  fb_count=$(echo "$fallback_json" | jq 'length' 2>/dev/null || echo 0)
  [ "$new_count" -gt 0 ] && summary+=" 本次修复 ${new_count} 个;"
  [ "$carried_count" -gt 0 ] && summary+=" 继承上轮 ${carried_count} 个;"
  [ "${fb_count:-0}" -gt 0 ] && summary+=" fallback扫描反推 ${fb_count} 个;"
  echo "已保存同步标记: $marker_path (源端 $(format_bytes "$source_bytes"), ${source_count} 文件, 修复合计 ${fixed_count} 个${summary})"
}

# 检查同步标记（同步前调用）
# 设置全局变量:
#   MARKER_ACTION        — "skip" | "warning" | "proceed"
#   MARKER_JSON          — 标记 JSON 原文
#   MARKER_CURRENT_BYTES — 当前源端字节数
#   MARKER_CURRENT_COUNT — 当前源端文件数
#   MARKER_CURRENT_DIRS  — 当前源端顶层目录列表
#   MARKER_LAST_SUCCESS  — 上次成功时间（ISO 8601）
#   MARKER_SINCE_HOURS   — 距上次同步的小时数
#   MARKER_FIXED_COUNT   — 已修复文件数（以非原名存在于目标端）
#   MARKER_FIXED_BYTES   — 已修复文件总字节数
#   MARKER_FIXED_FILES   — 已修复文件列表 JSON
# 用法: check_sync_marker <source_path> <dest_path> <task_name>
check_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  MARKER_ACTION="proceed"
  MARKER_JSON=""
  MARKER_CURRENT_BYTES=0
  MARKER_CURRENT_COUNT=0
  MARKER_CURRENT_DIRS=""
  MARKER_LAST_SUCCESS=""
  MARKER_SINCE_HOURS=0
  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"

  # 强制同步跳过所有检查
  if [ "$FORCE_SYNC" = "true" ]; then
    echo "强制同步模式，跳过标记检查"
    return 0
  fi

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 下载标记
  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  if [ -z "$marker_json" ]; then
    echo "无同步标记，继续同步"
    return 0
  fi

  MARKER_JSON="$marker_json"

  # 解析已修复文件信息（用于预览扣减和跳过通知）
  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

  # 解析上次成功时间
  local last_success
  last_success=$(echo "$marker_json" | jq -r '.last_success // ""')

  if [ -z "$last_success" ]; then
    echo "标记无时间戳，继续同步"
    return 0
  fi

  # 检查是否在跳过时间窗口内
  local now_epoch last_epoch diff
  now_epoch=$(date +%s)
  last_epoch=$(date -d "$last_success" +%s 2>/dev/null || echo 0)

  if [ "$last_epoch" -gt 0 ]; then
    diff=$((now_epoch - last_epoch))
    if [ "$diff" -lt "$SYNC_SKIP_SECONDS" ]; then
      echo "$((SYNC_SKIP_SECONDS / 3600))小时内已成功同步（距今 $((diff / 3600)) 小时），跳过"
      MARKER_ACTION="skip"
      MARKER_LAST_SUCCESS="$last_success"
      MARKER_SINCE_HOURS=$((diff / 3600))
      return 0
    fi
  fi

  # 检查源端大小是否减小（可能数据丢失）
  local marker_bytes
  marker_bytes=$(echo "$marker_json" | jq -r '.source_bytes // 0')

  local current_size_json
  current_size_json=$(rclone size "$source_path" --json 2>/dev/null || true)
  MARKER_CURRENT_BYTES=$(echo "$current_size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  MARKER_CURRENT_COUNT=$(echo "$current_size_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  MARKER_CURRENT_DIRS=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||' | sort)

  if [ "$MARKER_CURRENT_BYTES" -lt "$marker_bytes" ]; then
    echo "⚠️ 源端大小减小: $(format_bytes "$marker_bytes") → $(format_bytes "$MARKER_CURRENT_BYTES")"
    MARKER_ACTION="warning"
    return 0
  fi

  echo "标记检查通过，继续同步"
  MARKER_ACTION="proceed"
  return 0
}

# 仅加载 marker 的 fixed_files 信息（不做跳过判断，供预览使用）
# 设置全局变量: MARKER_FIXED_COUNT, MARKER_FIXED_BYTES, MARKER_FIXED_FILES
# 用法: _load_marker_fixed_files <source_path> <dest_path> <task_name>
_load_marker_fixed_files() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  [ -z "$marker_json" ] && return 0

  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")
}

# 发送源端大小减小的警告通知（同时跳过本次同步）
# 依赖全局变量: MARKER_JSON, MARKER_CURRENT_BYTES, MARKER_CURRENT_COUNT, MARKER_CURRENT_DIRS
# 用法: send_sync_warning <task_name> <source_path> <dest_path>
send_sync_warning() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count marker_dirs
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0')
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0')
  marker_dirs=$(echo "$MARKER_JSON" | jq -r '.top_dirs // ""')

  local diff_bytes=$((marker_bytes - MARKER_CURRENT_BYTES))
  local diff_count=$((marker_count - MARKER_CURRENT_COUNT))
  local pct=0
  if [ "$marker_bytes" -gt 0 ]; then
    pct=$((diff_bytes * 100 / marker_bytes))
  fi

  # 找出缺失和新增的目录
  local missing_dirs="" new_dirs=""
  if [ -n "$marker_dirs" ] && [ -n "$MARKER_CURRENT_DIRS" ]; then
    missing_dirs=$(comm -23 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
    new_dirs=$(comm -13 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
  fi

  # HTML 转义动态内容
  local e_task e_source e_dest
  e_task=$(escape_html "$task_name")
  e_source=$(escape_html "$source_path")
  e_dest=$(escape_html "$dest_path")

  local msg=""
  msg+="🚨🚨🚨 <b>源端大小异常减小</b> 🚨🚨🚨"$'\n'
  msg+="━━━━━━━━━━━━━━━━━━"$'\n'
  msg+="任务：<b>${e_task}</b>"$'\n'
  msg+="源端：<code>${e_source}</code>"$'\n'
  msg+="目标：<code>${e_dest}</code>"$'\n'
  msg+=$'\n'"📊 <b>大小对比</b>"$'\n'
  msg+="• 上次记录：<b>$(format_bytes "$marker_bytes")</b> (${marker_count} 文件)"$'\n'
  msg+="• 当前大小：<b>$(format_bytes "$MARKER_CURRENT_BYTES")</b> (${MARKER_CURRENT_COUNT} 文件)"$'\n'
  msg+="• 减少：<b>$(format_bytes "$diff_bytes")</b> (-${pct}%)"$'\n'
  if [ "$diff_count" -ne 0 ]; then
    msg+="• 文件减少：<b>${diff_count}</b> 个"$'\n'
  fi

  if [ -n "$missing_dirs" ]; then
    msg+=$'\n'"📁 <b>缺失的目录（可能被删除）</b>"$'\n'
    while IFS= read -r d; do
      [ -n "$d" ] && msg+="• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$missing_dirs"
  fi

  if [ -n "$new_dirs" ]; then
    msg+=$'\n'"📁 <b>新增的目录</b>"$'\n'
    while IFS= read -r d; do
      [ -n "$d" ] && msg+="• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$new_dirs"
  fi

  msg+=$'\n'"⏸️ <b>已跳过此同步，继续执行其他任务</b>"$'\n'
  msg+="如确认无误，请手动触发 force_sync=true"

  send_telegram_message "$msg" "HTML"
}

# 发送"近期已成功同步，本次跳过"的通知
# 依赖全局变量: MARKER_LAST_SUCCESS, MARKER_SINCE_HOURS, MARKER_JSON
# 用法: send_sync_skipped <task_name> <source_path> <dest_path>
send_sync_skipped() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0' 2>/dev/null || echo 0)
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0' 2>/dev/null || echo 0)

  # 已修复文件信息（通过 405/409 修复机制以非原名上传的文件）
  local fixed_count fixed_bytes
  fixed_count=$(echo "$MARKER_JSON" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$MARKER_JSON" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)

  # HTML 转义动态内容
  local e_task e_source e_dest e_last
  e_task=$(escape_html "$task_name")
  e_source=$(escape_html "$source_path")
  e_dest=$(escape_html "$dest_path")
  e_last=$(escape_html "$MARKER_LAST_SUCCESS")

  local msg=""
  msg+="⏭️ <b>同步任务跳过（1 天内已成功）</b>"$'\n'
  msg+="━━━━━━━━━━━━━━━━━━"$'\n'
  msg+="任务：<b>${e_task}</b>"$'\n'
  msg+="源端：<code>${e_source}</code>"$'\n'
  msg+="目标：<code>${e_dest}</code>"$'\n'
  msg+=$'\n'"🕒 <b>上次同步</b>"$'\n'
  msg+="• 时间：<code>${e_last}</code>"$'\n'
  msg+="• 距今：<b>${MARKER_SINCE_HOURS}</b> 小时"$'\n'
  msg+="• 记录大小：$(format_bytes "$marker_bytes") (${marker_count} 文件)"$'\n'
  if [ "${fixed_count:-0}" -gt 0 ]; then
    msg+="• 已修复文件：<b>${fixed_count}</b> 个 ($(format_bytes "$fixed_bytes"))，以非原名存在于目标端"$'\n'
    # 修复方式汇总（按 restore.kind 分组统计）
    local method_summary
    method_summary=$(echo "$MARKER_JSON" | jq -r '
      (.fixed_files // []) | group_by(.restore.kind // "unknown")
        | map({kind: .[0].restore.kind // "unknown",
               summary: .[0].restore.summary // "",
               count: length,
               bytes: ([.[].size_bytes] | add // 0)})
        | sort_by(-.bytes)
        | map("    · " + .kind + " (" + (.count|tostring) + " 个/"
            + (.bytes | tostring | if tonumber>0 then tonumber|tostring else "0" end) + "B) "
            + .summary)
        | join("\n")
    ' 2>/dev/null || echo "")
    [ -n "$method_summary" ] && msg+=$'\n'"🔧 <b>修复方式构成</b>"$'\n'"${method_summary}"$'\n'
    msg+="🔗 完整还原脚本保存在 OneDrive marker: <code>$(get_marker_path "$task_name" "$dest_path")</code> 的 fixed_files[].restore.script 字段"$'\n'
  fi
  msg+=$'\n'"⏸️ <b>本次跳过同步，继续执行其他任务</b>"$'\n'
  msg+="如需强制同步，请手动触发 force_sync=true"

  send_telegram_message "$msg" "HTML"
}
