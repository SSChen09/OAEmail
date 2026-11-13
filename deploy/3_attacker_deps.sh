#!/bin/bash
# =============================================================================
#  攻击端/备用客户端 192.168.1.232 一键安装系统依赖脚本（含校验）
#  依据: 配置.md —— 攻击端职责: DDoS 攻击服务器；其余同客户端一致
#  系统: CentOS 7 / root
# =============================================================================
#  覆盖依赖:
#    [DDoS 攻击] python36 + scapy==2.4.5 + requests + paramiko（attacker.py 依赖）
#                hping3 / nmap（辅助攻击与扫描）+ iproute（源 IP 别名 add_ips.sh）
#    [同客户端]  firefox 浏览器 + thunderbird 邮件客户端（备用客户端职责）
#    [通用]      curl/wget/vim/net-tools/tcpdump/bind-utils/jq
#    [内网域名]  /etc/hosts 写入 ddzt.old 等（纯内网、无公网 DNS）
#
#  用法:
#    bash 3_attacker_deps.sh            # 一键安装 + 校验
#    bash 3_attacker_deps.sh --check    # 仅校验（可重复执行）
#
#  可调环境变量:
#    ATTACKER_IP=192.168.1.232  SERVER_IP=192.168.1.137  MAIL_DOMAIN=ddzt.old
#  校验: 命令存在/版本/python 模块导入/域名解析 + 服务端连通性（信息性），
#        末尾输出 PASS/FAIL/WARN 汇总，存在 FAIL 时退出码非 0。
#  安全: 攻击脚本仅限隔离内网演练，只允许指向 $SERVER_IP，严禁指向网关/公网。
# =============================================================================
set -u

ATTACKER_IP="${ATTACKER_IP:-192.168.1.232}"
SERVER_IP="${SERVER_IP:-192.168.1.137}"
MAIL_DOMAIN="${MAIL_DOMAIN:-ddzt.old}"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PIP_INDEX2="https://mirrors.aliyun.com/pypi/simple"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

PASS=0; FAIL=0; WARNS=0

vcmd() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASS=$((PASS+1))
    else
        echo -e "\033[1;31m[x]\033[0m $desc  (命令: $*)"; FAIL=$((FAIL+1))
    fi
}
# vver "说明" 命令...      打印版本信息（要求命令退出码为 0，否则 FAIL）
vver() {
    local desc="$1"; shift
    local out rc
    out=$("$@" 2>&1); rc=$?
    out=$(printf '%s\n' "$out" | sed -n '/./{p;q}')   # 第一个非空行（nmap --version 首行为空）
    if [ "$rc" = "0" ] && [ -n "$out" ]; then
        ok "$desc : $out"; PASS=$((PASS+1))
    else
        echo -e "\033[1;31m[x]\033[0m $desc : 获取版本失败 ($*)"; FAIL=$((FAIL+1))
    fi
}
# vhosts 域名              内网解析检查（getent ahosts 走 getaddrinfo，
#                          能看到 /etc/hosts 的 IPv4；getent hosts 会被
#                          搜索域+IPv6 劫持 DNS 的 AAAA 干扰，故不用）
vhosts() {
    if grep -qE "[[:space:]]$1([[:space:]]|$)" /etc/hosts \
       && getent ahosts "$1" 2>/dev/null | grep -q "$SERVER_IP"; then
        ok "域名 $1 -> $SERVER_IP 解析正常"; PASS=$((PASS+1))
    else
        echo -e "\033[1;31m[x]\033[0m 域名 $1 未解析到 $SERVER_IP"; FAIL=$((FAIL+1))
    fi
}
vinfo() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASS=$((PASS+1))
    else
        warn "$desc — 服务端可能尚未部署，稍后可复查"; WARNS=$((WARNS+1))
    fi
}
pip_install() {
    pip3 install -i "$PIP_INDEX" "$@" && return 0
    warn "清华源安装失败，改用阿里云源重试: $*"
    pip3 install -i "$PIP_INDEX2" "$@"
}

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# =============================================================================
#  一、安装（--check 跳过）
# =============================================================================
if [ "$CHECK_ONLY" = "0" ]; then

    say "===== [1/5] 通用基础工具 ====="
    yum install -y yum-utils net-tools tcpdump wget curl vim bind-utils jq unzip tar \
        || warn "基础工具安装有失败项"

    say "===== [2/5] [DDoS 攻击] 攻击工具 ====="
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y hping3 nmap iproute || warn "攻击工具安装有失败项"

    say "===== [3/5] [DDoS 攻击] python36 + scapy/requests/paramiko ====="
    yum install -y python36 python36-pip || warn "python36 安装有失败项"
    pip_install "scapy==2.4.5" "requests" "paramiko" || warn "攻击依赖安装失败"

    say "===== [4/5] [同客户端] firefox + thunderbird ====="
    yum install -y firefox || warn "firefox 安装失败"
    yum install -y thunderbird || warn "thunderbird 安装失败（可用 OA 网页邮箱替代）"

    say "===== [5/5] [内网域名] 写入 /etc/hosts（纯内网无公网 DNS）====="
    for d in "$MAIL_DOMAIN" "mail.$MAIL_DOMAIN" "www.$MAIL_DOMAIN" "oa.$MAIL_DOMAIN"; do
        if grep -qE "[[:space:]]$d([[:space:]]|$)" /etc/hosts; then
            ok "/etc/hosts 已含 $d"
        else
            echo "$SERVER_IP  $d" >> /etc/hosts && ok "写入 /etc/hosts: $SERVER_IP $d"
        fi
    done

    say "===== [附加] 防火墙/SELinux（演示环境；NO_FIREWALL_CHANGE=1 可跳过）====="
    if [ "${NO_FIREWALL_CHANGE:-0}" = "1" ]; then
        warn "按 NO_FIREWALL_CHANGE=1 保留 firewalld / SELinux 现状"
    else
        # 与 ddos/attacker/2_setup_attacker.sh 约定一致：演示环境停 firewalld，
        # 避免出向/转发受限；scapy 原始套接字也要求 root + 无额外限制
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        ok "firewalld 已停止并取消开机自启"
        if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
            setenforce 0 && ok "SELinux 已临时设为 permissive"
        fi
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
    fi
fi

# =============================================================================
#  二、校验
# =============================================================================
say "===== 校验开始 ====="

say "-- [DDoS 攻击] python 依赖 --"
vver "python36" python3 --version
vcmd "pip3 可用" pip3 --version
vcmd "scapy 可导入"  python3 -c "import scapy"
vcmd "requests 可导入" python3 -c "import requests"
vcmd "paramiko 可导入" python3 -c "import paramiko"
vcmd "scapy 可发包(原始套接字权限)" python3 -c "from scapy.all import IP; assert IP()"

say "-- [DDoS 攻击] 攻击工具 --"
vcmd "hping3 可用" hping3 -v
vver "nmap" nmap --version
vcmd "iproute (ip 命令)" ip -V

say "-- [同客户端] 浏览器/邮件 --"
vver "firefox"    firefox --version
vver "thunderbird" thunderbird --version

say "-- [通用] 工具 --"
vver "curl" curl --version
vcmd "jq 可用" jq --version
vcmd "dig 可用 (bind-utils)" dig -v

say "-- [内网域名解析] --"
vhosts "$MAIL_DOMAIN"
vhosts "mail.$MAIL_DOMAIN"

say "-- [防火墙/SELinux] --"
if systemctl is-active firewalld >/dev/null 2>&1; then
    warn "firewalld 运行中（出向/演示可能受限，建议停用）"; WARNS=$((WARNS+1))
else
    ok "firewalld 未运行"; PASS=$((PASS+1))
fi
_se=$(getenforce 2>/dev/null || echo 未知)
if [ "$_se" = "Enforcing" ]; then
    warn "SELinux 为 Enforcing（演示环境建议 permissive）"; WARNS=$((WARNS+1))
else
    ok "SELinux 状态: $_se"; PASS=$((PASS+1))
fi

say "-- [本机 IP 自检] --"
if ip -o -4 addr show 2>/dev/null | grep -q "inet $ATTACKER_IP/"; then
    ok "本机 IP 即约定攻击端 $ATTACKER_IP"; PASS=$((PASS+1))
else
    warn "本机 IP 不是 $ATTACKER_IP，请确认脚本部署对象"; WARNS=$((WARNS+1))
fi

say "-- [服务端连通性]（信息性，服务端部署后转 PASS）--"
vinfo "ping $SERVER_IP 可达"      ping -c 1 -W 2 "$SERVER_IP"
vinfo "服务端 Web 端口 80 可访问" bash -c "curl -s -m 4 -o /dev/null -w '%{http_code}' 'http://$SERVER_IP/' | grep -qv '000'"
vinfo "邮件 SMTP 端口 25 可访问"  bash -c "timeout 3 bash -c '</dev/tcp/$SERVER_IP/25'"

# =============================================================================
#  三、汇总
# =============================================================================
echo
say "===== 校验汇总: PASS=$PASS  FAIL=$FAIL  WARN=$WARNS ====="
if [ "$FAIL" -gt 0 ]; then
    die "存在 $FAIL 项失败，请按上方 [x] 标记逐项排查"
fi
ok "攻击端依赖安装/校验通过（DDoS 攻击 + 同客户端职责）"
ok "提醒: 攻击脚本仅限隔离内网演练，只允许指向 $SERVER_IP"
exit 0
