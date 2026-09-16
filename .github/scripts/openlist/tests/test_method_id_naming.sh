#!/bin/bash
# 文件修复方法 ID 命名与黑名单口径 —— 回归测试
# 背景: 方法 ID 原为 m1/m2/m3/m4 序号，代码里读 _fix_method_gate m3 无法自
#   解释（得回查 _fix_method_desc 才知道是"zip 分卷"），且方法增删时序号会漂移。
#   现改为语义名 copyto_original / copyto_shorthash / zip_split_original /
#   zip_split_shorthash。
# 2026-09-16 命名统一（第二次改）: 此前"日志一套短标签、marker 一套冗长全名"双口径，
#   现统一为 `方法N·动作·变体`（中文可读）。持久化层（_fix_method_desc）必须
#   **保留 restore_info.jq 依赖的分类子串**，否则还原元数据退化成 kind=copy。
# 约束（均为踩过的坑）:
#   1. 展示层可读: `方法N·动作·变体`，日志里一眼可辨
#   2. 持久化层保留分类子串: "分卷切割" / "短哈希文件名"（restore_info.jq 靠它分类）
#   3. 说明方法形态: 原名 / 短名，这是选方法的依据（密文名超长时须避开带原名的方法）
#   4. 展示层与持久化层同源: 都从同一语义 ID 出发，不得各自演化
#   5. 黑名单跨命名版本兼容: 历史 marker 存的是旧全名，改口径后仍须能命中
# 验证:
#   1. 四个语义 ID → 对应描述（逐字）
#   2. 描述含 restore_info.jq 依赖的分类子串
#   3. 展示标签为 `方法N·…` 形态且中文可读
#   4. 展示层接受 ID / 描述 / 旧全名三种输入（消费历史 marker）
#   5. 未知/空输入不误伤
#   6. 黑名单: 归一存储、跨命名版本命中、重复拉黑不产生重复条目
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null

# 现行描述（与 _fix_method_desc 输出严格一致，改文案时此处需同步）
D1="方法1·原名直传（原路径 + 原文件名）"
D2="方法2·短名直传（短哈希文件名）"
D3="方法3·分卷·原名（zip 压缩 + 分卷切割，原文件名基底，默认 1GB 分卷）"
D4="方法4·分卷·短名（zip 压缩 + 分卷切割，短哈希文件名）"

# 历史全名（2026-09-16 统一之前的格式，用于验证跨版本黑名单兼容）
OLD1="文件修复方法1 copyto_original: 直接 rclone copyto（原路径 + 原文件名）"
OLD2="文件修复方法2 copyto_shorthash: 短哈希文件名直传（<md5前8位>.<扩展名>）"
OLD3="文件修复方法3 zip_split_original: zip 压缩 + 分卷上传（原文件名基底，默认 1GB 分卷）"
OLD4="文件修复方法4 zip_split_shorthash: zip 压缩 + 短哈希文件名 + 分卷上传"

# --- 1. 语义 ID → 描述（逐字） ---
[ "$(_fix_method_desc copyto_original)" = "$D1" ] && ok "1a copyto_original → 方法1" || bad "1a: $(_fix_method_desc copyto_original)"
[ "$(_fix_method_desc copyto_shorthash)" = "$D2" ] && ok "1b copyto_shorthash → 方法2" || bad "1b: $(_fix_method_desc copyto_shorthash)"
[ "$(_fix_method_desc zip_split_original)" = "$D3" ] && ok "1c zip_split_original → 方法3" || bad "1c: $(_fix_method_desc zip_split_original)"
[ "$(_fix_method_desc zip_split_shorthash)" = "$D4" ] && ok "1d zip_split_shorthash → 方法4" || bad "1d: $(_fix_method_desc zip_split_shorthash)"

# --- 2. ★ 描述必须保留 restore_info.jq 依赖的分类子串 ---
# restore_info.jq 对方法文本做子串匹配来生成还原元数据；丢了子串会让对应形态
# 分类失败并退化成 kind=copy（还原脚本错误）。这是本文件最重要的一组断言。
echo "$D3" | grep -q "分卷切割" && echo "$D4" | grep -q "分卷切割" \
  && ok "2a 方法3/4 保留 '分卷切割'（split_zip 分类依据）" || bad "2a: 缺'分卷切割' → restore_info.jq 会误判"
echo "$D2" | grep -q "短哈希文件名" && echo "$D4" | grep -q "短哈希文件名" \
  && ok "2b 方法2/4 保留 '短哈希文件名'（short_hash_rename 依据）" || bad "2b: 缺'短哈希文件名'"
# 反向: 方法 3 不得含"短哈希文件名"，否则会被短哈希分支先命中（分类顺序陷阱）
echo "$D3" | grep -q "短哈希文件名" && bad "2c 方法3 误含'短哈希文件名'（会被短哈希分支抢命中）" \
  || ok "2c 方法3 不含'短哈希文件名'（不与短哈希分支串）"
# 方法 1/2 不得含"分卷切割"（它们不是分卷）
echo "$D1" | grep -q "分卷切割" && bad "2d 方法1 误含'分卷切割'" || ok "2d 方法1 不含'分卷切割'"
echo "$D2" | grep -q "分卷切割" && bad "2e 方法2 误含'分卷切割'" || ok "2e 方法2 不含'分卷切割'"

# --- 3. 展示标签形态 ---
S1="方法1·原名直传"; S2="方法2·短名直传"; S3="方法3·分卷·原名"; S4="方法4·分卷·短名"
[ "$(_fix_method_short copyto_original)" = "$S1" ] && ok "3a 方法1 展示标签" || bad "3a: $(_fix_method_short copyto_original)"
[ "$(_fix_method_short copyto_shorthash)" = "$S2" ] && ok "3b 方法2 展示标签" || bad "3b: $(_fix_method_short copyto_shorthash)"
[ "$(_fix_method_short zip_split_original)" = "$S3" ] && ok "3c 方法3 展示标签" || bad "3c: $(_fix_method_short zip_split_original)"
[ "$(_fix_method_short zip_split_shorthash)" = "$S4" ] && ok "3d 方法4 展示标签" || bad "3d: $(_fix_method_short zip_split_shorthash)"
# 展示标签必须比描述短（展示层存在的意义），且以"方法N·"开头
for _s in "$S1" "$S2" "$S3" "$S4"; do
  case "$_s" in 方法[0-9]·*) ;; *) bad "3e 展示标签不以'方法N·'开头: $_s" ;; esac
done
ok "3e 四个展示标签均为 '方法N·…' 形态"
[ "${#S3}" -lt "${#D3}" ] && ok "3f 展示标签短于描述（展示层有价值）" || bad "3f: 展示标签未更短"

# --- 4. 展示层接受三种输入（ID / 新描述 / 旧全名）---
[ "$(_fix_method_short "$D1")" = "$S1" ] && ok "4a 新描述 → 同一展示标签" || bad "4a: $(_fix_method_short "$D1")"
[ "$(_fix_method_short "$OLD1")" = "$S1" ] && ok "4b 历史全名 → 同一展示标签（消费历史 marker）" || bad "4b: $(_fix_method_short "$OLD1")"
[ "$(_fix_method_short "$OLD4")" = "$S4" ] && ok "4c 历史全名（方法4）→ 同一展示标签" || bad "4c: $(_fix_method_short "$OLD4")"

# --- 5. 未知/空输入不误伤 ---
[ "$(_fix_method_desc "")" = "未知方法" ] && ok "5a 空输入 → 未知方法" || bad "5a: $(_fix_method_desc "")"
[ "$(_fix_method_desc "某个已下线的方法")" = "某个已下线的方法" ] \
  && ok "5b 未知描述原样返回（历史遗留方法不被吞掉）" || bad "5b: $(_fix_method_desc "某个已下线的方法")"
[ "$(_fix_method_short "")" = "未知方法" ] && ok "5c 展示层空输入 → 未知方法" || bad "5c: $(_fix_method_short "")"
# 现行描述幂等（marker 反复读写不漂移）
[ "$(_fix_method_desc "$D1")" = "$D1" ] && ok "5d 现行描述幂等" || bad "5d: $(_fix_method_desc "$D1")"

# --- 6. 黑名单: 归一存储 + 跨版本兼容 ---
TRY_FIX_ORIGINAL="path/to/file.mp4"
FIX_METHOD_BLACKLIST=()
_blacklist_add "$TRY_FIX_ORIGINAL" copyto_original
[ "${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}" = "copyto_original" ] \
  && ok "6a 黑名单存归一语义 ID（非描述）" || bad "6a: [${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}]"
_fix_method_blocked copyto_original && ok "6b 拉黑后可查询命中" || bad "6b: 拉黑未生效"
! _fix_method_blocked copyto_shorthash && ok "6c 未拉黑的方法不受影响" || bad "6c: 误拉黑"
# 用描述/旧全名查询也应命中（同一语义 ID 的三种表示）
_fix_method_blocked "$D1" && ok "6d 用新描述查询命中" || bad "6d: 口径不一致"
_fix_method_blocked "$OLD1" && ok "6e 用历史全名查询命中" || bad "6e: 历史条目失配（跨轮黑名单会失效）"
# 重复拉黑（ID + 描述 + 旧全名三次）不产生重复条目
FIX_METHOD_BLACKLIST=()
_blacklist_add "$TRY_FIX_ORIGINAL" copyto_shorthash
_blacklist_add "$TRY_FIX_ORIGINAL" "$D2"
_blacklist_add "$TRY_FIX_ORIGINAL" "$OLD2"
[ "${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}" = "copyto_shorthash" ] \
  && ok "6f 三种表示重复拉黑不产生重复条目" || bad "6f: [${FIX_METHOD_BLACKLIST[$TRY_FIX_ORIGINAL]}]"
# 多方法拉黑: | 分隔且各条目独立可查
FIX_METHOD_BLACKLIST=()
_blacklist_add "$TRY_FIX_ORIGINAL" copyto_original
_blacklist_add "$TRY_FIX_ORIGINAL" zip_split_original
_fix_method_blocked zip_split_original && ok "6g 多方法拉黑后可查（| 分隔解析）" || bad "6g: 多条目解析失败"
_fix_method_blocked copyto_shorthash && bad "6h 未拉黑的方法被误命中" || ok "6h 多条目中未拉黑的方法不误命中"
# 历史 marker 直接载入（未过 _blacklist_add）→ 查询仍须命中
FIX_METHOD_BLACKLIST["$TRY_FIX_ORIGINAL"]="$OLD3"
_fix_method_blocked zip_split_original && ok "6i 历史 marker 条目按原样载入仍可命中" || bad "6i: 历史载入条目失配"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
