# 真实范例集

全部摘自本仓库。写新通知时**照着抄结构**，不要自创。

| # | 类型 | 最佳范例 | 备选 |
|---|---|---|---|
| 1 | 最简单 | `.github/workflows/icloud-photos-downloader.yml:122-145` | `github_backup_all.yml:117-154` |
| 2 | 条目清单 | `.github/scripts/tg-channel/cleanup_ytdlp_residual.sh:37-65` | `openlist/sync_notify.sh:266-292` |
| 3 | `<pre>` 块 | `.github/workflows/openclaw.yml:1717-1745` | `openlist/sync_marker.sh:920-937` |
| 4 | 最复杂（进度面板） | `.github/scripts/openlist/sync_progress.sh:427-598` | `openlist/task_preview.sh:420-429` |
| 5 | pwsh | `.github/workflows/rdp.yml:86-102` | `tailscale-windows.yml:119-165` |
| 6 | python | `.github/scripts/proxy-speedtest/speedtest.py:954-1065` | `taier_speedtest.py:574-594` |

---

## 1. 最简单（接线 + 分态 + 发送）

`.github/workflows/icloud-photos-downloader.yml:122-145`（逐字）：

```yaml
      # ===== 通知（失败/取消也发布）=====
      # 此前通知写在业务 run 块末尾且无 always()：icloudpd 非零退出时通知整段不执行，
      # 失败时反而收不到消息；标题也恒「完成」。改为独立 step 按 job.status 分态。
      - name: "Notify: iCloud 下载结果"
        if: ${{ always() }}
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
          TG_RUN_STARTED_AT: ${{ github.run_started_at }}
        run: |
          source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"
          case "${{ job.status }}" in
            # 状态语义由标题 emoji 承担即可，kv 值里再带一个就成了重复（规范 5.1 节）
            success)   _emoji="☁️"; _status="完成" ;;
            cancelled) _emoji="⛔"; _status="已取消" ;;
            *)         _emoji="❌"; _status="失败" ;;
          esac
          msg=""
          tg_add_title msg "$_emoji iCloud 照片下载"
          tg_add_kv msg "图库" "个人 + 共享 · 增量 · 自动清理"
          tg_add_kv msg "状态" "$_status"
          tg_add_footer msg
          send_tg "$msg" || echo "::warning::iCloud 通知发送失败（不影响任务）"
```

**学什么**：全库最短完整闭环。① 接线四件套 + `always()` 一个不少；② 状态语义只由标题 emoji 承担；③ `|| echo "::warning::"` 是「通知失败不把任务判红」的标准写法。

多分支版本看 `github_backup_all.yml:117-154`：四态（⛔中断 / ⚠️异常 / ✅成功 / ❌失败）共用一条 `tg_add_footer + send_tg` 出口，⛔ 分支提前 `exit 0` 避免二次追加；凭据缺失静默 `exit 0`。

## 2. 条目清单（折叠管线的标准写法）

`.github/scripts/tg-channel/cleanup_ytdlp_residual.sh:37-65`（逐字）：

```bash
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

FILE_DETAILS=""
for f in "${FRAG_FILES[@]}"; do
  fname=$(basename "$f")
  fsize=$(du -h "$f" | cut -f1)
  # 条目行统一走 tg_add_entry（主体等宽 + 元数据 " · " 分隔、统一转义）
  tg_add_entry FILE_DETAILS "$fname" "$fsize"
done

DIR_LABEL=$(basename "$TARGET_DIR")
msg=""
tg_add_title msg "🧹 ph-dl 清理 yt-dlp 残留文件"
tg_add_path msg "目录" "$DIR_LABEL"
tg_add_kv msg "清理数量" "${FRAG_COUNT} 个"
tg_add_section msg "📋 文件列表 · ${FRAG_COUNT}"
tg_add_block msg "$(tree_fold "${FILE_DETAILS%$'\n'}")"
tg_add_footer msg
send_tg_chunked "$msg"
```

**学什么**：清单唯一正确管线 `tg_add_entry` → `tree_fold` → `tg_add_block`；`source` 在明细构建**之前**；清单可能上百条 → 折叠 + `send_tg_chunked`。

空清单跳过与两种折叠分工看 `openlist/sync_notify.sh:58-92`（`tree_code_fold` 收裸文本的排除规则）与 `:266-292`（`fix_total -gt 0` 才插分节，避免 `✅ … · 0`）。

## 3. `<pre>` 块

`.github/workflows/openclaw.yml:1717-1745` 的 `send_telegram_alert()`（一个函数 = 一条完整通知，可直接照抄）。要点：

- 机器值（对象 / Run ID）走 `tg_add_path` 进 `<code>`，自然语言（结论 / 原因）走 `tg_add_kv` 裸文本；
- 分节 `🧾 原始输出` **不带** ` · N`（计数只用于条目列表）；
- `tg_add_pre full_msg "$(printf '%s' "$detail" | tail -c 1200)"` —— 尾部 1200 字节，超长会跨分片破版；
- `<pre>` 是正文最后一块，其后只跟收尾区。

复制即用命令块的固定形态看 `openlist/sync_marker.sh:920-937`：`tg_add_note "▸ 描述"` + `tg_add_pre "命令"` 成对出现（`file_split.sh:104-107` 同形态）。

## 4. 进度面板（最复杂，全库唯一原地刷新）

`.github/scripts/openlist/sync_progress.sh:427-598`：

- 终态判定**按严重度排序**：⛔ 中断 > ⚠️ 有失败 > ✅ 带修复 > ✅ 完全完成。注释解释了为什么「中断」必须排在「失败」之前——顺序错了读者会误以为整轮跑完。
- 四组任务列表（待处理 / 已完成 / 已跳过 / 失败）**故意不折叠**（只调 `tree_lines`）——面板要一眼看全，这是合规的刻意例外。
- 时长**只从 `tg_add_footer` 出**（旧的「⏱️ 已用：」写法已废除）。
- 刷新走「删旧 + 发新」而非 `editMessageText`，配 `flock` 防孤儿消息（`:601-618`）。

「一个分节 + 一段预渲染树」的极简骨架看 `openlist/task_preview.sh:420-429`（主干只有 7 行，复杂排版都在辅助函数里）。

## 5. pwsh

`.github/workflows/rdp.yml:86-102`（17 行示范了 pwsh 侧全部规矩）：

```powershell
. "$env:GITHUB_WORKSPACE\.github\scripts\telegram\tg_notify.ps1"
# 自检: dot-source 失败会让后续调用未定义函数而静默无通知，显式暴露
if (-not (Get-Command Send-TgMessage -ErrorAction SilentlyContinue)) { throw "tg_notify.ps1 加载失败" }
$msg = "🖥️ Windows RDP 已就绪`n$TG_SEP`n" +
  "🔐 RDP · 3`n" +
  "  ├─ 地址：<code>$(Esc-Html $address)</code>`n" +
  "  ├─ 用户名：<code>runneradmin</code>`n" +
  "  └─ 密码：<code>$(Esc-Html $Env:RDP_PASSWORD)</code>`n" +
  "`n有效期：约 6 小时 · 超时自动结束"
$msg += "`n`nℹ️ 连接方式：Microsoft Remote Desktop / 任何 RDP 客户端，地址填上面这一行"
$footer = Get-TgFooter
if ($footer) { $msg += "`n`n$footer" }
Send-TgMessage $msg
```

**学什么**：dot-source 后必须 `Get-Command` 自检；分节 emoji 不与标题 emoji 重复；首个分节紧跟分隔线**不补空行**；`Get-TgFooter` 可能返回空（无 `TG_RUN_URL` 时降级），必须判空再拼。

多分节 + 条件分组 + 外部 API 失败逐项降级看 `tailscale-windows.yml:119-165`（说明段必须排在 kv 之后）。

## 6. python

`.github/scripts/proxy-speedtest/speedtest.py:954-1065` 的 `build_telegram_lines()` 是 python 侧完整参考实现，逐行注释标了规范章节。四个必学点：

1. 标题 emoji 随结论降级（0 可用节点 → ⚠️，不再恒 ✅）；
2. 折叠上限统一取 **8**（此前本域用 5，与 `tree_fold` 默认值不一致，是显式收敛过的）；
3. 折叠行并入条目流，末条 `└─` 由最后的循环统一决定（禁双 `└─`）；
4. 收尾区**固定一个空行**（曾连写两个 `append('')` 变双空行，见 `taier_speedtest.py:548` 注释）。

异常兜底通知的最小骨架看 `taier_speedtest.py:574-594`（12 行）：发送前先恢复环境（撤 TUN），否则 API 都送不出去；原始异常串属机器值 → `tg_entry`；兜底分支必须走 `notify_best_effort`，直接 `send_telegram(...)` 后 `except: pass` 会让 400/429 变成静默消失。

## 反例（别学）

- `.github/scripts/tg-channel/sync_to_tg.sh:72-90` 的 `notify()`：为了让 python 已拼好的正文复用 bash 的 `tg_add_footer`，它 `bash -c` 起子进程把整条消息塞进 `shlex.quote`。代价是正文完全绕过 `tg_add_*` 助手、跨语言桥接脆弱、每发一条启一个 bash。**python 侧就用 `speedtest_common` 的镜像助手，不要绕回 bash。**
- `upload-video-to-tg.yml:33` 硬编码频道 ID（不是通知收件人，不违反通知规范，但 hygiene 上应用 secret——同仓库 `ph-dl.yml` 走的就是 secret）。

**看似违规、实为合规**（别误判成反例）：进度面板任务列表不折叠；失败清单用 `tree_fold`、排除规则用 `tree_code_fold`；二层列表（`sync_notify.sh` fail_summary 的修复过程子行）手写按条目计数而不用 `tree_fold`；`sendDocument` 不走 sendMessage 发送层；单条排除规则不扩树。
