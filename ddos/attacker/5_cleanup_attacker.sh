#!/bin/bash
# =============================================================================
#  攻击机 192.168.1.232 一键关闭与清理脚本（CentOS 7 / root）
# =============================================================================
#  功能:
#    默认        : 1) 停止全部 attacker.py 进程（含 multiprocessing 的 syn/udp/
#                     multi-port/brute 子进程与 nohup 残留实例）
#                  2) 清理临时脚本
#                  3) 确认无发包进程存活（scapy 伪造源 flood 随进程退出即停）
#    --purge     : 额外删除部署产物——/opt/ddos、/usr/local/bin/ddos-attack、
#                  __pycache__（pip 依赖 scapy/requests/paramiko 保留，可选卸载见文末）
#    --restore-firewall   : 重新启用 firewalld（部署时被 2_setup_attacker.sh 停用）
#                  （警告：若防火墙默认策略未放行 SSH，远程连接会立即断开，
#                    建议在控制台执行）
#    --dry-run   : 只打印将执行的动作，不做任何改动
#    -h / --help : 帮助
#
#  用法（在攻击机上执行）:
#    bash 5_cleanup_attacker.sh               # 一键关闭（安全默认，保留代码）
#    bash 5_cleanup_attacker.sh --purge       # 关闭 + 彻底清理部署产物
#    bash 5_cleanup_attacker.sh --dry-run     # 预览将执行的动作
#
#  保留不动: /root/test_ddos/（手工拷贝的源码）以及 pip 依赖。
#  如需卸载 Python 依赖（可选）:
#    python3 -m pip uninstall -y scapy requests paramiko
# =============================================================================
set -u

APP_DIR="/opt/ddos"
WRAPPER="/usr/local/bin/ddos-attack"
TMP_SCRIPTS="/tmp/_probe.sh /tmp/_p130.sh /tmp/_p5000.sh /tmp/_restart.sh /tmp/x.sh"

PURGE=0
RESTORE_FW=0
DRY=0

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }
dry()  { echo -e "\033[1;35m[dry]\033[0m $*"; }

usage() {
    sed -n '2,27p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)            PURGE=1 ;;
        --restore-firewall) RESTORE_FW=1 ;;
        --dry-run)          DRY=1 ;;
        -h|--help)          usage ;;
        *) die "未知参数: $1 （bash $0 --help 查看用法）" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || die "请以 root 运行"

if [ "$DRY" = "1" ]; then
    say "===== 攻击机一键关闭与清理（DRY-RUN 预览，不实际改动） ====="
else
    say "===== 攻击机一键关闭与清理开始 ====="
fi

# ---------------------------- 1. 停止 attacker 进程 --------------------------
say "[1/3] 停止 attacker.py 进程"
# 说明: attacker 用 multiprocessing 起 syn-*/udp-*/multi-port/brute-* 子进程，
#       子进程继承父进程命令行，pkill -f 可一并命中；python2/python3 两种解释器都覆盖。
PIDS=$(pgrep -f 'attacker\.py' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    say "发现 attacker 进程: $(echo $PIDS | tr '\n' ' ')"
    if [ "$DRY" = "1" ]; then
        dry "pkill -f 'attacker\\.py' （必要时 kill -9）"
    else
        pkill -f 'attacker\.py' 2>/dev/null || true
        sleep 2
        PIDS=$(pgrep -f 'attacker\.py' 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            warn "常规终止未生效，强杀: $(echo $PIDS | tr '\n' ' ')"
            kill -9 $PIDS 2>/dev/null || true
            sleep 1
        fi
        pgrep -f 'attacker\.py' >/dev/null 2>&1 \
            && warn "仍有 attacker 进程残留，请手工检查" \
            || ok "attacker 进程已全部退出（scapy 发包随进程退出即停止）"
    fi
else
    ok "无 attacker 进程"
fi

# ---------------------------- 2. 清理临时脚本 --------------------------------
say "[2/3] 清理临时脚本"
for f in $TMP_SCRIPTS; do
    [ -e "$f" ] || continue
    if [ "$DRY" = "1" ]; then
        dry "rm -f $f"
    else
        rm -f "$f" && ok "已删除 $f"
    fi
done

# ---------------------------- 3. 彻底清理（--purge） -------------------------
if [ "$PURGE" = "1" ]; then
    say "[3/3] --purge：删除部署产物"
    if [ "$DRY" = "1" ]; then
        [ -d "$APP_DIR" ]      && dry "rm -rf $APP_DIR"
        [ -f "$WRAPPER" ]      && dry "rm -f $WRAPPER"
        find /root/test_ddos -name '__pycache__' -type d 2>/dev/null | while read -r d; do
            dry "rm -rf $d"
        done
    else
        if [ -d "$APP_DIR" ]; then
            rm -rf "$APP_DIR" && ok "已删除 $APP_DIR"
        fi
        if [ -f "$WRAPPER" ]; then
            rm -f "$WRAPPER" && ok "已删除快捷命令 $WRAPPER"
        fi
        find /root/test_ddos -name '__pycache__' -type d 2>/dev/null | while read -r d; do
            rm -rf "$d" && ok "已删除 $d"
        done
        ok "pip 依赖保留（如需卸载: python3 -m pip uninstall -y scapy requests paramiko）"
    fi
else
    say "[3/3] 保留部署产物（如需删除请加 --purge）"
fi

# ---------------------------- 可选：恢复安全策略 -----------------------------
if [ "$RESTORE_FW" = "1" ]; then
    warn "--restore-firewall：将重新启用 firewalld"
    warn "若防火墙默认策略未放行 SSH，远程连接会立即断开，建议在控制台执行！"
    if [ "$DRY" = "1" ]; then
        dry "systemctl enable --now firewalld"
    else
        systemctl enable --now firewalld 2>/dev/null && ok "firewalld 已启用" \
            || warn "firewalld 启用失败"
    fi
fi

# ---------------------------- 结果确认 ---------------------------------------
say "===== 结果确认 ====="
if [ "$DRY" = "1" ]; then
    dry "以上为预览；去掉 --dry-run 才会实际执行"
    exit 0
fi
pgrep -f 'attacker\.py' >/dev/null 2>&1 && warn "仍有 attacker 进程" || ok "无 attacker 进程"
[ -e "$WRAPPER" ] && warn "$WRAPPER 仍存在（--purge 可删除）" || true
ok "===== 完成 ====="
