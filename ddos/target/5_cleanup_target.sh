#!/bin/bash
# =============================================================================
#  靶机 192.168.1.137 一键关闭与清理脚本（CentOS 7 / root）
# =============================================================================
#  功能:
#    默认        : 1) 停止并禁用 ddos-agent 服务
#                  2) 杀掉残留 agent.py 进程（含 nohup / 手工前台启动的副本）
#                  3) 清除 iptables 中全部 DDoS_BLOCK 封禁规则（-A/-I 两种形态都处理）
#                  4) 清理临时脚本，确认 5000 端口释放
#    --purge     : 额外删除部署产物——systemd 单元、/opt/ddos、/var/log/ddos、
#                  演示账户 test，并从 .bak.ddos 备份恢复 nginx.conf 后重载
#    --stop-services      : 额外停止并禁用演示受害服务 nginx / vsftpd
#    --restore-firewall   : 重新启用 firewalld + SELinux enforcing
#                  （警告：若防火墙默认策略未放行 SSH，远程连接会立即断开，
#                    建议在控制台执行）
#    --dry-run   : 只打印将执行的动作，不做任何改动
#    -h / --help : 帮助
#
#  用法（在靶机上执行）:
#    bash 5_cleanup_target.sh                # 一键关闭（安全默认，保留代码与日志）
#    bash 5_cleanup_target.sh --purge        # 关闭 + 彻底清理部署产物
#    bash 5_cleanup_target.sh --dry-run      # 预览将执行的动作
#
#  保留不动: /root/test_ddos/（手工拷贝的源码/面板）以及 pip 依赖。
#  演示账户 test 删除后可用 1_setup_target.sh 重新创建。
# =============================================================================
set -u

APP_DIR="/opt/ddos"
LOG_DIR="/var/log/ddos"
UNIT_FILE="/etc/systemd/system/ddos-agent.service"
NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_BAK="/etc/nginx/nginx.conf.bak.ddos"
BLOCK_TAG="DDoS_BLOCK"
TMP_SCRIPTS="/tmp/_probe.sh /tmp/_p130.sh /tmp/_p5000.sh /tmp/_restart.sh /tmp/x.sh"

PURGE=0
STOP_SVC=0
RESTORE_FW=0
DRY=0

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }
dry()  { echo -e "\033[1;35m[dry]\033[0m $*"; }

usage() {
    sed -n '2,26p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)            PURGE=1 ;;
        --stop-services)    STOP_SVC=1 ;;
        --restore-firewall) RESTORE_FW=1 ;;
        --dry-run)          DRY=1 ;;
        -h|--help)          usage ;;
        *) die "未知参数: $1 （bash $0 --help 查看用法）" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || die "请以 root 运行（需要操作 systemd / iptables）"

if [ "$DRY" = "1" ]; then
    say "===== 靶机一键关闭与清理（DRY-RUN 预览，不实际改动） ====="
else
    say "===== 靶机一键关闭与清理开始 ====="
fi

# ---------------------------- 1. 停止 agent 服务与进程 -----------------------
say "[1/4] 停止 ddos-agent 服务"
if systemctl list-unit-files ddos-agent.service 2>/dev/null | grep -q ddos-agent; then
    if [ "$DRY" = "1" ]; then
        dry "systemctl stop ddos-agent"
        dry "systemctl disable ddos-agent"
    else
        systemctl stop ddos-agent 2>/dev/null || warn "ddos-agent 服务未在运行"
        systemctl disable ddos-agent 2>/dev/null || true
        ok "ddos-agent 已停止并取消开机自启"
    fi
else
    warn "未安装 ddos-agent 服务（可能为手工启动方式）"
fi

PIDS=$(pgrep -f 'agent\.py' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    say "发现 agent.py 残留进程: $(echo $PIDS | tr '\n' ' ')"
    if [ "$DRY" = "1" ]; then
        dry "pkill -f 'agent\\.py' （必要时 kill -9）"
    else
        pkill -f 'agent\.py' 2>/dev/null || true
        sleep 2
        PIDS=$(pgrep -f 'agent\.py' 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            warn "常规终止未生效，强杀: $(echo $PIDS | tr '\n' ' ')"
            kill -9 $PIDS 2>/dev/null || true
            sleep 1
        fi
        pgrep -f 'agent\.py' >/dev/null 2>&1 \
            && warn "仍有 agent.py 进程残留，请手工检查" \
            || ok "agent.py 进程已全部退出"
    fi
else
    ok "无 agent.py 进程"
fi

# ---------------------------- 2. 清理 iptables 封禁规则 ----------------------
say "[2/4] 清理 iptables 中的 $BLOCK_TAG 规则"
RULES=$(iptables -S INPUT 2>/dev/null | grep "$BLOCK_TAG" || true)
if [ -z "$RULES" ]; then
    ok "无 $BLOCK_TAG 残留规则"
else
    N=$(echo "$RULES" | wc -l)
    say "待清理 $N 条规则"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # iptables -S 输出形如 "-A INPUT <spec>"，删除时换成 "-D INPUT <spec>"
        DEL_ARGS="-D INPUT ${line#-A INPUT}"
        if [ "$DRY" = "1" ]; then
            dry "iptables $DEL_ARGS"
        else
            # shellcheck disable=SC2086
            iptables $DEL_ARGS >/dev/null 2>&1 \
                || warn "删除失败: iptables $DEL_ARGS"
        fi
    done <<EOF
$RULES
EOF
    if [ "$DRY" != "1" ]; then
        LEFT=$(iptables -S INPUT 2>/dev/null | grep -c "$BLOCK_TAG" || true)
        [ "${LEFT:-0}" -eq 0 ] && ok "封禁规则已全部清除" \
            || warn "仍残留 $LEFT 条规则，请手工检查: iptables -S INPUT | grep $BLOCK_TAG"
    fi
fi

# ---------------------------- 3. 清理临时脚本 --------------------------------
say "[3/4] 清理临时脚本"
for f in $TMP_SCRIPTS; do
    [ -e "$f" ] || continue
    if [ "$DRY" = "1" ]; then
        dry "rm -f $f"
    else
        rm -f "$f" && ok "已删除 $f"
    fi
done

# ---------------------------- 4. 彻底清理（--purge） -------------------------
if [ "$PURGE" = "1" ]; then
    say "[4/4] --purge：删除部署产物"
    if [ "$DRY" = "1" ]; then
        [ -f "$UNIT_FILE" ] && dry "rm -f $UNIT_FILE && systemctl daemon-reload"
        [ -d "$APP_DIR" ]   && dry "rm -rf $APP_DIR"
        [ -d "$LOG_DIR" ]   && dry "rm -rf $LOG_DIR（含 blocks.jsonl 等审计日志）"
        dry "userdel test（若存在）"
        grep -q 'log_format ddos' "$NGINX_CONF" 2>/dev/null && dry "从 $NGINX_BAK 恢复 nginx.conf 并 reload"
    else
        if [ -f "$UNIT_FILE" ]; then
            rm -f "$UNIT_FILE" && systemctl daemon-reload && ok "systemd 单元已删除"
        fi
        if [ -d "$APP_DIR" ]; then
            rm -rf "$APP_DIR" && ok "已删除 $APP_DIR"
        fi
        if [ -d "$LOG_DIR" ]; then
            rm -rf "$LOG_DIR" && ok "已删除 $LOG_DIR（含审计日志）"
        fi
        if id test >/dev/null 2>&1; then
            userdel test 2>/dev/null && ok "演示账户 test 已删除" || warn "test 账户删除失败"
        fi
        if grep -q 'log_format ddos' "$NGINX_CONF" 2>/dev/null; then
            if [ -f "$NGINX_BAK" ]; then
                cp -f "$NGINX_BAK" "$NGINX_CONF" && nginx -t >/dev/null 2>&1 \
                    && systemctl reload nginx 2>/dev/null \
                    && ok "nginx.conf 已从备份恢复并重载" \
                    || warn "nginx 恢复失败，请手工检查 $NGINX_CONF"
            else
                warn "无 $NGINX_BAK 备份，log_format ddos 保留（无害），可手工删除"
            fi
        fi
    fi
else
    say "[4/4] 保留部署产物（如需删除请加 --purge）"
fi

# ---------------------------- 可选：停止演示受害服务 -------------------------
if [ "$STOP_SVC" = "1" ]; then
    say "--stop-services：停止 nginx / vsftpd"
    for s in nginx vsftpd; do
        if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service"; then
            if [ "$DRY" = "1" ]; then
                dry "systemctl stop $s && systemctl disable $s"
            else
                systemctl stop "$s" 2>/dev/null && systemctl disable "$s" 2>/dev/null \
                    && ok "$s 已停止并取消自启" || warn "$s 停止失败或未安装"
            fi
        fi
    done
fi

# ---------------------------- 可选：恢复安全策略 -----------------------------
if [ "$RESTORE_FW" = "1" ]; then
    warn "--restore-firewall：将重新启用 firewalld 并恢复 SELinux enforcing"
    warn "若防火墙默认策略未放行 SSH，远程连接会立即断开，建议在控制台执行！"
    if [ "$DRY" = "1" ]; then
        dry "systemctl enable --now firewalld"
        dry "sed -i SELINUX=enforcing /etc/selinux/config && setenforce 1"
    else
        systemctl enable --now firewalld 2>/dev/null && ok "firewalld 已启用" \
            || warn "firewalld 启用失败"
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        setenforce 1 2>/dev/null && ok "SELinux enforcing 已生效（重启后仍为 enforcing）" \
            || warn "setenforce 失败（可能未装 SELinux）"
    fi
fi

# ---------------------------- 结果确认 ---------------------------------------
say "===== 结果确认 ====="
if [ "$DRY" = "1" ]; then
    dry "以上为预览；去掉 --dry-run 才会实际执行"
    exit 0
fi
if ss -lntp 2>/dev/null | grep -q ':5000 '; then
    warn "5000 端口仍被占用: $(ss -lntp 'sport = :5000' | tail -n +2)"
else
    ok "5000 端口已释放"
fi
LEFT=$(iptables -S INPUT 2>/dev/null | grep -c "$BLOCK_TAG" || true)
[ "${LEFT:-0}" -eq 0 ] && ok "iptables 无 $BLOCK_TAG 规则" || warn "iptables 仍有 $LEFT 条 $BLOCK_TAG 规则"
pgrep -f 'agent\.py' >/dev/null 2>&1 && warn "仍有 agent.py 进程" || ok "无 agent.py 进程"
ok "===== 完成 ====="
