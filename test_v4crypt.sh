#!/bin/bash
# v4 crypt 兼容测试: 字段映射 + obscure 转换 + cryptencode 实时加密往返
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_get_openlist_token() { return 1; }   # 强制走 db 兜底
source /workspace/.github/scripts/openlist/utils.sh 2>/dev/null
source /workspace/.github/scripts/openlist/fix.sh 2>/dev/null

DB=/opt/openlist-data/data.db
mkdir -p /opt/openlist-data
unset _CRYPT_ONTHEFLY _CRYPT_MOUNT _CRYPT_PASS _CRYPT_DNE _CRYPT_REMOTE _CRYPT_FNE _CRYPT_DIAG_MOUNT
rm -f /tmp/openlist_crypt_diag.log "$DB"

mkdb() {  # $1 = addition JSON
  rm -f "$DB"
  python3 - "$DB" "$1" <<'PY'
import sqlite3, sys
db, add = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("CREATE TABLE x_storages (mount_path TEXT, addition TEXT)")
con.execute("INSERT INTO x_storages VALUES (?, ?)", ("/wopan176Crypt", add))
con.commit(); con.close()
PY
}

reset_env() {
  unset _CRYPT_ONTHEFLY _CRYPT_MOUNT _CRYPT_PASS _CRYPT_DNE _CRYPT_REMOTE _CRYPT_FNE _CRYPT_DIAG_MOUNT
  rm -f /tmp/openlist_crypt_diag.log
}

# --- 1: v4 明文密码 → 本地 obscure 化 + 7 字段输出 ---
OBSP=$(rclone obscure "my-plain-pass")
OBSS=$(rclone obscure "my-salt")
mkdb "{\"remote_path\":\"/wopan176\",\"password\":\"my-plain-pass\",\"salt\":\"my-salt\",\"filename_encryption\":\"standard\",\"directory_name_encryption\":true,\"filename_encoding\":\"base64\",\"encrypted_suffix\":\".bin\"}"
reset_env
out=$(_get_crypt_config "/wopan176Crypt" 2>/dev/null)
read -r p1 p2 fne dne enc suf rem <<< "$out"
[ "$(rclone reveal "$p1" 2>/dev/null)" = "my-plain-pass" ] && ok "1a v4 明文密码被 obscure 化" || bad "1a: reveal=[$(rclone reveal "$p1" 2>/dev/null)]"
[ "$(rclone reveal "$p2" 2>/dev/null)" = "my-salt" ] && ok "1b salt→password2 obscure 化" || bad "1b"
[ "$fne" = "standard" ] && [ "$dne" = "true" ] && [ "$enc" = "base64" ] && [ "$suf" = ".bin" ] && [ "$rem" = "openlist:wopan176" ] \
  && ok "1c 7 字段映射正确" || bad "1c: [$out]"

# --- 2: v4 ___Obfuscated___ 前缀（真实存储形态）→ 剥前缀直接用 ---
mkdb "{\"remote_path\":\"/wopan176\",\"password\":\"___Obfuscated___${OBSP}\",\"salt\":\"___Obfuscated___${OBSS}\",\"filename_encryption\":\"standard\",\"directory_name_encryption\":true,\"filename_encoding\":\"base64\",\"encrypted_suffix\":\".bin\"}"
reset_env
out=$(_get_crypt_config "/wopan176Crypt" 2>/dev/null)
read -r p1 p2 _ <<< "$out"
[ "$p1" = "$OBSP" ] && [ "$p2" = "$OBSS" ] && ok "2 剥 Obfuscated 前缀直接用（不再二次转换）" || bad "2: p1=[$p1] 期望=[$OBSP]"

# --- 3: _ensure_crypt_config → on-the-fly 含全部 v4 参数 ---
reset_env
_ensure_crypt_config "openlist:wopan176Crypt/backup" 2>/dev/null \
  && echo "$_CRYPT_ONTHEFLY" | grep -q 'filename_encoding=base64' \
  && echo "$_CRYPT_ONTHEFLY" | grep -q 'suffix=".bin"' \
  && echo "$_CRYPT_ONTHEFLY" | grep -q 'password2=' \
  && ok "3 on-the-fly 含 password2/filename_encoding/suffix" || bad "3: [$_CRYPT_ONTHEFLY]"

# --- 4: v3 回归 → on-the-fly 不含 v4 参数 ---
OBV3=$(rclone obscure "v3pass")
mkdb "{\"path\":\"/wopan176\",\"password\":\"${OBV3}\",\"filename_encryption\":\"standard\",\"directory_name_encryption\":true}"
reset_env
_ensure_crypt_config "openlist:wopan176Crypt/backup" 2>/dev/null \
  && ! echo "$_CRYPT_ONTHEFLY" | grep -qE 'password2=|filename_encoding|suffix=' \
  && ok "4 v3 回归: on-the-fly 无 v4 参数" || bad "4: [$_CRYPT_ONTHEFLY]"

# --- 5: cryptencode 实时加密目录名 + 往返解密（v4 配置）---
mkdb "{\"remote_path\":\"/wopan176\",\"password\":\"my-plain-pass\",\"salt\":\"my-salt\",\"filename_encryption\":\"standard\",\"directory_name_encryption\":true,\"filename_encoding\":\"base64\",\"encrypted_suffix\":\".bin\"}"
reset_env
_ensure_crypt_config "openlist:wopan176Crypt/backup" 2>/dev/null || bad "5 ensure 失败"
enc_name=$(rclone cryptencode -- "$_CRYPT_ONTHEFLY" backup 2>/tmp/cryptencode_err.txt)
if [ -z "$enc_name" ] || grep -q . /tmp/cryptencode_err.txt 2>/dev/null; then
  bad "5a cryptencode 失败: $(cat /tmp/cryptencode_err.txt)"
else
  case "$enc_name" in
    *.bin) bad "5a 目录名不应带 .bin 后缀（suffix 只加在文件上）: [$enc_name]" ;;
    *) ok "5a cryptencode 目录名成功: ${enc_name:0:16}..." ;;
  esac
fi
dec_name=$(rclone cryptdecode -- "$_CRYPT_ONTHEFLY" "$enc_name" 2>/dev/null)
[ "$dec_name" = "backup" ] && ok "5b cryptdecode 往返一致" || bad "5b: [$dec_name]"

# --- 6: nonce 随机性: 同名两次加密密文不同（证明不能"预算一次硬编码"）---
enc2=$(rclone cryptencode -- "$_CRYPT_ONTHEFLY" backup 2>/dev/null)
[ -n "$enc2" ] && [ "$enc2" != "$enc_name" ] && ok "6 同名两次密文不同（nonce 随机）" || bad "6: [$enc2] vs [$enc_name]"

# --- 7: 密文形态 = base64 字母表（+,/ 或 -,_ URL 变体），非 base32 ---
case "$enc_name" in
  *[A-Z2-7]*|*[=]*)
    # base32 是大写字母+数字2-7; 若只含这些 → 可能是 base32（错口径）
    if ! printf '%s' "$enc_name" | grep -qE '[a-z+/-]'; then
      bad "7 密文疑似 base32 字母表（encoding 未生效）: [$enc_name]"
    else
      ok "7 密文含 base64 字母表特征"
    fi ;;
  *) ok "7 密文含 base64 字母表特征" ;;
esac

# --- 8: 错误密码 → 解不开（证明密码是必要条件）---
bad_otf=":crypt,remote=\"openlist:wopan176\",filename_encryption=standard,directory_name_encryption=true,password=\"$(rclone obscure wrong-pass)\",filename_encoding=base64:"
dec_wrong=$(rclone cryptdecode -- "$bad_otf" "$enc_name" 2>/dev/null)
[ "$dec_wrong" != "backup" ] && ok "8 错密码解不开（密钥必要）" || bad "8: 竟然解开了 [$dec_wrong]"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$DB" /tmp/cryptencode_err.txt
[ $FAIL -eq 0 ]
