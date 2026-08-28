#!/bin/bash
# 文件修复方法 ID 语义命名 —— 回归测试
# 背景: 方法 ID 原为 m1/m2/m3/m4 序号，代码里读 _fix_method_gate m3 无法自
#   解释（得回查 _method_desc 才知道是"zip 分卷"），且方法增删时序号会漂移。
#   现改为语义名 copyto_original / copyto_shorthash / zip_split_original /
#   zip_split_shorthash，全名格式为:
#       文件修复方法N <语义ID>: <方法形态说明>
# 三个命名约束（均为踩过的坑）:
#   1. 自解释: 全名含语义 ID 与形态说明，日志里一眼可辨，无需回查映射表
#   2. 带"文件修复"限定词: 仓库里另有多处独立的"方法N"编号体系，最易混的
#      是 sync.sh _refresh_ol_drivers 的驱动刷新三招（驱动刷新方法1 load_all /
#      方法2 重启容器 / 方法3 storage 探测）。不带限定词无法区分领域。
#   3. 说明方法形态: 原名 / 短哈希名 + 是否 zip 分卷，这是选方法的依据
#      （如密文名超长时必须避开带原名的方法）
# 不兼容历史: 旧写法（"方法1: ..."、m1）按未知方法原样返回，不再归一。
# 验证:
#   1. 四个语义 ID → 对应全名（含限定词 + 语义名 + 形态说明）
#   2. 全名可自解释: 含"文件修复"限定词与形态关键词（原名/短哈希/分卷）
#   3. 与驱动刷新方法不混淆: 两套全名字面不重叠
#   4. 旧写法不再被归一（按未知方法原样返回）
#   5. 未知/空输入不误伤
#   6. _method_short 输入语义 ID / 全名均输出同一短标签（带"修复"限定词）
#   7. 黑名单通道: 拉黑与查询用同一 ID 互通，重复拉黑不产生重复条目
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/fix.sh" 2>/dev/null

# 现行全名（与 _method_desc 输出严格一致，改全名文案时此处需同步）
D1="文件修复方法1 copyto_original: 直接 rclone copyto（原路径 + 原文件名）"
D2="文件修复方法2 copyto_shorthash: 短哈希文件名直传（<md5前8位>.<扩展名>）"
D3="文件修复方法3 zip_split_original: zip 压缩 + 分卷上传（原文件名基底，默认 1GB 分卷）"
D4="文件修复方法4 zip_split_shorthash: zip 压缩 + 短哈希文件名 + 分卷上传"

# --- 1. 语义 ID → 全名 ---
[ "$(_method_desc copyto_original)" = "$D1" ] && ok "1a copyto_original → 文件修复方法1" || bad "1a: $(_method_desc copyto_original)"
[ "$(_method_desc copyto_shorthash)" = "$D2" ] && ok "1b copyto_shorthash → 文件修复方法2" || bad "1b: $(_method_desc copyto_shorthash)"
[ "$(_method_desc zip_split_original)" = "$D3" ] && ok "1c zip_split_original → 文件修复方法3" || bad "1c: $(_method_desc zip_split_original)"
[ "$(_method_desc zip_split_shorthash)" = "$D4" ] && ok "1d zip_split_shorthash → 文件修复方法4" || bad "1d: $(_method_desc zip_split_shorthash)"

# --- 2. 全名自解释: 限定词 + 语义名 + 形态关键词 ---
for _d in "$D1" "$D2" "$D3" "$D4"; do
  echo "$_d" | grep -q "文件修复" || bad "2 全名缺'文件修复'限定词: $_d"
done
ok "2a 四个全名均带'文件修复'限定词"
# 语义名内嵌全名（读日志即知方法，无需回查）
echo "$D3" | grep -q "zip_split_original" && ok "2b 全名内嵌语义 ID" || bad "2b: $D3"
# 形态可辨: 原名 vs 短哈希、是否分卷
echo "$D1" | grep -q "原文件名" && ok "2c 文件修复方法1 说明用原名" || bad "2c: $D1"
echo "$D2" | grep -q "短哈希" && ok "2d 文件修复方法2 说明用短哈希名" || bad "2d: $D2"
echo "$D3" | grep -q "分卷" && echo "$D3" | grep -q "原文件名基底" \
  && ok "2e 文件修复方法3 说明分卷 + 原名基底" || bad "2e: $D3"
echo "$D4" | grep -q "分卷" && echo "$D4" | grep -q "短哈希" \
  && ok "2f 文件修复方法4 说明分卷 + 短哈希名" || bad "2f: $D4"

# --- 3. 与驱动刷新方法不混淆（两套编号体系字面不重叠） ---
# sync.sh _refresh_ol_drivers 的三招是另一套"方法N"，领域限定词必须不同
for _d in "$D1" "$D2" "$D3" "$D4"; do
  case "$_d" in *"驱动刷新"*) bad "3 文件修复全名误含'驱动刷新'限定词: $_d" ;; esac
done
ok "3a 文件修复全名不含'驱动刷新'限定词（领域不串）"
# 反向: sync.sh 里"驱动刷新方法N"的运行时日志不得带上文件修复限定词
# （注释里提到对方领域是正常的——那正是消歧说明；只查实际输出的日志行）
if grep -n 'echo .*驱动刷新方法' "$_REPO_ROOT/.github/scripts/openlist/sync.sh" | grep -q "文件修复"; then
  bad "3b 驱动刷新日志误带'文件修复'限定词"
else
  ok "3b 驱动刷新日志未误带文件修复限定词（两套文案不串）"
fi

# --- 4. 旧写法不再归一（不背历史包袱） ---
OLD1="方法1: 直接 rclone copyto（原路径 + 原文件名）"
[ "$(_method_desc "$OLD1")" = "$OLD1" ] \
  && ok "4a 旧全名按未知方法原样返回（不再归一）" || bad "4a: $(_method_desc "$OLD1")"
[ "$(_method_desc "m1")" = "m1" ] && ok "4b 旧序号 ID 按未知方法原样返回" || bad "4b: $(_method_desc "m1")"
# 现行全名再输入一次仍原样返回（幂等，marker 反复读写不漂移）
[ "$(_method_desc "$D1")" = "$D1" ] && ok "4c 现行全名幂等" || bad "4c: $(_method_desc "$D1")"

# --- 5. 未知/空输入不误伤 ---
[ "$(_method_desc "")" = "未知方法" ] && ok "5a 空输入 → 未知方法" || bad "5a: $(_method_desc "")"
[ "$(_method_desc "某个已下线的方法")" = "某个已下线的方法" ] \
  && ok "5b 未知全名原样返回（历史遗留方法不被吞掉）" || bad "5b: $(_method_desc "某个已下线的方法")"

# --- 6. _method_short 口径一致（短标签同样带限定词） ---
S1="修复方法1·copyto 原名"
[ "$(_method_short copyto_original)" = "$S1" ] && ok "6a 语义 ID → 短标签" || bad "6a: $(_method_short copyto_original)"
[ "$(_method_short "$D1")" = "$S1" ] && ok "6b 全名 → 同一短标签" || bad "6b: $(_method_short "$D1")"
[ "$(_method_short "")" = "未知方法" ] && ok "6c 空输入 → 未知方法" || bad "6c: $(_method_short "")"
echo "$(_method_short zip_split_shorthash)" | grep -q "^修复方法" \
  && ok "6d 短标签带'修复方法'限定词" || bad "6d: $(_method_short zip_split_shorthash)"

# --- 7. 黑名单通道 ---
FIX_METHOD_BLACKLIST=()
TRY_FIX_ORIGINAL="path/to/file.mp4"
_blacklist_add "$TRY_FIX_ORIGINAL" copyto_original
_method_blocked copyto_original && ok "7a 拉黑后可查询命中" || bad "7a: 拉黑未生效"
! _method_blocked copyto_shorthash && ok "7b 未拉黑的方法不受影响" || bad "7b: 误拉黑"
# 语义 ID 拉黑 → 用全名查询也应命中（黑名单存全名，两者须同一口径）
_method_blocked "$D1" && ok "7c 语义 ID 拉黑 → 全名查询命中" || bad "7c: 口径不一致"
# 同一方法重复拉黑（ID + 全名各一次）不产生重复条目
FIX_METHOD_BLACKLIST=()
_blacklist_add "$TRY_FIX_ORIGINAL" copyto_shorthash
_blacklist_add "$TRY_FIX_ORIGINAL" "$D2"
[ "${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}" = "$D2" ] \
  && ok "7d ID 与全名重复拉黑不产生重复条目" || bad "7d: [${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}]"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
