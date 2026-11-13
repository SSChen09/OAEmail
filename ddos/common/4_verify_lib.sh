#!/bin/bash
# =============================================================================
#  公共依赖自检 / 通用工具（source 使用，不直接执行）
# =============================================================================
#  被 1_setup_target.sh / 2_setup_attacker.sh / 3_setup_admin.sh 复用：
#    . ../common/4_verify_lib.sh   或   source "$SRC_DIR/../common/4_verify_lib.sh"
#
#  提供:
#    vlog/vok/vwarn/verr      统一彩色输出
#    need_root                检查 root
#    check_cmd  cmd           命令是否存在
#    check_py   module        检查 python 模块（python36/python3 优先，回退 py2）
#    check_port ip port       检查远端 TCP 端口
#    pip_install [args...]    使用清华源安装
#    check_iptables           检查 iptables 与 DDoS_BLOCK 残留
#    check_selinux            检查 SELinux 状态
#    collect_env              收集主机名/IP/路由/内核信息
# =============================================================================

# 防止重复 source（被直接执行时立即退出，避免污染 shell）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "本文件是公共库，请用 source 引用，不要直接执行。" >&2
    echo "示例: . \"$(dirname "$0")/4_verify_lib.sh\"" >&2
    exit 1
fi
if [ -n "${DDOS_LIB_LOADED:-}" ]; then
    return 0
fi
DDOS_LIB_LOADED=1

PIP_MIRROR="${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"

vlog()  { echo -e "\033[1;36m[*]\033[0m $*"; }
vok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
vwarn() { echo -e "\033[1;33m[!]\033[0m $*"; }
verr()  { echo -e "\033[1;31m[x]\033[0m $*"; }

need_root() {
    [ "$(id -u)" = "0" ] || { verr "需要 root 权限"; exit 1; }
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1 && { vok "命令存在: $1"; return 0; }
    vwarn "命令缺失: $1"; return 1
}

# 选择可用的 Python（优先 py3: python36/python3，回退 py2: python2/python）
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

check_py() {
    local mod="$1" py
    py="$(py_bin)"
    if [ -z "$py" ]; then
        vwarn "未找到可用的 Python（python36/python3/python2/python）"
        return 1
    fi
    if "$py" -c "import $mod" >/dev/null 2>&1; then
        vok "Python 模块可用: $mod ($py)"
        return 0
    fi
    vwarn "缺少 Python 模块: $mod（$py -m pip install -i $PIP_MIRROR $mod）"
    return 1
}

pip_install() {
    local py
    py="$(py_bin)"
    [ -n "$py" ] || { verr "无 Python，无法 pip 安装"; return 1; }
    "$py" -m pip install -i "$PIP_MIRROR" "$@" || { verr "pip 安装失败: $*"; return 1; }
}

check_port() {
    local ip="$1" port="$2" timeout="${3:-3}"
    if timeout "$timeout" bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then
        vok "端口可达: $ip:$port"; return 0
    fi
    vwarn "端口不可达: $ip:$port"; return 1
}

check_iptables() {
    check_cmd iptables || return 1
    local n
    n=$(iptables -S INPUT 2>/dev/null | grep -c DDoS_BLOCK || true)
    if [ "${n:-0}" -gt 0 ]; then
        vwarn "存在 $n 条 DDoS_BLOCK 残留规则（agent 启动时会自动清理，或手工: iptables -S INPUT | grep DDoS_BLOCK 后逐条 -D 删除）"
    else
        vok "无 DDoS_BLOCK 残留规则"
    fi
}

check_selinux() {
    if command -v getenforce >/dev/null 2>&1; then
        vlog "SELinux: $(getenforce)"
    else
        vwarn "未安装 SELinux 工具"
    fi
}

collect_env() {
    vlog "主机: $(hostname)  内核: $(uname -r)"
    vlog "IPv4: $(ip -o -4 addr show 2>/dev/null | awk '{print $2\":\"$4}' | tr '\n' ' ')"
}
