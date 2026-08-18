#!/usr/bin/env python3
"""从目标端扫描"修复特征"文件，反推 fixed_files 记录（fallback 机制）。

marker 被删除或首次同步时，marker.sh save_sync_marker 调用本脚本扫描目标端，
识别修复机制产生的替代形态文件（zip/7z 包、API 自动生成文件名、base64URL
编码文件名/目录名），并与源端列表比对反推出 original 路径。

用法: scan_fix_signatures.py <src_remote> <dst_remote> <out_path> [timeout_s]
输出: out_path 每行一条 <original>\t<alternative>\t<method>\t<size_bytes>
"""

import sys
import re
import base64
import subprocess


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
    API_RE = re.compile(r'^file_(\d+)_(\d+)_api(\..+)?$')

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
        matched = False

        # === 特征 1: .zip / .7z 包，去掉后缀文件名在源端存在 ===
        if fname.lower().endswith('.zip') or fname.lower().endswith('.7z'):
            ext_len = 4 if fname.lower().endswith('.zip') else 3
            orig_fname = fname[:-ext_len]
            if orig_fname in src_by_basename:
                used_b64_dir = False
                matched_dir_rel = '/'.join(dir_parts)
                if dir_parts:
                    dl = b64url_decode(dir_parts[-1])
                    if dl and dl in src_dir_leaf_set:
                        used_b64_dir = True
                        nd = dir_parts[:-1] + [dl]
                        cand = '/'.join(nd + [orig_fname])
                        if cand in src_full_set:
                            matched_dir_rel = '/'.join(nd)
                zip_tag = "zip" if fname.lower().endswith('.zip') else "7z"
                dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                method = f"rclone copyto（{dp}{zip_tag} 压缩包）"
                original = f"{matched_dir_rel}/{orig_fname}" if matched_dir_rel else orig_fname
                if original in src_full_set:
                    results.append((original, path, method, size_bytes))
                    matched = True

        # === 特征 2: API 自动生成文件名 file_<ts>_<pid>_api.<ext> ===
        if not matched:
            m = API_RE.match(fname)
            if m:
                ext = m.group(3) or ''
                candidates = []
                if dir_parts:
                    dl = b64url_decode(dir_parts[-1]) if dir_parts else None
                    probe_dirs = ['/'.join(dir_parts)]
                    if dl and dl in src_dir_leaf_set:
                        probe_dirs.append('/'.join(dir_parts[:-1] + [dl]))
                    for d in probe_dirs:
                        for _, fulls in src_by_basename.items():
                            for full in fulls:
                                if full.startswith(d + '/') and full.endswith(ext):
                                    candidates.append(full)
                    if not candidates and ext:
                        for _, fulls in src_by_basename.items():
                            for full in fulls:
                                if full.endswith(ext):
                                    candidates.append(full)
                if candidates:
                    original = sorted(set(candidates))[0]
                    used_b64_dir = False
                    if dir_parts:
                        dl = b64url_decode(dir_parts[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                    dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                    method = f"OpenList API /fs/form（{dp}API 自动生成文件名）"
                    results.append((original, path, method, size_bytes))
                    matched = True

        # === 特征 3: 文件名是 base64URL，解码后出现在源端同目录同扩展名 ===
        if not matched:
            if '.' in fname:
                nb, ext = fname.rsplit('.', 1)
                decoded = b64url_decode(nb)
                if decoded:
                    orig_name = decoded + '.' + ext
                    pp = list(dir_parts)
                    used_b64_dir = False
                    if pp:
                        dl = b64url_decode(pp[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                            pp[-1] = dl
                    cand = '/'.join(pp + [orig_name]) if pp else orig_name
                    if cand in src_full_set:
                        dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                        method = f"rclone copyto（{dp}base64URL 编码文件名）"
                        results.append((cand, path, method, size_bytes))
                        matched = True
            else:
                decoded = b64url_decode(fname)
                if decoded:
                    pp = list(dir_parts)
                    used_b64_dir = False
                    if pp:
                        dl = b64url_decode(pp[-1])
                        if dl and dl in src_dir_leaf_set:
                            used_b64_dir = True
                            pp[-1] = dl
                    cand = '/'.join(pp + [decoded]) if pp else decoded
                    if cand in src_full_set:
                        dp = "base64URL 编码目录 + " if used_b64_dir else "原路径 + "
                        method = f"rclone copyto（{dp}base64URL 编码文件名）"
                        results.append((cand, path, method, size_bytes))
                        matched = True

        # === 特征 4: 只有目录最末段是 base64URL，文件名和源端相同 ===
        if not matched and dir_parts:
            dl = b64url_decode(dir_parts[-1])
            if dl and dl in src_dir_leaf_set:
                nd = dir_parts[:-1] + [dl]
                cand = '/'.join(nd + [fname])
                if cand in src_full_set:
                    method = "rclone copyto（base64URL 编码目录 + 原文件名）"
                    results.append((cand, path, method, size_bytes))

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
