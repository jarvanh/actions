#!/bin/bash
# ===== OpenList 后端可写性诊断探针（零配置、可重复、单次 ~2 分钟）=====
#
# 为什么单独存在（而不是并进主 run 日志）:
#   主 run 里后端写失败只呈现为 rclone 的 "405 Method Not Allowed" —— 那是
#   OpenList 把驱动层的真实错误（如 wopan 的 8005 登录失败）包装后的形态，
#   原始 rsp_code/rep_desc 只落在**容器日志**里，而容器日志从不进 run 日志。
#   于是「登录令牌失效」与「路径/名长被拒」在 run 日志里长得一模一样，
#   判据只能靠猜（历史上把 405 一律当"名长"处理过一轮，方向是错的）。
#   本脚本把这几类分开，并把原始错误行打出来。
#
# 关键设计: 写探针落在**真实任务子路径**上，不是挂载根。
#   挂载根能写 ≠ 任务子路径能写（run 34728107625 实锤: 探针通过后 89s 即大量 405）。
#
# 用法: bash diag_backend.sh [目标路径] [容器名]
#   默认: openlist:wopan176Crypt/2  openlist
#
# ⚠️ 副作用: 会在目标路径下创建若干 oldiag_* 小文件并尽力删除。后端半死时
#   删除可能失败，残留文件以 oldiag_ 前缀可辨识（不参与同步，不影响数据）。
#
# 退出码恒为 0（诊断工具，失败信息在报告里；非 0 会掩盖报告）

set -uo pipefail

TARGET="${1:-openlist:wopan176Crypt/2}"
CONTAINER="${2:-openlist}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/report.txt}"
PROBE_GAP="${DIAG_PROBE_GAP:-2}"          # 探针间隔，避免触发后端 429
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

# 同时写 stdout（进 run 日志）与报告文件（进 artifact）
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }
# 从 rclone 输出里摘出 HTTP 码（405/401/423/500…）
# 不用 \b: BSD grep -E 不支持词边界，会静默零匹配（与本机已知的 \S 同类坑）。
# 改要求「码 + 空格 + 字母」——这同时避开了进度行的 "450.089 MiB"（后随 '.'）。
http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
# grep -c 在零命中时会打印 0 且 exit 1；不接 || echo 会拿到 "0\n0"
count_of() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

OL_TOKEN=""
get_token() {
  [ -n "$OL_TOKEN" ] && return 0
  # shellcheck disable=SC1090
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/openlist_api.sh" 2>/dev/null || true
  OL_TOKEN=$(_get_openlist_token 2>/dev/null) || OL_TOKEN=""
  [ -n "$OL_TOKEN" ]
}

say "OpenList 后端诊断探针"
say "目标路径: $TARGET"
say "容器名:   $CONTAINER"
say "开始时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ────────────────────────────────────────────────────────────
sec "1 · 环境"
say "rclone: $(rclone version 2>/dev/null | head -1)"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  say "容器:   $(docker inspect -f '{{.State.Status}} since {{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
  say "镜像:   $(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)"
else
  say "容器:   ❌ docker inspect 失败（容器不存在或无权限）"
fi
# 名长类拒写看的是**整条路径**的字节数，不只是文件名
say "目标路径字节长度: $(printf '%s' "$TARGET" | wc -c | tr -d ' ') B"

# ────────────────────────────────────────────────────────────
sec "2 · 存储清单（驱动状态）"
# 只打非敏感字段: addition 里存的是网盘登录凭据，值绝不出现在报告里
if get_token; then
  storages=$(curl -s -m 20 -X GET "http://127.0.0.1:5244/api/admin/storage/list" \
    -H "Authorization: $OL_TOKEN" 2>/dev/null || echo '')
  if [ -n "$storages" ]; then
    say "存储总数: $(jq -r '.data.total // (.data.content | length) // "?"' <<<"$storages" 2>/dev/null)"
    say ""
    say "挂载路径 | 驱动 | 状态 | 禁用"
    # status 是 OpenList 自己对驱动健康度的判定（work / broken / …）。
    # 主 run 从不打印它 —— 8005 有没有被 OpenList 自己认定为 broken，看这里。
    jq -r '.data.content[]? | "\(.mount_path) | \(.driver) | \(.status // "?") | \(.disabled // false)"' \
      <<<"$storages" 2>/dev/null | tee -a "$REPORT"
    say ""
    say "wopan 相关存储的 addition 键名（值已脱敏）:"
    jq -r '.data.content[]? | select((.driver|ascii_downcase|test("wopan")) or (.mount_path|test("wopan"))) | "\(.mount_path): \((.addition // {} | fromjson? // {} | keys_unsorted | join(",")))"' \
      <<<"$storages" 2>/dev/null | tee -a "$REPORT"
  else
    say "❌ /api/admin/storage/list 无响应"
  fi
else
  say "❌ 管理面登录失败（检查 OPENLIST_ADMIN_PASSWORD）—— 第 2 段与写探针复核降级"
fi

# ────────────────────────────────────────────────────────────
sec "3 · 容器日志原文（8005 的唯一出处）"
CONTAINER_LOG=/tmp/ol_diag/container.log
if docker logs "$CONTAINER" >"$CONTAINER_LOG" 2>&1; then
  say "容器日志总行数: $(wc -l <"$CONTAINER_LOG" | tr -d ' ')"
  hits=$(count_of '8005|rsp_code|rep_desc' "$CONTAINER_LOG")
  say "命中 8005/rsp_code/rep_desc 的行数: $hits"
  if [ "$hits" != "0" ]; then
    say ""
    say "最近 25 行原文:"
    grep -E '8005|rsp_code|rep_desc' "$CONTAINER_LOG" 2>/dev/null | tail -25 | tee -a "$REPORT"
  fi
  say ""
  say "驱动/token/login 相关最近 15 行:"
  grep -iE 'wopan|token|login|refresh|driver' "$CONTAINER_LOG" 2>/dev/null \
    | tail -15 | tee -a "$REPORT"
else
  say "❌ docker logs 失败"
  : > "$CONTAINER_LOG"
fi

# ────────────────────────────────────────────────────────────
sec "4 · 读探针"
read_out=$(rclone lsf "$TARGET" --max-depth 1 --retries 1 --timeout "$PROBE_TIMEOUT" 2>&1)
read_rc=$?
if [ "$read_rc" -eq 0 ]; then
  say "✅ 可读: $(wc -l <<<"$read_out" | tr -d ' ') 个条目"
else
  say "❌ 读失败 (exit=${read_rc}, http=$(http_code_of "$read_out"))"
  say "$read_out" | head -5 | sed 's/^/   ▸ /' | tee -a "$REPORT"
fi

# 写探针公共实现: 写 → 刷缓存 → 读回 → 删
# 为什么必须读回: rclone rc=0 只代表"PUT 被受理"，假成功（活在 OpenList 目录
# 缓存里的幽灵条目）与真落盘在 rclone 侧无差别，只有刷新服务端缓存后再列一次
# 才能分辨（run 31951008332 同口径）。
# 结果经全局变量回传（不能用命令替换: 函数内部的 say 也会被一起捕获）。
WRITE_PROBE_RESULT=""
write_probe() {
  local name="$1" label="$2" readback_dir="${3:-$TARGET}"
  local local_file=/tmp/ol_diag/payload
  printf 'oldiag' > "$local_file" 2>/dev/null || true
  sleep "$PROBE_GAP"

  local out rc=0
  out=$(rclone copyto "$local_file" "$TARGET/$name" \
    --retries 1 --low-level-retries 2 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1) || rc=$?

  local seen=0
  if [ "$rc" -eq 0 ]; then
    if get_token; then
      curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
        -H "Authorization: $OL_TOKEN" -H "Content-Type: application/json" \
        -d "{\"path\":\"/${TARGET#openlist:}\",\"recursive\":false}" >/dev/null 2>&1 || true
    fi
    sleep 3
    rclone lsf "$readback_dir" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null \
      | grep -qxF "${name##*/}" && seen=1
  fi

  rclone deletefile "$TARGET/$name" --retries 1 --low-level-retries 2 --timeout "$PROBE_TIMEOUT" \
    >/dev/null 2>&1 || true

  local nbytes
  nbytes=$(printf '%s' "${name##*/}" | wc -c | tr -d ' ')
  if [ "$rc" -eq 0 ] && [ "$seen" -eq 1 ]; then
    say "✅ $label: 真落盘（名长 ${nbytes} B）"
    WRITE_PROBE_RESULT=OK
  elif [ "$rc" -eq 0 ]; then
    say "⚠️ $label: rclone 报成功但复核不可见（PUT 假成功）"
    WRITE_PROBE_RESULT=FAKE
  else
    say "❌ $label: 写失败 (exit=${rc}, http=$(http_code_of "$out"), 名长 ${nbytes} B)"
    say "$out" | tail -3 | sed 's/^/   ▸ /' | tee -a "$REPORT"
    WRITE_PROBE_RESULT=FAIL
  fi
}

sec "5 · 写探针（短名基线）"
write_probe "oldiag_$(date +%s)_$$.txt" "写探针 · 短名"
short_result="$WRITE_PROBE_RESULT"

# ────────────────────────────────────────────────────────────
sec "6 · 名长阶梯（定位长度阈值）"
# wopan 的拒写被怀疑与名长相关。判据要落在**实测阈值**上，而不是"名长 100B"
# 这种从样本总结的经验值（528 样本里 391 个密文名仅 22B 也败 → 名长充分非必要）。
LADDER=""
for n in 32 64 80 100 112 128; do
  body_len=$(( n - 11 ))                     # "oldiag_" 7 + ".txt" 4 = 11
  [ "$body_len" -lt 1 ] && body_len=1
  lname="oldiag_$(printf 'x%.0s' $(seq 1 "$body_len")).txt"
  write_probe "$lname" "写探针 · ${n}B"
  LADDER="$LADDER ${n}B=$WRITE_PROBE_RESULT"
  # 短名基线都写不进时名长阶梯没有诊断价值（问题不在长度）——提前收手省时间
  if [ "$short_result" != "OK" ] && [ "$n" = "64" ]; then
    say "   （短名基线已失败，名长阶梯无诊断价值，提前收手）"
    break
  fi
done

# ────────────────────────────────────────────────────────────
sec "7 · 覆盖写探针（对应 rclone 的 unchunked simple update）"
# 生产日志里的原始错误是 "unchunked simple update failed" —— 那是**覆盖已存在
# 文件**的代码路径，与"新建文件"不是同一条。新建能过 ≠ 覆盖能过，而增量同步
# 绝大多数写操作是覆盖，所以这一项必须单独测。
ov_name="oldiag_ov_$(date +%s)_$$.txt"
printf 'oldiag-v1' > /tmp/ol_diag/ov 2>/dev/null || true
ov_out=$(rclone copyto /tmp/ol_diag/ov "$TARGET/$ov_name" --retries 1 --low-level-retries 2 \
  --timeout "$PROBE_TIMEOUT" 2>&1)
ov_rc=$?
if [ "$ov_rc" -eq 0 ]; then
  sleep "$PROBE_GAP"
  printf 'oldiag-v2-longer-content-for-overwrite' > /tmp/ol_diag/ov2 2>/dev/null || true
  ov_out=$(rclone copyto /tmp/ol_diag/ov2 "$TARGET/$ov_name" --retries 1 --low-level-retries 2 \
    --timeout "$PROBE_TIMEOUT" 2>&1)
  ov_rc=$?
  if [ "$ov_rc" -eq 0 ]; then
    say "✅ 覆盖写: 通过"
    OVERWRITE=OK
  else
    say "❌ 覆盖写: 失败 (exit=${ov_rc}, http=$(http_code_of "$ov_out")) ← 与生产日志同形态"
    say "$ov_out" | tail -3 | sed 's/^/   ▸ /' | tee -a "$REPORT"
    OVERWRITE=FAIL
  fi
else
  say "❌ 覆盖写: 首次新建即失败 (exit=${ov_rc}, http=$(http_code_of "$ov_out"))，覆盖段无意义"
  OVERWRITE=FAIL
fi
rclone deletefile "$TARGET/$ov_name" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────
sec "8 · 子目录写探针（父目录名长连坐）"
# 另一条假设: 失败样本里 74% 的父**目录名**超长。若"根下能写、长名子目录内
# 写不进"，该假设成立，修法应落在目录名而非文件名上（两条修法完全不同）。
sub_name="oldiag_subdir_$(date +%s)_$$"
rclone mkdir "$TARGET/$sub_name" >/dev/null 2>&1 || true
sleep "$PROBE_GAP"
write_probe "$sub_name/oldiag_inner.txt" "子目录内写" "$TARGET/$sub_name"
SUBDIR="$WRITE_PROBE_RESULT"
rclone purge "$TARGET/$sub_name" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────
sec "9 · 持续写入探针（复现生产的「量 / 时长」维度）"
# 为什么需要这一组（2026-09-14 首轮诊断的结论驱动）:
#   前四组都是「单文件、顺序、极低量」——实测 wopan176Crypt/2 **全 OK**
#   （含 128B 长名、覆盖写、子目录写），而生产在同一路径上是 1034 个文件 /
#   48 分钟 / 全部 405。两者可以同时成立，只要失效是**随时间或量累积**发生的
#   （后端限流、风控踢会话、token 在长同步中途失效）。F4 的写探针只在同步
#   **开跑前**跑一次，天然测不到这个维度——这就是「探针 ✅ 与真实写入 405 并存」
#   最可能的解释。这里连续写 N 个小文件，记录**第几个开始失败**：失败点位置
#   就是复现生产形态的直接证据（全成功则说明量/时长也不是原因，得往并发看）。
BURST_N="${DIAG_BURST_N:-150}"
BURST_DIR="oldiag_burst_$(date +%s)_$$"
BURST_OK=0
BURST_FAIL_AT=""
BURST_FAIL_OUT=""
if [ "${BURST_N:-0}" = "0" ]; then
  say "（DIAG_BURST_N=0，跳过持续写入探针）"
  BURST_RESULT="SKIPPED"
else
say "连续写 ${BURST_N} 个小文件（目标 $TARGET/${BURST_DIR}）..."
rclone mkdir "$TARGET/$BURST_DIR" >/dev/null 2>&1 || true
BURST_T0=$(date +%s)
for ((bi = 1; bi <= BURST_N; bi++)); do
  bname=$(printf 'oldiag_b%04d.txt' "$bi")
  printf 'oldiag' > /tmp/ol_diag/burst 2>/dev/null || true
  if ! BURST_FAIL_OUT=$(rclone copyto /tmp/ol_diag/burst "$TARGET/$BURST_DIR/$bname" \
        --retries 1 --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1); then
    BURST_FAIL_AT="$bi"
    break
  fi
  BURST_OK=$((BURST_OK + 1))
done
BURST_SECS=$(( $(date +%s) - BURST_T0 ))
if [ -z "$BURST_FAIL_AT" ]; then
  say "✅ 连续写: ${BURST_OK}/${BURST_N} 全部被受理（耗时 ${BURST_SECS}s）"
  BURST_RESULT="OK(${BURST_OK}/${BURST_N})"
else
  say "❌ 连续写: 第 ${BURST_FAIL_AT} 个开始失败（前 $((BURST_FAIL_AT - 1)) 个被受理，耗时 ${BURST_SECS}s）"
  say "   http=$(http_code_of "$BURST_FAIL_OUT")"
  say "$BURST_FAIL_OUT" | tail -3 | sed 's/^/   ▸ /' | tee -a "$REPORT"
  BURST_RESULT="FAIL@${BURST_FAIL_AT}"
fi
fi

# ────────────────────────────────────────────────────────────
sec "9b · 并发写探针（transfers=4，三态判别）"
# 与持续写解耦：持续写可以 DIAG_BURST_N=0 关掉，并发三态永远跑（它决定 transfers
# 能不能提，是最关键的判据；此前误把它放在 burst 的 else 分支里，burst_n=0 会连它
# 一起跳过——2026-09-14 实测踩到）。
# 并发维度（细化，2026-09-14 第二轮诊断驱动）:
#   首轮并发探针（transfers=4 / 20 文件 / 新目录）失败 7/20，错误是
#   「Update mkParentDir failed: Locked: 423 Locked」——423 是 WebDAV 的资源锁，
#   而报错点是**父目录创建**，不是文件写：4 个 worker 同时在同一个还不存在的
#   目录上 mkdir 才会互相锁。若真如此，并发本身可用，只要消除 mkdir 竞争。
#   于是拆成三态判据（每态 30 个小文件，秒级）:
#     a) 新目录 + transfers=4            → 复现首轮形态（预期 423）
#     b) 目录已存在 + transfers=4        → 去掉 mkdir 竞争是否就干净
#     c) 新目录 + transfers=4 + --retries 3 → 靠重试兜过竞争（生产的可用修法）
CONC_DIR="$TARGET/$BURST_DIR/conc"
CONC_RESULT=""
mkdir -p /tmp/ol_diag/concdir 2>/dev/null || true
for pi in $(seq 1 30); do
  printf 'oldiag' > "/tmp/ol_diag/concdir/oldiag_c$(printf '%02d' "$pi").txt" 2>/dev/null || true
done

run_conc() {  # <标签> <目标子目录> <retries>
  local _tag="$1" _dst="$2" _rt="$3" _out _rc
  _out=$(rclone copy /tmp/ol_diag/concdir "$_dst" \
    --transfers 4 --retries "$_rt" --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1)
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    say "✅ 并发写 ${_tag}: 被受理"
    CONC_RESULT="${CONC_RESULT}${_tag}:OK "
  else
    say "❌ 并发写 ${_tag}: 失败 (exit=${_rc}, http=$(http_code_of "$_out"))"
    say "$_out" | grep -E "ERROR|Failed" | tail -2 | sed 's/^/   ▸ /' | tee -a "$REPORT"
    CONC_RESULT="${CONC_RESULT}${_tag}:FAIL "
  fi
}

sleep "$PROBE_GAP"
# a) 新目录 + transfers=4（首轮形态）
run_conc "新目录×4并发×retries1" "$CONC_DIR/new_a" 1
# b) 目录已存在 + transfers=4
rclone mkdir "$CONC_DIR/ready" >/dev/null 2>&1 || true
sleep "$PROBE_GAP"
run_conc "已存在目录×4并发×retries1" "$CONC_DIR/ready" 1
# c) 新目录 + transfers=4 + retries 3（生产可用的兜底修法）
sleep "$PROBE_GAP"
run_conc "新目录×4并发×retries3" "$CONC_DIR/new_c" 3

# 兼容旧变量: 任一并发形态通过即认为并发可用
case "$CONC_RESULT" in
  *":OK "*) PARALLEL=OK ;;
  *)        PARALLEL=FAIL ;;
esac

# 清理（尽力）: 集中在一个子目录里，purge 一次即可，残留也便于辨识
rclone purge "$TARGET/$BURST_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 探针目录未能清除: $TARGET/${BURST_DIR}（以 oldiag_ 前缀可辨识，不影响同步数据）"

# ────────────────────────────────────────────────────────────
sec "10 · 路径长度 / 深度探针（定位生产中 405 的路径特异性）"
# 为什么补这一组（2026-09-14 生产取证驱动）:
#   run 34779382573 里对 `wopan175/2/1024j/动漫本子/路人女主/已解压/(CSP6) [流石堂
#   (流ひょうご)] 淫らな彼女達の作りかた (冴えない彼女の育てかた) [中国翻訳]/` 的写入
#   恒定 405 `unchunked simple update failed`，而同一对里 1004 个文件在上一层目录
#   正常落盘。前几组探针只测了「挂载根」和「根下一层短名子目录」，**没测深路径 +
#   长祖先目录**，所以既不能证伪也不能证实"路径特异性"。这里做两组阶梯:
#     长名阶梯: 父目录名 10/20/30/40/50/60 个中文字（密文更长）各写一个探针
#     深度阶梯: d1/d2/d3/d4/d5 逐层加深（各层短名）各写一个探针
#   判读: 长名阶梯在某档断 → 父目录名长阈值；深度阶梯在某层断 → 路径总长/深度阈值；
#         两组全过 → 405 与路径长度/深度无关，得回去查文件名本身（密文名长度）。
DEEP_DIR="$TARGET/oldiag_deep_$(date +%s)_$$"
printf 'oldiag' > /tmp/ol_diag/pp 2>/dev/null || true
LADDER_P=""
for _n in 10 20 30 40 50 60; do
  _nm=$(printf '测%.0s' $(seq 1 "$_n"))
  _out=$(rclone copyto /tmp/ol_diag/pp "$DEEP_DIR/$_nm/probe.txt" \
    --retries 1 --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1)
  if [ $? -eq 0 ]; then LADDER_P="$LADDER_P ${_n}字=OK"; else
    LADDER_P="$LADDER_P ${_n}字=FAIL($(http_code_of "$_out"))"
    say "   ▸ 父目录 ${_n} 字失败: $(printf '%s' "$_out" | grep -oE 'ERROR.*' | head -1)"
  fi
  sleep "$PROBE_GAP"
done
say "长名阶梯(父目录名):$LADDER_P"

# 字符集阶梯: 二分已把范围收敛到"那个具体目录名本身"（真实祖先下写合成长名全 OK），
# 而合成长名用的是纯中文。真实失败名是「ASCII 括号 + 方括号 + 空格 + 日文假名 + 中文」
# 的混合体，故这里**等长**换字符集，定位是"空格/括号"还是"长度叠加"。
# 判读: 某档断 → 该字符集（或形态）就是 405 的触发条件；全过 → 与字符集无关，
# 回去看该目录在后端的历史状态（可能是早期用不同参数创建、后端留了坏条目）。
CHARSET_R=""
_cs_try() {  # <标签> <目录名>
  local _tag="$1" _nm="$2" _o
  _o=$(rclone copyto /tmp/ol_diag/pp "$DEEP_DIR/$_nm/probe.txt" \
    --retries 1 --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1)
  if [ $? -eq 0 ]; then CHARSET_R="$CHARSET_R ${_tag}=OK"; else
    CHARSET_R="$CHARSET_R ${_tag}=FAIL($(http_code_of "$_o"))"
  fi
  sleep "$PROBE_GAP"
}
_cs_try "纯中文40字" "$(printf '测%.0s' $(seq 1 40))"
_cs_try "中文40+空格" "$(printf '测 %.0s' $(seq 1 20))"
_cs_try "中文40+圆括号" "$(printf '（测）%.0s' $(seq 1 10))"
_cs_try "中文40+半角括号" "$(printf '(测)%.0s' $(seq 1 10))"
_cs_try "中文40+方括号" "$(printf '[测]%.0s' $(seq 1 10))"
_cs_try "混合(贴近真实)" '(CSP6) [流石堂 (流ひょうご)] 淫らな彼女達の作りかた (冴えない彼女の育てかた) [中国翻訳]'
say "字符集阶梯:$CHARSET_R"

DEEP_R=""
_DEEP_P="$DEEP_DIR"
for _d in 1 2 3 4 5; do
  _DEEP_P="$_DEEP_P/d$_d"
  _out=$(rclone copyto /tmp/ol_diag/pp "$_DEEP_P/probe.txt" \
    --retries 1 --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1)
  if [ $? -eq 0 ]; then DEEP_R="$DEEP_R d$_d=OK"; else
    DEEP_R="$DEEP_R d$_d=FAIL($(http_code_of "$_out"))"
    say "   ▸ 深度 $_d 失败: $(printf '%s' "$_out" | grep -oE 'ERROR.*' | head -1)"
  fi
  sleep "$PROBE_GAP"
done
say "深度阶梯(各层短名):$DEEP_R"
rclone purge "$DEEP_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 路径探针目录未能清除: $DEEP_DIR（以 oldiag_ 前缀可辨识）"

# ────────────────────────────────────────────────────────────
sec "12 · 吞吐阶梯（并发到底加不加带宽——决定提速走哪条路）"
# 为什么要这一组（2026-09-14）:
#   生产单流的 rclone 进度行实测稳定在 **374 KiB/s**，而真实文件均值约 1.3 MB
#   （1004 个文件跑了 58 min）—— 说明瓶颈可能是**带宽**而不是往返延迟。
#   这直接决定提速策略:
#     · 若 transfers=1 → 4 的吞吐近似 **线性增长** ⇒ 后端按"每流"限速，
#       提并发（以及 job 内多同步对并行）就是有效杠杆；
#     · 若吞吐基本 **不变** ⇒ 后端按"账号总带宽"限速，提并发毫无意义，
#       只能换手段（多后端分摊、错峰、或接受这个上限重算工期）。
#   此前所有并发探针（9b）只测"能不能被受理"，**没测聚合吞吐**，所以这个问题
#   一直是空的。这里用 6 × 1 MiB（贴近生产均值）分别跑 transfers=1 与 4。
THRU_SRC="/tmp/ol_diag/thru"
mkdir -p "$THRU_SRC" 2>/dev/null || true
if command -v dd >/dev/null 2>&1; then
  for _ti in 1 2 3 4 5 6; do
    dd if=/dev/urandom of="$THRU_SRC/t$(printf '%02d' "$_ti").bin" bs=1024 count=1024 status=none 2>/dev/null || true
  done
fi
THRU_DIR="$TARGET/oldiag_thru_$(date +%s)_$$"
THRU_RESULT=""
for _tk in 1 4; do
  _t0=$(date +%s)
  rclone copy "$THRU_SRC" "$THRU_DIR/k${_tk}" --transfers "$_tk" --checkers 8 \
    --stats-one-line --contimeout 20s --timeout "$PROBE_TIMEOUT" > /tmp/ol_diag/thru_k${_tk}.log 2>&1
  _rc=$?
  _dt=$(( $(date +%s) - _t0 ))
  [ "$_dt" -le 0 ] && _dt=1
  # 6 MiB / 秒数 → MiB/s（两位小数；awk 避免 bash 无浮点）
  _rate=$(awk "BEGIN{printf \"%.2f\", 6/${_dt}}")
  if [ "$_rc" -eq 0 ]; then
    THRU_RESULT="${THRU_RESULT} transfers=${_tk}:${_rate}MiB/s(${_dt}s)"
  else
    THRU_RESULT="${THRU_RESULT} transfers=${_tk}:FAIL(exit=${_rc},$(http_code_of "$(cat /tmp/ol_diag/thru_k${_tk}.log 2>/dev/null)"),${_dt}s)"
  fi
  sleep "$PROBE_GAP"
done
say "吞吐阶梯（6×1MiB）:${THRU_RESULT}"
rclone purge "$THRU_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true

# 跨后端独立性（决定"并行同步对"这个提速手段成不成立）:
#   两个**不同挂载**同时各跑一条 transfers=4 的流。
#   · 各自速率与单跑时相当（≈1.00 MiB/s）⇒ 两个后端的上限**互相独立**，
#     并行同步对可以直接叠加速度（这是它的全部依据）；
#   · 各自速率腰斩（≈0.5 MiB/s）⇒ 两个挂载共享同一个账号/总带宽上限
#     （wopan175 与 wopan176 很可能是同一账号），并行无益。
if [ -n "${DIAG_TARGET2:-}" ]; then
  say "跨后端并发: ${TARGET} 与 ${DIAG_TARGET2} 各跑一条 transfers=4（各 6 MiB）..."
  _t2dir="$TARGET/oldiag_thru2_$(date +%s)_$$"
  _t2dir_b="$DIAG_TARGET2/oldiag_thru2_$(date +%s)_$$"
  _ct0=$(date +%s)
  # 每条流各自计时（此前用"总耗时"给两条流算速率，快的那条被慢的拖低，
  # 会把"独立"误判成"共享"——2026-09-14 首测踩到，故改为各写各的 elapsed）
  (
    _s0=$(date +%s)
    rclone copy "$THRU_SRC" "$_t2dir/c_a" --transfers 4 --checkers 8 --stats-one-line \
      --contimeout 20s --timeout "$PROBE_TIMEOUT" > /tmp/ol_diag/thru2a.log 2>&1; _ra=$?
    echo "$(( $(date +%s) - _s0 )) $_ra" > /tmp/ol_diag/thru2a.elapsed
  ) &
  _cpa=$!
  (
    _s0=$(date +%s)
    rclone copy "$THRU_SRC" "$_t2dir_b/c_b" --transfers 4 --checkers 8 --stats-one-line \
      --contimeout 20s --timeout "$PROBE_TIMEOUT" > /tmp/ol_diag/thru2b.log 2>&1; _rb=$?
    echo "$(( $(date +%s) - _s0 )) $_rb" > /tmp/ol_diag/thru2b.elapsed
  ) &
  _cpb=$!
  wait "$_cpa" || true
  wait "$_cpb" || true
  _cdt=$(( $(date +%s) - _ct0 ))
  [ "$_cdt" -le 0 ] && _cdt=1
  _ea=$(awk '{print $1}' /tmp/ol_diag/thru2a.elapsed 2>/dev/null || echo 1)
  _eb=$(awk '{print $1}' /tmp/ol_diag/thru2b.elapsed 2>/dev/null || echo 1)
  [[ "$_ea" =~ ^[0-9]+$ ]] && [ "$_ea" -gt 0 ] || _ea=1
  [[ "$_eb" =~ ^[0-9]+$ ]] && [ "$_eb" -gt 0 ] || _eb=1
  _ra=$(awk '{print $2}' /tmp/ol_diag/thru2a.elapsed 2>/dev/null || echo 0)
  _rb=$(awk '{print $2}' /tmp/ol_diag/thru2b.elapsed 2>/dev/null || echo 0)
  _rate_a=$(awk "BEGIN{printf \"%.2f\", 6/${_ea}}")
  _rate_b=$(awk "BEGIN{printf \"%.2f\", 6/${_eb}}")
  _sum=$(awk "BEGIN{printf \"%.2f\", 12/${_cdt}}")
  say "跨后端并发: A(${TARGET##*/})=${_rate_a} MiB/s(${_ea}s,rc=${_ra}) · B(${DIAG_TARGET2##*/})=${_rate_b} MiB/s(${_eb}s,rc=${_rb}) · 合计 ${_sum} MiB/s(${_cdt}s)"
  say "  判读: 合计 ≈ 单流独占（0.86）⇒ 跨后端无增益；合计 < 单流 ⇒ 共享瓶颈（并行有害）"
  rclone purge "$_t2dir" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
  rclone purge "$_t2dir_b" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
fi

# 出口带宽基准（把同样的 6 MiB 传到中立端点）: 用来区分瓶颈在下游后端还是在
# **runner 的出口/国际路由**。这一条决定"提速还有没有别的路"：
#   · 中立端点也慢（≈1 MiB/s 量级）⇒ 出口/路由才是天花板，改管线无用，
#     有效手段是换 runner 区域、走代理、或用自建 runner（用户有 RDP/Tailscale 那台）
#   · 中立端点很快（≫1 MiB/s）⇒ 瓶颈在目标后端，只能靠多后端/错峰
EGRESS_RESULT="SKIPPED"
if command -v curl >/dev/null 2>&1 && [ -s /tmp/ol_diag/thru/t01.bin ]; then
  _cf=$(curl -s -o /dev/null -w '%{speed_upload}' --max-time 90 \
    -F 'file=@/tmp/ol_diag/thru/t01.bin' https://speed.cloudflare.com/__up 2>/dev/null || true)
  if [ -n "$_cf" ] && [ "$_cf" != "0" ]; then
    EGRESS_RESULT="$(awk "BEGIN{printf \"%.2f\", ${_cf}/1048576}") MiB/s"
  else
    EGRESS_RESULT="取不到（端点不可达或被限）"
  fi
fi
say "出口带宽基准（Cloudflare speedtest 上传 1MiB）: $EGRESS_RESULT"

# ────────────────────────────────────────────────────────────
# ────────────────────────────────────────────────────────────
sec "11 · 重启后立即写探针（复现生产的「重启 → 预检 → 405」序列）"
# 附: 列表完整性验证（验证 _wait_driver_ready 的就绪信号是否充分）
#   背景: 生产把容器重启后的「盲等 60s」改成了自适应轮询（4af1cbc）——以
#   「目标路径可列出」为就绪信号。风险: 若重启后第一次 lsf 成功但**内容不完整**
#   （驱动还在补水），truth-check 的 diff 会把真实文件误判成假成功 → 大规模重传。
#   本节在容器重启后每 2s lsf 一次已知 20 文件的目录，记录「首次成功」与「凑齐 20」
#   的时间差；两者重合 ⇒ 就绪信号充分，改动安全。


# 为什么补这一组（2026-09-14 生产取证驱动）:
#   生产里每个目录可写性预检（_fix_probe_dir_writable）之前，几乎都刚重启过容器
#   ——truth-check、持久化复核都会重启。run 34779382573 里连续 3 次预检全部
#   405 `unchunked simple update failed`，而同一目录下有 1004 个真实文件落盘。
#   第 10 组已排除「路径长度/深度」，第 6-8 组排除了「名长/覆盖写/子目录」，
#   剩下的解释就是**时序**: 驱动在容器重启后需要一段时间才真正可写，而预检
#   没有等待/重试就直接判"目录不可写"，进而触发无谓的目录折叠与逐文件修复。
#   判读: 若 +0s/+10s 失败而 +30s/+60s 成功 ⇒ 预检必须加重试/等待；
#         若全部成功 ⇒ 时序不是原因，回去查那批文件本身的差异。
if docker restart "$CONTAINER" >/dev/null 2>&1; then
  RST_RESULT=""
  for _w in 0 10 30 60; do
    [ "$_w" -gt 0 ] && sleep "$_w"
    _o=$(rclone copyto /tmp/ol_diag/pp "$TARGET/oldiag_afterrestart.txt" \
      --retries 1 --low-level-retries 1 --contimeout 20s --timeout "$PROBE_TIMEOUT" 2>&1)
    if [ $? -eq 0 ]; then
      RST_RESULT="$RST_RESULT +${_w}s=OK"
    else
      RST_RESULT="$RST_RESULT +${_w}s=FAIL($(http_code_of "$_o"))"
    fi
  done
  say "重启后写入（累计等待）:$RST_RESULT"
  rclone deletefile "$TARGET/oldiag_afterrestart.txt" --retries 1 --timeout "$PROBE_TIMEOUT" \
    >/dev/null 2>&1 || true

  # 列表完整性验证（对应生产 4af1cbc 的「自适应就绪轮询」）:
  # 先造一个已知 20 文件的目录 → docker restart → 每 2s lsf 一次，记录
  # 「首次 lsf 成功」与「文件数凑齐 20」的时间。两者重合 ⇒ 就绪信号充分
  # （4af1cbc 安全）；首次成功但数量不足 ⇒ 生产 truth-check 会读到不完整
  # 列表（把真实文件误判假成功 → 大规模重传），必须回盲等或加数量校验。
  LSC_DIR="$TARGET/oldiag_lscheck_$(date +%s)_$$"
  mkdir -p /tmp/ol_diag/lscheck 2>/dev/null || true
  for _li in $(seq 1 20); do
    printf 'oldiag' > "/tmp/ol_diag/lscheck/l$(printf '%02d' "$_li").txt" 2>/dev/null || true
  done
  rclone copy /tmp/ol_diag/lscheck "$LSC_DIR" --transfers 4 --checkers 8 \
    --contimeout 20s --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
  _pre=$(rclone lsf "$LSC_DIR" --files-only 2>/dev/null | grep -c . || true)
  say "重启前列表数: ${_pre}（期望 20）"
  docker restart "$CONTAINER" >/dev/null 2>&1 || true
  _lsc_t0=$(date +%s)
  LSC_FIRST="" LSC_FULL="" _lsc_i=0
  # 窗口放大到 600s（默认，可配）: 上一版只等 60s 就放弃，得到的结论是
  # "不可见"，但给不出**到底多久可见** —— 而生产折叠校验的窗口（6×30s=3min）
  # 正需要这个数字来定。可见性是"延迟"不是"丢失"，必须量出延迟量级。
  local _lsc_max="${OPENLIST_VISIBILITY_MAX:-600}"
  while [ $(( $(date +%s) - _lsc_t0 )) -lt "$_lsc_max" ]; do
    sleep 5
    _lsc_i=$((_lsc_i + 1))
    _c=$(rclone lsf "$LSC_DIR" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null | grep -c . || true)
    if [ -z "$LSC_FIRST" ] && [ "${_c:-0}" -gt 0 ]; then
      LSC_FIRST="$(awk "BEGIN{printf \"%.0f\", $(date +%s) - $_lsc_t0}")s(${_c}个)"
    fi
    if [ "${_c:-0}" -ge 20 ]; then
      LSC_FULL="$(awk "BEGIN{printf \"%.0f\", $(date +%s) - $_lsc_t0}")s"
      break
    fi
  done
  say "列表可见性: 首次非空=${LSC_FIRST:-${_lsc_max}s内无} · 凑齐20=${LSC_FULL:-${_lsc_max}s内未}"
  say "  对照: 生产折叠校验（0a27089）的上界 = OPENLIST_FOLD_VERIFY_TRIES×WAIT = 6×30s = 180s ⇒ 实测凑齐时间若超过 180s 就仍需调大"
  say "  判读: 首次成功==凑齐 ⇒ 就绪信号充分（4af1cbc 安全）；首次成功但凑齐更晚 ⇒"
  say "        生产 truth-check 需在就绪后加数量校验，否则会大规模误判假成功"
  rclone purge "$LSC_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
else
  say "（docker restart 不可用，跳过重启后写入探针）"
  RST_RESULT="SKIPPED"
fi

# ────────────────────────────────────────────────────────────
sec "诊断结论"
say "目标路径: $TARGET"
say "短名写:   $short_result"
say "名长阶梯:$LADDER"
say "覆盖写:   $OVERWRITE"
say "子目录写: $SUBDIR"
say "父目录名长阶梯:${LADDER_P:-SKIPPED}"
say "字符集阶梯:  ${CHARSET_R:-SKIPPED}"
say "路径深度阶梯: ${DEEP_R:-SKIPPED}"
say "重启后写入:   ${RST_RESULT:-SKIPPED}"
say "吞吐阶梯:${THRU_RESULT:-SKIPPED}"
say "出口带宽基准: ${EGRESS_RESULT:-SKIPPED}"
say "持续写:   $BURST_RESULT"
say "并发写:   ${CONC_RESULT:-SKIPPED}（transfers=4，三态见上）"
say "容器日志 8005 命中: $(count_of '8005|rsp_code|rep_desc' "$CONTAINER_LOG") 行"
say ""
say "判读指引:"
say "  · 短名写 FAIL 且日志有 8005        → 登录令牌失效（账号正常不代表令牌正常）"
say "  · 短名写 OK、覆盖写 FAIL           → 后端拒绝「更新」，与登录无关"
say "  · 短名写 OK、名长阶梯在某 N 处断   → 名长阈值成立，修法落在文件名长度"
say "  · 短名写 OK、子目录写 FAIL         → 父目录名长连坐成立，修法落在目录名"
say "  · 单发全 OK、**持续写在第 K 个断** → 失效与**量/时长**相关（限流/风控/会话被踢），"
say "                                      修法应落在「同步中周期性重探 + 退避」，"
say "                                      而不是名长或登录令牌"
say "  · 新目录并发 FAIL、已存在目录 OK   → 423 是**父目录 mkdir 竞争**，并发可用:"
say "                                      生产侧先建目录或给足重试即可提 transfers"
say "  · 父目录名长阶梯在某档断           → 父目录名长阈值成立（生产 405 的路径特异性），"
say "                                      修法: 目录级折叠/短哈希目录（已实现，但要确认落盘）"
say "  · 深度阶梯在某层断                 → 与路径总长/深度相关，修法同上"
say "  · 两组阶梯全过                     → 405 与路径长度/深度无关，回到密文文件名长度假设"
say "  · 重启后 +0s/+10s FAIL、+30s/+60s OK → 预检时序问题: _fix_probe_dir_writable"
say "                                      必须加重试/等待，否则刚重启完的目录一律误判不可写"
say "  · 吞吐 transfers=4 ≈ 4×transfers=1   → 后端按每流限速，**提并发线性提速**（有效）"
say "  · 吞吐 transfers=4 ≈ 1×transfers=1   → 后端按账号总带宽限速，**提并发无用**，"
say "                                        必须换手段（多后端分摊/错峰/重算工期）"
say "  · 新目录并发 FAIL、retries3 也 FAIL → 并发确实触发后端锁，transfers 保持 1"
say "  · 全部 OK                          → 此刻后端完全可写（含并发），失败属时段性/外部条件"
say ""
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"

exit 0
