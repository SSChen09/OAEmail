#!/bin/bash
# =============================================================================
#  服务端 OA + 邮箱系统 一键启停脚本（带自检）   靶机 192.168.3.152 / root
# =============================================================================
#  功能:
#    start   : 启动 OA(nginx / php-fpm / mariadb) + 邮件(postfix / dovecot)，
#              随后自检（期望：全部在线）
#    stop    : 停止以上 5 个服务，随后自检（期望：全部离线、端口释放）
#    restart : 先停后启 + 自检（期望：全部在线）
#    status  : 只读体检（check 同义），不改动任何服务
#
#  自检内容（真实链路，不是只看进程）:
#    服务状态 / 端口 80 9000 3306 25 110 143 / OA 首页 HTTP /
#    webmail API / 文件共享 API / OA 登录 API / OA-邮箱自动关联 /
#    IMAP 登录(eva、admin) / SMTP 本机提交
#
#  说明:
#    * 幂等，可反复执行；自检汇总 PASS/FAIL/WARN，FAIL 时退出码非 0
#    * 只管辖 OA/邮件 5 个服务；不动 sshd / redis / vsftpd / ddos-agent
#      （DDoS 防护端由 /root/test/ddos/target/ 的脚本独立管理）
#  用法:
#    bash 5_oa_mail_ctl.sh start|stop|restart|status
# =============================================================================
set -u

OA_SVC="nginx php-fpm mariadb"
MAIL_SVC="postfix dovecot"
ALL_SVC="$OA_SVC $MAIL_SVC"
OA_PORT="80 9000 3306"
MAIL_PORT="25 110 143"
MAIL_DOMAIN="${MAIL_DOMAIN:-ddzt.old}"
EVAPASS="${EVAPASS:-rei}"   # eva@$MAIL_DOMAIN 口令（与 OA 门户一致，自检 IMAP 登录用）
ADMINPASS="${ADMINPASS:-admin}"  # admin@$MAIL_DOMAIN 口令（自检管理员角色用）
WAIT_TIMEOUT=15             # 端口等待上限（秒）；status 只读体检时用更短的值
# 自检用解释器：py3 优先，回退 py2（imaplib/smtplib 两者都有）
PYBIN="${PYBIN:-$(command -v python3 || command -v python36 || command -v python2 || command -v python || echo python3)}"

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

PASS=0; FAIL=0; WARNS=0
vok()   { PASS=$((PASS+1)); ok "$*"; }
vfail() { FAIL=$((FAIL+1)); echo -e "\033[1;31m[x]\033[0m $*"; }
vwarn() { WARNS=$((WARNS+1)); warn "$*"; }

usage() {
    cat <<'EOF'
用法: bash 5_oa_mail_ctl.sh {start|stop|restart|status}
  start   启动 OA(nginx/php-fpm/mariadb) + 邮件(postfix/dovecot) 并自检(应在线)
  stop    停止以上服务并自检(应离线、端口释放)
  restart 先停后启 + 自检(应在线)
  status  只读体检（check 同义）: 服务/端口/OA首页/webmail API/文件共享/OA登录/IMAP/SMTP
说明: 幂等可重复执行；FAIL 时退出码非 0；只管辖 OA/邮件，不动
      sshd / redis / vsftpd / ddos-agent
EOF
    exit 0
}

port_listening() {   # $1=port
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

wait_port() {        # $1=port  $2=up|down （up 等 WAIT_TIMEOUT，down 等 5s）
    local i n="$WAIT_TIMEOUT"
    [ "$2" = "down" ] && n=5
    for i in $(seq 1 "$n"); do
        if [ "$2" = "up" ]; then
            port_listening "$1" && return 0
        else
            port_listening "$1" || return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------- 启 / 停 ----------------------------------------
do_start() {
    say "===== 启动 OA + 邮箱系统 ====="
    for s in $ALL_SVC; do
        systemctl start "$s" 2>/dev/null \
            && ok "已启动 $s" || warn "启动 $s 返回异常（自检会判定结果）"
    done
}

do_stop() {
    say "===== 停止 OA + 邮箱系统 ====="
    for s in $ALL_SVC; do
        systemctl stop "$s" 2>/dev/null \
            && ok "已停止 $s" || warn "停止 $s 返回异常（可能本就未运行）"
    done
}

# ---------------------------- 自检 -------------------------------------------
check_up() {
    say "===== 自检开始（期望：全部在线） ====="
    say "-- [服务] --"
    for s in $ALL_SVC; do
        systemctl is-active --quiet "$s" \
            && vok "服务 $s 运行中" || vfail "服务 $s 未运行（journalctl -u $s -n 30）"
    done
    say "-- [端口] --"
    for p in $OA_PORT $MAIL_PORT; do
        wait_port "$p" up && vok "端口 $p 已监听" || vfail "端口 $p 未监听"
    done
    say "-- [OA 应用链路] --"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/ 2>/dev/null)
    if [ "$code" = "200" ]; then
        vok "OA 首页 HTTP 200 (Host: $MAIL_DOMAIN)"
    else
        vfail "OA 首页不可达（HTTP ${code:-无响应}）"
    fi
    curl -s -m 5 -X POST -d 'action=me' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/mail.php 2>/dev/null | $PYBIN -c 'import sys,json; d=json.load(sys.stdin); assert "ok" in d' >/dev/null 2>&1 \
        && vok "webmail API 响应正常 (api/mail.php)" \
        || vfail "webmail API 无响应（php-fpm / nginx fastcgi）"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST -d 'action=list' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/files.php 2>/dev/null)
    if [ "$code" = "401" ]; then
        vok "文件共享 API 未登录 401 (api/files.php)"
    else
        vfail "文件共享 API 异常（未登录 HTTP ${code:-无响应}）"
    fi
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $MAIL_DOMAIN" "http://127.0.0.1/api/content.php?action=data" 2>/dev/null)
    if [ "$code" = "401" ]; then
        vok "公告/日程接口未登录 401 (api/content.php)"
    else
        vfail "公告/日程接口异常（未登录 HTTP ${code:-无响应}）"
    fi
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: $MAIL_DOMAIN" "http://127.0.0.1/api/todos.php?action=list" 2>/dev/null)
    if [ "$code" = "401" ]; then
        vok "个人待办接口未登录 401 (api/todos.php)"
    else
        vfail "个人待办接口异常（未登录 HTTP ${code:-无响应}）"
    fi
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST -d 'action=me' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/auth.php 2>/dev/null)
    if [ "$code" = "401" ]; then
        vok "OA 登录接口响应正常（未登录 401，api/auth.php）"
    else
        vfail "OA 登录接口异常（HTTP ${code:-无响应}）"
    fi
    # 角色权限：admin 登录返回管理员角色；文件上传未登录必须 401
    if curl -s -m 5 -X POST -d "action=login&username=admin@ddzt.old&password=$ADMINPASS" -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/auth.php 2>/dev/null | grep -q '"role":"admin"'; then
        vok "OA 登录返回管理员角色（admin）"
    else
        vfail "OA 登录角色异常（admin 应为 admin）"
    fi
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST -d 'action=upload' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/files.php 2>/dev/null)
    if [ "$code" = "401" ]; then
        vok "文件上传未登录被拒绝（401）"
    else
        vfail "文件上传权限异常（未登录 HTTP ${code:-无响应}）"
    fi
    # OA 登录后应自动建立邮箱会话（同一套账号口令）
    _jar=$(mktemp)
    curl -s -m 5 -c "$_jar" -X POST -d "action=login&username=eva@ddzt.old&password=$EVAPASS" -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/auth.php >/dev/null 2>&1
    if curl -s -m 5 -b "$_jar" -X POST -d 'action=me' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/mail.php 2>/dev/null | grep -q "eva@$MAIL_DOMAIN"; then
        vok "OA 登录后邮箱自动关联（免二次登录）"
    else
        vfail "OA 登录后邮箱未自动关联（检查 auth.php / 邮箱用户口令）"
    fi
    # 公告/日程：登录后可读；普通账号写入必须 403
    if curl -s -m 5 -b "$_jar" -H "Host: $MAIL_DOMAIN" "http://127.0.0.1/api/content.php?action=data" 2>/dev/null | grep -q '"notices"'; then
        vok "公告/日程接口登录后可读 (api/content.php)"
    else
        vfail "公告/日程接口读取失败（检查 /var/www/oa-data 权限）"
    fi
    if curl -s -m 5 -b "$_jar" -H "Host: $MAIL_DOMAIN" "http://127.0.0.1/api/todos.php?action=list" 2>/dev/null | grep -q '"todos"'; then
        vok "个人待办接口登录后可读 (api/todos.php)"
    else
        vfail "个人待办接口读取失败（检查 /var/www/oa-data 权限）"
    fi
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -b "$_jar" -X POST -d 'action=notice_save&title=x&dept=x&date=2026-01-01' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/content.php 2>/dev/null)
    if [ "$code" = "403" ]; then
        vok "普通账号写入公告被拒绝（403，仅管理员可写）"
    else
        vfail "公告写入权限异常（eva 应被拒绝，实际 HTTP ${code:-无响应}）"
    fi
    rm -f "$_jar"
    # DDoS 面板同源反代（信息性：面板是否部署不影响 OA/邮件本身）
    curl -s -m 5 -H "Host: $MAIL_DOMAIN" http://127.0.0.1/ddos/api/stats 2>/dev/null | grep -q '"auto"' \
        && vok "DDoS 面板反代 /ddos/api/stats 可用" \
        || vwarn "DDoS 面板反代不可用（/ddos/ 需要 ddos-agent 在 5000 端口运行）"
    [ -f /var/www/oa/api/files.php ] && vok "文件共享后端文件存在" \
        || vfail "缺少 /var/www/oa/api/files.php（重跑 4_oa_mail_setup.sh）"
    [ -f /var/www/oa/api/auth.php ] && vok "OA 登录后端文件存在" \
        || vfail "缺少 /var/www/oa/api/auth.php（重跑 4_oa_mail_setup.sh）"
    [ -f /var/www/oa/api/users.php ] && vok "OA 账号配置文件存在" \
        || vfail "缺少 /var/www/oa/api/users.php（重跑 4_oa_mail_setup.sh）"
    [ -f /var/www/oa/api/content.php ] && vok "公告/日程后端文件存在" \
        || vfail "缺少 /var/www/oa/api/content.php（重跑 4_oa_mail_setup.sh）"
    [ -f /var/www/oa-data/content.json ] && vok "公告/日程数据文件存在" \
        || vfail "缺少 /var/www/oa-data/content.json（重跑 4_oa_mail_setup.sh）"
    [ -f /var/www/oa/api/todos.php ] && vok "个人待办后端文件存在" \
        || vfail "缺少 /var/www/oa/api/todos.php（重跑 4_oa_mail_setup.sh）"
    say "-- [邮件链路] --"
    env IMAP_USER="eva@$MAIL_DOMAIN" IMAP_PASS="$EVAPASS" "$PYBIN" -c "import os,imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login(os.environ['IMAP_USER'], os.environ['IMAP_PASS']); print('IMAP_OK')" >/dev/null 2>&1 \
        && vok "IMAP 登录 eva@$MAIL_DOMAIN 可用（dovecot）" \
        || vfail "IMAP 登录失败（dovecot / 认证配置）"
    env IMAP_USER="admin@$MAIL_DOMAIN" IMAP_PASS="${ADMINPASS:-admin}" "$PYBIN" -c "import os,imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login(os.environ['IMAP_USER'], os.environ['IMAP_PASS']); print('IMAP_OK')" >/dev/null 2>&1 \
        && vok "IMAP 登录 admin@$MAIL_DOMAIN 可用（dovecot）" \
        || vfail "IMAP 登录 admin@$MAIL_DOMAIN 失败（admin 邮箱未开通）"
    "$PYBIN" -c "import smtplib; s=smtplib.SMTP('127.0.0.1'); s.ehlo(); s.quit(); print('SMTP_OK')" >/dev/null 2>&1 \
        && vok "SMTP 本机提交可用（postfix）" \
        || vfail "SMTP 提交失败（postfix）"
}

check_down() {
    say "===== 自检开始（期望：全部离线） ====="
    say "-- [服务] --"
    for s in $ALL_SVC; do
        systemctl is-active --quiet "$s" \
            && vfail "服务 $s 仍在运行" || vok "服务 $s 已停止"
    done
    say "-- [端口] --"
    for p in $OA_PORT $MAIL_PORT; do
        wait_port "$p" down && vok "端口 $p 已释放" || vfail "端口 $p 仍被监听"
    done
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/ 2>/dev/null)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        vok "Web 服务已不可访问"
    else
        vwarn "HTTP 仍有响应（$code），请确认 80 端口属于哪个进程"
    fi
}

summary() {
    echo
    say "===== 自检汇总: PASS=$PASS  FAIL=$FAIL  WARN=$WARNS ====="
    [ "$FAIL" -gt 0 ] && die "自检未通过"
    ok "自检通过"
}

# ---------------------------- 入口 -------------------------------------------
[ "$(id -u)" = "0" ] || die "请以 root 运行"
CMD="${1:-status}"
case "$CMD" in
    -h|--help) usage ;;
    start)     do_start;              check_up;   summary ;;
    stop)      do_stop;               check_down; summary ;;
    restart)   do_stop; do_start;     check_up;   summary ;;
    status|check) say "只读体检（不改动任何服务）"; WAIT_TIMEOUT=3; check_up; summary ;;
    *)         die "未知命令: $CMD（bash $0 --help 查看用法）" ;;
esac
