#!/bin/bash
# =============================================================================
#  管理机 192.168.1.130 一键环境脚本（任意 Linux 发行版 / 需 root 或 sudo）
# =============================================================================
#  管理机职责: 只用浏览器访问靶机面板 http://192.168.1.137:5000/
#  本脚本做四件事:
#    1. 纯管理机：只校验连通性（不装攻击/防护组件）
#    2. 可选 --tools : 安装 curl / jq / tcpdump / python（py3 优先，回退 py2）/ requests（便于用 API 验证）
#    3. 连通性自检: 靶机 80、5000 端口，以及 /api/stats 返回
#    4. 输出可复制的 curl 验证命令（手动解封、切换自动屏蔽、导出统计）
#
#  用法:
#    bash 3_setup_admin.sh            # 仅自检
#    bash 3_setup_admin.sh --tools    # 安装客户端工具后自检
#
#  可调环境变量:
#    TARGET_IP=192.168.1.137
#    PANEL_PORT=5000
# =============================================================================
set -u

TARGET_IP="${TARGET_IP:-192.168.1.137}"
PANEL_PORT="${PANEL_PORT:-5000}"
INSTALL_TOOLS=0
[ "${1:-}" = "--tools" ] && INSTALL_TOOLS=1

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

# 选择 Python 解释器：优先 py3，回退 py2（CentOS7 自带 python）
py_bin() {
    for p in python3 python2 python; do
        command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    echo ""
}

# 解释器主版本（2 或 3）；探测失败按 3 处理
py_major() {
    "$1" -c 'import sys; sys.stdout.write(str(sys.version_info[0]))' 2>/dev/null || echo 3
}

if [ "$(id -u)" != "0" ]; then
    SUDO="sudo"
else
    SUDO=""
fi

say "===== 管理机环境检查（靶机 $TARGET_IP）====="

# ---------------------------- 1. 本机 IP 提示 --------------------------------
MY_IPS=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
say "本机 IPv4: $MY_IPS"
case " $MY_IPS " in
    *192.168.1.130*) ok "本机即约定的管理机（客户端）192.168.1.130" ;;
    *192.168.1.232*) ok "本机是备用客户端（攻击端）192.168.1.232，同样已加入 WHITELIST" ;;
    *) warn "本机不是 192.168.1.130 / 192.168.1.232；请确认该 IP 已加入靶机 WHITELIST（否则会被封）" ;;
esac

# ---------------------------- 2. 可选工具 ------------------------------------
if [ "$INSTALL_TOOLS" = "1" ]; then
    say "安装客户端工具 curl / jq / tcpdump / python"
    # 先探测本机 Python（py3 优先，回退 py2）
    PY=$(py_bin)
    if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y curl jq tcpdump || warn "dnf 安装有失败项"
        $SUDO dnf install -y python3 python3-pip >/dev/null 2>&1 \
            || $SUDO dnf install -y python2 python-pip >/dev/null 2>&1 \
            || warn "python 安装有失败项"
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y epel-release 2>/dev/null || true
        $SUDO yum install -y curl jq tcpdump || warn "yum 安装有失败项"
        $SUDO yum install -y python36 python36-pip >/dev/null 2>&1 \
            || $SUDO yum install -y python3 python3-pip >/dev/null 2>&1 \
            || $SUDO yum install -y python2-pip python-pip >/dev/null 2>&1 \
            || warn "python 安装有失败项（可用系统自带 python）"
    elif command -v apt >/dev/null 2>&1; then
        $SUDO apt update && $SUDO apt install -y curl jq tcpdump || warn "apt 安装有失败项"
        $SUDO apt install -y python3 python3-pip || warn "python3 安装有失败项"
    else
        warn "未识别的包管理器，跳过工具安装"
    fi
    # 重探（安装后才可能出现）
    PY=$(py_bin)
    if [ -n "$PY" ]; then
        PY_MAJOR=$(py_major "$PY")
        if "$PY" -m pip --version >/dev/null 2>&1; then
            if [ "$PY_MAJOR" = "3" ]; then REQ="requests"; else REQ="requests==2.27.1"; fi
            $SUDO "$PY" -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple "$REQ" \
                || warn "requests 安装失败（不影响浏览器面板使用）"
        else
            warn "$PY 无 pip 模块，跳过 requests（不影响浏览器面板使用）"
        fi
    else
        warn "未找到 Python，跳过 requests（不影响浏览器面板使用）"
    fi
fi

# 后续命令统一用 PY（heredoc 与 jq 分支都会用到）
PY=${PY:-$(py_bin)}
PY_MAJOR=${PY_MAJOR:-$(py_major "$PY" 2>/dev/null || echo 3)}

# ---------------------------- 3. 连通性自检 ----------------------------------
command -v curl >/dev/null 2>&1 || die "缺少 curl，可重跑: bash $0 --tools"

say "检查网络与路由"
ip route get "$TARGET_IP" 2>/dev/null || warn "无到靶机的路由"
if ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
    ok "ping $TARGET_IP 可达"
else
    warn "ping 不可达（靶机可能禁 ping，继续检查 TCP）"
fi

say "检查靶机 Nginx (80)"
CODE=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "http://$TARGET_IP/" || echo "000")
if [ "$CODE" != "000" ] && [ -n "$CODE" ]; then
    ok "80 端口 HTTP 状态码 $CODE"
else
    warn "80 端口不可达"
fi

say "检查靶机面板 (:$PANEL_PORT)"
STATS=$(curl -s -m 4 "http://$TARGET_IP:$PANEL_PORT/api/stats" || true)
if echo "$STATS" | grep -q '"ts"'; then
    ok "面板 API 正常"
    if command -v jq >/dev/null 2>&1; then
        echo "$STATS" | jq -c '{ts, auto, blocked:(.blocked|length), events:(.events|length)}'
    else
        echo "$STATS" | head -c 300; echo
    fi
else
    warn "面板 API 不可达：请确认靶机 agent 已启动、且本机 IP 在 WHITELIST 中"
fi

# ---------------------------- 4. 输出验证命令 --------------------------------
say "===== 常用验证命令（复制执行）====="
cat <<EOF

 # 打开面板
   http://$TARGET_IP:$PANEL_PORT/

 # 查看统计（格式化）
   curl -s http://$TARGET_IP:$PANEL_PORT/api/stats | ${PY:-python3} -m json.tool
   curl -s http://$TARGET_IP:$PANEL_PORT/api/stats | jq '.blocked, .events[:5]'

 # 手动解封
   curl -X POST http://$TARGET_IP:$PANEL_PORT/api/unblock \\
        -H 'Content-Type: application/json' -d '{"ip":"192.168.1.232"}'

 # 关闭 / 开启自动屏蔽（基线测试 / 防护测试切换）
   curl -X POST http://$TARGET_IP:$PANEL_PORT/api/auto \\
        -H 'Content-Type: application/json' -d '{"enabled":false}'
   curl -X POST http://$TARGET_IP:$PANEL_PORT/api/auto \\
        -H 'Content-Type: application/json' -d '{"enabled":true}'

 # 持续观察（每 2 秒刷新一行摘要）
   watch -n 2 "curl -s http://$TARGET_IP:$PANEL_PORT/api/stats | ${PY:-python3} -c \\
     'import sys,json;d=json.load(sys.stdin);print(\"%s auto=%s blocked=%s\" % (d[\"ts\"],d[\"auto\"],len(d[\"blocked\"])))'"

 # 在靶机上查看封禁规则与审计日志（ssh 到靶机执行）
   iptables -S INPUT | grep DDoS_BLOCK
   tail -f /var/log/ddos/blocks.jsonl

EOF
ok "管理机检查完成"
