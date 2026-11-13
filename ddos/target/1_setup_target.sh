#!/bin/bash
# =============================================================================
#  靶机 192.168.1.137 一键部署脚本（CentOS 7 / root）
# =============================================================================
#  功能:
#    1. 安装 Nginx / SSH / FTP(可选 Redis) / tcpdump 等基础软件
#    2. 关闭 firewalld、SELinux（演示环境需要，prod 请勿照搬）
#    3. 安装 Python 依赖 scapy/flask（自动选解释器：py3 -> flask==2.0.3；py2 -> flask==1.1.4）
#    4. 创建演示账户、日志目录
#    5. 配置 Nginx ddos 日志格式并重载
#    6. 部署 agent.py + index.html 到 /opt/ddos/
#    7. 安装 systemd 服务 ddos-agent 并启动
#
#  用法（在靶机上执行）:
#    # 拷贝整个 target/ 目录（含 index.html、nginx/、systemd/）到靶机，例如:
#    #   scp -r target/* root@192.168.1.137:/opt/ddos-setup/
#    bash 1_setup_target.sh
#
#  可调环境变量:
#    ADMIN_IP=192.168.1.130    管理机（客户端）IP（自动加入 agent 白名单）
#    SSR_IP=192.168.1.232      攻击机（攻击端）IP（默认也在白名单，观察真实封禁可注释）
#    WITH_REDIS=1              是否安装 redis（6379 爆破演示）
#    SKIP_PKG=1                跳过 yum/pip 安装（离线环境）
#    SKIP_NGINX=1              跳过 Nginx 配置修改
#    SKIP_START=1              只部署不启动服务
# =============================================================================
set -e

# ---------------------------- 参数区 -----------------------------------------
TARGET_IP="192.168.1.137"
ADMIN_IP="${ADMIN_IP:-192.168.1.130}"
SSR_IP="${SSR_IP:-192.168.1.232}"
WITH_REDIS="${WITH_REDIS:-0}"
SKIP_PKG="${SKIP_PKG:-0}"
SKIP_NGINX="${SKIP_NGINX:-0}"
SKIP_START="${SKIP_START:-0}"

APP_DIR="/opt/ddos"
LOG_DIR="/var/log/ddos"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"      # 本脚本所在的 target/ 目录
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

# ---------------------------- 工具函数 ---------------------------------------
say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

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

[ "$(id -u)" = "0" ] || die "请以 root 运行"
cd "$SRC_DIR"

say "===== 靶机 DDoS 演示环境部署开始 ====="
say "源目录: $SRC_DIR"
say "管理机白名单: $ADMIN_IP    攻击机: $SSR_IP"

# ---------------------------- 1. 基础软件 ------------------------------------
if [ "$SKIP_PKG" != "1" ]; then
    say "[1/7] 安装基础软件包"
    if ! rpm -q epel-release >/dev/null 2>&1; then
        yum install -y epel-release || warn "epel-release 安装失败（离线环境可忽略）"
    fi
    yum install -y nginx openssh-server vsftpd net-tools tcpdump iptables \
                   curl || die "yum 安装失败"
    # python36 优先（EPEL），装不上就回退系统自带 py2
    yum install -y python36 python36-pip >/dev/null 2>&1 \
        || warn "python36 不可用，回退系统自带 Python（py2）"
    if [ "$WITH_REDIS" = "1" ]; then
        yum install -y redis || warn "redis 安装失败"
    fi

    systemctl enable nginx sshd vsftpd
    systemctl start  nginx sshd vsftpd
    if [ "$WITH_REDIS" = "1" ]; then
        systemctl enable redis; systemctl start redis
    fi
    ok "基础软件安装完成"
else
    warn "[1/7] 跳过软件安装（SKIP_PKG=1）"
fi

# ---------------------------- 2. 安全策略 ------------------------------------
say "[2/7] 关闭 firewalld / SELinux，开放 FTP 匿名演示账户"
systemctl stop firewalld  2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
grep -q '^anonymous_enable' /etc/vsftpd/vsftpd.conf 2>/dev/null \
    && sed -i 's/^anonymous_enable=.*/anonymous_enable=NO/' /etc/vsftpd/vsftpd.conf && systemctl restart vsftpd
ok "firewalld 已停止，SELinux permissive"

# ---------------------------- 3. Python 依赖 ---------------------------------
# 先选解释器（py3 优先，回退 py2），按主版本装对应依赖版本
PY=$(py_bin)
[ -n "$PY" ] || die "未找到可用的 Python（python36/python3/python2/python）"
PY_MAJOR=$(py_major "$PY")
say "使用解释器: $PY (Python $PY_MAJOR) -> $(command -v "$PY")"

if [ "$SKIP_PKG" != "1" ]; then
    say "[3/7] 安装 Python 依赖 (scapy / flask)"
    ensure_pip "$PY" "$PY_MAJOR" || die "$PY 无 pip 模块（可安装 python2-pip/python36-pip 后重试）"
    if [ "$PY_MAJOR" = "3" ]; then
        "$PY" -m pip install -i "$PIP_MIRROR" --upgrade pip >/dev/null 2>&1 || true
        "$PY" -m pip install -i "$PIP_MIRROR" scapy==2.4.5 flask==2.0.3 \
            || die "pip 依赖安装失败"
    else
        # py2: 先升到最后一个支持 py2 的 pip，否则老 pip 不识别 python_requires 会装错版本
        "$PY" -m pip install -i "$PIP_MIRROR" "pip==20.3.4" >/dev/null 2>&1 \
            || warn "pip 升级到 20.3.4 失败，继续用现有 pip"
        "$PY" -m pip install -i "$PIP_MIRROR" scapy==2.4.5 flask==1.1.4 \
            || die "pip 依赖安装失败"
    fi
    "$PY" -c "import flask, scapy" >/dev/null 2>&1 \
        || die "依赖导入自检失败（$PY，$PY_MAJOR）"
    ok "Python 依赖安装完成（$PY, Python $PY_MAJOR）"
else
    warn "[3/7] 跳过 pip 安装（SKIP_PKG=1）"
fi

# ---------------------------- 4. 账户与日志目录 ------------------------------
say "[4/7] 创建演示账户 test/test 与日志目录"
id test >/dev/null 2>&1 || useradd test
echo 'test:123456' | chpasswd
mkdir -p "$LOG_DIR" "$APP_DIR"
chmod 755 "$LOG_DIR"
[ -f "$LOG_DIR/blocks.jsonl" ] || : > "$LOG_DIR/blocks.jsonl"
ok "演示账户: test / 123456，日志目录: $LOG_DIR"

# ---------------------------- 5. Nginx 日志格式 ------------------------------
if [ "$SKIP_NGINX" != "1" ]; then
    say "[5/7] 配置 Nginx ddos 日志格式"
    NGINX_CONF="/etc/nginx/nginx.conf"
    cp -n "$NGINX_CONF" "$NGINX_CONF.bak.ddos" 2>/dev/null || true
    if grep -q 'log_format ddos' "$NGINX_CONF"; then
        ok "已存在 log_format ddos，跳过"
    else
        # 在 http 配置块起始行的下一行插入片段内容（片段只含 http 级指令）
        # 说明: 此处用字符集合包裹花括号，保证脚本自身的花括号计数平衡
        TMP=$(mktemp)
        awk -v frag="$(cat "$SRC_DIR/nginx/ddos.conf")" '
            { print }
            /^[[:space:]]*http[[:space:]]*[\{]/ && !done { print frag; done=1 }
        ' "$NGINX_CONF" > "$TMP"
        if grep -q 'log_format ddos' "$TMP"; then
            mv "$TMP" "$NGINX_CONF"
            ok "已插入 log_format ddos"
        else
            rm -f "$TMP"
            warn "未找到 http 配置块，请手工把 nginx/ddos.conf 内容加入 $NGINX_CONF"
        fi
    fi
    nginx -t && systemctl reload nginx && ok "Nginx 重载完成" || warn "nginx -t 失败，请检查配置"
else
    warn "[5/7] 跳过 Nginx 配置（SKIP_NGINX=1）"
fi

# ---------------------------- 6. 部署 agent ----------------------------------
say "[6/7] 部署 agent.py / index.html 到 $APP_DIR"
[ -f "$SRC_DIR/agent.py" ]   || die "缺少 agent.py"
[ -f "$SRC_DIR/index.html" ] || die "缺少 index.html（面板已与 agent 分离独立部署）"
install -m 755 "$SRC_DIR/agent.py"   "$APP_DIR/agent.py"
install -m 644 "$SRC_DIR/index.html" "$APP_DIR/index.html"
mkdir -p "$APP_DIR/nginx"
[ -f "$SRC_DIR/nginx/ddos.conf" ] && install -m 644 "$SRC_DIR/nginx/ddos.conf" "$APP_DIR/nginx/ddos.conf"

# 白名单按部署参数落地（改 agent.py 顶部 WHITELIST 亦可）
sed -i "s/\"192.168.1.130\"/\"$ADMIN_IP\"/" "$APP_DIR/agent.py"
if [ -n "$SSR_IP" ]; then
    sed -i "s/\"192.168.1.232\"/\"$SSR_IP\"/" "$APP_DIR/agent.py"
fi
PY=${PY:-$(py_bin)}
[ -n "$PY" ] || die "未找到可用的 Python（python36/python3/python2/python）"
"$PY" -m py_compile "$APP_DIR/agent.py" && ok "agent.py 语法检查通过（$PY）"

# systemd（按实际解释器的绝对路径修正 ExecStart）
if [ -f "$SRC_DIR/systemd/ddos-agent.service" ]; then
    install -m 644 "$SRC_DIR/systemd/ddos-agent.service" /etc/systemd/system/ddos-agent.service
    PY_ABS=$(command -v "$PY")
    sed -i "s#^ExecStart=[^ ]* #ExecStart=$PY_ABS #" /etc/systemd/system/ddos-agent.service
    systemctl daemon-reload
    systemctl enable ddos-agent
    ok "systemd 单元已安装（ExecStart=$PY_ABS）"
fi

# ---------------------------- 7. 启动 ----------------------------------------
if [ "$SKIP_START" != "1" ]; then
    say "[7/7] 启动 agent"
    systemctl restart ddos-agent || die "ddos-agent 启动失败，查看: journalctl -u ddos-agent -n 50"
    sleep 2
    systemctl --no-pager status ddos-agent | head -n 12
    IP=$(hostname -I | awk '{print $1}')
    ok "面板地址: http://$TARGET_IP:5000/ （本机: http://${IP:-127.0.0.1}:5000/）"
    curl -s -m 3 "http://127.0.0.1:5000/api/stats" | head -c 300; echo
else
    warn "[7/7] 跳过启动（SKIP_START=1），手工: systemctl start ddos-agent"
fi

say "===== 部署完成 ====="
cat <<EOF

 提示：
   1) 管理机 $ADMIN_IP 必须在 agent 的 WHITELIST 中（本脚本已写入）。
   2) 若攻击机 $SSR_IP 也需要被封禁，请编辑 $APP_DIR/agent.py 顶部 WHITELIST 删除该行，
      然后 systemctl restart ddos-agent。
   3) 常用命令：
        systemctl status ddos-agent
        journalctl -u ddos-agent -f
        iptables -S INPUT | grep DDoS_BLOCK
        tail -f $LOG_DIR/blocks.jsonl
   4) 实验顺序建议：先测爆破/扫描（真实 IP，会被全端口封），再测伪造源 flood。

EOF
