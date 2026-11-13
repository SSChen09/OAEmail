# 部署与网段规划

## 1. 目录结构（本机开发目录）

```
ddos/
├── target/                          # 靶机 192.168.1.137
│   ├── agent.py                     # 采集/检测/自动封禁/Flask API（无内嵌 HTML）
│   ├── index.html                   # 独立面板（深色主题，2s 轮询 /api/stats）
│   ├── nginx/ddos.conf              # Nginx ddos 日志格式片段（放入 http{} 内）
│   ├── systemd/ddos-agent.service   # 靶机常驻服务
│   └── 1_setup_target.sh            # 靶机一键依赖 + 部署脚本
├── attacker/                        # 攻击机 192.168.1.232
│   ├── attacker.py                  # syn/udp/http/multi-port/brute/mixed/dry-run
│   └── 2_setup_attacker.sh          # 攻击机一键依赖 + 部署脚本
├── admin/                           # 管理机 192.168.1.130
│   └── 3_setup_admin.sh             # 连通性自检 + 客户端工具 + 验证命令
├── common/
│   └── 4_verify_lib.sh              # 公共依赖自检函数（source 使用）
├── docs/netplan.md                  # 本文件
├── _selftest.py                     # 开发机本地自检（不参与部署）
└── README.md                        # 使用说明
```

## 2. 三台机器部署后的布局

| 机器 | IP | 路径 | 内容 |
|---|---|---|---|
| 靶机 | 192.168.1.137 | `/opt/ddos/agent.py`、`/opt/ddos/index.html` | root 运行，`ddos-agent.service` |
| | | `/var/log/ddos/*.jsonl` | packets / http / auth / blocks |
| | | `/etc/nginx/nginx.conf` | `log_format ddos` + `access_log` |
| 攻击机 | 192.168.1.232 | `/opt/ddos/attacker.py` | root 运行（Scapy 原始套接字） |
| | | `/usr/local/bin/ddos-attack` | 快捷包装命令 |
| 管理机 | 192.168.1.130 | 无（仅浏览器） | `http://192.168.1.137:5000/` |

## 3. 端口与流量方向

| 方向 | 端口 | 协议 | 用途 |
|---|---|---|---|
| 管理机 → 靶机 | 5000/tcp | HTTP | 面板与 API（**必须加入 WHITELIST**） |
| 管理机/攻击机 → 靶机 | 22/tcp | SSH | 维护（flood 封禁规则永远不含 22） |
| 攻击机 → 靶机 | 80/tcp | HTTP/SYN | flood 与扫描目标 |
| 攻击机 → 靶机 | 53/udp | UDP | UDP flood 目标 |
| 攻击机 → 靶机 | 21/23/6379 | TCP | FTP/Redis/Telnet 爆破 |
| 攻击机 → 靶机 | 21个常用端口 | TCP SYN | multi-port 扫描 |

## 4. 封禁规则语义

| 判定 | iptables 规则 | 影响范围 |
|---|---|---|
| SYN/UDP/HTTP flood | `-s IP -p tcp --dport 80 -j DROP` + `-s IP -p udp --dport 53 -j DROP` | 仅 80/53，**SSH 22 不受影响** |
| 端口扫描 / SSH 爆破 | `-s IP -j DROP` | 全端口（含 22），仅针对被判定的源 |

- 所有规则带 `-m comment --comment DDoS_BLOCK`，解封按记录的参数逐条 `-D`。
- agent 启动时执行 `cleanup_rules()` 删除所有 `DDoS_BLOCK` 残留。
- `BLOCK_TTL=60s` 到期自动解封；面板按钮 / `POST /api/unblock` 可手动解封。

## 5. 网卡探测

两台机器均以 `ip route get 对方IP` 的 `dev` 字段为准，默认 `eth0`：

```bash
ip route get 192.168.1.232     # 靶机上执行 -> 得到靶机出口网卡
ip route get 192.168.1.137     # 攻击机上执行 -> 得到攻击机出口网卡
```

agent 可用 `--iface` 显式指定，例如 `--iface ens33`。

## 6. 本机（开发机）→ Linux 传输

在 Windows 开发机上用 scp 分发（ssh 客户端或 WinSCP 均可）：

```bash
scp -r ddos/target/*   root@192.168.1.137:/opt/ddos-setup/
scp -r ddos/attacker/* root@192.168.1.232:/opt/ddos-setup/
scp -r ddos/admin/*    root@192.168.1.130:/opt/ddos-setup/
```

注意：`1_setup_target.sh` 依赖同目录下的 `agent.py`、`index.html`、`nginx/`、`systemd/`，
所以要用 `*` 把 `target/` 整个目录内容发过去。
