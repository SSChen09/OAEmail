#!/bin/bash
# Cleanup leftover repo files + optional fixups. ASCII-only output.
set -u
TS=$(date +%Y%m%d-%H%M%S)
CLEAN=/root/pkgmirror-cleanup-$TS
mkdir -p "$CLEAN"
cd /etc/yum.repos.d || exit 1

echo "[cleanup] move stray repo files -> $CLEAN"
for f in *.rpmnew *.backup epel-testing.repo; do
  [ -e "$f" ] || continue
  case "$f" in
    epel-testing.repo)
      if grep -q '^enabled=1' "$f" 2>/dev/null; then
        echo "  WARN: $f had enabled=1, moving anyway"
      fi
      ;;
  esac
  mv -f "$f" "$CLEAN/" && echo "  moved $f"
done

echo "[ca-certificates] current: $(rpm -q ca-certificates)"
CURRENT=$(rpm -q --qf '%{VERSION}' ca-certificates 2>/dev/null)
case "$CURRENT" in
  2023.*|2024.*|2025.*) echo "  ok, skip" ;;
  *)
    echo "  upgrading via yum (timeout 300s)"
    timeout 300 yum -y update ca-certificates 2>&1 | tail -5
    echo "  now: $(rpm -q ca-certificates)"
    ;;
esac

echo "[pip] version: $(pip3 -V 2>&1 | cut -c1-40)"
PIPMAJ=$(pip3 -V 2>&1 | awk '{print $2}' | cut -d. -f1)
if [ "${PIPMAJ:-0}" -lt 21 ]; then
  echo "  upgrading pip"
  timeout 240 pip3 install --upgrade pip 2>&1 | tail -3
  echo "  now: $(pip3 -V 2>&1 | cut -c1-40)"
else
  echo "  ok, skip"
fi

echo "[verify] repolist:"
timeout 120 yum -q repolist 2>&1 | tail -6
echo "[verify] curl:"
for u in https://mirrors.aliyun.com/centos/ https://mirrors.aliyun.com/pypi/simple/; do
  echo "  $u -> $(timeout 15 curl -s -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)"
done
echo "== DONE"
