# ===== Windows runner (pwsh) — Telegram 通知发送层 + 排版助手 =====
# 规范唯一真源: docs/telegram-notify.md。与 bash 版 telegram/tg_notify.sh 同语义:
#   - 统一 HTML parse_mode，动态内容必须经 Esc-Html 转义
#   - 429 限流按 Retry-After 重试（最多 5 次）
#   - HTML 解析失败（400 can't parse entities）不重发、直接抛出:
#     消息本就没被 Telegram 接收，退化纯文本只会把版式 bug 藏起来
# 用法（workflow 中 dot-source，函数与变量进入当前作用域）:
#   . "$env:GITHUB_WORKSPACE\.github\scripts\telegram\tg_notify.ps1"
# 提供:
#   Esc-Html <s>           HTML 实体转义（& < >）
#   Get-TgFooter           收尾区字符串（⏱ 已运行 X · 🔗 运行日志；降级链与 tg_add_footer 同）
#   Send-TgMessage <text>  单条发送（HTML；失败 throw，错误含响应体前 200 字符）
#   $TG_SEP                统一分隔线（18 个全角横线，勿手写）

$TG_SEP = [string][char]0x2501 * 18

function Esc-Html([string]$s) {
  if (-not $s) { return $s }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

# 秒数 → 中文三段式（X 小时 Y 分 / X 分钟 / X 秒，与 bash tg_add_footer 逐字一致）
function Format-TgDuration([int]$totalSec) {
  $hh = [int][math]::Floor($totalSec / 3600)
  $mm = [int][math]::Floor(($totalSec % 3600) / 60)
  $ss = $totalSec % 60
  if ($hh -gt 0) { return "$hh 小时 $mm 分" }
  elseif ($mm -gt 0) { return "$mm 分钟" }
  else { return "$ss 秒" }
}

# 收尾区（与 bash tg_add_footer 同形态同降级链）:
#   TG_RUN_STARTED_AT → 时长；解析失败 → 系统 uptime 兜底（GitHub 平台已移除
#   github.run_started_at 表达式上下文，2026-09-05 验证；hosted runner VM 随 job
#   启动，误差秒级）；仍取不到 → 无时长；TG_RUN_URL 缺失 → 无链接；两者皆无 → 空串
function Get-TgFooter {
  $dur = ""
  try {
    $started = [DateTime]::Parse($Env:TG_RUN_STARTED_AT, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $dur = Format-TgDuration ([int][math]::Max(0, [math]::Round(((Get-Date).ToUniversalTime() - $started.ToUniversalTime()).TotalSeconds)))
  } catch { }
  if (-not $dur) {
    try {
      $up = [int][math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
      if ($up -gt 0) { $dur = Format-TgDuration $up }
    } catch { }
  }
  $footer = ""
  if ($dur) { $footer = "⏱ 已运行 <b>$dur</b>" }
  if ($Env:TG_RUN_URL) {
    if ($footer) { $footer += " · " }
    $footer += "🔗 <a href=""$(Esc-Html $Env:TG_RUN_URL)"">运行日志</a>"
  }
  return $footer
}

# 单条发送（HTML parse_mode；429 按 Retry-After 重试最多 5 次；其余失败 throw 并带响应体）
function Send-TgMessage([string]$text) {
  $body = @{ chat_id = $Env:TELEGRAM_CHAT_ID; text = $text; disable_web_page_preview = 'true'; parse_mode = 'HTML' }
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      Invoke-RestMethod -Uri "https://api.telegram.org/bot$Env:TELEGRAM_BOT_TOKEN/sendMessage" `
        -Method Post -Body $body | Out-Null
      return
    } catch {
      $resp = $_.Exception.Response
      $status = 0
      if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }
      if ($status -eq 429) {
        $wait = 5
        try { if ($resp.Headers['Retry-After']) { $wait = [int]$resp.Headers['Retry-After'] } } catch { }
        Write-Host "⚠️ Telegram 限流 (429)，等待 ${wait}s 后重试 ($attempt/5)..."
        Start-Sleep -Seconds $wait
        continue
      }
      # 错误信息带上 API 响应体（如 "can't parse entities"），与 bash 发送层同语义
      $detail = $_.ErrorDetails.Message
      if ($detail) { throw "Telegram 通知发送失败 (HTTP $status): $($detail.Substring(0, [Math]::Min(200, $detail.Length)))" }
      throw
    }
  }
  throw "Telegram 通知发送失败（重试 5 次仍限流）"
}
