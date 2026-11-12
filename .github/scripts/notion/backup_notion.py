#!/usr/bin/env python3
"""Back up every Notion workspace root with the internal exportBlock API.

This script is intended for GitHub Actions. It reads the Notion browser
cookies from a JSON file (normally synced from Dropbox), exports each root
page recursively, verifies the ZIP, and uploads fixed-name files to an
rclone remote. Fixed names let the remote's version history keep old copies
without accumulating daily filenames.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import requests

API_BASE = "https://www.notion.so/api/v3"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:139.0) "
    "Gecko/20100101 Firefox/139.0"
)
LOG = logging.getLogger("notion-backup")


def unwrap_record(record: dict[str, Any]) -> dict[str, Any]:
    value = record.get("value") or {}
    nested = value.get("value")
    if isinstance(nested, dict) and nested.get("type"):
        return nested
    return value


def plain_title(properties: dict[str, Any]) -> str:
    title = properties.get("title") or []
    if isinstance(title, list):
        parts: list[str] = []
        for item in title:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, list):
                for sub in item:
                    if isinstance(sub, str):
                        parts.append(sub)
                    elif isinstance(sub, dict):
                        parts.append(sub.get("plain_text", ""))
            elif isinstance(item, dict):
                parts.append(item.get("plain_text", ""))
        return "".join(parts).strip()
    return str(title).strip()


def safe_name(value: str) -> str:
    value = re.sub(r"[\\/:*?\"<>|]+", "-", value).strip(" .-")
    return value or "untitled"


@dataclass
class RootPage:
    block_id: str
    space_id: str
    title: str


class NotionExportClient:
    def __init__(
        self,
        token_v2: str,
        file_token: str,
        time_zone: str,
        max_wait: int,
        poll_interval: int,
        download_timeout: int,
    ) -> None:
        self.token_v2 = token_v2
        self.file_token = file_token
        self.time_zone = time_zone
        self.max_wait = max_wait
        self.poll_interval = max(poll_interval, 5)
        self.download_timeout = download_timeout
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Cookie": f"token_v2={token_v2}; file_token={file_token}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
                "Origin": "https://www.notion.so",
                "Referer": "https://www.notion.so/",
            }
        )

    def post(self, endpoint: str, payload: dict[str, Any]) -> dict[str, Any]:
        url = f"{API_BASE}/{endpoint}"
        last_error: Exception | None = None
        for attempt in range(4):
            try:
                response = self.session.post(url, json=payload, timeout=60)
                if response.status_code == 429:
                    wait = int(response.headers.get("Retry-After", "20"))
                    LOG.warning("Rate limited by Notion, sleeping %ss", wait)
                    time.sleep(wait)
                    continue
                response.raise_for_status()
                return response.json()
            except Exception as error:  # noqa: BLE001
                last_error = error
                if attempt < 3:
                    time.sleep(5 * (attempt + 1))
        raise RuntimeError(f"Notion API call failed: {endpoint}: {last_error}")

    def load_roots(self) -> list[RootPage]:
        data = self.post("loadUserContent", {})
        blocks = ((data.get("recordMap") or {}).get("block") or {})
        roots: list[RootPage] = []
        seen: set[tuple[str, str]] = set()
        for block_id, record in blocks.items():
            value = unwrap_record(record)
            if (
                value.get("type") != "page"
                or value.get("parent_table") != "space"
                or value.get("alive") is False
            ):
                continue
            space_id = value.get("parent_id")
            if not space_id:
                continue
            key = (space_id, block_id)
            if key in seen:
                continue
            seen.add(key)
            roots.append(
                RootPage(
                    block_id=block_id,
                    space_id=space_id,
                    title=plain_title(value.get("properties") or {}) or block_id[:8],
                )
            )
        roots.sort(key=lambda item: (item.title.lower(), item.block_id))
        return roots

    def enqueue(self, root: RootPage) -> str:
        body = {
            "block": {"id": root.block_id, "spaceId": root.space_id},
            "recursive": True,
            "shouldExportComments": True,
            "exportOptions": {
                "exportType": "markdown",
                "timeZone": self.time_zone,
                "locale": "en",
                "collectionViewExportType": "currentView",
                "flattenExportFiletree": False,
            },
        }
        response = self.post("enqueueExportBlock", body)
        output_key = response.get("outputKey") or response.get("taskId")
        if not output_key:
            raise RuntimeError(f"No outputKey for root {root.title}")
        return str(output_key)

    def wait_for_url(self, root: RootPage, output_key: str) -> str:
        deadline = time.monotonic() + self.max_wait
        last_count: int | None = None
        while time.monotonic() < deadline:
            payload = {
                "requests": [
                    {
                        "pointer": {
                            "table": "task_output",
                            "id": output_key,
                            "spaceId": root.space_id,
                        },
                        "version": -1,
                    }
                ],
                "spacePointer": {"table": "space", "id": root.space_id},
            }
            response = self.post("syncRecordValuesMain", payload)
            record = (
                ((response.get("recordMap") or {}).get("task_output") or {})
                .get(output_key, {})
            )
            wrapper = record.get("value") or {}
            body = wrapper.get("value") if isinstance(wrapper.get("value"), dict) else wrapper
            value = body.get("value") or {}
            lifecycle = body.get("lifecycle") or body.get("state")
            count = value.get("exportedCount")
            url = value.get("exportURL") or value.get("exportUrl") or body.get("exportURL")
            if count != last_count:
                LOG.info(
                    "Exporting %s: lifecycle=%s exported=%s",
                    root.title,
                    lifecycle,
                    count,
                )
                last_count = count
            if lifecycle == "success" and url:
                return str(url)
            if lifecycle in {"failure", "failed", "error"}:
                raise RuntimeError(f"Export failed for {root.title}: {body.get('error')}")
            time.sleep(self.poll_interval)
        raise TimeoutError(f"Export timed out for {root.title}")

    def download(self, url: str, destination: Path) -> None:
        with self.session.get(
            url,
            stream=True,
            timeout=self.download_timeout,
        ) as response:
            response.raise_for_status()
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        handle.write(chunk)

    @staticmethod
    def verify(path: Path) -> tuple[int, str]:
        with zipfile.ZipFile(path) as archive:
            bad = archive.testzip()
            if bad is not None:
                raise RuntimeError(f"Corrupt ZIP entry: {bad}")
            names = archive.namelist()
            if not names:
                raise RuntimeError("ZIP archive is empty")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return len(names), digest.hexdigest()


def upload(local: Path, remote: str, remote_name: str) -> None:
    target = f"{remote.rstrip('/')}/{remote_name}"
    subprocess.run(
        ["rclone", "copyto", str(local), target],
        check=True,
    )
    LOG.info("Uploaded %s -> %s", local.name, target)


def main() -> int:
    parser = argparse.ArgumentParser(description="Back up Notion workspace roots")
    parser.add_argument("--cookies", required=True, help="Path to notion-cookies.json")
    parser.add_argument("--remote", default="onedrive:notion-backups")
    parser.add_argument("--root", action="append", default=None)
    parser.add_argument("--time-zone", default="Asia/Shanghai")
    parser.add_argument("--max-wait", type=int, default=7200)
    parser.add_argument("--poll-interval", type=int, default=15)
    parser.add_argument("--download-timeout", type=int, default=1800)
    parser.add_argument("--no-upload", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )

    cookie_path = Path(args.cookies)
    if not cookie_path.exists():
        LOG.error("Cookie file not found: %s", cookie_path)
        return 2
    cookie_data = json.loads(cookie_path.read_text())
    for key in ("token_v2", "file_token"):
        if not cookie_data.get(key):
            LOG.error("Missing %s in %s", key, cookie_path)
            return 2

    free = shutil.disk_usage("/tmp").free
    if free < 12 * 1024**3:
        LOG.error("Not enough free space in /tmp: %.2f GiB", free / 1024**3)
        return 2

    client = NotionExportClient(
        cookie_data["token_v2"],
        cookie_data["file_token"],
        args.time_zone,
        args.max_wait,
        args.poll_interval,
        args.download_timeout,
    )
    roots = client.load_roots()
    if args.root:
        wanted = {value.lower() for value in args.root}
        roots = [
            root
            for root in roots
            if root.title.lower() in wanted or root.block_id in wanted
        ]
    if not roots:
        LOG.error("No workspace root pages found")
        return 3

    LOG.info(
        "Found %d root page(s): %s",
        len(roots),
        ", ".join(f"{root.title}({root.space_id[:8]})" for root in roots),
    )

    manifest: list[dict[str, Any]] = []
    failures = 0
    for root in roots:
        try:
            LOG.info("Starting export for %s (%s)", root.title, root.block_id)
            output_key = client.enqueue(root)
            url = client.wait_for_url(root, output_key)
            remote_name = f"notion-export-{safe_name(root.title)}-latest.zip"
            with tempfile.TemporaryDirectory(prefix="notion-backup-") as temp_dir:
                path = Path(temp_dir) / remote_name
                LOG.info("Downloading %s", remote_name)
                client.download(url, path)
                entries, digest = client.verify(path)
                size = path.stat().st_size
                LOG.info(
                    "Verified %s: %d entries, %.2f GiB, sha256=%s",
                    remote_name,
                    entries,
                    size / 1024**3,
                    digest,
                )
                if not args.no_upload:
                    upload(path, args.remote, remote_name)
                manifest.append(
                    {
                        "root": root.title,
                        "block_id": root.block_id,
                        "space_id": root.space_id,
                        "file": remote_name,
                        "size": size,
                        "entries": entries,
                        "sha256": digest,
                    }
                )
        except Exception as error:  # noqa: BLE001
            failures += 1
            LOG.exception("Backup failed for %s: %s", root.title, error)

    manifest_path = Path("/tmp/notion-backup-manifest.json")
    manifest_path.write_text(
        json.dumps(
            {
                "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "remote": args.remote,
                "roots": manifest,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    if not args.no_upload:
        upload(manifest_path, args.remote, "notion-backup-manifest.json")

    if failures:
        LOG.error("%d root page(s) failed", failures)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
