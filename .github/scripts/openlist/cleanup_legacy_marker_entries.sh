#!/usr/bin/env bash
# ===== 旧格式 marker 条目一次性清理（V1 改版，§15.4，2026-09-22 用户决策）=====
# 决策沿革: 原方案「schema 自检 + 识别隔离」改为「全部清理，以后只有一种 marker 格式」。
# 判据（条目级，读现行代码定案）: fixed_files[] 条目带 restore.kind（restore_info.jq
#   序列化恒写入，全集 split_zip/hash_dir/short_hash_rename/base64url_dir/copy，
#   目录级批量折叠条目也是 kind=hash_dir，见 file_fix_pipeline.sh 目录级批量折叠段）。
#   缺 restore 或 kind 不在全集 ⇒ 旧格式条目，清理。
# fix_blacklist: 值**不删除**，按 file_fix.sh _fix_method_norm 同款映射归一重写为
#   语义 ID —— 删除会让文件重新尝试已判假成功的方法；改写无损（归一后语义不变）。
# 影响面: 被清条目保护的产物失去 filter 保护 ⇒ 下轮被 sync 删 ⇒ 源文件重回缺失按
#   新格式重修（用户已知情拍板）。只动 marker JSON，不碰媒体数据。
# 用法: cleanup_legacy_marker_entries.sh [--dry-run|--apply] <本地 marker 目录>
#   --dry-run（默认）: 只统计 + 逐 marker 留证清单，不改任何文件
#   --apply: 原地清理写回（调用方负责先把原目录备份到远端）
# 输出: 汇总到 stdout；逐 marker 留证写 <dir>/_legacy_evidence/<marker名>.legacy.json
set -euo pipefail

MODE="--dry-run"
DIR=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|--apply) MODE="$arg" ;;
    -h|--help) echo "用法: $0 [--dry-run|--apply] <本地 marker 目录>"; exit 0 ;;
    *) DIR="$arg" ;;
  esac
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "❌ 缺少有效的本地 marker 目录"; exit 1; }

# 与 file_fix.sh _fix_method_norm / restore_info.jq 保持同步的 kind 全集
KIND_RE='^(split_zip|hash_dir|short_hash_rename|base64url_dir|copy)$'
LEGACY_JQ="((.restore.kind // \"\") | test(\"$KIND_RE\") | not)"

EVDIR="$DIR/_legacy_evidence"
mkdir -p "$EVDIR"

total_files=0; files_with_legacy=0; total_entries=0; total_legacy=0; total_bl=0
report="$(mktemp)"

for f in "$DIR"/*.json; do
  [ -f "$f" ] || continue
  total_files=$((total_files + 1))
  name=$(basename "$f")
  stats=$(jq -r --argjson kre "null" '
    (.fixed_files // []) as $ff
    | ([$ff[] | select('"$LEGACY_JQ"')] ) as $legacy
    | [( $ff | length), ($legacy | length), ((.fix_blacklist // {}) | length)] | @tsv' "$f" 2>/dev/null || printf '0\t0\t0')
  IFS=$'\t' read -r n_total n_legacy n_bl <<< "$stats"
  [[ "$n_total" =~ ^[0-9]+$ ]] || n_total=0
  [[ "$n_legacy" =~ ^[0-9]+$ ]] || n_legacy=0
  [[ "$n_bl" =~ ^[0-9]+$ ]] || n_bl=0
  total_entries=$((total_entries + n_total))
  total_bl=$((total_bl + n_bl))
  [ "$n_legacy" -eq 0 ] && continue
  files_with_legacy=$((files_with_legacy + 1))
  total_legacy=$((total_legacy + n_legacy))
  # 留证: 旧条目原文（original/alternative/method/alternative 的产物形态），
  # apply 后这些产物将失去 filter 保护 —— 清单供核对与必要时人工接管
  # 注: jq 对象值表达式必须整体括号包裹，裸写 key: .x // "y" 是编译错误
  #   （sync_marker.sh 修复方式汇总段同款教训）
  jq '{marker: (.last_success // "(无时间戳)"),
       legacy: [.fixed_files[] | select('"$LEGACY_JQ"') |
                {original, alternative, method, size_bytes}]}' "$f" \
    > "$EVDIR/${name%.json}.legacy.json"
  printf '%s\t%s\t%s\n' "$name" "$n_total" "$n_legacy" >> "$report"
done

echo "===== 旧格式条目清理报告（mode=$MODE）====="
echo "扫描 marker: $total_files 个 · 含旧条目的: $files_with_legacy 个"
echo "条目: 总 $total_entries · 旧格式 $total_legacy · 保留 $((total_entries - total_legacy))"
echo "黑名单条目（将归一重写，不删除）: $total_bl"
if [ -s "$report" ]; then
  echo "----- 逐 marker（名称 / 总条目 / 旧条目）-----"
  sort -t$'\t' -k3,3nr "$report" | head -40
fi
echo "留证目录: $EVDIR"

if [ "$MODE" = "--apply" ]; then
  changed=0
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    tmp=$(mktemp)
    # 清理旧条目 + 黑名单归一（映射关系与 _fix_method_norm 一致；长名优先无子串冲突:
    # 四个语义 ID 互不为彼此子串）。未识别的值原样保留，绝不静默丢弃。
    if jq '
      .fixed_files = ([(.fixed_files // [])[] | select('"$LEGACY_JQ"' | not)])
      | .fix_blacklist = ((.fix_blacklist // {}) | to_entries | map(
          .value = ([.value | split("|") | .[] |
            if   test("zip_split_shorthash") then "zip_split_shorthash"
            elif test("zip_split_original")  then "zip_split_original"
            elif test("copyto_shorthash")    then "copyto_shorthash"
            elif test("copyto_original")     then "copyto_original"
            elif test("分卷·短名")            then "zip_split_shorthash"
            elif test("分卷·原名")            then "zip_split_original"
            elif test("短名直传")             then "copyto_shorthash"
            elif test("原名直传")             then "copyto_original"
            else . end] | unique | join("|"))
        ) | from_entries)
    ' "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      if ! cmp -s "$f" "$tmp"; then
        mv "$tmp" "$f"
        changed=$((changed + 1))
      else
        rm -f "$tmp"
      fi
    else
      echo "⚠️ jq 处理失败，保持原样: $(basename "$f")"
      rm -f "$tmp"
    fi
  done
  echo "===== apply 完成: 改写 $changed 个 marker ====="
  # 终检: 清理后任何 marker 里都不应再有旧格式条目（判据静默失败的直接反证）
  residual=$(cat "$DIR"/*.json 2>/dev/null | jq -rs '
    [ .[] | (.fixed_files // [])[] | select('"$LEGACY_JQ"') ] | length' 2>/dev/null || echo "ERR")
  if [ "$residual" = "0" ]; then
    echo "✅ 终检通过: 残留旧格式条目 0"
  else
    echo "❌ 终检失败: 残留旧格式条目 $residual —— 中止上传，保留现场排查"
    exit 1
  fi
else
  echo "（dry-run 未改任何文件；确认存量后用 --apply 执行）"
fi
