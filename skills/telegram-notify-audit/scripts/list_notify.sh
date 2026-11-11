#!/usr/bin/env bash
# ===== Telegram 通知清单 / 机械校验（自动枚举，勿手工维护）=====
# 用法:
#   bash skills/telegram-notify-audit/scripts/list_notify.sh [域过滤子串]
#       枚举发送点 / 标题字面量 / 档位汇总（替代手工逐条清单）
#   bash skills/telegram-notify-audit/scripts/list_notify.sh --check
#       跑审计清单 1–15 项的机械校验，有 FAIL 时退出码 1
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

root, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
os.chdir(root)

EXTS = (".sh", ".yml", ".yaml", ".py", ".ps1")

# 库内部实现（发送层/包装层）不算通知发送点，避免把路由当调用方统计
LIB_SKIP = {
    ".github/scripts/telegram/tg_notify.sh",
    ".github/scripts/openlist/telegram.sh",
    ".github/scripts/proxy-speedtest/speedtest_common.py",
}

# 允许直连 Bot API 的文件（发送层自身 / 面板 message_id / sendDocument / 菜单配置）
CURL_ALLOW = {
    ".github/scripts/telegram/tg_notify.sh",
    ".github/scripts/openlist/telegram.sh",
    ".github/scripts/openlist/sync_notify.sh",
    ".github/scripts/telegram/ensure-miniapp-menu.sh",
}

ANY_SEND = re.compile(
    r"(?<![\w-])(send_tg_chunked|send_tg|send_telegram_message|send_telegram_chunked|send_telegram)\b"
    r"|(?<![\w-])Send-TgMessage\b"
)
NOTIFY_LINE = re.compile(r"tg_add_|tg_append|send_tg|send_telegram|Send-TgMessage")
# 真实调用（带变量/实参），用于排除 docstring 里「提到函数名」的散文
CALL_LINE = re.compile(
    r"\btg_(add_kv|add_section|add_title|add_path|add_note|add_pre|add_block|append)\s+\S+"
    r"|\bsend_tg(_chunked)?\s+\S+"
    r"|\bsend_telegram(_chunked)?\s*\("
    r"|\bSend-TgMessage\s+\S+"
)


def files(filt=""):
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


# ============ 清单模式 ============

def inventory(filt):
    rows, titles = [], []
    for path in files(filt):
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


# ============ 校验模式 ============

def strip_code(line):
    """去掉注释与引号内容，用于括号/花括号配平判断。"""
    out, q = [], None
    i = 0
    while i < len(line):
        ch = line[i]
        if q:
            if ch == q:
                q = None
            i += 1
            continue
        if ch in "'\"":
            q = ch; i += 1; continue
        if ch == "#":
            break
        out.append(ch); i += 1
    return "".join(out)


def scopes_for(path, lines):
    """把文件切成「独立 shell 作用域」：.sh 整文件；.yml 按 run: | 块；heredoc 单独成域。

    各 GitHub step 是独立 shell，跨 step 累计花括号会把后面的 source 误判成函数体内。
    """
    if not path.endswith((".yml", ".yaml")):
        return [(1, [(i + 1, l) for i, l in enumerate(lines)])]

    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)run:\s*\|", lines[i])
        if not m:
            i += 1
            continue
        base = len(m.group(1))
        i += 1
        body = []
        while i < len(lines):
            l = lines[i]
            if l.strip() and (len(l) - len(l.lstrip())) <= base:
                break
            body.append((i + 1, l))
            i += 1
        out.extend(_split_heredocs(body))
    return out


def _split_heredocs(body):
    """把 heredoc 体（cat > x <<'EOF' … EOF）切成独立作用域。"""
    out, cur, i = [], [], 0
    while i < len(body):
        ln, l = body[i]
        cur.append((ln, l))
        m = re.search(r"<<(?!<)[-~]?\s*['\"]?(\w+)['\"]?", l)
        if m and not l.strip().startswith("#"):
            delim = m.group(1)
            j = i + 1
            hd = []
            while j < len(body) and body[j][1].strip() != delim:
                hd.append(body[j])
                j += 1
            out.append((cur[0][0] if cur else 0, cur))
            out.append((hd[0][0] if hd else 0, hd))
            cur = []
            i = j + 1
            continue
        i += 1
    if cur:
        out.append((cur[0][0], cur))
    return out


def check():
    results = []   # (id, name, status, details, note)
    all_files = files()

    def add(cid, name, bad, note=""):
        results.append((cid, name, "FAIL" if bad else "PASS", bad, note))

    # 1 粗体/斜体
    bad = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            s = l.strip()
            if s.startswith("#") or '"""' in s:
                continue
            if re.search(r"</?[bi]>", l):
                bad.append(f"{p}:{i}: {s[:80]}")
    add(1, "粗体/斜体（<b>/<i>）", bad)

    # 2 平铺条目
    bad = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#"):
                continue
            if "•" in l:
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(2, "平铺条目（•）", bad)

    # 3 半角冒号 kv（只看真实通知调用行）
    bad = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#") or not CALL_LINE.search(l):
                continue
            if re.search(r"[一-龥]:", l):
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(3, "半角冒号 kv", bad)

    # 4 紧凑时长 / 长小数 / ISO 直出（只看真实通知调用行）
    bad = []
    pat = re.compile(r"\d+h ?\d+m|\d\.\d{4,} 秒|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}")
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#") or not CALL_LINE.search(l):
                continue
            if pat.search(l):
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(4, "紧凑时长/长小数/ISO 直出", bad)

    # 5 curl 直发（白名单外即偏差）
    bad = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#"):
                continue
            if re.search(r"curl .*(sendMessage|/bot)", l) and p not in CURL_ALLOW:
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(5, "curl 直发（白名单外）", bad)

    # 6 分隔线：四处同值 18 条
    defs = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if re.search(r"TG_SEP\s*=", l) and not l.strip().startswith("#"):
                defs.append((p, i, l.strip()))
    bad = []
    if len(defs) != 4:
        bad.append(f"定义处数 {len(defs)}（期望 4）: " + "; ".join(f"{p}:{i}" for p, i, _ in defs))
    for p, i, l in defs:
        if "0x2501" in l:
            ok = "* 18" in l
        elif "━" in l:
            ok = l.count("━") == 18 or "* 18" in l
        else:
            ok = False
        if not ok:
            bad.append(f"{p}:{i}: 分隔线不是 18 条: {l[:70]}")
    add(6, "分隔线四处同值 18 条", bad)

    # 7 收尾区覆盖：需人工判断分支汇聚，这里只做提示
    results.append((7, "收尾区覆盖（分支汇聚需人工）", "MANUAL", [], ""))

    # 8 TG_RUN_URL 接线
    bad = []
    for p in sorted(set(f for f in all_files if f.endswith((".yml", ".yaml")))):
        t = open(p, encoding="utf-8", errors="replace").read()
        if ANY_SEND.search(t) and "TG_RUN_URL" not in t:
            bad.append(f"{p}: 有发送点但未注入 TG_RUN_URL")
    add(8, "TG_RUN_URL 接线", bad)

    # 9 树形前缀必须包 <code>
    bad = []
    for p in all_files:
        if p.endswith("tg_notify.sh"):
            continue
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#"):
                continue
            if not ("├─" in l or "└─" in l) or "<code>" in l:
                continue
            # 连接符定义/取值（connector = '└─' if … else '├─'）：拼接处另行包 <code>
            if re.match(r"^\s*[A-Za-z_]\w*\s*=\s*['\"][├└]", l):
                continue
            bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(9, "树形前缀包 <code>", bad)

    # 10 分节后跟列表必须带计数
    bad = []
    for p in all_files:
        L = open(p, encoding="utf-8", errors="replace").read().split("\n")
        for i, l in enumerate(L):
            if "tg_add_section" not in l or l.strip().startswith("#"):
                continue
            if " · " in l or "${" in l.split("tg_add_section")[-1]:
                continue
            if "tree_" in "\n".join(L[i + 1:i + 6]):
                bad.append(f"{p}:{i+1}: {l.strip()[:80]}")
    add(10, "分节后跟列表带计数", bad)

    # 11 助手速查表存在性
    bad = []
    try:
        doc = open("docs/telegram-notify.md", encoding="utf-8").read()
        sec = doc.split("### 5.3 助手速查")[1].split("---")[0]
        rows = [l for l in sec.split("\n") if l.startswith("|") and "`" in l][2:]
        srcs = {
            "bash": open(".github/scripts/telegram/tg_notify.sh", encoding="utf-8").read(),
            "pwsh": open(".github/scripts/telegram/tg_notify.ps1", encoding="utf-8").read(),
            "python": open(".github/scripts/proxy-speedtest/speedtest_common.py", encoding="utf-8").read(),
        }
        for r in rows:
            cells = [c.strip() for c in r.strip("|").split("|")]
            for col, kind in ((1, "bash"), (2, "pwsh"), (3, "python")):
                if col >= len(cells):
                    continue
                for name in re.findall(r"`([A-Za-z_]\w*)`", cells[col]):
                    if kind == "bash":
                        ok = re.search(rf"^{name}\(\)", srcs[kind], re.M) or name == "TG_SEP"
                    elif kind == "pwsh":
                        ok = re.search(rf"^function {name}\b", srcs[kind], re.M) or name.startswith("$")
                    else:
                        ok = re.search(rf"^def {name}\b", srcs[kind], re.M) or name == "TG_SEP"
                    if not ok:
                        bad.append(f"5.3 表 {kind} 列: {name} 在真源不存在")
    except Exception as e:
        bad.append(f"解析 5.3 表失败: {e}")
    add(11, "助手速查表与真源一致", bad)

    # 12 函数体内 source 真源（按 YAML run 块 / heredoc 分作用域：
    # 各 step 是独立 shell，跨 step 累计括号会误判）
    bad = []
    for p in all_files:
        if not p.endswith((".sh", ".yml", ".yaml")):
            continue
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
        for _start, body in scopes_for(p, lines):
            depth = 0
            fn_stack = []
            for ln, l in body:
                code = strip_code(l)
                if re.search(r"source\s+.*tg_notify\.sh", l) and not l.strip().startswith("#"):
                    if fn_stack:
                        bad.append(f"{p}:{ln}: 在函数 {fn_stack[-1]} 内 source（应移到顶层）")
                m = re.search(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{", code)
                if m:
                    fn_stack.append(m.group(1))
                depth += code.count("{") - code.count("}")
                while fn_stack and depth <= 0:
                    fn_stack.pop()
                    depth = 0
    add(12, "函数体内 source 真源", bad)

    # 13 接力轮去重：语义项，需人工
    results.append((13, "接力轮重复通知（需人工）", "MANUAL", [], ""))

    # 14 🕒 只允许常驻服务
    bad = []
    for p in all_files:
        if p.endswith("health/system_health.sh"):
            continue
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if "🕒" in l and not l.strip().startswith("#"):
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(14, "🕒 只用于常驻服务", bad)

    # 15 通知里不得直出 UTC
    bad = []
    for p in all_files:
        for i, l in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if l.strip().startswith("#") or not CALL_LINE.search(l):
                continue
            if "UTC" in l:
                bad.append(f"{p}:{i}: {l.strip()[:80]}")
    add(15, "通知里不直出 UTC", bad)

    print("# Telegram 通知机械校验（审计清单 1–15 项）")
    print(f"# 仓库: {root}")
    print()
    fails = 0
    for cid, name, status, details, note in results:
        mark = {"PASS": "✅", "FAIL": "❌", "MANUAL": "👤"}[status]
        print(f"{mark} [{cid:>2}] {name}")
        for d in details:
            print(f"        {d}")
        if status == "FAIL":
            fails += 1
    print()
    print(f"结果: {sum(1 for r in results if r[2]=='PASS')} 项通过 · "
          f"{fails} 项失败 · {sum(1 for r in results if r[2]=='MANUAL')} 项需人工")
    if fails:
        print("提示: 第 7/13 项依赖语义判断，见 references/audit-checklist.md")
        sys.exit(1)


if arg == "--check":
    check()
else:
    inventory(arg)
PY