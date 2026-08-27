# 修复方式 → 还原元数据（kind/summary/steps/script）分类程序
# 由 sync.sh _sync_serialize_fixed_files 以 jq -R -s --arg sp <src> --arg dp <dst> -f 调用
# 输入: fix_list 原始文本（| 分隔，每行 original|alternative|method|restore_hint|size_human|size_bytes|method_id）
# 输出: fixed_files JSON 数组
def restore_info($orig; $alt; $method; $src; $dst):
  # 现行 4 种修复方式精确识别（文案来源: fix.sh _fix_succeed 各调用点）:
  #   "rclone copyto（原路径 + 原文件名）"             → copy，alt==orig 无需还原 (方法1)
  #   "rclone copyto（base64URL 编码目录 + 原文件名）"  → base64url_dir (方法1 目录降级变体)
  #   "rclone copyto（[base64URL 编码目录 + ]短哈希文件名 <hash>）" → short_hash_rename (方法2)
  #   "分卷 zip（[base64URL 编码目录 + ][短哈希文件名 + ]<粒度> 分卷切割，共 N 卷）"
  #                                                   → split_zip (方法3 原名 / 方法4 短哈希)
  # 注: 分卷分支必须排在短哈希之前——方法4 的方法文本同时含"分卷切割"和
  #     "短哈希文件名"两个子串，先命中短哈希会把打包类误判成改名类
  # 注: 不能用 ".*文件名" 模糊匹配，"原文件名" 里也有 "文件名" 3 个字，会误判
  # 语法: jq 对象值不能裸用 + 拼接（{a: "x" + "y"} 非法），script 值必须括号包裹
  ($method | test("分卷切割")) as $has_split_zip
  | ($method | test("短哈希文件名")) as $has_short_hash
  | ($method | test("base64URL 编码目录 ")) as $has_b64_dir
  | ($orig | split("/") | .[-1]) as $orig_name
  | if   $has_split_zip then {kind:"split_zip",
      summary: "zip 打包后切割为分卷上传（粒度见方法文本，OPENLIST_SPLIT_PART_BYTES 可调），替代名为原名（方法3）或短哈希名（方法4）",
      steps: ["下载所有分卷到同一目录", "按顺序合并: cat *.0* > merged.zip", "执行: 7z x merged.zip -o<output_dir>（或 unzip merged.zip）"],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_DIR=$(dirname \"$ALT\")\nALT_FNAME=$(basename \"$ALT\")\nSPLIT_FULL=\"${ALT_FNAME%.*}\"\necho \"分卷前缀: $SPLIT_FULL\"\nrclone copy \"${DST}/${ALT_DIR}\" \"$TMP\" --include \"${SPLIT_FULL}.*\" --progress 2>&1 | tail -5\ncd \"$TMP\"\ncat ${SPLIT_FULL}.0* > merged.zip\necho \"合并后 zip 大小: $(stat -c%s merged.zip 2>/dev/null || stat -f%z merged.zip 2>/dev/null) bytes\"\n7z x merged.zip -o\"$TMP/out\" -y || unzip merged.zip -d \"$TMP/out\"\nls -la \"$TMP/out/\"\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\nrm -rf \"$TMP\"")}
    elif $has_short_hash then {kind:"short_hash_rename",
      summary: "文件名替换为 8 位 md5 前缀（规避密文名超长），内容未变",
      steps:   ["下载目标端 " + $alt, "重命名为原文件名: " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_b64_dir then {kind:"base64url_dir",
      summary: "最末一层目录名做了 base64URL 编码，文件名保持原样",
      steps:   ["取目录最末层路径段 → base64URL 解码即得原目录名", "文件名无需改动"],
      script:  ("set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/\\/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    else {kind:"copy",
      summary: "文件按原路径原文件名直接 copyto，无需还原处理",
      steps:   ["目标端路径与源端相同，直接使用即可"],
      script:  ("# 路径未变化，无需还原\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\n# 如需取回: rclone copyto \"${DST}/${ALT}\" ./local_copy")}
    end;
split("\n") | map(select(length > 0)) | map(
  split("|") as $f
  | {
      original:    $f[0],
      alternative: $f[1],
      method:      $f[2],
      restore_hint: $f[3],
      size_human:  $f[4],
      size_bytes:  ($f[5] // "0" | tonumber),
      method_id:   ($f[6] // "")
    }
  | . + {restore: (restore_info(.original; .alternative; .method; $sp; $dp) + {hint: .restore_hint})}
)
