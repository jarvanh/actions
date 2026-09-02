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

# ge2o 用 Go 把 modified 当 time.Time 解析，空字符串会导致整个响应解析失败并回源中转，
# 因此任何情况下都必须给出合法 RFC3339 时间戳。
FALLBACK_TIME = "1970-01-01T00:00:00Z"

LINK_TTL = 40 * 60          # downloadUrl 官方约 1 小时有效，保守缓存 40 分钟
TOKEN_REFRESH_MARGIN = 600  # 距过期不足 10 分钟就刷新
CONF_CACHE_TTL = 5          # rclone.conf 读取缓存秒数
BOOTSTRAP_RETRY = 300       # 就绪前重试间隔

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
    """脱敏，防止意外把凭据/链接写进公开日志。"""
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
        self._read_at = 0
        self._mtime = 0

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

    def _load(self, force=False):
        now = time.time()
        if not force and self._at and now < self._expiry - TOKEN_REFRESH_MARGIN:
            return self._at
        if not force and now - self._read_at < CONF_CACHE_TTL and self._at \
                and now < self._expiry - TOKEN_REFRESH_MARGIN:
            return self._at

        try:
            mtime = os.path.getmtime(RCLONE_CONF)
        except Exception:
            mtime = 0
        if not force and mtime == self._mtime and self._at \
                and now < self._expiry - TOKEN_REFRESH_MARGIN:
            return self._at

        section = self._read_conf()
        raw = section.get("token", "")
        tok = {}
        if raw:
            try:
                tok = json.loads(raw)
            except Exception:
                tok = {}

        at = tok.get("access_token", "")
        expiry = parse_expiry(tok.get("expiry"))

        if (not at) or (expiry and now > expiry - TOKEN_REFRESH_MARGIN) or force:
            # 让 rclone 自己完成刷新（它会回写 conf），再取回新 token
            log("触发 rclone 刷新 token（force=%s）" % bool(force))
            try:
                subprocess.run(["rclone", "about", "onedrive:", "--config", RCLONE_CONF],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=90)
            except Exception as e:
                log("rclone 刷新失败: %s" % type(e).__name__)
            section = self._read_conf()
            tok = {}
            try:
                tok = json.loads(section.get("token", "") or "{}")
            except Exception:
                tok = {}
            at = tok.get("access_token", "")
            expiry = parse_expiry(tok.get("expiry"))

        self._read_at = now
        if at:
            self._at = at
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
    """复刻 rclone 的路径解析：逐段下钻，遇 remoteItem 切换 drive 继续。"""

    def __init__(self, graph):
        self.graph = graph
        self.ready = False
        self.root_drive = ""
        self.root_id = ""
        self.shortcuts = {}     # 顶层名 -> (remote driveId, remote itemId)
        self.root_items = []    # 根目录条目（bootstrap 一次拿全，列根不再依赖上游）
        self.dir_cache = {}     # "3/电影" -> (driveId, itemId, is_dir)
        self.link_cache = {}    # "3/电影/x.mkv" -> (url, expire_ts)
        self._lock = threading.Lock()

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
        """逐段下钻。返回 (driveId, itemId, is_dir, crossed, err, modified)。"""
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

    def list_children(self, drive, item_id):
        items = []
        url = "%s/drives/%s/items/%s/children?$select=name,id,size,folder,lastModifiedDateTime&$top=200" % (
            GRAPH, enc(drive), enc(item_id))
        while url:
            st, body, err = self.graph.req(url)
            if st != 200 or not body:
                log("列目录失败 http=%s err=%s" % (st, err))
                break
            for it in body.get("value", []):
                items.append({
                    "name": it.get("name", ""),
                    "size": it.get("size", 0),
                    "is_dir": "folder" in it,
                    "modified": ts(it.get("lastModifiedDateTime")),
                })
            url = body.get("@odata.nextLink", "")
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

    def do_GET(self):
        if self.path == "/ping":
            self._send(200, b'{"code":200,"message":"pong","data":null}')
        elif self.path == "/healthz":
            res = self.server.resolver
            st = 200 if (res.ready and self.server.tokens.get()) else 503
            data = {"ready": res.ready, "shortcuts": len(res.shortcuts),
                    "graph": res.graph.stats}
            self._send(st, json.dumps(data).encode())
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
            status, body = forward_upstream(
                api, payload, self.headers.get("Authorization", ""))
            self._send(status if status else 502, body or openlist_err(500, "upstream error"))
            return

        drive, item_id, is_dir, crossed, err, modified = res.resolve(segments)
        if err or not item_id:
            # Graph 解析失败 → 转发兜底，不把故障放大给用户
            status, body = forward_upstream(
                api, payload, self.headers.get("Authorization", ""))
            log("回退 OpenList 段数=%d 首段=%s http=%s" % (
                len(segments), segments[0], err[0] if err else "-"))
            self._send(status if status else 502, body or openlist_err(500, "upstream error"))
            return

        if api == "/api/fs/list":
            content = res.list_children(drive, item_id) if is_dir else []
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
            self._send(200, openlist_ok({
                "name": name, "size": 0, "is_dir": True, "modified": modified,
                "raw_url": "", "provider": "OneDrive"}))
            log("get 目录 段数=%d 跨盘=%d" % (len(segments), crossed))
            return

        key = "/".join(segments)
        url, size, modified = res.download_url(drive, item_id, key)
        if not url:
            self._send(200, openlist_err(500, "no downloadUrl"))
            log("get 文件 段数=%d 跨盘=%d 未取到直链" % (len(segments), crossed))
            return

        host = urllib.parse.urlparse(url).netloc
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
    while not stop.is_set():
        if resolver.bootstrap():
            return
        stop.wait(60)
    return


def main():
    tokens = TokenStore()
    graph = Graph(tokens)
    resolver = Resolver(graph)

    stop = threading.Event()
    t = threading.Thread(target=bootstrap_loop, args=(resolver, stop), daemon=True)
    t.start()

    log("odlink 启动 端口=%d 上游=%s root前缀=%s 日志=%s"
        % (PORT, UPSTREAM, ROOT_PREFIX, LOG_PATH))
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
