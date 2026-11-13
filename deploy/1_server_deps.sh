#!/bin/bash
# =============================================================================
#  服务端 192.168.3.152 一键安装系统依赖脚本（含校验）
#  依据: 配置.md —— 服务端职责: OA系统部署 + 防御DDoS部署 + 邮件系统部署
#  系统: CentOS 7 / root
# =============================================================================
#  覆盖三大系统依赖（本脚本只装依赖，不部署业务）:
#    [OA]        nginx + mariadb + php(-fpm/-mysql/-gd/-mbstring/-xml/-ldap/-opcache)
#                + JDK1.8（部分 OA 为 Java 实现）
#    [邮件]      postfix + dovecot + cyrus-sasl + mailx（域名 ddzt.old，纯内网）
#    [DDoS 防御] nginx/openssh/vsftpd/redis（演示靶服务）+ iptables
#                + python36 + scapy==2.4.5 + flask==2.0.3（运行 agent/面板）
#    [通用]      curl/wget/vim/net-tools/tcpdump/lsof 等基础工具
#    [内网域名]  /etc/hosts 写入 ddzt.old 等（纯内网、无公网 DNS）
#
#  用法:
#    bash 1_server_deps.sh            # 一键安装 + 校验
#    bash 1_server_deps.sh --check    # 仅校验（可重复执行）
#
#  可调环境变量:
#    SERVER_IP=192.168.3.152  MAIL_DOMAIN=ddzt.old  PIP_INDEX=...
#  校验: 每个依赖均做 命令存在/版本/服务状态/端口监听/域名解析 检查，
#        末尾输出 PASS/FAIL/WARN 汇总，存在 FAIL 时退出码非 0。
# =============================================================================
set -u

SERVER_IP="${SERVER_IP:-192.168.3.152}"
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

# ------------------------- 校验辅助函数 -------------------------------------
# vcmd "说明" 命令...      必选依赖：命令执行成功记 PASS，否则 FAIL
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
# vsvc 服务名              服务已启动且开机自启
vsvc() {
    local s="$1"
    if systemctl is-active "$s" >/dev/null 2>&1; then
        if systemctl is-enabled "$s" >/dev/null 2>&1; then
            ok "服务 $s 运行中且已自启"; PASS=$((PASS+1))
        else
            warn "服务 $s 运行中但未自启"; WARNS=$((WARNS+1))
        fi
    else
        echo -e "\033[1;31m[x]\033[0m 服务 $s 未运行 (systemctl status $s)"; FAIL=$((FAIL+1))
    fi
}
# vport 端口 说明          端口监听检查（重试 15s，兼容服务慢启动）
vport() {
    local p="$1" desc="$2" i
    for i in $(seq 1 15); do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
            ok "端口 $p 监听 — $desc"; PASS=$((PASS+1)); return 0
        fi
        sleep 1
    done
    echo -e "\033[1;31m[x]\033[0m 端口 $p 未监听 — $desc"; FAIL=$((FAIL+1))
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
# pip_install 包列表       双镜像源安装 Python 依赖
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

    say "===== [0/5] 通用基础工具 ====="
    yum install -y yum-utils net-tools tcpdump wget curl vim lsof unzip tar bind-utils \
        || warn "基础工具安装有失败项"

    say "===== [1/5] [DDoS 防御] 演示靶服务 + 过滤组件 ====="
    yum install -y nginx openssh-server vsftpd iptables || warn "靶服务安装有失败项"
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y redis || warn "redis 安装失败（6379 爆破演示不可用）"

    say "===== [2/5] [DDoS 防御] Python36 + scapy/flask（agent 依赖）====="
    yum install -y python36 python36-pip || warn "python36 安装有失败项"
    pip_install "scapy==2.4.5" "flask==2.0.3" || warn "scapy/flask 安装失败"
    mkdir -p /var/log/ddos && ok "/var/log/ddos 就绪"

    say "===== [3/5] [OA] Web/DB/PHP/JDK 依赖 ====="
    # 核心包失败即终止（yum 单事务全有或全无，混装会让 OA 整体没装上却只 warn）
    yum install -y nginx mariadb-server mariadb php-fpm php php-cli php-mysql php-pdo \
        || die "OA 核心依赖安装失败（检查本地 yum 源是否含 nginx/mariadb/php）"
    # 扩展/可选包单独装，缺失只告警
    yum install -y php-gd php-mbstring php-xml php-ldap php-opcache php-imap \
        || warn "PHP 扩展安装有失败项（gd/mbstring/xml/ldap/opcache/imap 部分不可用）"
    yum install -y java-1.8.0-openjdk || warn "JDK1.8 安装失败（Java 型 OA 不可用）"

    say "===== [4/5] [邮件] postfix/dovecot/sasl/mailx（域名 $MAIL_DOMAIN）====="
    yum install -y postfix dovecot cyrus-sasl-plain mailx || warn "邮件依赖安装有失败项"
    # postfix 默认 inet_interfaces=localhost（仅 127.0.0.1:25），客户端/攻击端
    # 无法连接；邮件依赖就绪的定义是 LAN 可达，故放开为 all。
    # 注意：邮箱域(ddzt.old)/用户(eva@/kk@)等业务配置属部署阶段，此处不做。
    postconf -e 'inet_interfaces = all'
    systemctl restart postfix && ok "postfix inet_interfaces=all（LAN 可达）"
    # dovecot 默认 listen=*；如被改动过则恢复，保证 110/143 LAN 可达
    # 用独立片段文件而不是 sed 改主配置（幂等、可回滚、不会误改注释示例）
    if doveconf -n 2>/dev/null | grep -qE '^listen[[:space:]]*=[[:space:]]*\*'; then
        ok "dovecot listen=*（LAN 可达）"
    else
        printf 'listen = *\n' > /etc/dovecot/conf.d/99-oa-listen.conf
        systemctl restart dovecot && ok "dovecot listen=*（LAN 可达，片段 99-oa-listen.conf）" \
            || warn "dovecot 重启失败，请检查 doveconf -n"
    fi

    say "===== [5/5] [内网域名] 写入 /etc/hosts（纯内网无公网 DNS）====="
    # 先清掉这四个域名的旧映射（IP 变更后会残留旧地址），再统一写入当前 SERVER_IP
    _hosts_tmp=$(mktemp)
    if awk -v d1="$MAIL_DOMAIN" -v d2="mail.$MAIL_DOMAIN" \
             -v d3="www.$MAIL_DOMAIN" -v d4="oa.$MAIL_DOMAIN" '
        { keep=1
          for (i=2; i<=NF; i++)
              if ($i==d1 || $i==d2 || $i==d3 || $i==d4) keep=0
          if (keep) print }
    ' /etc/hosts > "$_hosts_tmp" && [ -s "$_hosts_tmp" ]; then
        cat "$_hosts_tmp" > /etc/hosts
    else
        warn "整理 /etc/hosts 失败，保留原文件（可能残留旧域名映射）"
    fi
    rm -f "$_hosts_tmp"
    for d in "$MAIL_DOMAIN" "mail.$MAIL_DOMAIN" "www.$MAIL_DOMAIN" "oa.$MAIL_DOMAIN"; do
        echo "$SERVER_IP  $d" >> /etc/hosts && ok "写入 /etc/hosts: $SERVER_IP $d"
    done

    say "启动并设置开机自启（OA / 邮件 / DDoS 靶服务）"
    systemctl enable nginx mariadb postfix dovecot redis vsftpd sshd php-fpm >/dev/null 2>&1 || true
    systemctl start  nginx mariadb postfix dovecot redis vsftpd sshd php-fpm || warn "服务启动有失败项，请用 systemctl status 排查"

    say "===== [附加] 防火墙/SELinux（演示环境；NO_FIREWALL_CHANGE=1 可跳过）====="
    if [ "${NO_FIREWALL_CHANGE:-0}" = "1" ]; then
        warn "按 NO_FIREWALL_CHANGE=1 保留 firewalld / SELinux 现状（请自行放行 80/25/110/143/21/5000 等端口）"
    else
        # 与 ddos/target/1_setup_target.sh 约定一致：演示环境停 firewalld、
        # SELinux permissive（DDoS agent 直接写 iptables 规则，与 firewalld 冲突，
        # 且 firewalld 默认只放行 ssh，80/25 等服务端口全被拦）
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        ok "firewalld 已停止并取消开机自启"
        if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
            setenforce 0 && ok "SELinux 已临时设为 permissive"
        fi
        if [ -f /etc/selinux/config ]; then
            cp -a /etc/selinux/config "/etc/selinux/config.bak.$(date +%F-%H%M%S)"
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
            grep -q '^SELINUX=permissive' /etc/selinux/config \
                && ok "SELINUX 已持久化 permissive" \
                || warn "SELINUX 持久化失败（/etc/selinux/config 未匹配 SELINUX=enforcing）"
        fi
    fi
fi

# =============================================================================
#  二、校验
# =============================================================================
say "===== 校验开始 ====="

say "-- [通用] 基础工具 --"
vver "curl"   curl --version
vver "wget"   wget --version
vver "tcpdump" tcpdump --version

say "-- [DDoS 防御] 依赖 --"
vver "nginx"    nginx -v
vver "python36" python3 --version
vcmd "pip3 可用" pip3 --version
vcmd "scapy 可导入" python3 -c "import scapy"
vcmd "flask 可导入" python3 -c "import flask"
vcmd "iptables 可用" iptables -L -n
vver "redis"   redis-server --version
vcmd "/var/log/ddos 目录存在" test -d /var/log/ddos

say "-- [OA] 依赖 --"
vver "mariadb" mysql --version
vver "php"     php -v
vcmd "php-fpm 可用" php-fpm -t
vcmd "php mysql 扩展"    bash -c "php -m | grep -qi mysql"
vcmd "php pdo_sqlite 扩展(文件共享需要)" bash -c "php -m | grep -qi pdo_sqlite"
vcmd "php imap 扩展(webmail 需要)" bash -c "php -m | grep -qi imap"
vcmd "php gd 扩展"       bash -c "php -m | grep -qi gd"
vcmd "php mbstring 扩展" bash -c "php -m | grep -qi mbstring"
vcmd "JDK1.8" bash -c "java -version 2>&1 | grep -q '1\.8'"

say "-- [邮件] 依赖 --"
vver "postfix" postconf -d mail_version
vcmd "postfix 配置检查" postfix check
if postconf -n | grep -q '^inet_interfaces = all'; then
    ok "postfix inet_interfaces=all（SMTP 对 LAN 可达）"; PASS=$((PASS+1))
else
    echo -e "\033[1;31m[x]\033[0m postfix inet_interfaces 非 all，客户端 SMTP 无法连接"; FAIL=$((FAIL+1))
fi
vver "dovecot" dovecot --version
vcmd "dovecot 配置检查" doveconf -n
vver "mailx"   mail -V

say "-- [服务状态] --"
vsvc nginx
vsvc mariadb
vsvc postfix
vsvc dovecot
vsvc vsftpd
vsvc sshd
vsvc php-fpm
# redis 为 6379 爆破演示的可选组件：未安装只告警，不让整体校验失败
if command -v redis-server >/dev/null 2>&1; then
    vsvc redis
else
    warn "redis 未安装，跳过 6379 爆破演示依赖（不影响 OA/邮件/防护）"; WARNS=$((WARNS+1))
fi

say "-- [端口监听] --"
vport 80   "nginx (OA/面板)"
vport 3306 "mariadb (OA 数据库)"
vport 9000 "php-fpm"
vport 25   "postfix SMTP (邮件)"
vport 110  "dovecot POP3"
vport 143  "dovecot IMAP"
if command -v redis-server >/dev/null 2>&1; then
    vport 6379 "redis (6379 爆破演示)"
fi
vport 21   "vsftpd (FTP 爆破演示)"
vport 22   "sshd"

say "-- [内网域名解析] --"
for _d in "$MAIL_DOMAIN" "mail.$MAIL_DOMAIN" "www.$MAIL_DOMAIN" "oa.$MAIL_DOMAIN"; do
    vhosts "$_d"
done

say "-- [防火墙/SELinux] --"
if systemctl is-active firewalld >/dev/null 2>&1; then
    warn "firewalld 运行中，80/25/110/143 等服务端口可能被拦（演示环境建议停用；若 NO_FIREWALL_CHANGE=1 请自行放行）"; WARNS=$((WARNS+1))
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
if ip -o -4 addr show 2>/dev/null | grep -q "inet $SERVER_IP/"; then
    ok "本机 IP 即约定服务端 $SERVER_IP"; PASS=$((PASS+1))
else
    warn "本机 IP 不是 $SERVER_IP，请确认脚本部署对象"; WARNS=$((WARNS+1))
fi

# 角色标记：供 tools/net_sync.py 在 IP 变化后自动识别本机角色（勿删）
[ -f /etc/ddzt-role ] || echo "server" > /etc/ddzt-role

# =============================================================================
#  三、汇总
# =============================================================================
echo
say "===== 校验汇总: PASS=$PASS  FAIL=$FAIL  WARN=$WARNS ====="
if [ "$FAIL" -gt 0 ]; then
    die "存在 $FAIL 项失败，请按上方 [x] 标记逐项排查"
fi
ok "服务端依赖安装/校验全部通过（OA + 邮件 + DDoS 防御）"
ok "下一步: 部署 OA 系统、邮件系统(ddzt.old, eva@/kk@)、DDoS 防御 agent"
exit 0
