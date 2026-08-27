#!/usr/bin/env python3
"""从目标端扫描"修复特征"文件，反推 fixed_files 记录（fallback 机制）。

marker 被删除或首次同步时，marker.sh save_sync_marker 调用本脚本扫描目标端，
识别修复机制（fix.sh 方法 1-4）产生的替代形态文件，并与源端列表比对反推出
original 路径。

可识别特征（对应现行修复方法）:
  特征 1: base64URL 编码目录（文件名与源端相同）  → 方法1 目录降级变体
  特征 2: 分卷 <name>.zip.00N                     → 方法3（含 b64 目录变体）
无法反推的修复形态（不产出条目）:
  - 方法2/4 短哈希文件名（md5 前 8 位不可逆，无法关联到源端文件）
  - 方法1 原名直传（替代路径 == 原路径，本就是普通文件形态）

用法: scan_fix_signatures.py <src_remote> <dst_remote> <out_path> [timeout_s]
输出: out_path 每行一条 <original>\t<alternative>\t<method>\t<size_bytes>
"""

import sys
import re
import base64
import subprocess

SPLIT_VOL_RE = re.compile(r'^(?P<p>.+)\.zip\.(?P<n>\d{3})$')


def main():
    if len(sys.argv) < 4:
        return
    src_remote = sys.argv[1]
    dst_remote = sys.argv[2]
    out_path = sys.argv[3]
    timeout_s = int(sys.argv[4]) if len(sys.argv) > 4 else 300

    def b64url_decode(s):
        s = s.replace('-', '+').replace('_', '/')
        pad = (-len(s)) % 4
        try:
            return base64.b64decode(s + '=' * pad).decode('utf-8', errors='replace')
        except Exception:
            return None

    def rclone_lsf(remote, files_only=False, with_size=False, timeout_s=timeout_s):
        args = ["rclone", "lsf", remote, "-R"]
        if files_only:
            args.append("--files-only")
        if with_size:
            args += ["--format", "ps", "--separator", ";"]
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=timeout_s)
            return r.stdout
        except Exception:
            return ""

    src_listing = rclone_lsf(src_remote)
    src_by_basename = {}
    src_full_set = set()
    src_dir_leaf_set = set()
    for line in src_listing.splitlines():
        line = line.rstrip('/').strip()
        if not line:
            continue
        src_full_set.add(line)
        parts = line.split('/')
        for i, p in enumerate(parts):
            if i == len(parts) - 1:
                src_by_basename.setdefault(p, []).append(line)
            else:
                src_dir_leaf_set.add(p)

    dst_listing = rclone_lsf(dst_remote, files_only=True, with_size=True)

    results = []
    # 分卷分组收集: (目录, 前缀) -> {卷号: (完整路径, size)}；主循环后成组处理
    split_groups = {}

    for line in dst_listing.splitlines():
        if ';' not in line:
            continue
        path, _, s = line.rpartition(';')
        try:
            size_bytes = int(s)
        except ValueError:
            size_bytes = 0
        if not path:
            continue
        parts = path.split('/')
        fname = parts[-1]
        dir_parts = parts[:-1]

        # === 特征 2（收集阶段）: 分卷 <name>.zip.00N（方法3）===
        # 分卷文件只进分组表（成组才能数出卷数、定位首卷），跳过其余特征
        m = SPLIT_VOL_RE.match(fname)
        if m:
            key = ('/'.join(dir_parts), m.group('p'))
            split_groups.setdefault(key, {})[m.group('n')] = (path, size_bytes)
            continue

        # === 特征 1: 只有目录最末段是 base64URL，文件名和源端相同（方法1 目录降级变体）===
        if dir_parts:
            dl = b64url_decode(dir_parts[-1])
            if dl and dl in src_dir_leaf_set:
                nd = dir_parts[:-1] + [dl]
                cand = '/'.join(nd + [fname])
                if cand in src_full_set:
                    results.append((cand, path,
                                    "rclone copyto（base64URL 编码目录 + 原文件名）", size_bytes))

    # === 特征 2（成组阶段）: 分卷 <前缀>.zip.00N（方法3）===
    # 前缀即原文件名；所在目录可能是 base64URL 编码目录（方法1 目录降级变体）。
    # 方法4 的卷前缀是短哈希名，不可逆 → 不产出条目。
    for (dir_rel, prefix), vols in split_groups.items():
        if prefix not in src_by_basename:
            continue
        vol_count = len(vols)
        first_vol = min(vols)
        alt_path, _ = vols[first_vol]
        total_size = sum(sz for _, sz in vols.values())
        dir_parts = dir_rel.split('/') if dir_rel else []
        probes = [(dir_parts, False)]
        if dir_parts:
            dl = b64url_decode(dir_parts[-1])
            if dl and dl in src_dir_leaf_set:
                probes.append((dir_parts[:-1] + [dl], True))
        for d, used_b64_dir in probes:
            cand = '/'.join(d + [prefix]) if d else prefix
            if cand in src_full_set:
                dir_desc = "base64URL 编码目录" if used_b64_dir else "原路径"
                method = f"分卷 zip（{dir_desc} + 分卷切割，共 {vol_count} 卷）"
                results.append((cand, alt_path, method, total_size))
                break

    # 去重：按 original，保留 size 更大条目
    seen = {}
    for orig, alt, method, sz in results:
        if orig not in seen or sz > seen[orig][3]:
            seen[orig] = (orig, alt, method, sz)
    with open(out_path, 'w', encoding='utf-8') as f:
        for orig, (_, alt, method, sz) in seen.items():
            esc_tab = lambda s: s.replace('\t', ' ').replace('\n', ' ')
            f.write(f"{esc_tab(orig)}\t{esc_tab(alt)}\t{esc_tab(method)}\t{sz}\n")


if __name__ == "__main__":
    main()
