#!/bin/bash
# 清理 yt-dlp 下载过程中产生的残留文件
# 残留文件类型：
#   *.mp4-Frag*、*.part-Frag*   - 未完成的分片下载
#   *.ytdl                       - yt-dlp 临时元数据文件
#   *.m3u8                       - HLS 播放列表残留
#
# 用法: cleanup_ytdlp_residual.sh [target_dir]
#   target_dir  - 待清理的目录路径，默认 ~/onedrive/0/j-1024j-视频-pornhub-favorites
#
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE,
#           GITHUB_REPOSITORY, GITHUB_RUN_ID（用于发送 Telegram 通知）

set +e

TARGET_DIR="${1:-$HOME/onedrive/0/j-1024j-视频-pornhub-favorites}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "目录不存在，跳过清理: $TARGET_DIR"
  exit 0
fi

cd "$TARGET_DIR" || exit 0

# 递归查找 yt-dlp 残留文件（包含子目录）
mapfile -t FRAG_FILES < <(find . -type f \( -name '*.mp4-Frag*' -o -name '*.part-Frag*' -o -name '*.ytdl' -o -name '*.m3u8' \) -print)
FRAG_COUNT=${#FRAG_FILES[@]}

if [ "$FRAG_COUNT" -eq 0 ]; then
  echo "未发现 yt-dlp 残留文件"
  exit 0
fi

# 发送 Telegram 通知（统一 HTML 排版；明细超长自动分片）
# 助手需在明细构建前可用：文件名经 escape_html（含 & < > 未转义会 400 解析失败、
# 整条消息发送失败——解析失败不重发，直接暴露）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

# 收集文件名与大小，用于通知（树形条目统一 ├─/└─；元数据 " · …"，禁括号）。
# 每组上限 8 条 + 折叠行"还有 N 条…"并入条目流（规范 · 折叠规则：残留可能上百条，
# 全量穷举会刷屏并顶到 4000 分片边界把收尾区切走；末条 └─ 由 tree_lines 统一决定）
FILE_DETAILS=""
for f in "${FRAG_FILES[@]}"; do
  fname=$(basename "$f")
  # 大小口径统一走真源助手（规范 · 大小写法）：du -h 的「8.0M」与全库不同口径
  fsize=$(format_bytes "$(stat -c%s "$f")")
  # 条目行统一走 tg_add_entry（主体等宽 + 元数据 " · " 分隔、统一转义）
  tg_add_entry FILE_DETAILS "$fname" "$fsize"
done
# 超 8 条折叠交给真源 tree_fold（规范 · 折叠规则）：条目流已由 tg_add_entry 构建（已转义、
# 已含 <code>），tree_fold 只截断 + 加折叠行；此前此处手写计数器截断 + 拼折叠行，
# 是 tree_fold 的重复实现（与 file_split / sync_marker / sync_to_tg 收敛后不一致）

# 删除残留文件
find . -type f \( -name '*.mp4-Frag*' -o -name '*.part-Frag*' -o -name '*.ytdl' -o -name '*.m3u8' \) -delete
echo "已清理 ${FRAG_COUNT} 个 yt-dlp 残留文件"

DIR_LABEL=$(basename "$TARGET_DIR")
msg=""
tg_add_title msg "🧹 ph-dl 清理 yt-dlp 残留文件"
tg_add_path msg "目录" "$DIR_LABEL"
tg_add_kv msg "清理数量" "${FRAG_COUNT} 个"
tg_add_section msg "📋 文件列表 · ${FRAG_COUNT}"
tg_add_block msg "$(tree_fold "${FILE_DETAILS%$'\n'}")"
tg_add_footer msg
send_tg_chunked "$msg"
