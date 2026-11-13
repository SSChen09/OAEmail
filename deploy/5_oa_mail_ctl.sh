#!/bin/bash
# =============================================================================
#  服务端 OA + 邮箱系统 一键启停脚本（带自检）   靶机 192.168.1.137 / root
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
#    webmail API / 文件共享 API / IMAP 登录(eva) / SMTP 本机提交
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
MAIL_DOMAIN="ddzt.old"
EVAPASS="eva"   # 演示账号 eva@$MAIL_DOMAIN 的口令（自检 IMAP 登录用）

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
  status  只读体检（check 同义）: 服务/端口/OA首页/webmail API/文件共享/IMAP/SMTP
说明: 幂等可重复执行；FAIL 时退出码非 0；只管辖 OA/邮件，不动
      sshd / redis / vsftpd / ddos-agent
EOF
    exit 0
}

port_listening() {   # $1=port
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

wait_port() {        # $1=port  $2=up|down （up 等 15s，down 等 5s）
    local i n=15
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
    curl -s -m 5 -X POST -d 'action=me' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/mail.php 2>/dev/null | grep -q '"ok"' \
        && vok "webmail API 响应正常 (api/mail.php)" \
        || vfail "webmail API 无响应（php-fpm / nginx fastcgi）"
    curl -s -m 5 -X POST -d 'action=list' -H "Host: $MAIL_DOMAIN" http://127.0.0.1/api/files.php 2>/dev/null | grep -q '"ok":true' \
        && vok "文件共享 API 响应正常 (api/files.php)" \
        || vfail "文件共享 API 无响应"
    say "-- [邮件链路] --"
    python3 -c "import imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login('eva@$MAIL_DOMAIN','$EVAPASS'); print('IMAP_OK')" >/dev/null 2>&1 \
        && vok "IMAP 登录 eva@$MAIL_DOMAIN 可用（dovecot）" \
        || vfail "IMAP 登录失败（dovecot / 认证配置）"
    python3 -c "import smtplib; s=smtplib.SMTP('127.0.0.1'); s.ehlo(); s.quit(); print('SMTP_OK')" >/dev/null 2>&1 \
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
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)
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
    status|check) say "只读体检（不改动任何服务）";  check_up;   summary ;;
    *)         die "未知命令: $CMD（bash $0 --help 查看用法）" ;;
esac
