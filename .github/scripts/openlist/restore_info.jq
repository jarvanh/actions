# 修复方式 → 还原元数据（kind/summary/steps/script）分类程序
# 由 sync.sh _sync_serialize_fixed_files 以 jq -R -s --arg sp <src> --arg dp <dst> -f 调用
# 输入: fix_list 原始文本（| 分隔，每行 original|alternative|method|restore_hint|size_human|size_bytes|method_id）
# 输出: fixed_files JSON 数组
def restore_info($orig; $alt; $method; $src; $dst):
  # 现行 11 种修复方式精确识别（方法 1-11，与 fix.sh _method_desc 对齐）：
  #   "原路径 + 原文件名"                             → 原样 copy (方法1)
  #   "base64URL 编码目录 + 原文件名"                → 仅 b64 目录 (方法1变体)
  #   "rclone crypt 直写（原名原路径）"              → copy，alt==orig 无需还原 (方法2)
  #   "原路径 + 短哈希文件名"                        → short hash rename (方法3)
  #   "原路径 + zip 压缩包"                          → zip (方法4)
  #   "base64URL 编码目录 + zip 压缩包"              → zip(+b64dir) (方法4变体)
  #   "原路径 + 7z 压缩包"                           → 7z (方法5)
  #   "base64URL 编码目录 + 7z 压缩包"               → 7z(+b64dir) (方法5变体)
  #   "原路径 + <粒度> 分卷切割"                     → split zip (方法6)
  #   "原路径 + base64URL 编码文件名 + <粒度> 分卷切割" → split zip + b64name (方法7)
  #   "base64URL 编码目录 + [b64文件名 +] <粒度> 分卷切割" → split zip 变体 (方法6/7变体)
  #   "原路径 + API 自动生成文件名"                  → api rename (方法8)
  #   "base64URL 编码目录 + API 自动生成文件名"      → api rename(+b64dir) (方法8变体)
  #   "父目录 + 编码原始目录名的文件名"              → parent dir (方法9)
  #   "AES256 加密 zip + .enc.zip 扩展名"             → encrypted zip (方法10)
  #   "临时目录上传 + OpenList API move"             → tmp + move (方法11)
  # 分卷粒度默认 1GB（OPENLIST_SPLIT_PART_BYTES 可调），方法文本携带实际粒度
  # 已删除方法（b64 文件名单传 / .bak / 根目录上传 / base64 内容）的分类分支
  # 仅为兼容旧 marker 残留条目与 fallback 扫描输出保留
  # 注: 不能用 ".*文件名" 模糊匹配，"原文件名" 里也有 "文件名" 3 个字，会误判
  # 注: 分卷分支必须排在 b64 目录/文件名分支之前——分卷文本同时含
  #     "base64URL 编码目录/文件名" 子串，先命中 b64 分支会被误判为改名类
  # 语法: jq 对象值不能裸用 + 拼接（{a: "x" + "y"} 非法），script 值必须括号包裹
  ($method | test("base64URL 编码目录 ")) as $has_b64_dir
  | ($method | test("base64URL 编码文件名")) as $has_b64_name
  | ($method | test("zip 压缩包")) as $has_zip
  | ($method | test("7z 压缩包")) as $has_7z
  | ($method | test("API 自动生成文件名")) as $has_api
  | ($method | test("重命名 .bak")) as $has_bak
  | ($method | test("父目录")) as $has_parent
  | ($method | test("base64 编码文件内容")) as $has_b64_content
  | ($method | test("AES256 加密 zip")) as $has_enc_zip
  | ($method | test("临时目录上传")) as $has_tmp_move
  | ($method | test("短哈希文件名")) as $has_short_hash
  | ($method | test("分卷切割") and ($method | test("base64URL 编码文件名") | not)) as $has_split_zip
  | ($method | test("分卷切割") and ($method | test("base64URL 编码文件名"))) as $has_split_zip_b64name
  # 原目录部分（去掉文件名）和文件名
  | ([$orig | split("/") | .[0:-1] | join("/"), $orig | split("/") | .[-1]]) as [$orig_dir, $orig_name]
  | ([$alt  | split("/") | .[0:-1] | join("/"), $alt  | split("/") | .[-1]]) as [$alt_dir,  $alt_name]
  | if   $has_zip      then {kind:"zip",
      summary: "文件被打包为 .zip（存储模式 mx=0）",
      steps:   ["下载目标端 " + $alt, "执行: 7z x <alt_zip> -o<output_dir>（或 unzip）", "解压后得到 " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.zip\" --progress\n7z x \"$TMP/package.zip\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/out/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_7z       then {kind:"seven_zip",
      summary: "文件被打包为 .7z（存储模式 mx=0）",
      steps:   ["下载目标端 " + $alt, "执行: 7z x <alt_7z> -o<output_dir>", "解压后得到 " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.7z\" --progress\n7z x \"$TMP/package.7z\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/out/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_short_hash then {kind:"short_hash_rename",
      summary: "文件名替换为 8 位 md5 前缀（规避密文名超长），内容未变",
      steps:   ["下载目标端 " + $alt, "重命名为原文件名: " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_api      then {kind:"api_rename",
      summary: "文件名被 OpenList API 自动改写（前缀 file_<ts>_<pid>_api，扩展名保留）",
      steps:   ["下载目标端 " + $alt, "根据内容哈希对比或直接重命名为: " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_FNAME=\"" + $alt_name + "\"\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 已直接保存为原始文件名。内容校验可用: rclone hashsum SHA1 \"${SRC}/${ORIG}\" 与 sha1sum \"$TMP/${ORIG_FNAME}\" 对比\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_split_zip_b64name then {kind:"split_zip_b64name",
      summary: "文件名 base64URL 编码后，zip 打包并切割为分卷上传（粒度默认 1GB，OPENLIST_SPLIT_PART_BYTES 可调），分卷命名 <encoded>.zip.001/.002/...",
      steps: ["下载所有 .zip.0* 分卷到同一目录", "按顺序合并: cat *.zip.0* > merged.zip", "解压 merged.zip 得到原始内容文件", "文件名还原：对编码文件名的 base64URL 前缀部分解码"],
      script:  ("set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_DIR=$(dirname \"$ALT\")\nALT_FNAME=$(basename \"$ALT\")\nSPLIT_FULL_PREFIX=\"${ALT_FNAME%.*}\"\nENCODED_BASE=\"${SPLIT_FULL_PREFIX%.zip}\"\n[ -z \"$ENCODED_BASE\" ] && ENCODED_BASE=\"${SPLIT_FULL_PREFIX}\"\nif [[ \"$ENCODED_BASE\" == *.* ]]; then\n  NAME_EXT=\"${ENCODED_BASE##*.}\"\n  NAME_NOEXT=\"${ENCODED_BASE%.*}\"\n  DECODED_NOEXT=$(b64url_decode \"$NAME_NOEXT\")\n  DECODED_FNAME=\"${DECODED_NOEXT}.${NAME_EXT}\"\nelse\n  DECODED_FNAME=$(b64url_decode \"$ENCODED_BASE\")\nfi\necho \"还原文件名: $ENCODED_BASE -> $DECODED_FNAME\"\nrclone copy \"${DST}/${ALT_DIR}\" \"$TMP\" --include \"${SPLIT_FULL_PREFIX}.*\" --progress 2>&1 | tail -5\ncd \"$TMP\"\ncat ${SPLIT_FULL_PREFIX}.0* > merged.zip 2>/dev/null || ( ls *.zip.0* >/dev/null 2>&1 && cat *.zip.0* > merged.zip )\necho \"合并后 zip 大小: $(stat -c%s merged.zip 2>/dev/null || stat -f%z merged.zip 2>/dev/null) bytes\"\n7z x merged.zip -o\"$TMP/out\" -y || unzip merged.zip -d \"$TMP/out\"\nls -la \"$TMP/out/\"\nrm -rf \"$TMP\"")}
    elif $has_split_zip then {kind:"split_zip",
      summary: "文件被打包为 zip（存储模式 mx=0）并切割为分卷上传（粒度默认 1GB，OPENLIST_SPLIT_PART_BYTES 可调），分卷命名 <name>.zip.001/.002/...",
      steps: ["下载所有 .zip.0* 分卷到同一目录", "按顺序合并: cat *.zip.0* > merged.zip", "执行: 7z x merged.zip -o<output_dir>（或 unzip merged.zip）"],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_DIR=$(dirname \"$ALT\")\nALT_FNAME=$(basename \"$ALT\")\nSPLIT_PREFIX=\"${ALT_FNAME%.*}\"\necho \"分卷前缀: $SPLIT_PREFIX\"\nrclone copy \"${DST}/${ALT_DIR}\" \"$TMP\" --include \"${SPLIT_PREFIX}.zip.*\" --progress 2>&1 | tail -5\ncd \"$TMP\"\ncat ${SPLIT_PREFIX}.zip.0* > merged.zip\necho \"合并后 zip 大小: $(stat -c%s merged.zip 2>/dev/null || stat -f%z merged.zip 2>/dev/null) bytes\"\n7z x merged.zip -o\"$TMP/out\" -y || unzip merged.zip -d \"$TMP/out\"\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\nrm -rf \"$TMP\"")}
    elif ($has_b64_dir and $has_b64_name) then {kind:"base64url_both",
      summary: "目录最末一层和文件名均做了 base64URL 编码",
      steps:   ["取目录最末层路径段 → base64URL 解码得到原目录名", "取文件名（扩展名前部分） → base64URL 解码得到原文件名"],
      script:  ("set -euo pipefail\n# base64URL 解码工具: base64 -d 时要把 -_ 替换为 +/ 并补齐 = 填充\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\n# 把 ALT 路径按 / 分段，dir 末段和文件名做 base64URL 解码即可还原 ORIG 路径\n# 脚本给出示例：下载后按原名保存\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_b64_dir then {kind:"base64url_dir",
      summary: "最末一层目录名做了 base64URL 编码，文件名保持原样",
      steps:   ["取目录最末层路径段 → base64URL 解码即得原目录名", "文件名无需改动"],
      script:  ("set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_b64_name then {kind:"base64url_name",
      summary: "文件名（不含扩展名部分）做了 base64URL 编码，目录保持原样",
      steps:   ["取文件名扩展名前部分 → base64URL 解码得到原文件名", "目录名无需改动"],
      script:  ("set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_b64_content then {kind:"base64_content",
      summary: "文件内容被 base64 编码后上传，完全改变了 hash 和内容特征",
      steps:   ["下载目标端 " + $alt, "执行: base64 -d <alt_file> > <orig_file>", "解码后得到原始文件 " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/encoded.b64\" --progress\nbase64 -d \"$TMP/encoded.b64\" > \"$TMP/" + $orig_name + "\"\n# 还原后的源文件在: $TMP/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_enc_zip   then {kind:"encrypted_zip",
      summary: "文件被 AES256 加密 zip 打包后上传，改变了二进制特征",
      steps:   ["下载目标端 " + $alt, "执行: 7z x -p<password> <enc_zip> -o<output_dir>", "解压后得到 " + $orig_name],
      script:  ("set -euo pipefail\n# 密码在修复时的 restore_hint 中记录\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.enc.zip\" --progress\n# 密码格式: OpenList<timestamp>，从 restore_hint 中获取\n7z x -p\"OpenList<password>\" \"$TMP/package.enc.zip\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\nrm -rf \"$TMP\"")}
    elif $has_bak       then {kind:"rename_bak",
      summary: "文件被重命名为 .bak 后缀后上传",
      steps:   ["下载目标端 " + $alt, "重命名为原始文件名: " + $orig_name],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 文件已恢复原始文件名\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_parent    then {kind:"parent_dir",
      summary: "文件上传到父目录（跳过有问题的子目录），文件名编码了原始目录信息",
      steps:   ["下载目标端 " + $alt, "从文件名 __fixed__<base64>__<filename> 中解码原始目录名", "移动到正确的目录路径"],
      script:  ("set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\"")}
    elif $has_tmp_move  then {kind:"tmp_move",
      summary: "文件上传到临时目录后用 OpenList API move 移动（可能已移动或保留在临时目录）",
      steps:   ["检查目标路径是否已有原文件", "如未移动，用 OpenList API move 从临时目录移动"],
      script:  ("set -euo pipefail\n# 检查目标是否已存在\nrclone lsjson \u0027" + $dst + "/" + $orig + "\u0027 --max-depth 1 2>/dev/null | jq \u0027length\u0027\n# 如不存在，用 OpenList API move\n# curl -X POST http://127.0.0.1:5244/api/fs/move -H \u0027Authorization: <token>\u0027 -d \u0027{\"src_dir\":\"/wopan176Crypt/backup/" + $alt + "\",\"dst_dir\":\"/wopan176Crypt/backup/" + $orig + "\"}\u0027")}
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
