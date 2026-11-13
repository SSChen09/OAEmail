#!/bin/bash
# =============================================================================
#  攻击机 192.168.3.153 源 IP 别名管理脚本（CentOS 7 / root）
# =============================================================================
#  功能:
#    add <IPs>   把真实源 IP 添加到网卡（临时，重启失效；--persist 持久化）
#    del <IPs>   删除源 IP（--persist 同时删除 ifcfg 别名文件）
#    list        列出网卡 IPv4 地址
#
#  用法（在攻击机上执行）:
#    bash add_ips.sh add 192.168.3.233-240             # 临时添加 .233 ~ .240
#    bash add_ips.sh add --persist 192.168.3.233-234   # 持久化（写 ifcfg 别名）
#    bash add_ips.sh del 192.168.3.233-240
#    bash add_ips.sh list
#
#  IPs 参数: 逗号/空格分隔，元素可为单 IP 或范围
#    范围写法: 192.168.3.233-240  或  192.168.3.233-192.168.3.240（含两端）
#
#  选项:
#    -i <网卡>   指定网卡（默认按 ip route get 192.168.3.152 自动探测）
#    --persist   add: 写 /etc/sysconfig/network-scripts/ifcfg-<网卡>:<n>
#                del: 同时删除对应 ifcfg 别名文件
#
#  配合 attacker.py 使用（多真实源 IP 模拟）:
#    bash add_ips.sh add 192.168.3.233-240
#    python3 attacker.py --mode mixed --src-range 192.168.3.233-240 --duration 30
#  注意: 持久化删除/添加不影响当前网络连接，重启后才完全一致；网卡别名请
#        使用与主 IP 同网段的空闲地址，勿与 130/115 冲突。
# =============================================================================
set -u

PROBE_DST="192.168.3.152"     # 探测出口网卡用的目的地址（靶机）
NIC=""
PERSIST=0

say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

usage() {
    sed -n '2,28p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
    exit 0
}

# ---------------------------- 参数解析 --------------------------------------
CMD=""
SPECS=()
while [ $# -gt 0 ]; do
    case "$1" in
        add|del|list) [ -z "$CMD" ] || die "只能一个动作: $CMD 与 $1 冲突"; CMD="$1" ;;
        -i)           shift; NIC="${1:-}"; [ -n "$NIC" ] || die "-i 需要网卡名" ;;
        --persist)    PERSIST=1 ;;
        -h|--help)    usage ;;
        -*)           die "未知选项: $1 （bash $0 --help 查看用法）" ;;
        *)            SPECS+=("$1") ;;
    esac
    shift
done
[ -n "$CMD" ] || die "缺少动作: add / del / list （bash $0 --help 查看用法）"
[ "$(id -u)" = "0" ] || die "请以 root 运行"

# ---------------------------- 工具函数 --------------------------------------
ip2int() {
    local ip=$1 a b c d rest
    a=${ip%%.*}; rest=${ip#*.}
    b=${rest%%.*}; rest=${rest#*.}
    c=${rest%%.*}; d=${rest#*.}
    echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

int2ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

valid_ip() {
    local ip=$1 rest o
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    # 逐段校验 0-255（不用 IFS/read 拆分，避免环境差异）
    rest=$ip
    o=${rest%%.*}; rest=${rest#*.}; [ "$o" -le 255 ] || return 1
    o=${rest%%.*}; rest=${rest#*.}; [ "$o" -le 255 ] || return 1
    o=${rest%%.*}; rest=${rest#*.}; [ "$o" -le 255 ] || return 1
    o=${rest};                    [ "$o" -le 255 ] || return 1
    return 0
}

# 展开一个 spec（单 IP 或范围）为空格分隔的 IP 列表
expand_spec() {
    local spec=$1 lo hi lo_n hi_n n
    spec=${spec//,/ }
    for item in $spec; do
        if [[ "$item" == *-* ]]; then
            lo=${item%%-*}
            hi=${item#*-}
            [[ "$hi" == *.* ]] || hi="${lo%.*}.$hi"        # 简写结尾：只给末段
            valid_ip "$lo" || die "非法起始 IP: $lo"
            valid_ip "$hi" || die "非法结束 IP: $hi"
            lo_n=$(ip2int "$lo"); hi_n=$(ip2int "$hi")
            [ "$hi_n" -ge "$lo_n" ] || die "范围结束小于起始: $item"
            [ $((hi_n - lo_n)) -lt 1024 ] || die "范围超过 1024 个 IP: $item"
            n=$lo_n
            while [ "$n" -le "$hi_n" ]; do
                int2ip "$n"
                n=$((n + 1))
            done
        else
            valid_ip "$item" || die "非法 IP: $item"
            echo "$item"
        fi
    done
}

detect_nic() {
    if [ -z "$NIC" ]; then
        # 优先按到靶机的路由探测；靶机 IP 变了/未配置时回退默认路由、再回退首块非 lo 网卡
        NIC=$(ip route get "$PROBE_DST" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
        if [ -z "$NIC" ]; then
            NIC=$(ip route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
        fi
        if [ -z "$NIC" ]; then
            NIC=$(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2; exit}')
        fi
        [ -n "$NIC" ] || die "探测出口网卡失败，请用 -i <网卡> 指定"
    fi
    ip link show "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
}

detect_prefix() {
    local cidr
    cidr=$(ip -o -4 addr show dev "$NIC" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$cidr" ] && [[ "$cidr" == */* ]]; then
        echo "${cidr#*/}"
    else
        echo "24"
    fi
}

# ---------------------------- list ------------------------------------------
if [ "$CMD" = "list" ]; then
    say "网卡 IPv4 地址一览:"
    ip -o -4 addr show | awk '{printf "  %-12s %s\n", $2, $4}'
    exit 0
fi

detect_nic
PREFIX=$(detect_prefix)
[ ${#SPECS[@]} -gt 0 ] || die "缺少 IP 参数（如 192.168.3.233-240）"

IPS=()
for s in "${SPECS[@]}"; do
    OUT=$(expand_spec "$s") || die "解析 IP 参数失败: $s"
    while read -r ip; do
        [ -n "$ip" ] && IPS+=("$ip")
    done <<< "$OUT"
done
[ ${#IPS[@]} -gt 0 ] || die "没有解析出任何 IP"

say "网卡=$NIC  前缀=/$PREFIX  共 ${#IPS[@]} 个 IP  persist=$PERSIST"

# 地址是否已绑定在该网卡上（按 "IP/" 前缀精确匹配，避免 192.168.3.1 命中 192.168.3.10）
addr_bound() {
    ip -o -4 addr show dev "$NIC" | awk -v p="$1/" 'index($4, p) == 1 { found = 1 } END { exit(found ? 0 : 1) }'
}

# ---------------------------- add / del -------------------------------------
added=0; skipped=0; removed=0
for ip in "${IPS[@]}"; do
    if [ "$CMD" = "add" ]; then
        if addr_bound "$ip"; then
            warn "$ip 已绑定，跳过"
            skipped=$((skipped + 1))
            continue                      # 已存在的地址不要再写一份 ifcfg 别名
        fi
        ip addr add "$ip/$PREFIX" dev "$NIC" 2>/dev/null \
            || die "添加失败: $ip（是否与现有地址冲突？）"
        ok "已添加 $ip/$PREFIX -> $NIC"
        added=$((added + 1))
        if [ "$PERSIST" = "1" ]; then
            IFDIR="/etc/sysconfig/network-scripts"
            n=1
            while [ -e "$IFDIR/ifcfg-$NIC:$n" ]; do n=$((n + 1)); done
            cat > "$IFDIR/ifcfg-$NIC:$n" <<EOF
DEVICE=$NIC:$n
IPADDR=$ip
PREFIX=$PREFIX
ONBOOT=yes
EOF
            ok "持久化: $IFDIR/ifcfg-$NIC:$n"
        fi
    else  # del
        if addr_bound "$ip"; then
            ip addr del "$ip/$PREFIX" dev "$NIC" 2>/dev/null \
                || ip addr del "$ip" dev "$NIC" 2>/dev/null \
                || die "删除失败: $ip"
            ok "已删除 $ip"
            removed=$((removed + 1))
        else
            warn "$ip 未绑定，跳过"
        fi
        if [ "$PERSIST" = "1" ]; then
            for f in /etc/sysconfig/network-scripts/ifcfg-"$NIC":*; do
                [ -e "$f" ] || continue
                if awk -v want="IPADDR=$ip" '$0 == want { found = 1 } END { exit(found ? 0 : 1) }' "$f"; then
                    rm -f "$f"
                    ok "删除持久化: $f"
                fi
            done
        fi
    fi
done

if [ "$CMD" = "add" ]; then
    say "完成: 新增 $added 个，跳过 $skipped 个"
    say "验证: bash add_ips.sh list；然后跑 attacker.py --src-range ... --mode dry-run"
else
    say "完成: 删除 $removed 个"
fi
