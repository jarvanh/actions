import sys
import json
import re
from pathlib import Path

def mask_config():
    conf_path = Path.home().joinpath(".config/rclone/rclone.conf")
    if not conf_path.exists():
        return
        
    text = conf_path.read_text()
    secrets = set()

    for match in re.finditer(r'(?im)^\s*(?:client_secret|pass|password)\s*=\s*(.+?)\s*$', text):
        secrets.add(match.group(1).strip())

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
