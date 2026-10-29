#!/usr/bin/env bash
# openclaw 工作流「Install OpenClaw」步骤本体（2026-10-30 搬移自 yml，除注明处零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限，每轮 push 全部 "workflow file issue" 零 job 失败、
# schedule 停摆 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env：OC_CLI_INSTALL_PID（installer 后台子壳 pid）、INST_T0（步骤起始时刻）
#   落盘：/tmp/install-openclaw-step.log（失败通知取摘要）、
#         /tmp/openclaw-restore-meta.env（就绪/自愈通知）、/tmp/openclaw-cli-install.rc
# 唯一逻辑适配：原 `wait $OC_CLI_INSTALL_PID` 依赖父子关系 —— 脚本与 installer
# 是兄弟进程拿不到，改为轮询 rc 文件（installer 子壳退出前落盘），1800s 上限兜底。
# 调用方必须用 `bash -e` 运行本脚本（与 GitHub run: 的默认 shell 语义一致）。

# 2026-10-23：本步骤失败也要能触发失败通知。此前通知只认
# run_openclaw.outcome == 'failure'，而 run 39888680026 / 39886777685
# 都是 Install 失败、Run OpenClaw 却成功（doctor 现造配置），通知被静默跳过。
# 把本步输出落一份到 /tmp，供失败通知取错误摘要。（yml 侧已 tee 前半段，
# 这里对本段输出续写同一日志，通知读到的摘要两段齐全。）
exec > >(tee -a /tmp/install-openclaw-step.log) 2>&1

wait_cli_install() {
  # 2026-10-30 外置适配：轮询 rc 文件等 installer 收尾（进程消失也兜底判失败）。
  local waited=0
  while [ ! -s /tmp/openclaw-cli-install.rc ] && [ "$waited" -lt 1800 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ ! -s /tmp/openclaw-cli-install.rc ] || [ "$(cat /tmp/openclaw-cli-install.rc 2>/dev/null || echo 1)" != "0" ]; then
    echo "❌ OpenClaw CLI 安装失败（/tmp/openclaw-cli-install.log 尾部：）"
    tail -n 20 /tmp/openclaw-cli-install.log 2>/dev/null || true
    exit 1
  fi
  echo "✅ OpenClaw CLI 安装完成"
  echo "⏱️ install timing: cli_install_sec=$(( $(date +%s) - INST_T0 ))"
}

echo "Configuring local ~/.openclaw with Dropbox-linked config..."
mkdir -p /dropbox/self-hosted/openclaw
mkdir -p ~/.openclaw
mkdir -p ~/.openclaw/extensions

TMP_OPENCLAW_TAR="/tmp/openclaw.tar.gz"
RESTORE_DIR="/tmp/openclaw-restore"

# 2026-10-23 恢复来源追踪：通知里要能说清本轮用的是云端主包，
# 还是历史 revision、以及该 revision 的创建时间。空值 = 未知。
OPENCLAW_RESTORE_SOURCE=""
OPENCLAW_RESTORE_REV=""
OPENCLAW_RESTORE_REV_TIME=""

cleanup_archive_workdir() {
  rm -f "$TMP_OPENCLAW_TAR" 2>/dev/null || true
  rm -rf "$RESTORE_DIR" 2>/dev/null || true
}
free_kb() { df -Pk "${1:-/tmp}" | awk 'NR==2 {print $4}'; }
require_free_kb() {
  local path="$1" min_kb="$2" label="$3"
  local avail
  avail=$(free_kb "$path")
  if [ "${avail:-0}" -lt "$min_kb" ]; then
    echo "❌ ${label}: insufficient free space at ${path}. available=${avail}KB required=${min_kb}KB" >&2
    exit 1
  fi
  echo "✅ ${label}: free space ok at ${path}. available=${avail}KB required=${min_kb}KB"
}
require_free_kb /tmp $((2 * 1024 * 1024)) "openclaw restore preflight"

cleanup_archive_workdir
mkdir -p "$RESTORE_DIR"

echo "📦 Restoring ~/.openclaw: prefer archive, fallback to raw directory sync..."
# 2026-10-02 加固：rclone 对 Dropbox 的瞬时失败（token 刷新/限流/挂载抖动）曾把
# 「探测失败」误判成「无归档」→ 落入 else 从**空的**原始目录兜底（openclaw/ 目录
# 早已清空，兜底恒为 no-op）→ ~/.openclaw 空壳静默上岗：网关起不来、归档循环
# 连续 12 轮 rc=4 告警（2026-10-02 04:09-08:16）。探测重试 3 次再定性，
# 瞬态不至于丢掉整份主包恢复。
ARCHIVE_PRESENT=0
for _probe in 1 2 3; do
  if rclone ls dropbox:self-hosted/openclaw.tar.gz > /dev/null 2>&1; then
    ARCHIVE_PRESENT=1
    break
  fi
  echo "⚠️ rclone ls 探测归档失败（第 ${_probe}/3 次），15s 后重试..."
  sleep 15
done
if [ "$ARCHIVE_PRESENT" = "1" ]; then
  echo "📦 Found openclaw.tar.gz! Downloading and extracting..."
  INST_T1=$(date +%s)
  # 主包下载已在 Prefetch cold artifacts 步骤里于后台起跑（实测 9.3GB / 54s
  # 是纯串行等待）。这里只等它收尾：轮询 rc 文件（prefetch 进程先没了就立刻收，
  # 不空等），命中则 mv 进恢复路径 —— 同一文件系统，mv 是 rename 不是拷贝。
  # 未命中/失败一律回落原有同步下载，判据与语义不变。
  PREFETCH_DIR="/tmp/openclaw-prefetch"
  if [ -f "$PREFETCH_DIR/openclaw-tar.pid" ]; then
    _pf_waited=0
    while [ ! -f "$PREFETCH_DIR/openclaw-tar.rc" ] && [ "$_pf_waited" -lt 900 ]; do
      _pf_pid="$(cat "$PREFETCH_DIR/openclaw-tar.pid" 2>/dev/null | tr -dc '0-9')"
      [ -n "$_pf_pid" ] || break
      kill -0 "$_pf_pid" 2>/dev/null || break
      sleep 2
      _pf_waited=$((_pf_waited + 2))
    done
    _pf_rc="$(cat "$PREFETCH_DIR/openclaw-tar.rc" 2>/dev/null || echo none)"
    if [ "$_pf_rc" = "0" ] && [ -s "$PREFETCH_DIR/openclaw.tar.gz" ]; then
      mv "$PREFETCH_DIR/openclaw.tar.gz" "$TMP_OPENCLAW_TAR"
      rm -f "$PREFETCH_DIR/openclaw.tar.gz.part" "$PREFETCH_DIR/openclaw-tar.rc" "$PREFETCH_DIR/openclaw-tar.pid" 2>/dev/null || true
      echo "✅ 主包 prefetch 命中（等待 ${_pf_waited}s）"
    else
      # 回落同步下载前必须清掉 prefetch 的 .part：后台进程被杀时不会自己删，
      # 残留的 9GB 会把 /tmp 挤到解包预检（kb*3+1GB）硬失败 —— 白丢一整轮。
      echo "⚠️ 主包 prefetch 未命中（rc=${_pf_rc}），回落同步下载"
      rm -f "$PREFETCH_DIR/openclaw.tar.gz.part" 2>/dev/null || true
      rclone copyto dropbox:self-hosted/openclaw.tar.gz "$TMP_OPENCLAW_TAR" --multi-thread-streams 16
    fi
  else
    rm -f "$PREFETCH_DIR/openclaw.tar.gz.part" 2>/dev/null || true
    rclone copyto dropbox:self-hosted/openclaw.tar.gz "$TMP_OPENCLAW_TAR" --multi-thread-streams 16
  fi
  # 2026-10-02 二次事故：云端主包被 98KB 空壳包覆盖后仍被恢复上岗 —— 恢复侧原
  # 只验 gzip 完整性（98KB 空壳照样通过），而 preflight doctor 会现造一份合法
  # 配置骗过归档侧 config validate，健康门全绿后空壳照样打上行。恢复是最后防线：
  # 真实主包 GB 级，50MB 绝对下限留约两个数量级余量，且 openclaw.json 必须真实
  # 在包内。结构判据之外 2026-10-11 加配置预检：任一不满足 → 走 Dropbox revision
  # 回退（候选上限 100）逐个验到能过为止，全部不可用才 exit 1（任务失败→通知）。
  # 宁可失败，不要空壳/坏配置上岗。
  #
  # 2026-10-21 改成单趟：上面四道判据一条没减，但读的是**解包之后的盘上文件**。
  # 旧实现对同一个包解了三趟全量流 —— listing_has_config 的 tar -tf、ARCHIVE_OK
  # 的 tar -tf、最终 tar -xf，实测白烧 ~180s CPU+IO。第二趟想换来的「gzip 流
  # 完整、tar 结构没坏」这个信息，一趟带写入的解压本来就用非零退出码给出了。
  # 顺带修掉一处哑门：旧流程在 if 之外做 `_verdict="$(config_precheck_ok ...)"`
  # 赋值，本步骤跑在 bash -e 下，配置判据一旦 FAIL 就直接把整步打死，
  # revision 回退分支根本走不到 —— 预检越严，回退越是死代码。
  OPENCLAW_TARBALL_MIN_KB=$((50 * 1024))
  extract_openclaw_archive() {
    # 用法: extract_openclaw_archive <tar.gz 路径> <落点目录>
    # pigz 并行解压（2026-10-02 实测 305MB 样本 5.44s → 3.29s；产物是标准
    # gzip 流，与 tar -xzf 完全兼容）。pipefail 必须开：否则 tar 的失败会被
    # pigz 的成功码掩盖。
    local tar="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    if command -v pigz >/dev/null 2>&1; then
      ( set -o pipefail; pigz -dc "$tar" | tar -xf - -C "$dest" )
    else
      tar -xzf "$tar" -C "$dest"
    fi
  }
  validate_openclaw_tree() {
    # 用法: validate_openclaw_tree <解包落点>，stdout 给 PASS/SKIP/FAIL 结论
    # 三道判据由宽到严：结构（openclaw.json 真在包里）→ 配置语义 → secrets 可解析性。
    # 配置判据（2026-10-11）：主包可能顶着「结构完好」被恢复上岗，网关却因配置
    # 语义坏起不来，且每轮恢复同一份坏主包、无自动出口 —— 归档侧 config validate
    # 门（退出码 5 不覆盖云端）只挡得住「归档时配置已坏」，挡不住「归档时健康、
    # 运行中写坏」的形态（2026-09-18 事故）。
    # 二进制不可得（openclaw 未装上/安装失败）时跳过语义判据、只按结构放行：
    # 没有校验器比有结构校验强，拦死恢复反而让下一轮连结构兜底都没了。
    # secrets 判据（2026-10-19 事故 run 39229141269）：config validate 不校验
    # SecretRef 可解析性，「新增 telegram 账号但 env 变量没进 secrets allowlist」
    # 的配置照样 validate PASS，网关却在 secrets 激活阶段恒崩（required secrets
    # are unavailable）→ 自愈链（doctor / 回退同版本重装）对该故障无出口，反复
    # 恢复同一份坏主包死循环。unresolved>0 即判不合格，回退到「能真正启动」的
    # 历史版本为止。audit 从 $OPENCLAW_STATE_DIR/.env 取值 —— 单趟解包后 .env
    # 已在盘上（老 revision 包内没有 .env 也不会错杀：老式明文配置不依赖 env
    # 引用，audit 仍给 unresolved=0）。audit 自身崩溃按不合格处理 —— 宁可回退，
    # 不可放行必坏包。
    local root="$1"
    if [ ! -s "$root/.openclaw/openclaw.json" ]; then
      echo "FAIL (openclaw.json missing)"
      return 1
    fi
    command -v openclaw >/dev/null 2>&1 || { echo "SKIP (openclaw not on PATH)"; return 0; }
    if ! OPENCLAW_CONFIG_PATH="$root/.openclaw/openclaw.json" openclaw config validate >/dev/null 2>&1; then
      echo "FAIL (config invalid)"
      return 1
    fi
    local audit_out audit_rc unresolved_n
    if audit_out="$(OPENCLAW_STATE_DIR="$root/.openclaw" OPENCLAW_CONFIG_PATH="$root/.openclaw/openclaw.json" timeout 120 openclaw secrets audit 2>&1)"; then
      echo "PASS"
      return 0
    fi
    audit_rc=$?
    unresolved_n="$(printf '%s' "$audit_out" | grep -oE 'unresolved=[0-9]+' | head -n 1 | cut -d= -f2 || true)"
    if [ -n "${unresolved_n:-}" ] && [ "${unresolved_n}" -gt 0 ]; then
      echo "FAIL (secrets unresolved=${unresolved_n})"
      return 1
    fi
    echo "FAIL (secrets audit rc=${audit_rc})"
    return 1
  }
  try_openclaw_candidate() {
    # 用法: try_openclaw_candidate <tar.gz 路径> <对象名>
    # 通过 = 体积达标 + 能完整解开 + 盘上判据全过，解好的树留在 $RESTORE_DIR 等就位；
    # 任一不过 = 清掉 $RESTORE_DIR，绝不让下一个候选对着上一次的半成品判。
    local tar="$1" label="$2" kb
    kb="$(du -sk "$tar" 2>/dev/null | awk '{print $1}')"
    if [ -z "${kb:-}" ] || [ "$kb" -le 0 ]; then
      echo "⚠️ ${label}: 无法取得包体积，按不可用处理"
      return 1
    fi
    echo "${label} 大小: ${kb}KB"
    if [ "$kb" -lt "$OPENCLAW_TARBALL_MIN_KB" ]; then
      echo "⚠️ ${label} 体积不足（${kb}KB < ${OPENCLAW_TARBALL_MIN_KB}KB），按空壳处理"
      return 1
    fi
    require_free_kb /tmp $((kb * 3 + 1024 * 1024)) "${label} extract preflight"
    if ! extract_openclaw_archive "$tar" "$RESTORE_DIR"; then
      echo "⚠️ ${label} 解包失败（gzip 流不完整或 tar 结构坏）"
      rm -rf "$RESTORE_DIR"
      return 1
    fi
    OPENCLAW_RESTORE_VERDICT="$(validate_openclaw_tree "$RESTORE_DIR" || true)"
    if [[ "$OPENCLAW_RESTORE_VERDICT" == FAIL* ]]; then
      echo "⚠️ ${label} 判据未通过（${OPENCLAW_RESTORE_VERDICT}），不采用"
      rm -rf "$RESTORE_DIR"
      return 1
    fi
    echo "✅ ${label} 结构+配置+secrets 判据通过（${OPENCLAW_RESTORE_VERDICT}）"
    return 0
  }
  # B2 收口：try_openclaw_candidate 内的 config validate / secrets audit
  # 需要 openclaw CLI —— installer 必须在此前完成，判据强度不衰减。
  wait_cli_install
  tarball_usable=0
  if try_openclaw_candidate "$TMP_OPENCLAW_TAR" "云端主包"; then
    tarball_usable=1
    OPENCLAW_RESTORE_SOURCE="cloud-main"
  else
    echo "⚠️ 云端主包不可用，尝试 revision 回退..."
    DBX_TOKEN=$(rclone config show dropbox 2>/dev/null | sed -n 's/^token = .*"access_token":"\([^"]*\)".*/\1/p' | tail -1)
    if [ -n "$DBX_TOKEN" ]; then
      # limit=100（Dropbox API 上限即 100）：历史版本要多捞些，逐个验到能过为止
      mapfile -t GOOD_REVS < <(curl -s --max-time 60 -X POST https://api.dropboxapi.com/2/files/list_revisions \
        -H "Authorization: Bearer $DBX_TOKEN" -H "Content-Type: application/json" \
        -d '{"path":"/self-hosted/openclaw.tar.gz","mode":"path","limit":100}' \
        | python3 -c "import json,sys; d=json.load(sys.stdin); [print(r['rev'] + '|' + r.get('server_modified','')) for r in d.get('entries',[]) if r.get('size',0) >= ${OPENCLAW_TARBALL_MIN_KB} * 1024]" 2>/dev/null)
      echo "revision 候选（体积达标）: ${#GOOD_REVS[@]} 个"
      _rev_n=0
      for _entry in "${GOOD_REVS[@]:-}"; do
        [ -z "$_entry" ] && continue
        _rev="${_entry%%|*}"
        _rev_time="${_entry#*|}"
        [ "$_rev_time" = "$_entry" ] && _rev_time=""
        _rev_n=$((_rev_n + 1))
        echo "⬇️ 下载历史 revision $_rev（创建于 ${_rev_time:-未知}，候选 $_rev_n/${#GOOD_REVS[@]}）..."
        # 2026-10-23 修复：files/download 的参数必须放 Dropbox-API-Arg 头，
        # 此前是裸 JSON 头 → Dropbox 直接 400 拒掉，95 个候选全在 1s 内
        # 全灭且无任何判据输出，回退名存实亡。-f 让 4xx 显式失败，
        # 失败时打印 rc 与响应前几行，不再盲试。
        if curl -fsS --max-time 1800 -X POST https://content.dropboxapi.com/2/files/download \
           -H "Authorization: Bearer $DBX_TOKEN" \
           -H "Dropbox-API-Arg: {\"path\":\"/self-hosted/openclaw.tar.gz\",\"rev\":\"$_rev\"}" \
           -o "$TMP_OPENCLAW_TAR" \
           && try_openclaw_candidate "$TMP_OPENCLAW_TAR" "revision $_rev"; then
          tarball_usable=1
          OPENCLAW_RESTORE_SOURCE="revision"
          OPENCLAW_RESTORE_REV="$_rev"
          OPENCLAW_RESTORE_REV_TIME="$_rev_time"
          echo "✅ 已采用历史 revision $_rev（创建于 ${_rev_time:-未知}）"
          break
        else
          _rev_rc=$?
          echo "⚠️ revision $_rev 不可用（rc=${_rev_rc}）: $(head -c 120 "$TMP_OPENCLAW_TAR" 2>/dev/null)"
          rm -f "$TMP_OPENCLAW_TAR"
        fi
      done
    else
      echo "⚠️ 未能从 rclone 配置取到 Dropbox token，跳过 revision 回退"
    fi
  fi
  if [ "$tarball_usable" -ne 1 ]; then
    echo "❌ 云端主包与全部候选 revision 均不可用（体积/解包/配置/secrets 判据未通过）：拒绝用坏状态上岗" >&2
    exit 1
  fi
  # 判据已在盘上过，剩下的唯一动作是就位：清空 ~/.openclaw 后把通过校验的树搬过去。
  # cp -a → mv（2026-10-02）：/tmp 与 $HOME 实测同一文件系统（设备号相同），跨目录
  # mv 是 rename 而非拷贝 —— 6.39GiB 实测 cp -a 37.3s → mv 0.002s，语义等价（同样
  # 先清空再放入新内容）。回退：若将来换机导致跨设备 mv 失败，重建目录并退回 cp -a。
  if [ -d "$RESTORE_DIR/.openclaw" ]; then
    find ~/.openclaw -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    if rmdir "$HOME/.openclaw" 2>/dev/null && mv "$RESTORE_DIR/.openclaw" "$HOME/.openclaw" 2>/dev/null; then
      :
    else
      mkdir -p "$HOME/.openclaw"
      cp -a "$RESTORE_DIR/.openclaw/." "$HOME/.openclaw/"
    fi
    echo "✅ Restored ~/.openclaw from archive"
    echo "⏱️ install timing: wait_prefetch_and_extract_sec=$(( $(date +%s) - INST_T1 ))"
  else
    echo "⚠️ Archive does not contain .openclaw root, skipping archive restore."
  fi
  cleanup_archive_workdir
else
  echo "⚠️ No openclaw archive found. Falling back to sync from raw directory..."
  OPENCLAW_RESTORE_SOURCE="raw-dir"
  # B2 收口：installer 后台并行，与 raw 目录同步重叠；步骤结束前必须 wait，
  # 否则 GH 在 step 结束时回收子进程会打断半截安装。
  wait_cli_install
  rclone copy dropbox:self-hosted/openclaw ~/.openclaw \
    --retries 10 \
    --low-level-retries 20 \
    --timeout 1m \
    --contimeout 15s \
    --exclude "logs/**" \
    -P || true
fi

# 恢复来源落盘：跨 step 只能走文件（🟢 就绪通知 / 🚨 自愈失败通知都会读）。
{
  printf 'OPENCLAW_RESTORE_SOURCE=%s\n' "${OPENCLAW_RESTORE_SOURCE:-unknown}"
  printf 'OPENCLAW_RESTORE_REV=%s\n' "${OPENCLAW_RESTORE_REV:-}"
  printf 'OPENCLAW_RESTORE_REV_TIME=%s\n' "${OPENCLAW_RESTORE_REV_TIME:-}"
} > /tmp/openclaw-restore-meta.env

# 恢复后诊断：主包里到底恢复了什么（判断是否缺关键文件/状态库）
echo "=== restored ~/.openclaw ==="
ls -A ~/.openclaw | sort || true
echo "⏱️ install timing total_sec=$(( $(date +%s) - INST_T0 ))"
du -sh ~/.openclaw 2>/dev/null || true
stat -c '%s bytes  %n' ~/.openclaw/openclaw.json 2>/dev/null || echo "⚠️ openclaw.json 不存在"
ls -l ~/.openclaw/state 2>/dev/null || echo "⚠️ state/ 不存在"
# 2026-10-02 硬后置校验：恢复完成后 openclaw.json 必须在盘上。原设计只「大声
# 标记」、指望 Run OpenClaw 启动失败路径兜底 —— 实测不成立：preflight doctor
# 会现造一份合法配置让网关健康上岗（当轮 98KB 空壳即此形态），随后空壳照样
# 被打上行。改为直接 exit 1 硬失败，触发任务失败通知；带病上岗比失败一轮代价大。
if [ ! -s "$HOME/.openclaw/openclaw.json" ]; then
  echo "❌ 恢复完成后 openclaw.json 仍缺失：本轮状态不全，拒绝继续" >&2
  exit 1
fi
