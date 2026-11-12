#!/usr/bin/env bash
# 启动 vaultwarden 容器：把 secret 当作**数据**（docker run 参数串）解析，不做 shell 求值。
#
# 安全整改（ACT9d）：原 workflow 写成
#     run: ${{ secrets.VAULTWARDEN }}
# —— secret 在 workflow 编译阶段被直接内插进 run 脚本，等价于把一段外部文本当代码
# 执行：任何 `$(...)`、反引号、管道、重定向都会以 runner 权限运行；同时该 secret
# 的完整内容会进入 workflow run 的 run 字段。现在改为：
#   1. workflow 只用 env 注入（VAULTWARDEN_RUN），不再出现在 run: 模板里
#   2. 本脚本用 Python shlex 按 POSIX 词法切分成 argv（**不经过 shell**），
#      再用 exec docker <argv...> 启动
#   3. 只接受 `docker run ...` 形态；其他内容一律拒绝并给出明确报错
#
# 支持的 secret 形态（示例）：
#   docker run -d --name vaultwarden \
#     -v /dropbox/self-hosted/bitwarden/bitwarden-data:/data \
#     -p 8080:80 -e ADMIN_TOKEN=xxx vaultwarden/server:1.34.3
# 允许前置 sudo；反斜杠续行会被合并。任何 shell 元字符都只会作为普通字符/参数，
# 不会被解释执行（`$()`、反引号、`;`、`|` 等不再是命令分隔符）。
set -euo pipefail

: "${VAULTWARDEN_RUN:?VAULTWARDEN_RUN 未注入（secrets.VAULTWARDEN 未配置）}"

export VAULTWARDEN_RUN
# Python 只做词法切分与 NUL 分隔输出；-I 隔离用户 site-packages。
mapfile -d '' -t ARGV < <(python3 -I - <<'PY'
import os
import re
import shlex
import sys

raw = os.environ["VAULTWARDEN_RUN"]
# 合并 POSIX 反斜杠续行（secret 里常见 `\` + 换行的手写格式）
raw = re.sub(r"\\\s*\n", " ", raw)
try:
    argv = shlex.split(raw, comments=False, posix=True)
except ValueError as exc:
    print(f"无法解析 VAULTWARDEN_RUN 的 docker 参数: {exc}", file=sys.stderr)
    sys.exit(2)

if not argv:
    print("VAULTWARDEN_RUN 为空", file=sys.stderr)
    sys.exit(2)
if argv[0] == "sudo":
    argv = argv[1:]
if len(argv) < 2 or argv[0] != "docker" or argv[1] != "run":
    print(
        "VAULTWARDEN_RUN 必须是 `docker run ...`（或 `sudo docker run ...`）形式的参数串；"
        "拒绝执行其他内容",
        file=sys.stderr,
    )
    sys.exit(2)

sys.stdout.buffer.write(b"\0".join(a.encode() for a in argv[2:]) + b"\0")
PY
)
if [ "${#ARGV[@]}" -eq 0 ]; then
  echo "::error::VAULTWARDEN_RUN 解析后无 docker run 参数（拒绝执行）" >&2
  exit 2
fi

echo "启动 vaultwarden：docker run（参数 ${#ARGV[@]} 个，内容不落日志）"
exec docker run "${ARGV[@]}"
