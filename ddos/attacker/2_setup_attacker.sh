#!/bin/bash
# =============================================================================
#  攻击机 192.168.3.153 一键部署脚本（CentOS 7 / root）
# =============================================================================
#  功能:
#    1. 安装 python（优先 py3: python36/python3，回退 py2）/ curl / tcpdump
#    2. 安装 Python 依赖 scapy==2.4.5 requests paramiko（py2 钉 requests==2.27.1 paramiko==2.10.4）
#    3. 关闭 firewalld（避免本机出向被拦）
#    4. 部署 attacker.py 到 /opt/ddos/，生成快捷命令 /usr/local/bin/ddos-attack
#    5. 连通性自检：到靶机 80 / 5000 的探测（不发攻击流量）
#
#  用法（在攻击机上执行）:
#    #   scp -r attacker/* root@192.168.3.153:/opt/ddos-setup/
#    bash 2_setup_attacker.sh
#
#  可调环境变量:
#    TARGET_IP=192.168.3.152   靶机 IP
#    SKIP_PKG=1                跳过 yum/pip（离线环境）
#    NO_FIREWALL_CHANGE=1      不改动 firewalld
# =============================================================================
set -e

# ---------------------------- 参数区 -----------------------------------------
TARGET_IP="${TARGET_IP:-192.168.3.152}"
SKIP_PKG="${SKIP_PKG:-0}"
NO_FIREWALL_CHANGE="${NO_FIREWALL_CHANGE:-0}"

APP_DIR="/opt/ddos"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

# 靶机 IP 合法性：该值会写进 /etc/ddos/target 和 ddos-attack，非法值会让攻击脚本在运行时才失败
echo "$TARGET_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    || die "TARGET_IP 非法: '$TARGET_IP'（需要 a.b.c.d）"
printf '%s\n' "$TARGET_IP" | awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' \
    || die "TARGET_IP 非法: '$TARGET_IP'（每段需 <=255）"

# 选择 Python 解释器：优先 py3（CentOS7 为 python36），回退 py2（自带 python2/python）
py_bin() {
    for p in python36 python3 python2 python; do
        command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    echo ""
}

# 解释器主版本（2 或 3）；探测失败按 3 处理
py_major() {
    "$1" -c 'import sys; sys.stdout.write(str(sys.version_info[0]))' 2>/dev/null || echo 3
}

# 该解释器是否带 pip 模块；没有则尝试补装对应包
ensure_pip() {
    "$1" -m pip --version >/dev/null 2>&1 && return 0
    warn "$1 无 pip 模块，尝试安装..."
    if [ "$2" = "3" ]; then
        yum install -y python36-pip python3-pip >/dev/null 2>&1 || true
    else
        yum install -y python2-pip python-pip >/dev/null 2>&1 || true
    fi
    "$1" -m pip --version >/dev/null 2>&1
}

[ "$(id -u)" = "0" ] || die "请以 root 运行（Scapy 需要原始套接字权限）"
cd "$SRC_DIR"

say "===== 攻击机 DDoS 模拟环境部署开始 ====="
say "靶机: $TARGET_IP"

# ---------------------------- 1. 基础软件 ------------------------------------
if [ "$SKIP_PKG" != "1" ]; then
    say "[1/5] 安装基础软件包"
    if ! rpm -q epel-release >/dev/null 2>&1; then
        yum install -y epel-release || warn "epel-release 安装失败（离线可忽略）"
    fi
    yum install -y curl net-tools tcpdump || die "yum 安装失败"
    # python36 优先（EPEL），装不上就回退系统自带 py2
    yum install -y python36 python36-pip >/dev/null 2>&1 \
        || warn "python36 不可用，回退系统自带 Python（py2）"
    ok "基础软件安装完成"
else
    warn "[1/5] 跳过软件安装（SKIP_PKG=1）"
fi

# ---------------------------- 2. 网络与防火墙 --------------------------------
if [ "$NO_FIREWALL_CHANGE" != "1" ]; then
    say "[2/5] 关闭 firewalld（仅演示环境）"
    systemctl stop firewalld   2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    setenforce 0 2>/dev/null || true
    ok "firewalld 已停止"
else
    warn "[2/5] 按 NO_FIREWALL_CHANGE=1 保留 firewalld"
fi

say "网卡信息（以 ip route get $TARGET_IP 为准）"
ip route get "$TARGET_IP" 2>/dev/null || warn "无法获取路由，请检查 IP/网卡"
ip -o -4 addr show | awk '{print "   " $2, $4}'

# ---------------------------- 3. Python 依赖 ---------------------------------
# 先选解释器（py3 优先，回退 py2），按主版本装对应依赖版本
PY=$(py_bin)
[ -n "$PY" ] || die "未找到可用的 Python（python36/python3/python2/python）"
PY_MAJOR=$(py_major "$PY")
say "使用解释器: $PY (Python $PY_MAJOR) -> $(command -v "$PY")"

if [ "$SKIP_PKG" != "1" ]; then
    say "[3/5] 安装 Python 依赖 (scapy / requests / paramiko)"
    ensure_pip "$PY" "$PY_MAJOR" || die "$PY 无 pip 模块（可安装 python2-pip/python36-pip 后重试）"
    if [ "$PY_MAJOR" = "3" ]; then
        "$PY" -m pip install -i "$PIP_MIRROR" --upgrade pip >/dev/null 2>&1 || true
        "$PY" -m pip install -i "$PIP_MIRROR" scapy==2.4.5 requests==2.27.1 paramiko==2.10.4 \
            || die "pip 依赖安装失败"
    else
        # py2: 先升到最后一个支持 py2 的 pip，否则老 pip 不识别 python_requires 会装错版本
        "$PY" -m pip install -i "$PIP_MIRROR" "pip==20.3.4" >/dev/null 2>&1 \
            || warn "pip 升级到 20.3.4 失败，继续用现有 pip"
        "$PY" -m pip install -i "$PIP_MIRROR" scapy==2.4.5 requests==2.27.1 paramiko==2.10.4 \
            || die "pip 依赖安装失败"
    fi
    "$PY" -c "import scapy.all, requests, paramiko" >/dev/null 2>&1 \
        || die "依赖导入自检失败（$PY，$PY_MAJOR）"
    ok "Python 依赖安装完成（$PY, Python $PY_MAJOR）"
else
    warn "[3/5] 跳过 pip 安装（SKIP_PKG=1）"
fi

# ---------------------------- 4. 部署脚本 ------------------------------------
say "[4/5] 部署 attacker.py 到 $APP_DIR"
[ -f "$SRC_DIR/attacker.py" ] || die "缺少 attacker.py"
mkdir -p "$APP_DIR"
install -m 755 "$SRC_DIR/attacker.py" "$APP_DIR/attacker.py"
PY=${PY:-$(py_bin)}
[ -n "$PY" ] || die "未找到可用的 Python（python36/python3/python2/python）"
"$PY" -m py_compile "$APP_DIR/attacker.py" && ok "attacker.py 语法检查通过（$PY）"

# 靶机地址落地到 /etc/ddos/target（attacker.py 与 ddos-attack 运行时都读它；IP 变了只改此文件）
install -d /etc/ddos
printf '%s\n' "$TARGET_IP" > /etc/ddos/target
echo "attacker" > /etc/ddzt-role
ok "靶机地址: /etc/ddos/target = $TARGET_IP"

# 快捷命令：ddos-attack <mode> [其余参数...]（--target 在运行时解析，不烧死 IP）
cat > /usr/local/bin/ddos-attack <<EOF
#!/bin/bash
# 简写包装：ddos-attack <mode> [其余参数...]
MODE=\${1:-mixed}
[ \$# -gt 0 ] && shift
# 靶机地址运行时解析：/etc/ddos/target 为空或缺失时回退部署时的默认值（文件内容由 net_sync 维护）
T=\$(tr -d ' \\r\\n' < /etc/ddos/target 2>/dev/null || true)
[ -n "\$T" ] || T=$TARGET_IP
exec $(command -v "$PY") "$APP_DIR/attacker.py" --mode "\$MODE" --target "\$T" "\$@"
EOF
chmod 755 /usr/local/bin/ddos-attack
ok "快捷命令: ddos-attack <syn|udp|http|multi-port|brute|mixed|dry-run> [参数]"

# ---------------------------- 5. 连通性自检 ----------------------------------
say "[5/5] 连通性自检（不发送攻击流量）"
if ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
    ok "ping $TARGET_IP 可达"
else
    warn "ping $TARGET_IP 不可达（若靶机禁 ping 可忽略）"
fi
CODE=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$TARGET_IP/" 2>/dev/null || true)
if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
    ok "靶机 Nginx 80 端口可达（HTTP $CODE）"
else
    warn "靶机 80 端口不可达，请确认 Nginx 已启动"
fi
if curl -s -m 3 "http://$TARGET_IP:5000/api/stats" | grep -q '"ts"'; then
    ok "靶机面板 5000 端口可达（可浏览器验证）"
else
    warn "靶机 5000 端口不可达，请确认靶机 agent.py 已启动"
fi

say "===== 部署完成 ====="
cat <<EOF

 快速开始（请按顺序，先测真实 IP 的扫描/爆破，再测伪造源 flood）:
   ddos-attack dry-run                                     # 查看计划
   ddos-attack multi-port --mp-rate 50 --duration 20
   ddos-attack brute --brute-kinds ssh,ftp,redis,telnet --duration 40
   ddos-attack mixed --syn-procs 4 --syn-rate 200 --udp-procs 2 --udp-rate 200 \\
              --http-threads 20 --mp-rate 50 --brute-kinds ssh --duration 40

 注意：
   - 攻击机默认在靶机白名单中（/etc/ddos/whitelist.txt），只观测、不会被封。要演示真实全端口封禁，
     请在靶机 /etc/ddos/whitelist.txt 删掉本机 IP 那一行，再 systemctl restart ddos-agent。
   - 爆破/扫描会把本机真实 IP 封 60s；被封后 flood 结果不可信，务必按顺序执行。

EOF
