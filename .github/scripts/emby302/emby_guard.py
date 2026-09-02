#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Emby 数据目录完整性校验（恢复后 / 备份前 共用同一份实现）。

为什么需要它
------------
Emby 数据来自云端备份的流式解压，任何一环中断都可能留下"半恢复"的残库。
此时若照常启动，Emby 会把它当成全新空库并重建索引；更糟的是备份步骤会把
这份空数据回传云端，把好备份覆盖掉。所以两处都必须先过这道闸：
  - install emby  ：恢复完成后校验，不通过就拒绝启动（宁可本轮失败，不启空库）
  - backup emby   ：打包回传前再校验一次，确认要上传的确实是好数据

检查项（任一不通过即以非零码退出，调用方据此中止）
------------------------------------------------
1. 关键库文件存在：data/users.db、data/library.db
2. 存在指定用户（Derrick）        —— 防空库
3. 媒体库根结构正确               —— Id=1 为 "Media Folders"、Id=2 为 "root"
4. Media Folders 下存在媒体库目录 —— 防库结构残缺
5. root 下存在 /onedrive 真实媒体路径 —— 防路径缺失导致 302 直链必然失效

隐私
----
仓库公开，输出只给计数（用户数/条目数），绝不打印用户名与媒体路径明细。

用法
----
    sudo python3 emby_guard.py <emby-data-root>      # 例：/var/lib/emby
"""

import json
import sqlite3
import sys
from pathlib import Path

# 期望存在的用户名：库里没有它就说明这份数据不是我们的备份
EXPECTED_USER = "Derrick"
# 媒体路径前缀：Emby 库路径必须落在这里，才能与 OpenList/rclone 挂载根对齐
MEDIA_PREFIX = "/onedrive/"


def fail(msg):
    raise SystemExit("❌ Emby guard failed: %s" % msg)


def check_users(root):
    """校验用户表：确认存在期望用户。"""
    users_db = root / "data/users.db"
    conn = sqlite3.connect("file:%s?mode=ro" % users_db, uri=True)
    conn.row_factory = sqlite3.Row
    try:
        names = []
        for row in conn.execute("select data from LocalUsersv2"):
            raw = row["data"]
            # 老版本该列可能是 BLOB，统一解码后按 JSON 解析
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", "ignore")
            names.append(json.loads(raw).get("Name"))
    finally:
        conn.close()

    if EXPECTED_USER not in names:
        fail("%s user is missing (users=%d)" % (EXPECTED_USER, len(names)))
    return len(names)


def check_library(root):
    """校验媒体库结构：根条目、媒体库目录、/onedrive 媒体路径。"""
    library_db = root / "data/library.db"
    conn = sqlite3.connect("file:%s?mode=ro" % library_db, uri=True)
    try:
        media_items = conn.execute("select count(*) from MediaItems").fetchone()[0]

        # Id=1/2 是 Emby 固定的两个根：Media Folders(type=2) 与 root(type=1)
        root_rows = {
            row[0]: (row[1], row[2])
            for row in conn.execute(
                "select Id, Name, type from MediaItems where Id in (1, 2)")
        }
        library_folders = [
            row[0]
            for row in conn.execute(
                "select Name from MediaItems where ParentId = 1 and type = 4 order by Name")
        ]
        media_paths = [
            row[0]
            for row in conn.execute(
                """
                select Path
                from MediaItems
                where ParentId = 2
                  and type = 3
                  and Path is not null
                  and Path like ?
                order by Path
                """,
                (MEDIA_PREFIX + "%",))
        ]
    finally:
        conn.close()

    if root_rows.get(1) != ("Media Folders", 2) or root_rows.get(2) != ("root", 1):
        fail("invalid root structure: %s" % root_rows)
    if not library_folders:
        fail("no media library folders under Media Folders")
    if not media_paths:
        fail("no real %s media paths under root" % MEDIA_PREFIX)

    return media_items, len(library_folders), len(media_paths)


def main():
    if len(sys.argv) != 2:
        fail("usage: emby_guard.py <emby-data-root>")
    root = Path(sys.argv[1])

    for rel in ("data/users.db", "data/library.db"):
        if not (root / rel).is_file():
            fail("missing %s" % (root / rel))

    users = check_users(root)
    media_items, folders, paths = check_library(root)

    # 只输出计数，不输出明细
    print("Emby guard: users=%d media_items=%d folders=%d media_paths=%d ✅"
          % (users, media_items, folders, paths))


if __name__ == "__main__":
    main()
