#!/usr/bin/env python3
"""清理 yt-dlp 输出的文件名。

用法: python3 clean_ytdlp_filename.py <原始文件名> [可选: 原始URL]
输出: 清理后的文件名（仅当需要清理时才不同）
"""
import sys
import re
import os
import time
import unicodedata

if len(sys.argv) < 2:
    print("")
    sys.exit(0)

filename = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else ""

s = filename.lstrip("\ufeff")
s = re.sub(r"[\x00-\x1f\x7f]", "", s)
s = s.strip(" ")
s = unicodedata.normalize("NFC", s)

base, ext = os.path.splitext(s)
if not base or len(base) < 3:
    m = re.search(r"ph[a-f0-9]+", filename)
    if m:
        s = "video-%s%s" % (m.group(0), ext)
    else:
        s = "video-%d%s" % (int(time.time()), ext)

print(s)
