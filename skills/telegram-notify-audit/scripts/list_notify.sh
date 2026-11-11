#!/usr/bin/env bash
# ===== Telegram 通知清单（自动枚举，勿手工维护）=====
# 用途: 现场回答「全库现在有哪些通知发送点、各走什么档位、标题是什么」，
#       替代手工维护的逐条清单（手工清单必然随实现漂移）。
# 用法: bash skills/telegram-notify-audit/scripts/list_notify.sh [域过滤子串]
#   例: bash skills/telegram-notify-audit/scripts/list_notify.sh openlist
# 输出: 发送点 / 标题字面量 / 汇总三段。
#
# 判据:
#   档位 —— 调用点显式传 alert 才算重要档；tier 是变量则标「动态」并提示人工确认；
#           缺省为普通档。进度面板与 sendDocument/sendVideo 直连 bot，不在本清单内。
#   标题 —— tg_add_title 的第二个实参，或 title=/_title= 赋值；变量拼接只列变量名。
# 范围: .github/ 下的 .sh/.yml/.py/.ps1，排除 tests（夹具里的发送是 mock）。
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
exec python3 - "$ROOT" "${1:-}" <<'PY'
import os, re, sys, datetime

root, filt = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
os.chdir(root)

EXTS = (".sh", ".yml", ".yaml", ".py", ".ps1")

# 库内部实现（发送层/包装层）不算通知发送点，避免把路由当调用方统计
LIB_SKIP = {
    ".github/scripts/telegram/tg_notify.sh",
    ".github/scripts/openlist/telegram.sh",
    ".github/scripts/proxy-speedtest/speedtest_common.py",
}

ANY_SEND = re.compile(
    r"(?<![\w-])(send_tg_chunked|send_tg|send_telegram_message|send_telegram_chunked|send_telegram)\b"
    r"|(?<![\w-])Send-TgMessage\b"
)


def files():
    out = []
    for base, dirs, names in os.walk(".github"):
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]
        for n in names:
            p = os.path.join(base, n)
            if not n.endswith(EXTS) or "/tests/" in p or "\\tests\\" in p:
                continue
            if filt and filt not in p:
                continue
            out.append(p[2:] if p.startswith("./") else p)
    return sorted(out)


def joined(lines, i):
    """把续行拼起来（bash 的 \\ 续行、python 的多行调用）。"""
    buf = lines[i].rstrip("\n")
    j = i
    while buf.rstrip().endswith("\\") and j + 1 < len(lines):
        j += 1
        buf = buf.rstrip()[:-1] + " " + lines[j].strip()
    guard = 0
    while buf.count("(") > buf.count(")") and j + 1 < len(lines) and guard < 30:
        j += 1
        buf += " " + lines[j].strip()
        guard += 1
    return buf, j


def split_args(s):
    """按顶层逗号切参数（括号/引号内的逗号不切）。"""
    args, cur, q, depth = [], "", None, 0
    for ch in s:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in "'\"":
            q = ch; cur += ch
        elif ch in "([{":
            depth += 1; cur += ch
        elif ch in ")]}":
            depth -= 1; cur += ch
        elif ch == "," and depth == 0:
            args.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        args.append(cur.strip())
    return [a for a in args if a]


def bash_args(rest):
    """把 bash 的一段调用文本按空白切分，引号内不切。"""
    args, cur, q = [], "", None
    for ch in rest:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in "'\"":
            q = ch; cur += ch
        elif ch in " \t":
            if cur:
                args.append(cur); cur = ""
        else:
            cur += ch
    if cur:
        args.append(cur)
    return args


def classify(tier):
    t = (tier or "").strip().strip("'\"")
    t = re.sub(r"[;)\s]+$", "", t)
    if not t:
        return "普通"
    if t == "alert":
        return "alert"
    return "动态"


rows, titles = [], []
for path in files():
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines(True)
    except OSError:
        continue
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped.startswith("#"):
            continue

        # 标题字面量（与发送点解耦：标题行不含发送调用）
        mt = re.search(r"tg_add_title\s+\S+\s+(.+)", stripped)
        if mt:
            titles.append((path, i + 1, mt.group(1).strip()[:110]))
            continue
        mt = re.search(r'^\s*_?title\s*=\s*(.+)', stripped)
        if mt and "tg_" not in stripped:
            titles.append((path, i + 1, mt.group(1).strip()[:110]))
            continue

        if not ANY_SEND.search(raw):
            continue
        if "Get-Command" in raw or path in LIB_SKIP:
            continue

        kind = tier = None
        cmd, _ = joined(lines, i)
        if cmd.strip().startswith("#"):
            continue

        # bash
        m = re.search(r"(?<![\w-])(send_tg_chunked|send_tg|send_telegram_message)\b", cmd)
        if m and "() {" not in cmd:
            rest = cmd[m.end():]
            # 参数在 shell 控制符处结束（|| && ; | ) then），否则会把后续命令当成 tier
            rest = re.split(r"\|\||&&|;|\||\)|\bthen\b", rest, maxsplit=1)[0]
            args = bash_args(rest)
            if m.group(1) == "send_telegram_message":
                tier = args[2] if len(args) > 2 else ""
            else:
                tier = args[1] if len(args) > 1 else ""
            kind = "bash"

        # python
        if kind is None:
            m = re.search(r"(?<![\w.])(send_telegram_chunked|send_telegram)\s*\(", cmd)
            if m and not cmd.strip().startswith("def "):
                rest = cmd[m.end():]
                depth, end = 1, len(rest)
                for idx, ch in enumerate(rest):
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            end = idx
                            break
                args = split_args(rest[:end])
                tier = args[2] if len(args) > 2 else ""
                kind = "python"

        # pwsh
        if kind is None:
            m = re.search(r"(?<![\w-])Send-TgMessage\b", cmd)
            if m and "function " not in cmd:
                args = bash_args(cmd[m.end():])
                tier = args[1] if len(args) > 1 else ""
                kind = "pwsh"

        if kind:
            rows.append((path, i + 1, kind, classify(tier),
                         re.sub(r"\s+", " ", cmd.strip())[:96]))

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
print("# Telegram 通知清单（自动枚举 · 勿手工维护）")
print(f"# 仓库: {root}")
print(f"# 时间: {now:%Y-%m-%d %H:%M}（东八区）")
if filt:
    print(f"# 过滤: {filt}")
print()

print("## 发送点（调用行）")
print(f"{'文件:行':<52} {'实现':<7} {'档位':<5} 调用")
for p, ln, kind, tier, cmd in rows:
    print(f"{p + ':' + str(ln):<52} {kind:<7} {tier:<5} {cmd}")

print()
print("## 标题字面量")
for p, ln, t in titles:
    print(f"{p + ':' + str(ln):<52} {t}")

n = {"普通": 0, "alert": 0, "动态": 0}
for *_x, tier, _c in rows:
    n[tier] = n.get(tier, 0) + 1
print()
print("## 汇总")
print(f"发送点 {len(rows)} 个：普通 {n['普通']} · alert {n['alert']} · 动态 {n['动态']}")
print(f"标题字面量 {len(titles)} 条（变量拼接的只到变量名，需回文件确认取值）")
print("面板 / sendDocument / sendVideo 直连 bot，不在本清单内（见台账 · 域索引）")
if n["动态"]:
    print(f"注意: {n['动态']} 个发送点的档位是变量，需人工确认取值后再判断档位")
PY