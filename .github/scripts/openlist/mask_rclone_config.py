import sys
import json
import re
from pathlib import Path

# 掩码 rclone.conf 中的敏感值（::add-mask:: 防止 Actions 日志泄露）。
# 覆盖: 键名含 pass/secret 的单行键（pass, client_secret, api_secret 等）、
#       token = {...} JSON 内的 access/refresh/id_token。
# 不覆盖: 多行值（如 service_account_json 的 PEM 块）— rclone 对这类
#         配置通常引用文件路径而非内联，且 secrets.* 注入本身已被 GitHub 掩码。

def mask_config():
    conf_path = Path.home().joinpath(".config/rclone/rclone.conf")
    if not conf_path.exists():
        return
        
    text = conf_path.read_text()
    secrets = set()

    for match in re.finditer(r'(?im)^\s*([a-z0-9_]*?(?:pass|secret)[a-z0-9_]*?)\s*=\s*(.+?)\s*$', text):
        secrets.add(match.group(2).strip())

    for match in re.finditer(r'(?im)^\s*token\s*=\s*(\{.*\})\s*$', text):
        try:
            token = json.loads(match.group(1))
        except Exception:
            continue
        for key in ("access_token", "refresh_token", "id_token"):
            value = token.get(key)
            if value:
                secrets.add(str(value))

    for value in sorted(secrets, key=len, reverse=True):
        if value:
            print(f"::add-mask::{value}")

if __name__ == "__main__":
    mask_config()
