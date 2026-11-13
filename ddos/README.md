# 隔离内网多向量 DDoS / 端口扫描 / 爆破模拟与 Python 自动过滤审计

按 `ddos.md` 需求实现，全部 Python 3.6（CentOS 7）单文件脚本；**面板 HTML 已独立为 `index.html`**，
每个角色都有**一键依赖+部署脚本**。

> ⚠️ 仅限隔离内网演示：单攻击机 → 单靶机，不打网关/公网，每轮短时低强度，实验前对两台 VM 做快照。

## 交付物

| 文件 | 角色 | 说明 |
|---|---|---|
| [target/agent.py](target/agent.py) | 靶机 | 4 线程（sniff / nginx tail / secure tail / blocker）+ Flask API |
| [target/index.html](target/index.html) | 靶机 | 独立面板页（与 OA 一致的浅色主题，2s 轮询，解封按钮 / 自动开关 / **流量统计图表与分类**；`?embed=1` 嵌入 OA 时隐藏侧栏） |
| [target/nginx/ddos.conf](target/nginx/ddos.conf) | 靶机 | `log_format ddos` + `access_log` 片段（放入 `http{}`） |
| [target/systemd/ddos-agent.service](target/systemd/ddos-agent.service) | 靶机 | 常驻服务 |
| [target/1_setup_target.sh](target/1_setup_target.sh) | 靶机 | **一键**装依赖（nginx/sshd/vsftpd/scapy/flask）、配日志、部署、起服务 |
| [target/5_cleanup_target.sh](target/5_cleanup_target.sh) | 靶机 | **一键**关闭清理：停 agent、清 DDoS_BLOCK 规则（`--purge` 连部署产物一起删） |
| [attacker/attacker.py](attacker/attacker.py) | 攻击机 | syn / udp / http / multi-port / brute / mixed / dry-run；多源 IP（`--src-ips/--src-range`）、自定义发包大小（`--pkt-size`，MB） |
| [attacker/2_setup_attacker.sh](attacker/2_setup_attacker.sh) | 攻击机 | **一键**装依赖（scapy/requests/paramiko）、部署、生成 `ddos-attack` 命令 |
| [attacker/add_ips.sh](attacker/add_ips.sh) | 攻击机 | 给网卡绑定/删除同网段别名 IP（多源模拟用，`--persist` 写 ifcfg 持久化） |
| [attacker/5_cleanup_attacker.sh](attacker/5_cleanup_attacker.sh) | 攻击机 | **一键**关闭清理：杀 attacker 进程（`--purge` 连 /opt/ddos、ddos-attack 一起删） |
| [admin/3_setup_admin.sh](admin/3_setup_admin.sh) | 管理机 | **一键**连通性自检（可选装 curl/jq/tcpdump）、输出验证命令 |
| [common/4_verify_lib.sh](common/4_verify_lib.sh) | 公共 | 三个脚本共用的自检函数库（source 引用） |
| [docs/netplan.md](docs/netplan.md) | 文档 | 目录/端口/规则/网卡/传输规划 |

## 快速开始

1. **分发**（Windows 开发机 → 三台 Linux）：
   ```bash
   scp -r ddos/target/*   root@192.168.3.152:/opt/ddos-setup/
   scp -r ddos/attacker/* root@192.168.3.153:/opt/ddos-setup/
   scp -r ddos/admin/*    root@192.168.3.155:/opt/ddos-setup/
   ```
2. **靶机**：`bash /opt/ddos-setup/1_setup_target.sh` → 浏览器开 `http://192.168.3.152:5000/`
   （OA 部署后也可从 OA 左侧「🛡️ 安全防护」进入，或 `http://ddzt.old/ddos/`，见下文「面板已接入 OA」）
3. **攻击机**：`bash /opt/ddos-setup/2_setup_attacker.sh`
4. **管理机**：`bash /opt/ddos-setup/3_setup_admin.sh`（验证 API 与解封命令）
5. **验证流程**（先关防护跑基线，再开防护重跑）：
   ```bash
   ddos-attack dry-run
   curl -X POST http://192.168.3.152:5000/api/auto -H 'Content-Type: application/json' -d '{"enabled":false}'
   ddos-attack multi-port --mp-rate 50 --duration 20
   ddos-attack brute --brute-kinds ssh,ftp,redis,telnet --duration 40
   ddos-attack mixed --syn-procs 4 --syn-rate 200 --udp-procs 2 --udp-rate 200 \
              --http-threads 20 --mp-rate 50 --brute-kinds ssh --duration 40
   curl -X POST http://192.168.3.152:5000/api/auto -H 'Content-Type: application/json' -d '{"enabled":true}'
   # 重复上述三条命令，在面板观察“被屏蔽 IP”与速率回落
   ```
   顺序：**先爆破/扫描（真实 IP；扫描源会被全端口封 60s），再伪造源 flood**。

## 网络前提：IP 变了怎么办（DHCP 也安全）

早期版本把 IP 写死在白名单 / 攻击目标里，DHCP 一变就全线失配。现版本改为**运行时读配置**：

- 服务端白名单：`agent.py` 启动时加载 `/etc/ddos/whitelist.txt`（每行一个 IP 或 CIDR，`#` 注释）；
- 攻击端目标：`attacker.py` 与 `ddos-attack` 运行时依次读 `/etc/ddos/target` → `/etc/hosts` 的 `ddzt.old` → 内置兜底值；
- 三台 `/etc/hosts` 的 ddzt.old 四域名映射由部署脚本重建。

**IP 变化后的标准动作**（Windows 侧，约 30 秒）：

```powershell
python tools\net_sync.py            # 预览：扫描网段识别 server/client/attacker，列出要改的文件
python tools\net_sync.py --apply    # 执行：改仓库 + 远程刷新 hosts/白名单/target + 重启 ddos-agent
```

工具按 `/etc/ddzt-role` 标记识别角色（部署脚本自动写入），无法扫描时用
`--map server=IP,client=IP,attacker=IP` 手工指定；扫描不到的机器默认按「IP 未确认」中止，确认没变时加 `--allow-stale`。

**仍推荐做 DHCP 保留（MAC 绑定）**，把三台 IP 钉死，避免每次开赛都同步。

部署时若 IP 与默认值不同，也可直接用环境变量覆盖：

```bash
ADMIN_IP=192.168.3.x SSR_IP=192.168.3.y bash 1_setup_target.sh   # 靶机（写入 WHITELIST 与 /etc/ddos/whitelist.txt）
TARGET_IP=192.168.3.z bash 2_setup_attacker.sh                    # 攻击机（写入 /etc/ddos/target）
TARGET_IP=192.168.3.z bash 3_setup_admin.sh                       # 管理机
```

（不再需要手改 `1_setup_target.sh` 的 `TARGET_IP` 或 `agent.py` 里的白名单行。）

## 攻击机命令参考（attacker.py）

入口：`python3 attacker.py [参数]`（攻击机 153 上也可用 `ddos-attack`，等价 `python3 /opt/ddos/attacker.py`；
依赖 scapy/requests/paramiko 装在 **python3.6.8**，务必用 `python3` 而不是 `python`）。

### 模式（`--mode`）

| 模式 | 行为 | 源 IP 方式 |
|---|---|---|
| `syn` | TCP SYN flood（目的端口 `--port`，默认 80） | scapy 伪造源 |
| `udp` | UDP flood（目的端口 `--port`，默认 80；建议显式 `--port 53`） | scapy 伪造源 |
| `http` | HTTP 请求洪泛（GET；配 `--pkt-size` 时 POST 大 body） | 真实连接，绑定源 IP 池 |
| `multi-port` | 多端口扫描（默认 23 个常见端口，或 `--ports` 指定） | scapy 伪造源 |
| `brute` | 弱口令爆破（`--brute-kinds`，真实握手，会命中 ssh=root/root、ftp=test/123456） | 真实连接，绑定源 IP 池 |
| `mixed` | syn+udp+http+multi-port+brute 组合（默认模式） | 混合 |
| `dry-run` | 只打印攻击计划/源 IP 分配/拆包计划，不发包 | 不发包 |

### 参数一览

| 参数 | 默认 | 说明 |
|---|---|---|
| `--target` | `192.168.3.152` | 靶机 IP（内置只允许内网） |
| `--mode` | `mixed` | 见上表 |
| `--port` | `80` | SYN/UDP/HTTP 目的端口 |
| `--ports` | 内置 23 端口 | multi-port 端口列表，如 `21,22,80,6379` |
| `--syn-procs` | `4` | SYN 进程数 |
| `--syn-rate` | `200` | 每进程 SYN pps |
| `--udp-procs` | `2` | UDP 进程数 |
| `--udp-rate` | `200` | 每进程 UDP pps |
| `--http-threads` | `20` | HTTP 并发线程 |
| `--mp-rate` | `50` | multi-port 每端口 pps |
| `--pkt-size` | `0` | 发包载荷大小（MB，0~16）；0=默认小包，见《自定义发包大小》 |
| `--brute-kinds` | `ssh,ftp` | 爆破类型：`ssh,ftp,redis,telnet` 任意组合 |
| `--brute-interval` | `0.2` | 爆破每次尝试间隔（秒） |
| `--src-ips` | 空 | 源 IP 池，逗号分隔，元素可为范围（`192.168.3.233,192.168.3.235-240`） |
| `--src-range` | 空 | 源 IP 范围（`192.168.3.233-240` 或全写），与 `--src-ips` 可混用 |
| `--duration` | `30` | 持续时间（秒） |

### 常用组合示例

```bash
# 看计划（不发包）：源 IP 分配 + 拆包计划
python3 attacker.py --mode dry-run --src-range 192.168.3.233-235 --pkt-size 1

# 多源 HTTP 洪泛 30s（真实源 IP，需先 add_ips.sh add）
python3 attacker.py --mode http --http-threads 4 --src-ips 192.168.3.233,192.168.3.234 --duration 30

# 大包 UDP 洪泛：1MB/包，5 pps，打 53 端口
python3 attacker.py --mode udp --port 53 --pkt-size 1 --udp-rate 5 --src-ips 192.168.3.233 --duration 15

# SSH+FTP 爆破（真实握手，触发爆破封禁：只封 tcp/22）
python3 attacker.py --mode brute --brute-kinds ssh,ftp --src-ips 192.168.3.233 --duration 20

# 多端口扫描（伪造源）
python3 attacker.py --mode multi-port --ports 21,22,80,443,3306,6379 --mp-rate 50 --duration 20

# 组合攻击 40s
python3 attacker.py --mode mixed --src-range 192.168.3.233-234 --duration 40
```

> 提示：`--src-ips/--src-range` 里 http/brute 用的 IP 必须先绑定到本机网卡（`bash add_ips.sh add …`），
> 否则启动即报错并列出缺失 IP；syn/udp/multi-port 为伪造源，不需要绑定。

## 多源 IP 模拟（攻击机）

验证“多源批量封禁 / TTL 自动解封”链路时，让攻击机以**多个真实源 IP** 出现在靶机日志里：

```bash
# 1) 在网卡上绑定同网段别名 IP（默认探测去往靶机的网卡；--persist 写 ifcfg 持久化）
bash add_ips.sh add 192.168.3.233-235            # 支持范围简写/全写、逗号分隔
bash add_ips.sh list
bash add_ips.sh del 192.168.3.235                # 实验后删除别名

# 2) 攻击时指定源 IP 池
ddos-attack http  --src-ips 192.168.3.233,192.168.3.234 --http-threads 4 --duration 30
ddos-attack brute --src-range 192.168.3.233-234 --brute-kinds ssh --duration 20
```

- `--src-ips` / `--src-range` 可混用；范围支持简写末段（`192.168.3.233-235`）或全写。
- **http / brute** 轮询**绑定真实源 IP**（需先 `add_ips.sh add`，否则启动即报错并提示缺哪些）；
  **syn / udp / multi-port** 是 scapy 伪造源，从池中随机抽取发包，不需要绑定。
- dry-run 会打印源 IP 池分配计划，并只警告未绑定的 IP。

## 自定义发包大小（攻击机）

`--pkt-size` 按 **MB** 设定每个逻辑包的载荷大小（浮点，0~16，默认 0 = 原小包）：

```bash
ddos-attack udp  --pkt-size 1   --udp-rate 5 --port 53 --src-ips 192.168.3.233 --duration 15
ddos-attack syn  --pkt-size 0.5 --syn-rate 10 --src-ips 192.168.3.233 --duration 15
ddos-attack http --pkt-size 2   --http-threads 2 --src-ips 192.168.3.233 --duration 15
```

- **syn / udp**：载荷超过单包上限（TCP 65495 / UDP 65507 字节）自动拆成多个报文，
  IP 层由内核分片；一个逻辑包消耗一个速率令牌，`--pkt-size 1` 时约 1MB×速率 的字节量。
- **http**：以 `--pkt-size` 字节数作为 POST body 发送，超时随包大小自动放宽（2~15s）。
- 大包实测（udp --pkt-size 1 @5pps，6s）：1KB 档 31KB 到达、2KB 档 92KB、1MB 档 9.4MB
  （136 个分片全部由内核拆装），`iptables -vnx` 计数器逐档吻合。
- 发包速率受网卡吞吐限制：大包模式下实际 pps 会低于 `--*-rate` 设定（发送耗时所致）。
- dry-run 会打印拆包计划（syn 拆几个 IP 包 / udp 拆几个数据报 / http body 字节数）。
- 上限 16MB（`PKT_SIZE_MAX_MB`，attacker.py 常量区可调）。

## 收尾清理（一键关闭）

实验结束后分别在两台机器上执行（先攻击机后靶机，确保无发包进程再清封禁）：

```bash
# 攻击机 192.168.3.153
bash 5_cleanup_attacker.sh                # 停 attacker 进程 + 清临时脚本
bash 5_cleanup_attacker.sh --purge        # 连 /opt/ddos、ddos-attack 一起删
bash add_ips.sh del 192.168.3.233-235 --persist   # 如用过别名 IP，删掉它们（含 ifcfg）

# 靶机 192.168.3.152
bash 5_cleanup_target.sh                  # 停 agent + 清 DDoS_BLOCK 封禁规则
bash 5_cleanup_target.sh --purge          # 连 systemd 单元、/opt/ddos、日志、test 账户一起删
```

两个脚本都支持 `--dry-run`（只预览不动手）；靶机脚本另有 `--stop-services`
（停 nginx/vsftpd）与 `--restore-firewall`（恢复 firewalld + SELinux enforcing，
**可能断开 SSH，建议控制台执行**）。默认保留 `/root/test_ddos/` 源码与 pip 依赖。
`--purge` 后可重新跑 `1_setup_target.sh` / `2_setup_attacker.sh` 还原整个环境。

## 参数与阈值（agent.py 顶部常量区）

| 常量 | 默认 | 含义 |
|---|---|---|
| `SYN_RATE_TH` | 80 | 单源 80/tcp SYN pps 阈值 |
| `UDP_RATE_TH` | 80 | 单源 53/udp pps 阈值 |
| `HTTP_RATE_TH` | 20 | 单源 HTTP req/s 阈值 |
| `SCAN_PORT_TH` | 10 | 5s 内不同端口数阈值（超即全端口封） |
| `BRUTE_TH` | 5 | 60s 内 SSH 失败次数阈值（超即封 tcp/22） |
| `BLOCK_TTL` | 60 | 封禁自动解除秒数 |
| `MAX_BLOCKED` | 200 | 同时封禁上限 |
| `WHITELIST` | 127.0.0.1 + `/etc/ddos/whitelist.txt` | 永不封禁；文件每行一个 IP/CIDR（.152 靶机、.153 攻击机、.154 管理机由部署脚本写入） |

运行时也可用命令行覆盖：
`--iface ens33 --port 5000 --syn-rate 100 --ttl 120 --no-auto --no-cleanup --panel /opt/ddos/index.html`

## API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 返回 `index.html` 面板 |
| GET | `/api/stats` | 统计 JSON（结构见 `ddos.md` 3.6；含 `traffic` 流量统计与 `classify` 来源分类） |
| POST | `/api/unblock` | `{"ip":"x.x.x.x"}` 手动解封 |
| POST | `/api/auto` | `{"enabled":true/false}` 切换自动屏蔽 |

`/api/stats` 流量统计字段：

- `traffic.totals`：自 agent 启动的分类累计计数（`syn`/`udp`/`http`/`brute`/`other`）
- `traffic.hist`：最近 120 秒每秒直方图桶 `{t,syn,udp,http,brute,other}`，面板据此画趋势图
- `traffic.rates`：当前窗口速率（syn/udp/http 按 5s，brute 按 60s，pkts 为全端口包速率）
- `classify`：每来源的窗口内主导攻击类型判定（SYN/UDP/HTTP/爆破/扫描/其他，扫描需 ≥3 个不同端口），含各类分项计数与封禁状态

## 面板功能（index.html）

- **流量统计与分类**：近 120 秒五分类趋势折线图（canvas 手绘，无外部依赖，离线可用）+ 分类累计/占比/近 60s 计数表
- **来源分类**：每来源主导攻击类型徽标 + SYN/UDP/HTTP/爆破/扫描端口分项计数
- 来源速率三表、端口分布、扫描/爆破、被屏蔽 IP（含解封按钮）、最近事件
- 自动屏蔽开关、断线重连提示、页面回前台立即刷新

## 面板已接入 OA（同源反代）

OA 站点（`deploy/4_oa_mail_setup.sh` 生成的 `oa.conf`）新增了 `/ddos/` 反代到 `127.0.0.1:5000`，因此：

| 访问方式 | 地址 | 说明 |
|---|---|---|
| OA 内置页 | `http://ddzt.old/#/security` | 左侧「🛡️ 安全防护」，iframe 内嵌，带刷新/新窗口按钮 |
| 同源面板 | `http://ddzt.old/ddos/` | 无 OA 外壳；`?embed=1` 隐藏面板自带标题/页脚 |
| 直连 agent | `http://192.168.3.152:5000/` | 原方式，仍需 5000 端口与白名单 |

- 面板前端 API 已改为**相对路径**（`api/stats`），直连 `:5000` 与经 `/ddos/` 反代都能用。
- 反代请求源是 `127.0.0.1`，天然在白名单，不会再出现「面板把自己封了」。
- 只改 nginx 与前端，`agent.py` 无需改动；`net_sync` 换 IP 后依然只需一条命令。

## 日志 `/var/log/ddos/*.jsonl`

`packets.jsonl`(ts,src,proto,dport) · `http.jsonl`(ts,remote,xff,method,path,status,ua) ·
`auth.jsonl`(ts,src,user,event) · `blocks.jsonl`(ts,action,ip,reason,full,why)

## 安全约束（已内置）

- flood 封禁规则只含 `tcp/80`、`udp/53`，**永不碰 SSH 22**；全端口 DROP 仅对判定为端口扫描的源，爆破源只封 `tcp/22`。
- 白名单来源永不被封；攻击机 / 管理机可自行决定是否从白名单移除。
- 伪造源 IP 仅限内网短时；HTTP 层只伪造 `X-Forwarded-For`，面板按 `remote_addr` 统计。
- `MAX_BLOCKED` 上限 + `BLOCK_TTL` 自动解封，避免规则堆积。
