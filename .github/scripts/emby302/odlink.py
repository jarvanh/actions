#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""odlink —— OpenList 协议兼容的 OneDrive 直链服务（302 直链的协议胶水层）

背景
----
ge2o 只能通过 alist/OpenList 的 /api/fs/* 接口取直链，而 OpenList 官方 OneDrive
驱动**不跟随快捷方式(remoteItem)**：网盘根目录下 0-5/backup 全是快捷方式，指向各自
的远程盘，OpenList 按路径寻址必然 object not found → 302 直链永不生效 → 播放
静默回源中转。rclone 之所以通，是因为它逐段解析、遇 remoteItem 就切到
/drives/{driveId}/items/{itemId} 继续下钻。

本服务对外伪装成 OpenList 的 /api/fs/get|list|other，对内用 Microsoft Graph
复刻 rclone 的快捷方式跟随，把 @microsoft.graph.downloadUrl 作为 raw_url 返回，
ge2o 据此发出 302。非快捷方式路径（或 Graph 解析失败）原样转发给本机
OpenList(:5244)，保证零回归——odlink 不可用时行为与今天完全一致。

只读：不写网盘数据，不修改任何链路状态。

接口契约（与 ge2o internal/service/openlist/api.go 一致）
------------------------------------------------------
POST /api/fs/get   {path,password,refresh} → data.raw_url  （直链的关键）
POST /api/fs/list  {path,password,refresh} → data.content  （目录树/探活）
POST /api/fs/other 转码预览，未启用，返回非 200 即可
请求头 Authorization: <token>；ge2o 要求 HTTP 200 且响应体 code == 200

凭据体系（三套，互不相干）
------------------------
1. Graph access_token（微软 OneDrive 侧）：本服务用。由 rclone.conf [onedrive] 段的
   refresh_token 自动换取（rclone 内置应用通常无 client_id/secret，故在临近过期或
   遭遇 401 时调用 `rclone about` 触发刷新再从配置取回）。仅用于直连微软 Graph
   解析路径/取直链，与 OpenList 的任何账号密码无关。
2. OpenList 会话 token（OpenList 侧）：workflow 用 OPENLIST_ADMIN_PASSWORD secret
   登录 /api/auth/login 自动获取并写入 /tmp/openlist-token，供探活与（直链源退回
   OpenList 时的）转发链路使用。ge2o 的请求会原样透传 Authorization 头，本服务
   只在本进程的 AUTH_TOKEN 上校验 odlink 自身的 token（/tmp/odlink-token）。
3. admin 密码（OpenList 管理面）：仅 oe 后台人工登录用（admin + secret）。
   只有机器用 secret 登录失败时才自愈重置，并经 TG 私信告知；正常运行绝不改密。
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GRAPH = "https://graph.microsoft.com/v1.0"
RCLONE_CONF = os.environ.get("ODLINK_RCLONE_CONF",
                             os.path.expanduser("~/.config/rclone/rclone.conf"))
# OpenList 存储挂载根（也是 rclone 挂载点）。ge2o 映射 /onedrive:/onedrive 后
# 送来的 path 形如 /onedrive/3/电影/x.mkv，需剥掉该前缀再交给 Graph 解析。
ROOT_PREFIX = os.environ.get("ODLINK_ROOT", "/onedrive")
UPSTREAM = os.environ.get("ODLINK_UPSTREAM", "http://127.0.0.1:5244")
UPSTREAM_TOKEN_FILE = os.environ.get("ODLINK_UPSTREAM_TOKEN", "/tmp/openlist-token")
AUTH_TOKEN = os.environ.get("ODLINK_TOKEN", "")
PORT = int(os.environ.get("ODLINK_PORT", "5245"))
LOG_PATH = os.environ.get("ODLINK_LOG", "/opt/logs/odlink.log")
# 最近一次成功取到的直链落盘位置，供 playlog 的 TG 通知附上直链。
# 只写在 runner 本地、不进 workflow 日志（公开仓库），TG 侧是私密 chat。
LAST_LINK_FILE = os.environ.get("ODLINK_LAST", "/opt/odlink-last.json")

# ge2o 用 Go 把 modified 当 time.Time 解析，空字符串会导致整个响应解析失败并回源中转，
# 因此任何情况下都必须给出合法 RFC3339 时间戳。
FALLBACK_TIME = "1970-01-01T00:00:00Z"

# 目录条目缓存无 TTL：本轮 run 内路径不会自己搬家，命中即用，减少 Graph 往返
LINK_TTL = 40 * 60          # downloadUrl 官方约 1 小时有效，保守缓存 40 分钟
TOKEN_REFRESH_MARGIN = 600  # 距过期不足 10 分钟就提前刷新
BOOTSTRAP_RETRY_SEC = 60    # bootstrap 未就绪时的重试间隔

# 仓库公开：日志一律脱敏，不输出 token、完整直链、完整媒体路径
_QS = re.compile(r"[?&](api_key|access_token|token)=[^&]*", re.I)
_URL = re.compile(r"https?://\S+")


def log(msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)


def redact(s):
    """脱敏，防止意外把凭据/链接写进公开日志。

    顺序有意为之：先按 query 参数脱敏（覆盖日志里出现的裸 ?api_key=...），
    再把整个 URL 替换成占位符——URL 里可能还藏着签名、itemId 等，整体替换最安全。
    """
    s = _QS.sub(lambda m: m.group(0).split("=")[0] + "=[redacted]", str(s))
    s = _URL.sub("<url>", s)
    return s[:400]


def parse_expiry(value):
    """rclone 的 expiry 形如 2026-09-02T11:00:00.123456789+08:00。"""
    if not value:
        return 0
    try:
        s = str(value).strip().replace("Z", "+00:00")
        s = re.sub(r"(\.\d{6})\d+", r"\1", s)  # 纳秒截断到微秒，兼容低版本 fromisoformat
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return 0


def enc(s):
    """Graph 路径段编码：保留 ! 等 OneDrive itemId 常用字符。"""
    return urllib.parse.quote(s, safe="!()*'$-_.+~")


def ts(value):
    """保证返回合法 RFC3339 时间戳（ge2o 按 time.Time 解析，空串会直接报错）。"""
    if not value:
        return FALLBACK_TIME
    s = str(value).strip()
    # Graph 返回形如 2024-05-01T12:34:56Z，Go 的 time.Time 可直接解析
    return s if s.endswith("Z") or "+" in s[10:] else FALLBACK_TIME


class TokenStore(object):
    """access_token 从 rclone.conf 的 [onedrive] 段读取。

    runner 上有 rclone mount 常驻，它会持续刷新并回写 conf，所以读 conf 就是
    最省事也最可靠的取值方式（自己拿 refresh_token 换需要 client_id/secret，
    而 rclone 内置应用下这两个字段是空的）。仅在临近过期或遭遇 401 时，
    用 `rclone about` 主动触发一次刷新再重读。
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._at = ""
        self._expiry = 0

    def _read_conf(self):
        section = {}
        in_sec = False
        try:
            with open(RCLONE_CONF, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.rstrip("\n").rstrip("\r")
                    if line.startswith("["):
                        in_sec = line.strip().lower() == "[onedrive]"
                        continue
                    if in_sec and "=" in line:
                        k, v = line.split("=", 1)
                        section[k.strip()] = v.strip()
        except Exception as e:
            log("读取 rclone.conf 失败: %s" % type(e).__name__)
            return {}
        return section

    def _read_token(self):
        """从 rclone.conf 的 [onedrive] 段解析出 token JSON。"""
        raw = self._read_conf().get("token", "")
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def _rclone_refresh(self):
        """让 rclone 自己完成刷新（它会把新 token 回写 conf），我们再读回。"""
        try:
            subprocess.run(["rclone", "about", "onedrive:", "--config", RCLONE_CONF],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=90)
        except Exception as e:
            log("rclone 刷新失败: %s" % type(e).__name__)

    def _load(self, force=False):
        """按代价从低到高取一个可用的 access_token。

        1) 内存里的 token 仍在有效期内（留 TOKEN_REFRESH_MARGIN 余量）→ 直接返回
        2) 否则重读 rclone.conf —— 常驻的 rclone mount 会持续把刷新后的 token 写回
        3) 重读后依旧缺失/临近过期 → 主动触发一次 rclone 刷新，再读回
        """
        now = time.time()
        if not force and self._at and now < self._expiry - TOKEN_REFRESH_MARGIN:
            return self._at

        tok = self._read_token()
        at = tok.get("access_token", "")
        expiry = parse_expiry(tok.get("expiry"))

        if force or (not at) or (expiry and now > expiry - TOKEN_REFRESH_MARGIN):
            log("触发 rclone 刷新 token（force=%s）" % bool(force))
            self._rclone_refresh()
            tok = self._read_token()
            at = tok.get("access_token", "")
            expiry = parse_expiry(tok.get("expiry"))

        if at:
            self._at = at
            # conf 里没有 expiry 时按 1 小时兜底，避免反复触发刷新
            self._expiry = expiry or (now + 3600)
        return self._at

    def get(self):
        with self._lock:
            return self._load(force=False)

    def refresh(self):
        with self._lock:
            return self._load(force=True)


class Graph(object):
    def __init__(self, tokens):
        self.tokens = tokens
        self.stats = {"ok": 0, "err": 0, "refresh": 0}
        self._lock = threading.Lock()

    def req(self, url, retry_on_auth=True):
        """返回 (http_code, json_body_or_None, error_code)。"""
        token = self.tokens.get()
        if not token:
            return 0, None, "no-token"

        def once(tok):
            r = urllib.request.Request(url, headers={
                "Authorization": "Bearer " + tok,
                "Accept": "application/json",
                "User-Agent": "odlink/1.0",
            })
            try:
                with urllib.request.urlopen(r, timeout=30) as resp:
                    return resp.status, json.loads(resp.read().decode("utf-8", "replace")), ""
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", "replace") if hasattr(e, "read") else ""
                code = ""
                try:
                    j = json.loads(body)
                    code = (j.get("error") or {}).get("code", "")
                except Exception:
                    pass
                return e.code, None, code or ("http%d" % e.code)
            except Exception as e:
                return 0, None, type(e).__name__

        status, body, err = once(token)

        # 401/403：token 失效 → 刷新一次再试
        if status in (401, 403) and retry_on_auth:
            log("Graph %d，刷新 token 后重试" % status)
            self.tokens.refresh()
            with self._lock:
                self.stats["refresh"] += 1
            status, body, err = once(self.tokens.get())

        # 429/5xx：退避重试一次
        if status in (429, 500, 502, 503, 504):
            time.sleep(2)
            status, body, err = once(self.tokens.get())

        with self._lock:
            if status == 200:
                self.stats["ok"] += 1
            else:
                self.stats["err"] += 1
        return status, body, err


class Resolver(object):
    """路径→直链解析：优先缓存与 Graph 路径寻址一次解析，逐段下钻作兜底
    （兜底复刻 rclone 的行为：遇 remoteItem 切换 drive 继续）。"""

    def __init__(self, graph):
        self.graph = graph
        self.ready = False
        self.root_drive = ""
        self.root_id = ""
        self.shortcuts = {}     # 顶层名 -> (remote driveId, remote itemId)
        self.root_items = []    # 根目录条目（bootstrap 一次拿全，列根不再依赖上游）
        self.dir_cache = {}     # "3/电影" -> (driveId, itemId, is_dir, modified)
        self.link_cache = {}    # "3/电影/x.mkv" -> (url, size, expire_ts, modified)
        # 计数器：供 /stats 与收尾 TG 通知汇总本轮 302 链路运行情况
        self.stats = {"get": 0, "list": 0, "link_ok": 0, "link_miss": 0,
                      "resolve_err": 0, "fallback": 0, "cross_drive": 0,
                      "fast_path": 0}
        self._lock = threading.Lock()

    def bump(self, key, n=1):
        """累加计数。与 stats_snapshot 共用同一把锁，保证读到的快照不自相矛盾。"""
        with self._lock:
            self.stats[key] = self.stats.get(key, 0) + n

    def stats_snapshot(self):
        with self._lock:
            return dict(self.stats)

    def bootstrap(self):
        """列一次根目录：拿到主盘 root 的 (driveId,itemId) 与快捷方式集合。"""
        st, body, err = self.graph.req(GRAPH + "/me/drive/root?$select=id,parentReference")
        if st != 200 or not body:
            log("bootstrap 失败：主盘 root 不可达 http=%s err=%s" % (st, err))
            return False
        self.root_drive = (body.get("parentReference") or {}).get("driveId", "")
        self.root_id = body.get("id", "")
        if not (self.root_drive and self.root_id):
            log("bootstrap 失败：root 缺少 driveId/itemId")
            return False

        st, body, err = self.graph.req(
            GRAPH + "/me/drive/root/children"
                    "?$select=name,id,remoteItem,folder,lastModifiedDateTime&$top=200")
        if st != 200 or not body:
            log("bootstrap 失败：根目录列举 http=%s err=%s" % (st, err))
            return False

        shortcuts = {}
        root_items = []
        for it in body.get("value", []):
            name = it.get("name", "")
            root_items.append({
                "name": name,
                "size": it.get("size", 0),
                "is_dir": True,          # 顶层全是快捷方式（指向远程盘目录）或普通目录
                "modified": ts(it.get("lastModifiedDateTime")),
            })
            ri = it.get("remoteItem")
            if not ri:
                continue
            drive = (ri.get("parentReference") or {}).get("driveId", "")
            iid = ri.get("id", "")
            if drive and iid:
                shortcuts[name] = (drive, iid)
                self.dir_cache[name] = (drive, iid, True,
                                        ts(it.get("lastModifiedDateTime")))

        with self._lock:
            self.shortcuts = shortcuts
            self.root_items = root_items
        self.ready = True
        log("bootstrap 就绪：主盘 drive=%s… 快捷方式 %d 个 %s"
            % (self.root_drive[:8], len(shortcuts), redact(sorted(shortcuts.keys()))))
        return True

    def is_shortcut(self, first_seg):
        with self._lock:
            return first_seg in self.shortcuts

    def resolve(self, segments):
        """解析路径。返回 (driveId, itemId, is_dir, crossed, err, modified)。

        三级策略（按成本从低到高）：
        1. 整段路径已在 dir_cache（此前解析过/列目录回填过）→ 零 Graph 调用；
        2. 路径寻址一次解析：首段快捷方式切盘后（bootstrap 已预缓存），
           /drives/{d}/items/{id}:/{sub/…}: 一次请求拿到底——冷解析从 N 段
           串行 Graph 往返压到 1 次（逐段每段一调、单次数百 ms，N 段深路径
           冷解析数秒，是 302 起播慢的服务端主因）；
        3. 寻址失败（中段快捷方式未被路径寻址跟随等）→ 逐段下钻兜底。
        """
        key = "/".join(segments)
        with self._lock:
            cached = self.dir_cache.get(key)
            sc0 = bool(segments) and segments[0] in self.shortcuts
        if cached:
            drive, item_id, is_dir, modified = cached
            return drive, item_id, is_dir, (1 if sc0 else 0), None, modified

        if len(segments) > 1:
            with self._lock:
                cached0 = self.dir_cache.get(segments[0])
            if cached0:
                d0, i0 = cached0[0], cached0[1]
                rest = "/".join(enc(s) for s in segments[1:])
                url = ("%s/drives/%s/items/%s:/%s:"
                       "?$select=id,name,size,folder,parentReference,remoteItem,lastModifiedDateTime") % (
                    GRAPH, enc(d0), enc(i0), rest)
                st, body, err = self.graph.req(url)
                if st == 200 and body and not body.get("remoteItem"):
                    drive = (body.get("parentReference") or {}).get("driveId", d0)
                    item_id = body.get("id", "")
                    is_dir = "folder" in body
                    modified = ts(body.get("lastModifiedDateTime"))
                    if item_id:
                        self.bump("fast_path")
                        with self._lock:
                            self.dir_cache[key] = (drive, item_id, is_dir, modified)
                        return drive, item_id, is_dir, 1, None, modified
                # 终点是快捷方式（remoteItem）时也走兜底：下钻逻辑对 remoteItem
                # 的跨盘换算更完整，不值得为这个罕见场景复制一份
                log("路径寻址未命中 http=%s err=%s 段数=%d，回退逐段下钻"
                    % (st, err, len(segments)))

        return self._resolve_drill(segments)

    def _resolve_drill(self, segments):
        """逐段下钻（兜底路径，兼容中段快捷方式）。返回值同 resolve()。"""
        drive, item_id = self.root_drive, self.root_id
        crossed = 0
        is_dir = True
        modified = FALLBACK_TIME

        for i, seg in enumerate(segments):
            key = "/".join(segments[:i + 1])
            with self._lock:
                cached = self.dir_cache.get(key)
                is_sc = seg in self.shortcuts
            # bootstrap 已把快捷方式首段预缓存，命中缓存时同样计一次跨盘
            if is_sc:
                crossed += 1
            if cached:
                drive, item_id, is_dir, modified = cached
                continue

            url = ("%s/drives/%s/items/%s:/%s:"
                   "?$select=id,name,size,folder,parentReference,remoteItem,lastModifiedDateTime") % (
                GRAPH, enc(drive), enc(item_id), enc(seg))
            st, body, err = self.graph.req(url)
            if st != 200 or not body:
                log("解析失败 段%d http=%s err=%s 首段=%s"
                    % (i + 1, st, err, segments[0] if segments else "-"))
                return None, None, None, crossed, (st, err), modified

            ri = body.get("remoteItem")
            if ri:
                nd = (ri.get("parentReference") or {}).get("driveId", "")
                ni = ri.get("id", "")
                if not (nd and ni):
                    return None, None, None, crossed, (st, "remoteItem-incomplete"), modified
                drive, item_id = nd, ni
                is_dir = "folder" in ri
                crossed += 1
            else:
                drive = (body.get("parentReference") or {}).get("driveId", drive)
                item_id = body.get("id", "")
                is_dir = "folder" in body

            modified = ts(body.get("lastModifiedDateTime"))
            if not item_id:
                return None, None, None, crossed, (st, "no-item-id"), modified
            with self._lock:
                self.dir_cache[key] = (drive, item_id, is_dir, modified)

        return drive, item_id, is_dir, crossed, None, modified

    def download_url(self, drive, item_id, cache_key):
        """取预授权直链。不带 $select 取完整对象，确保含 @microsoft.graph.downloadUrl。

        返回 (url, size, modified)；失败时 url 为空串。
        """
        now = time.time()
        with self._lock:
            hit = self.link_cache.get(cache_key)
        if hit and hit[2] > now:
            return hit[0], hit[1], hit[3]

        st, body, err = self.graph.req("%s/drives/%s/items/%s" % (GRAPH, enc(drive), enc(item_id)))
        if st != 200 or not body:
            log("取直链失败 http=%s err=%s" % (st, err))
            return "", 0, FALLBACK_TIME
        url = body.get("@microsoft.graph.downloadUrl") or \
            (body.get("content") or {}).get("downloadUrl") or ""
        size = body.get("size", 0)
        modified = ts(body.get("lastModifiedDateTime"))
        if url:
            with self._lock:
                self.link_cache[cache_key] = (url, size, now + LINK_TTL, modified)
        return url, size, modified

    def list_children(self, drive, item_id, cache_prefix=None):
        """列目录。cache_prefix 给定时把子条目回填 dir_cache——列过的目录，
        其下条目后续解析直接整路径命中缓存，不再逐段下钻（子级快捷方式按
        bootstrap 同口径缓存为远程盘坐标）。"""
        items = []
        url = "%s/drives/%s/items/%s/children?$select=name,id,size,folder,parentReference,remoteItem,lastModifiedDateTime&$top=200" % (
            GRAPH, enc(drive), enc(item_id))
        new_cache = {}
        while url:
            st, body, err = self.graph.req(url)
            if st != 200 or not body:
                log("列目录失败 http=%s err=%s" % (st, err))
                break
            for it in body.get("value", []):
                name = it.get("name", "")
                modified = ts(it.get("lastModifiedDateTime"))
                items.append({
                    "name": name,
                    "size": it.get("size", 0),
                    "is_dir": "folder" in it,
                    "modified": modified,
                })
                ri = it.get("remoteItem")
                if cache_prefix and name and it.get("id"):
                    if ri:
                        nd = (ri.get("parentReference") or {}).get("driveId", "")
                        ni = ri.get("id", "")
                        if nd and ni:
                            new_cache["%s/%s" % (cache_prefix, name)] = (nd, ni, "folder" in ri, modified)
                    else:
                        new_cache["%s/%s" % (cache_prefix, name)] = (drive, it["id"], "folder" in it, modified)
            url = body.get("@odata.nextLink", "")
        if new_cache:
            with self._lock:
                self.dir_cache.update(new_cache)
        return items


def strip_root(path):
    """剥掉 OpenList 存储挂载前缀 /onedrive，得到网盘内路径。"""
    p = (path or "").strip()
    if ROOT_PREFIX:
        if p == ROOT_PREFIX:
            return ""
        if p.startswith(ROOT_PREFIX + "/"):
            return p[len(ROOT_PREFIX) + 1:]
    return p.lstrip("/")


def openlist_ok(data):
    return json.dumps({"code": 200, "message": "success", "data": data},
                      ensure_ascii=False).encode("utf-8")


def openlist_err(code, message):
    return json.dumps({"code": code, "message": message, "data": None},
                      ensure_ascii=False).encode("utf-8")


def forward_upstream(api, payload, auth):
    """原样转发给本机 OpenList，保持非快捷方式路径的行为不变。"""
    try:
        url = UPSTREAM + api
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": auth or ""})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""
    except Exception as e:
        return 0, json.dumps({"code": 500, "message": "upstream %s" % type(e).__name__,
                              "data": None}).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "odlink"

    def log_message(self, fmt, *args):
        pass  # 访问日志不落盘（含路径，公开仓库需避免噪声）

    def _send(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _status_payload(self):
        """/healthz 与 /stats 的公共载荷。只含计数，不含任何凭据与直链。"""
        res = self.server.resolver
        return {"ready": res.ready, "shortcuts": len(res.shortcuts),
                "graph": res.graph.stats, "fs": res.stats_snapshot(),
                "dirs_cached": len(res.dir_cache),
                "links_cached": len(res.link_cache)}

    def do_GET(self):
        if self.path == "/ping":
            self._send(200, b'{"code":200,"message":"pong","data":null}')
        elif self.path == "/healthz":
            # 探活：ready 且确实能取到 token 才算 200，否则 503 让上层回退 direct
            p = self._status_payload()
            st = 200 if (p["ready"] and self.server.tokens.get()) else 503
            self._send(st, json.dumps(
                {k: p[k] for k in ("ready", "shortcuts", "graph")}).encode())
        elif self.path == "/stats":
            # 本轮 302 链路运行统计，供启动/收尾 TG 通知汇总
            self._send(200, json.dumps(self._status_payload()).encode())
        else:
            self._send(404, b'{"code":404,"message":"not found","data":null}')

    def do_POST(self):
        api = self.path.split("?")[0]
        if api not in ("/api/fs/get", "/api/fs/list", "/api/fs/other"):
            self._send(404, b'{"code":404,"message":"not found","data":null}')
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            self._send(400, b'{"code":400,"message":"bad request","data":null}')
            return

        # 转码预览未启用：如实返回不可用，ge2o 会按现有策略处理
        if api == "/api/fs/other":
            self._send(200, openlist_err(500, "video_preview not supported"))
            return

        if AUTH_TOKEN and self.headers.get("Authorization", "") != AUTH_TOKEN:
            self._send(401, b'{"code":401,"message":"unauthorized","data":null}')
            return

        path = payload.get("path", "") or ""
        rel = strip_root(path)
        segments = [s for s in rel.split("/") if s]

        res = self.server.resolver

        # odlink 已就绪时的根目录请求：bootstrap 已拿到全部顶层条目，
        # 直接本地应答，不必再绕上游（少一个级联故障点）
        if res.ready and not segments:
            if api == "/api/fs/list":
                content = res.root_items
                self._send(200, openlist_ok({
                    "content": content, "total": len(content), "readme": "",
                    "header": "", "write": False, "provider": "OneDrive"}))
                log("list 根目录 条目=%d" % len(content))
            else:
                self._send(200, openlist_ok({
                    "name": ROOT_PREFIX.strip("/"), "size": 0, "is_dir": True,
                    "modified": ts(None), "raw_url": "", "provider": "OneDrive"}))
                log("get 根目录（目录，无直链）")
            return

        # 分流：odlink 未就绪、或首段不是快捷方式 → 原样转发 OpenList（零回归）
        if (not res.ready) or (not segments) or (not res.is_shortcut(segments[0])):
            res.bump("fallback")
            status, body = forward_upstream(
                api, payload, self.headers.get("Authorization", ""))
            self._send(status if status else 502, body or openlist_err(500, "upstream error"))
            return

        drive, item_id, is_dir, crossed, err, modified = res.resolve(segments)
        if err or not item_id:
            # Graph 解析失败 → 转发兜底，不把故障放大给用户
            res.bump("resolve_err")
            res.bump("fallback")
            status, body = forward_upstream(
                api, payload, self.headers.get("Authorization", ""))
            log("回退 OpenList 段数=%d 首段=%s http=%s" % (
                len(segments), segments[0], err[0] if err else "-"))
            self._send(status if status else 502, body or openlist_err(500, "upstream error"))
            return

        if crossed:
            res.bump("cross_drive")

        if api == "/api/fs/list":
            res.bump("list")
            content = res.list_children(drive, item_id, cache_prefix="/".join(segments)) if is_dir else []
            self._send(200, openlist_ok({
                "content": content, "total": len(content), "readme": "",
                "header": "", "write": False, "provider": "OneDrive"}))
            log("list 段数=%d 跨盘=%d 条目=%d" % (len(segments), crossed, len(content)))
            return

        # /api/fs/get
        name = segments[-1] if segments else ""
        if is_dir:
            # 探活会对媒体顶层目录做 fs/get，目录没有直链但必须返回 200，
            # 否则会被判成链路不健康而回退 direct。
            res.bump("get")
            self._send(200, openlist_ok({
                "name": name, "size": 0, "is_dir": True, "modified": modified,
                "raw_url": "", "provider": "OneDrive"}))
            log("get 目录 段数=%d 跨盘=%d" % (len(segments), crossed))
            return

        key = "/".join(segments)
        url, size, modified = res.download_url(drive, item_id, key)
        res.bump("get")
        if not url:
            res.bump("link_miss")
            self._send(200, openlist_err(500, "no downloadUrl"))
            log("get 文件 段数=%d 跨盘=%d 未取到直链" % (len(segments), crossed))
            return

        res.bump("link_ok")
        host = urllib.parse.urlparse(url).netloc
        # 最近一次直链落盘，供 playlog 的 TG 通知附上直链（仅本轮 runner 内，
        # 不进 workflow 日志；TG 侧为私密 chat）
        try:
            with open(LAST_LINK_FILE, "w", encoding="utf-8") as f:
                json.dump({"name": name, "url": url, "host": host,
                           "size": size, "ts": time.time()}, f)
        except Exception:
            pass
        self._send(200, openlist_ok({
            "name": name, "size": size, "is_dir": False, "modified": modified,
            "raw_url": url, "provider": "OneDrive"}))
        log("get 文件 段数=%d 跨盘=%d 直链 host=%s 长度=%d" % (
            len(segments), crossed, host, len(url)))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, resolver, tokens):
        ThreadingHTTPServer.__init__(self, addr, handler)
        self.resolver = resolver
        self.tokens = tokens


def bootstrap_loop(resolver, stop):
    """就绪前反复重试；一旦成功即退出——顶层快捷方式名单就此固定。

    这是有意的行为：**顶层**名单是本轮 run 的快照，期间新建/改名/删除的快捷方式
    不会被感知（首段不命中 → 原样转发 OpenList）。快捷方式**内部**的子路径不受
    影响，它们是每次请求实时逐段下钻的，任意深度都无需预先扫描。
    """
    while not stop.is_set():
        if resolver.bootstrap():
            return
        stop.wait(BOOTSTRAP_RETRY_SEC)


def main():
    tokens = TokenStore()
    graph = Graph(tokens)
    resolver = Resolver(graph)

    stop = threading.Event()
    t = threading.Thread(target=bootstrap_loop, args=(resolver, stop), daemon=True)
    t.start()

    log("odlink 启动 端口=%d 上游=%s root前缀=%s 日志=%s"
        % (PORT, UPSTREAM, ROOT_PREFIX, LOG_PATH))
    log("凭据说明：本服务仅使用 Graph access_token（rclone.conf 自动刷新，微软侧）；"
        "OpenList 会话 token 由 workflow 机器自动登录获取；"
        "oe 后台人工登录（admin+secret）与本进程互不影响")
    if not AUTH_TOKEN:
        log("警告：未配置 ODLINK_TOKEN，将不校验 Authorization")

    srv = Server(("127.0.0.1", PORT), Handler, resolver, tokens)
    try:
        srv.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        srv.server_close()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("odlink 异常退出: %s" % redact("%s: %s" % (type(e).__name__, e)))
        sys.exit(1)
