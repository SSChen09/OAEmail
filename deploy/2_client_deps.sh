#!/bin/bash
# =============================================================================
#  客户端 192.168.1.130 一键安装系统依赖脚本（含校验）
#  依据: 配置.md —— 客户端职责: 浏览器访问 OA、发送邮件（邮件发送在 OA 系统中）
#  系统: CentOS 7 / root
# =============================================================================
#  覆盖依赖:
#    [访问OA]   firefox 浏览器（访问 http://$OA_HOST/）
#    [邮件]     thunderbird 邮件客户端（收发验证 eva@ddzt.old / kk@ddzt.old，
#               正常业务发信在 OA 系统内完成，客户端备用）
#    [通用]     curl/wget/vim/net-tools/tcpdump/bind-utils/jq
#    [可选]     python3 + requests（便于用脚本调 OA/面板 API 验证）
#    [内网域名] /etc/hosts 写入 ddzt.old 等（纯内网、无公网 DNS）
#
#  用法:
#    bash 2_client_deps.sh            # 一键安装 + 校验
#    bash 2_client_deps.sh --check    # 仅校验（可重复执行）
#
#  可调环境变量:
#    CLIENT_IP=192.168.1.130  SERVER_IP=192.168.1.137  MAIL_DOMAIN=ddzt.old
#  校验: 命令存在/版本/域名解析 + 对服务端的连通性检查（信息性），
#        末尾输出 PASS/FAIL/WARN 汇总，存在 FAIL 时退出码非 0。
# =============================================================================
set -u

CLIENT_IP="${CLIENT_IP:-192.168.1.130}"
SERVER_IP="${SERVER_IP:-192.168.1.137}"
MAIL_DOMAIN="${MAIL_DOMAIN:-ddzt.old}"
OA_URL="http://$SERVER_IP/"
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
# vinfo "说明" 命令...   信息性检查（不影响成败）
vinfo() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASS=$((PASS+1))
    else
        warn "$desc — 服务端可能尚未部署，稍后可复查"; WARNS=$((WARNS+1))
    fi
}

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# =============================================================================
#  一、安装（--check 跳过）
# =============================================================================
if [ "$CHECK_ONLY" = "0" ]; then

    say "===== [1/4] 通用基础工具 ====="
    yum install -y yum-utils net-tools tcpdump wget curl vim bind-utils jq unzip tar \
        || warn "基础工具安装有失败项"

    say "===== [2/4] [访问OA] firefox 浏览器 ====="
    yum install -y firefox || warn "firefox 安装失败（无法浏览器访问 OA）"

    say "===== [3/4] [邮件] thunderbird 邮件客户端 ====="
    yum install -y thunderbird || warn "thunderbird 安装失败（可用 OA 网页邮箱替代）"

    say "===== [4/4] [可选] python3 + requests + [内网域名] /etc/hosts ====="
    yum install -y python3 python3-pip >/dev/null 2>&1 \
        || yum install -y python36 python36-pip >/dev/null 2>&1 \
        || warn "python3 安装失败（不影响浏览器使用）"
    pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple requests >/dev/null 2>&1 \
        || pip3 install -i https://mirrors.aliyun.com/pypi/simple requests >/dev/null 2>&1 \
        || warn "requests 安装失败（不影响浏览器使用）"
    for d in "$MAIL_DOMAIN" "mail.$MAIL_DOMAIN" "www.$MAIL_DOMAIN" "oa.$MAIL_DOMAIN"; do
        if grep -qE "[[:space:]]$d([[:space:]]|$)" /etc/hosts; then
            ok "/etc/hosts 已含 $d"
        else
            echo "$SERVER_IP  $d" >> /etc/hosts && ok "写入 /etc/hosts: $SERVER_IP $d"
        fi
    done
fi

# =============================================================================
#  二、校验
# =============================================================================
say "===== 校验开始 ====="

say "-- [访问OA] 浏览器 --"
vver "firefox" firefox --version

say "-- [邮件] 客户端 --"
vver "thunderbird" thunderbird --version

say "-- [通用] 工具 --"
vver "curl"  curl --version
vver "wget"  wget --version
vcmd "jq 可用" jq --version
vcmd "dig/nslookup 可用 (bind-utils)" dig -v

say "-- [可选] python --"
if command -v python3 >/dev/null 2>&1; then
    vver "python3" python3 --version
    vcmd "requests 可导入" python3 -c "import requests"
else
    warn "无 python3（可选组件）"; WARNS=$((WARNS+1))
fi

say "-- [内网域名解析] --"
vhosts "$MAIL_DOMAIN"
vhosts "mail.$MAIL_DOMAIN"

say "-- [本机 IP 自检] --"
if ip -o -4 addr show 2>/dev/null | grep -q "inet $CLIENT_IP/"; then
    ok "本机 IP 即约定客户端 $CLIENT_IP"; PASS=$((PASS+1))
else
    warn "本机 IP 不是 $CLIENT_IP，请确认脚本部署对象"; WARNS=$((WARNS+1))
fi

say "-- [服务端连通性]（信息性，服务端部署后转 PASS）--"
vinfo "ping $SERVER_IP 可达"       ping -c 1 -W 2 "$SERVER_IP"
vinfo "OA Web 端口 80 可访问"      bash -c "curl -s -m 4 -o /dev/null -w '%{http_code}' '$OA_URL' | grep -qv '000'"
vinfo "邮件 SMTP 端口 25 可访问"   bash -c "timeout 3 bash -c '</dev/tcp/$SERVER_IP/25'"
vinfo "OA 域名 $MAIL_DOMAIN 可访问" bash -c "curl -s -m 4 -o /dev/null 'http://$MAIL_DOMAIN/'"

# =============================================================================
#  三、汇总
# =============================================================================
echo
say "===== 校验汇总: PASS=$PASS  FAIL=$FAIL  WARN=$WARNS ====="
if [ "$FAIL" -gt 0 ]; then
    die "存在 $FAIL 项失败，请按上方 [x] 标记逐项排查"
fi
ok "客户端依赖安装/校验通过（浏览器访问 OA + 邮件）"
ok "下一步: 浏览器打开 $OA_URL 或 http://$MAIL_DOMAIN/ 验证 OA 可用"
exit 0
