#!/bin/bash
# Standardize CentOS 7 yum + pip sources to Aliyun mirrors. ASCII-only output.
set -u
TS=$(date +%Y%m%d-%H%M%S)
BAK=/root/pkgmirror-backup-$TS
mkdir -p "$BAK"

echo "[1/10] backup -> $BAK"
cp -a /etc/yum.repos.d "$BAK/repos.d" 2>/dev/null
[ -f /etc/pip.conf ] && cp -a /etc/pip.conf "$BAK/pip.conf"
[ -f /root/.pip/pip.conf ] && cp -a /root/.pip/pip.conf "$BAK/user-pip.conf"
[ -f /root/.config/pip/pip.conf ] && cp -a /root/.config/pip/pip.conf "$BAK/user-xdg-pip.conf"

echo "[2/10] drop extra repo files"
cd /etc/yum.repos.d || exit 1
for f in *.repo; do
  [ -e "$f" ] || continue
  case "$f" in
    CentOS-Base.repo|epel.repo) ;;
    *) mv -f "$f" "$BAK/" ;;
  esac
done

echo "[3/10] write aliyun CentOS-Base.repo"
cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-$releasever - Updates - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-$releasever - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[centosplus]
name=CentOS-$releasever - Plus - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos/$releasever/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
EOF

echo "[4/10] write aliyun epel.repo"
cat > /etc/yum.repos.d/epel.repo <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=https://mirrors.aliyun.com/epel/7/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7

[epel-debuginfo]
name=Extra Packages for Enterprise Linux 7 - $basearch - Debug
baseurl=https://mirrors.aliyun.com/epel/7/$basearch/debug/
enabled=0
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7
EOF

echo "[5/10] import gpg keys"
rpm --import https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7 2>&1 | tail -2
rpm --import https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7 2>&1 | tail -2

echo "[6/10] rebuild yum cache"
yum clean all >/dev/null 2>&1
timeout 240 yum makecache fast 2>&1 | tail -8

echo "[7/10] write /etc/pip.conf"
cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
timeout = 60
EOF
rm -f /root/.pip/pip.conf /root/.config/pip/pip.conf

echo "[8/10] ensure epel-release"
if ! rpm -q epel-release >/dev/null 2>&1; then
  timeout 180 yum install -y epel-release 2>&1 | tail -3
else
  echo "already installed: $(rpm -q epel-release)"
fi

echo "[9/10] ensure python3 + pip"
command -v python3 >/dev/null 2>&1 || timeout 300 yum install -y python3 2>&1 | tail -3
command -v pip3 >/dev/null 2>&1 || timeout 300 yum install -y python3-pip 2>&1 | tail -3

echo "[10/10] verify"
echo "--- yum repolist:"
timeout 180 yum -q repolist 2>&1 | tail -8
echo "--- pip config:"
command -v pip3 >/dev/null 2>&1 && pip3 config list 2>/dev/null || echo "no pip3"
echo "--- pip download test:"
rm -rf /tmp/pipchk; mkdir -p /tmp/pipchk
timeout 120 pip3 download --no-deps -d /tmp/pipchk six 2>&1 | tail -3
echo "--- curl check:"
for u in https://mirrors.aliyun.com/centos/ https://mirrors.aliyun.com/pypi/simple/; do
  echo "  $u -> $(timeout 15 curl -s -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)"
done
echo "== DONE"
