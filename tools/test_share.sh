#!/bin/bash
# 文件共享（/api/files.php）全流程测试：登录 → list → 上传 → 下载校验 → 超限 → 权限 → 删除
# 用法: bash test_share.sh [server_ip]        默认 192.168.3.152
# 管理员口令可用 ADMINPASS 覆盖（默认 admin）
set -u
B="http://${1:-192.168.3.152}"
ADMINPASS="${ADMINPASS:-admin}"
WORK="$(mktemp -d /tmp/sharetest.XXXXXX)"
JAR="$WORK/cookies.txt"
cd "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT

echo "== 登录 admin（上传/删除需要管理员会话） =="
curl -s -c "$JAR" -X POST -d "action=login&username=admin@ddzt.old&password=$ADMINPASS" "$B/api/auth.php"; echo

echo "== 权限：未登录上传应 401 =="
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -F "action=upload" -F "file=@/etc/hostname" "$B/api/files.php"

echo "== list (before) =="
curl -s "$B/api/files.php?action=list"; echo

echo "== make 3MB test file =="
head -c 3145728 /dev/urandom > ./t3.bin
md5sum ./t3.bin

echo "== upload (admin) =="
RESP=$(curl -s -b "$JAR" -F "action=upload" -F "file=@./t3.bin" "$B/api/files.php")
echo "$RESP"
NEW_ID=$(printf '%s' "$RESP" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p')

echo "== list =="
curl -s -X POST -d "action=list" "$B/api/files.php"; echo

if [ -n "$NEW_ID" ]; then
    echo "== download id=$NEW_ID =="
    curl -s -o ./t3.dl.bin "$B/api/files.php?action=download&id=$NEW_ID"
    md5sum ./t3.dl.bin
else
    echo "[!] 上传响应里没有 id，跳过下载/删除步骤"
fi

echo "== oversize 21MB (expect reject) =="
head -c 22020096 /dev/urandom > ./big.bin
curl -s -b "$JAR" -F "action=upload" -F "file=@./big.bin" "$B/api/files.php"; echo

if [ -n "$NEW_ID" ]; then
    echo "== delete id=$NEW_ID (admin) =="
    curl -s -b "$JAR" -X POST -d "action=delete" -d "id=$NEW_ID" "$B/api/files.php"; echo
fi
