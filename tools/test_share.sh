#!/bin/bash
# 文件共享（/api/files.php）全流程测试：登录 → list → 上传（说明/到期） → 下载校验 → 过期 → 权限 → 删除
# 用法: bash test_share.sh [server_ip]        默认 192.168.3.152
# 口令可用 ADMINPASS / EVAPASS 覆盖（默认 admin / rei）
set -u
B="http://${1:-192.168.3.152}"
ADMINPASS="${ADMINPASS:-admin}"
EVAPASS="${EVAPASS:-rei}"
WORK="$(mktemp -d /tmp/sharetest.XXXXXX)"
AJAR="$WORK/admin.cookies"
EJAR="$WORK/eva.cookies"
ANON="$WORK/anon.cookies"
cd "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT

echo "== 登录 admin / eva =="
curl -s -c "$AJAR" -X POST -d "action=login&username=admin@ddzt.old&password=$ADMINPASS" "$B/api/auth.php"; echo
curl -s -c "$EJAR" -X POST -d "action=login&username=eva@ddzt.old&password=$EVAPASS" "$B/api/auth.php"; echo

echo "== 未登录：list / upload 应 401 =="
curl -s -o /dev/null -w 'list  HTTP %{http_code}\n' -X POST -d "action=list" "$B/api/files.php"
curl -s -o /dev/null -w 'upload HTTP %{http_code}\n' -F "action=upload" -F "file=@/etc/hostname" "$B/api/files.php"

echo "== list (before, admin) =="
curl -s -b "$AJAR" -X POST -d "action=list" "$B/api/files.php"; echo

echo "== make 3MB test file =="
head -c 3145728 /dev/urandom > ./t3.bin
md5sum ./t3.bin

echo "== upload (admin, note + 2099 到期) =="
RESP=$(curl -s -b "$AJAR" -F "action=upload" -F "file=@./t3.bin" \
    -F "note=端到端测试说明" -F "expires_at=2099-12-31T23:59" "$B/api/files.php")
echo "$RESP"
NEW_ID=$(printf '%s' "$RESP" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p')

if [ -n "$NEW_ID" ]; then
    echo "== download id=$NEW_ID（需登录） =="
    curl -s -b "$AJAR" -o ./t3.dl.bin "$B/api/files.php?action=download&id=$NEW_ID"
    md5sum ./t3.dl.bin
    echo "== eva 删除他人文件（应 403） =="
    curl -s -b "$EJAR" -X POST -d "action=delete" -d "id=$NEW_ID" "$B/api/files.php"; echo
else
    echo "[!] 上传响应里没有 id，跳过下载/删除步骤"
fi

echo "== 过期文件：上传 2020 到期（应标注 expired） =="
EXP=$(curl -s -b "$AJAR" -F "action=upload" -F "file=@/etc/hostname" \
    -F "note=过期测试" -F "expires_at=2020-01-01T00:00" "$B/api/files.php")
echo "$EXP"
EXP_ID=$(printf '%s' "$EXP" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p')
if [ -n "$EXP_ID" ]; then
    echo "== 下载过期文件（应 410） =="
    curl -s -b "$AJAR" -o /dev/null -w 'HTTP %{http_code}\n' "$B/api/files.php?action=download&id=$EXP_ID"
fi

echo "== oversize 21MB (expect reject) =="
head -c 22020096 /dev/urandom > ./big.bin
curl -s -b "$AJAR" -F "action=upload" -F "file=@./big.bin" "$B/api/files.php"; echo

echo "== 删除测试文件 =="
for ID in "$NEW_ID" "$EXP_ID"; do
    [ -n "$ID" ] && { curl -s -b "$AJAR" -X POST -d "action=delete" -d "id=$ID" "$B/api/files.php"; echo; }
done

echo "== list (after, admin) =="
curl -s -b "$AJAR" -X POST -d "action=list" "$B/api/files.php"; echo
