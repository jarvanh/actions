#!/usr/bin/env bash
# 验证 create-clirelay-archive.sh 的 pg_dump 失败保护：
#   Bug: 直接重定向到 clirelay-latest.sql，shell 在 pg_dump 启动前就截断旧 SQL，
#        失败时磁盘上留半截 dump，旧的好 SQL 已毁，日志却说「保留旧 SQL 继续」。
# 从真实 openclaw.yml 抽取脚本块注入 mock，按四种 pg_dump 形态跑真脚本。
set -uo pipefail
WF=/workspace/.github/workflows/openclaw.yml
WORK=/tmp/cr_dump_test
PASS=0; FAIL=0
ok()   { echo "  ok   $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

rm -rf "$WORK"; mkdir -p "$WORK"

awk '/^          cat > \/tmp\/create-clirelay-archive\.sh <<.EOF.$/{f=1;next} \
     f && /^          EOF$/{f=0} f' "$WF" \
  | sed 's/^          //' > "$WORK/create-clirelay-archive.sh"
if [ ! -s "$WORK/create-clirelay-archive.sh" ]; then
  echo "EXTRACT_FAIL"; exit 1
fi
if ! bash -n "$WORK/create-clirelay-archive.sh"; then
  echo "SYNTAX_FAIL"; exit 1
fi
echo "抽取脚本 $(wc -l < "$WORK/create-clirelay-archive.sh") 行，语法 OK"

mk_env() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root/src/auths" "$root/src/sql" "$root/bin"
  printf 'SELECT 1;\n' > "$root/src/auths/token.json"
  printf 'compose: x\n'   > "$root/src/docker-compose.yml"
  printf 'CLIRELAY_X=1\n' > "$root/src/.env"
  printf 'config: y\n'    > "$root/src/config.yaml"
  # 一份「上一轮的好 SQL」（>200B，过脚本的小输出阈值）
  {
    printf -- '-- GOOD FULL DUMP FROM PREVIOUS ROUND --\n'
    printf 'CREATE TABLE t(a int);\n'
    for i in $(seq 1 20); do printf 'INSERT INTO t VALUES (%s);\n' "$i"; done
  } > "$root/src/sql/clirelay-latest.sql"
  cat > "$root/bin/docker" <<'EOS'
#!/usr/bin/env bash
mode="$(cat "$DUMP_STATE/dump_mode" 2>/dev/null || echo good)"
case "$mode" in
  good)      cat "$DUMP_STATE/good.sql" ;;
  partial)   printf -- '-- PARTIAL\nCREATE TABLE broken(' ; exit 1 ;;
  fail)      echo "pg_dump: error" >&2 ; exit 1 ;;
  tiny)      printf -- '-- EMPTY DB --\n' ;;
esac
EOS
  chmod +x "$root/bin/docker"
  # 本轮 dump（>200B 且让整包 >5KB 门槛，否则走不到体积校验）
  {
    printf -- '-- FRESH GOOD DUMP THIS ROUND --\n'
    printf 'CREATE TABLE t(a int);\nCREATE TABLE u(b int);\n'
    for i in $(seq 1 40); do printf 'INSERT INTO u VALUES (%s, %s);\n' "$i" "$((i * 7))"; done
    head -c 6000 /dev/zero | tr '\0' '-'
    printf '\n'
  } > "$root/good.sql"
}

run_case() {
  local name="$1" mode="$2" root="$WORK/$1"
  mk_env "$root"
  echo "$mode" > "$root/dump_mode"
  sed -e "s#^SRC_DIR=\"/tmp/local_CliRelay\"#SRC_DIR=\"$root/src\"#" \
      -e "s#^COMPOSE=\"docker #COMPOSE=\"$root/bin/docker #" \
      "$WORK/create-clirelay-archive.sh" > "$root/script.sh"
  chmod +x "$root/script.sh"
  echo "== $name (pg_dump: $mode) =="
  ( export DUMP_STATE="$root"; bash "$root/script.sh" "$root/out.tar.gz" ) > "$root/log" 2>&1
  sed 's/^/     /' "$root/log"
}

run_case good good
R="$WORK/good"
grep -q "FRESH GOOD DUMP" "$R/src/sql/clirelay-latest.sql" \
  && ok "成功时旧 SQL 被新 dump 覆盖" || bad "成功时未覆盖"
grep -q "pg_dump ok size=" "$R/log" && ok "成功时打印 pg_dump ok" || bad "缺 pg_dump ok"
tar -tzf "$R/out.tar.gz" | grep -q "sql/clirelay-latest.sql" \
  && ok "包内含 SQL 快照" || bad "包内缺 SQL"
tar -tzf "$R/out.tar.gz" | grep -q "clirelay-pgdump" \
  && bad "包内混入临时 dump 文件" || ok "包内无临时 dump 残留"

run_case partial partial
R="$WORK/partial"
if grep -q "GOOD FULL DUMP FROM PREVIOUS ROUND" "$R/src/sql/clirelay-latest.sql" \
   && ! grep -q "PARTIAL" "$R/src/sql/clirelay-latest.sql"; then
  ok "半截 dump 未污染旧 SQL（bug 已修）"
else
  bad "旧 SQL 已被半截 dump 破坏 —— bug 仍在"
fi
grep -q "pg_dump 失败" "$R/log" && ok "失败有日志" || bad "失败无日志"
tar -tzf "$R/out.tar.gz" 2>/dev/null | grep -q "clirelay-pgdump" \
  && bad "包内混入临时 dump 文件" || ok "失败时包内无临时 dump 残留"
tar -tzf "$R/out.tar.gz" 2>/dev/null | grep -q "sql/clirelay-latest.sql" \
  && ok "失败时包内仍是上一轮的好 SQL" || bad "失败时包内没有 SQL"

run_case fail fail
R="$WORK/fail"
grep -q "GOOD FULL DUMP" "$R/src/sql/clirelay-latest.sql" \
  && ok "dump 失败时旧 SQL 完好" || bad "dump 失败时旧 SQL 被毁"

run_case tiny tiny
R="$WORK/tiny"
grep -q "GOOD FULL DUMP" "$R/src/sql/clirelay-latest.sql" \
  && ok "空库小输出不覆盖旧 SQL" || bad "空库小输出覆盖了旧 SQL"
grep -q "输出过小" "$R/log" && ok "小输出有告警" || bad "小输出无告警"

R="$WORK/first"
mk_env "$R"; rm -f "$R/src/sql/clirelay-latest.sql"; echo "fail" > "$R/dump_mode"
sed -e "s#^SRC_DIR=\"/tmp/local_CliRelay\"#SRC_DIR=\"$R/src\"#" \
    -e "s#^COMPOSE=\"docker #COMPOSE=\"$R/bin/docker #" \
    "$WORK/create-clirelay-archive.sh" > "$R/script.sh"
( export DUMP_STATE="$R"; bash "$R/script.sh" "$R/out.tar.gz" ) > "$R/log" 2>&1
echo "== first (无旧 SQL + dump 失败) =="
grep -q "归档内不含可用 SQL 快照" "$R/log" \
  && ok "首轮无 SQL 时有明确提示" || bad "首轮无 SQL 无提示"

R="$WORK/good"
grep -q "CliRelay 归档内容" "$R/log" && ok "日志有归档内容清单" || bad "日志缺清单"
grep -qE "^ +[0-9]+ +\./sql/clirelay-latest\.sql" "$R/log" \
  && ok "清单列出 sql 快照及大小" || bad "清单未列 sql 快照"
grep -qE "^ +[0-9]+ +\./config\.yaml" "$R/log" && ok "清单列出 config.yaml" || bad "清单缺 config"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
