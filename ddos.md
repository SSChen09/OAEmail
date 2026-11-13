# DDoS 模拟与监控系统 — 需求规格（供 Agent 生成脚本）

> 用途：将此文档整体作为上下文喂给代码生成 Agent，产出服务端采集/过滤/面板脚本与攻击端模拟脚本。全部 Python 实现，仅限隔离内网。

---

## 1. 实验背景与边界

- 场景：网络安全赛项，隔离内网，**单台攻击端 → 单台服务端**，不做真实分布式、不做反射放大、不打公网。
- 目标：模拟多向量异常流量/请求、多端口攻击、常用端口爆破；服务端完成日志记录、流量统计、自动过滤屏蔽、可视化监控面板。
- 命名建议：**“隔离内网多向量 DDoS/端口扫描/爆破模拟与 Python 自动过滤审计”**。
- 硬性约束：
  - 只打服务端 `192.168.3.152`，不碰网关/公网。
  - 不用 `hping3 --flood`、`--rand-source`；Scapy 伪造源 IP 仅限内网短时。
  - 实验前对两台 VM 快照；每轮短时低强度。
  - 屏蔽规则不得影响 SSH 22（除“全端口封禁”策略外，且全端口封禁只针对被判定扫描/爆破的源）。

---

## 2. 环境与主机

| 角色 | IP | 系统 | 说明 |
|---|---|---|---|
| 服务端 | 192.168.3.152 | CentOS 7 | Nginx + SSH + FTP + 可选 Redis；运行 agent + 面板 |
| 攻击端（兼备用客户端） | 192.168.3.153 | CentOS 7 | 运行 attacker.py（Scapy 需 root）；也可浏览器访问面板 |
| 客户端 | 192.168.3.155 | 待定 | 浏览器访问面板，需加入 WHITELIST |

> 角色对照（与已生成脚本注释一致）：服务端=靶机（被攻击方，运行 agent + 面板），攻击端=攻击机（运行 attacker.py，兼备用客户端，也可浏览器查看面板），客户端=管理机（浏览器查看面板）。

网卡名以 `ip route get 192.168.3.153` 为准，默认按 `eth0` 配置。

### 服务端软件
```bash
yum install -y nginx openssh-server vsftpd net-tools tcpdump
systemctl start nginx sshd vsftpd && systemctl enable nginx sshd vsftpd
systemctl stop firewalld
setenforce 0
# 可选 Redis（6379 爆破演示）
yum install -y epel-release && yum install -y redis && systemctl start redis

# 测试账户（仅演示）
useradd test 2>/dev/null; echo 'test:123456' | chpasswd

# Python
yum install -y python36 python36-pip
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple scapy==2.4.5 flask==2.0.3
mkdir -p /var/log/ddos
```

### 攻击端软件
```bash
yum install -y python36 python36-pip
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple scapy==2.4.5 requests paramiko
```

### Nginx 日志格式（`/etc/nginx/nginx.conf` 的 `http {}` 内）
```nginx
log_format ddos '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
access_log /var/log/nginx/access.log ddos;
```
重载：`nginx -t && systemctl reload nginx`

---

## 3. 服务端 agent 需求（`/opt/ddos/agent.py`，root 运行）

### 3.1 总体架构
- Flask Web 服务：`0.0.0.0:5000`，提供面板页面与 JSON API。
- 后台线程：
  1. **Scapy 抓包线程**：`sniff(iface=IFACE, filter="tcp or udp")`，统计 L4 来源、端口分布、每源端口集合。
  2. **Nginx 日志 tail 线程**：`tail -F /var/log/nginx/access.log`，正则解析，统计 HTTP 来源 QPS。
  3. **`/var/log/secure` tail 线程**：解析 `Failed password for ... from IP port`，统计 SSH 失败。
  4. **Blocker 线程**：每 2s 评估阈值 → 调 iptables 封禁/解封 → 写审计日志。
- 启动时执行 `cleanup_rules()` 清理残留 `DDoS_BLOCK` 规则。
- 全局锁保护共享字典；滑动窗口统一 `WINDOW=5.0s`（爆破窗口 60s）。

### 3.2 采集与统计数据结构
```python
l4[src]            = deque(ts)       # 80端口 TCP SYN
udp[src]           = deque(ts)       # 53端口 UDP
http[src]          = deque(ts)       # Nginx 请求
port_cnt[dport]    = deque(ts)       # 全局端口分布
src_ports[src][dport] = deque(ts)    # 每源端口集合（扫描检测）
brute[src]         = deque(ts)       # SSH 失败（60s 窗口）
blocked[ip]        = {reason, until, rules, full}
events             = deque(maxlen=200)
```

### 3.3 检测规则与默认阈值
| 检测项 | 条件 | 封禁范围 | 原因文案 |
|---|---|---|---|
| SYN Flood | 单源 80 端口 SYN > `SYN_RATE_TH=80` pps | tcp/80 + udp/53 | `SYN flood N/s` |
| UDP Flood | 单源 53 端口 UDP > `UDP_RATE_TH=80` pps | tcp/80 + udp/53 | `UDP flood N/s` |
| HTTP Flood | 单源 HTTP > `HTTP_RATE_TH=20` req/s | tcp/80 + udp/53 | `HTTP flood N/s` |
| 端口扫描 | 单源 5s 内不同端口数 > `SCAN_PORT_TH=10` | **全端口 DROP** | `port scan N ports` |
| SSH 爆破 | 单源 60s SSH 失败 > `BRUTE_TH=5` | **仅 DROP tcp/22** | `SSH brute N/60s` |

其他参数：`BLOCK_TTL=60s`（到期自动解封）、`MAX_BLOCKED=200`、每轮最多处理 20 个新源、`WHITELIST={"127.0.0.1","192.168.3.152","192.168.3.155","192.168.3.153"}`（服务端自身 + 客户端 + 攻击端/备用客户端）、`AUTO_BLOCK=True` 可面板切换。

### 3.4 过滤屏蔽实现
- 通过 `subprocess` 调 `iptables -I INPUT 1 ...`，规则带 `-m comment --comment DDoS_BLOCK` 便于清理。
- 普通封禁规则：
  - `-s IP -p tcp --dport 80 -m comment --comment DDoS_BLOCK -j DROP`
  - `-s IP -p udp --dport 53 -m comment --comment DDoS_BLOCK -j DROP`
- 全端口封禁规则：`-s IP -m comment --comment DDoS_BLOCK -j DROP`（仅用于**端口扫描**源；爆破源只封 `tcp/22`，避免把攻击机 22 端口一起封死）
- 解封按记录的 rules 逐条 `-D`。
- 启动清理：遍历 `iptables -S INPUT`，删除含 `DDoS_BLOCK` 的 `-A` 规则。

### 3.5 日志文件（均 JSON Lines，位于 `/var/log/ddos/`）
| 文件 | 字段 |
|---|---|
| `packets.jsonl` | `ts, src, proto(tcp/udp), dport` |
| `http.jsonl` | `ts, remote, xff, method, path, status, ua` |
| `auth.jsonl` | `ts, src, user, event:"ssh_failed"` |
| `blocks.jsonl` | `ts, action(block/unblock), ip, reason, full, why` |

### 3.6 HTTP API
| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 返回内嵌 HTML 面板 |
| GET | `/api/stats` | 返回 JSON（见 3.7） |
| POST | `/api/unblock` | body `{"ip":"x.x.x.x"}`，手动解封 |
| POST | `/api/auto` | body `{"enabled":true/false}`，切换自动屏蔽 |

`/api/stats` 返回结构：
```json
{
  "ts": "HH:MM:SS",
  "auto": true,
  "l4":    [{"ip":"", "rate":0.0, "blocked":false}],
  "udp":   [{"ip":"", "rate":0.0, "blocked":false}],
  "http":  [{"ip":"", "rate":0.0, "blocked":false}],
  "ports": [{"port":80, "rate":0.0}],
  "scans": [{"ip":"", "ports":0, "blocked":false}],
  "brute": [{"ip":"", "fails":0, "blocked":false}],
  "blocked":[{"ip":"", "reason":"", "full":false, "ttl":0}],
  "events":[{"ts":"HH:MM:SS","msg":""}]
}
```

### 3.7 面板 UI 要求（单页 HTML，内嵌 CSS/JS，`fetch` 每 2s 轮询）
区块：
1. 标题栏：时间、自动屏蔽状态（开/关）、切换按钮。
2. 三列表：TCP SYN 来源(80)、UDP 来源(53)、HTTP 来源（列：ip/rate/blocked）。
3. 三列表：端口分布（port/rate）、扫描/多端口来源（ip/ports/blocked）、SSH 爆破失败（ip/fails/blocked）。
4. 被屏蔽 IP 表：ip/原因/是否全端口/剩余秒/解封按钮。
5. 最近事件表：时间/事件。
与 OA 一致的浅色主题（深蓝侧栏 + 白卡片），顶部统计卡展示总速率/活跃来源/封禁数/自动屏蔽状态，`blocked` 用红色徽标标识；经 OA `/ddos/?embed=1` 内嵌时隐藏侧栏，只保留状态栏与数据区。

---

## 4. 攻击端 attacker 需求（`/opt/ddos/attacker.py`，root 运行）

### 4.1 参数
```
--target        默认 192.168.3.152
--mode          syn | udp | http | multi-port | brute | mixed（默认 mixed）
--port          默认 80
--ports         默认常用端口列表（见下）
--syn-procs     默认 4      --syn-rate   默认 200（每进程 pps）
--udp-procs     默认 2      --udp-rate   默认 200
--http-threads  默认 20
--mp-rate       默认 50     # 多端口每端口 pps
--brute-kinds   默认 "ssh,ftp"，可选 ssh,ftp,redis,telnet
--brute-interval 默认 0.2
--duration      默认 30
```

默认多端口列表：
`21,22,23,25,53,80,110,135,139,143,443,445,993,995,1433,1521,3306,3389,5432,6379,8080,8443,27017`

### 4.2 模块
| 模块 | 实现 | 源 IP |
|---|---|---|
| syn | Scapy `IP(src=RandIP())/TCP(flags="S")` 批量 20 包 | 伪造随机 |
| udp | Scapy `IP(src=RandIP())/UDP(dport=53)/Raw` 批量 20 包 | 伪造随机 |
| http | requests 多线程 GET，伪造 `X-Forwarded-For`、`User-Agent: ddos-test`，timeout=1 | 真实（攻击机源 IP） |
| multi-port | Scapy 遍历 ports 逐个发 SYN，按 `mp-rate` 限速 | 伪造随机 |
| brute | 见 4.3 | 真实（攻击机源 IP） |

并发：syn/udp/multi-port/brute 用 `multiprocessing.Process`；http 用 `threading.Thread`。统一 `multiprocessing.Event` 停止，`duration` 后 `stop.set()` 并 join。

### 4.3 爆破子模块
- **ssh**：paramiko，遍历 4 用户 × 6 密码，捕获 `AuthenticationException`，超时 1s。
- **ftp**：ftplib，login 失败捕获异常。
- **redis**：socket 发 `AUTH pwd\r\n`，收 64 字节。
- **telnet**：socket 连 23，依次发用户名/密码。
- 用户字典：`root, admin, test, guest`；密码字典：`123456, password, admin, test, root, 111111`。
- 命中成功打印 `[ssh] success u/p`，不中断继续（演示用）。
- 每次尝试后 `sleep(brute-interval)`。

---

## 5. 运行与验证流程

1. 服务端启动：`python3 /opt/ddos/agent.py`，客户端浏览器开 `http://192.168.3.152:5000`
   （OA 部署后从 OA 左侧「🛡️ 安全防护」进入，或 `http://ddzt.old/ddos/`，见 ddos/README「面板已接入 OA」）。
2. **防护关闭基线**：面板关自动屏蔽，依次跑：
   - 多端口：`--mode multi-port --mp-rate 50 --duration 20`
   - 爆破：`--mode brute --brute-kinds ssh,ftp,redis,telnet --duration 40`
   - 混合：`--mode mixed --syn-procs 4 --syn-rate 200 --udp-procs 2 --udp-rate 200 --http-threads 20 --mp-rate 50 --brute-kinds ssh --duration 40`
   - 记录：端口分布、扫描端口数、SSH 失败数、各来源速率、连接数、CPU。
3. **防护开启**：面板开自动屏蔽，重跑同样命令。
   - 期望：扫描源进入“被屏蔽 IP”（全端口）、爆破源进“被屏蔽 IP”（仅 22），flood 伪造源被普通封禁；速率回落；`blocks.jsonl` 有 block/unblock 记录；`iptables -S INPUT | grep DDoS_BLOCK` 可见规则。
4. 手动解封：面板按钮或
   ```bash
   curl -X POST http://192.168.3.152:5000/api/unblock -H 'Content-Type: application/json' -d '{"ip":"192.168.3.153"}'
   ```
5. 顺序建议：**先测爆破/扫描（真实 IP；扫描源会被全端口封 60s），再测伪造源 flood**，避免攻击端先被封后无法继续。

---

## 6. 已知限制与风险

- 单攻击端无法产生真实分布式；SYN/UDP/multi-port 用 `RandIP()` 伪造源制造“多源特征”，回包会发往伪造地址，仅限内网短时。
- HTTP 层必须真实握手，只能伪造 `X-Forwarded-For`；面板来源统计以 `remote_addr` 为准。
- 伪造源多时可能触发 `MAX_BLOCKED=200` 上限；可缩短 `BLOCK_TTL` 或调高阈值。
- 爆破是真实认证，`test` 账户用于演示，勿用生产账户；真实环境会触发账户锁定。
- 全端口封禁会阻断该源所有流量（含 SSH），只对判定为**端口扫描**的源使用；爆破源只封 22。
- 客户端 IP 必须加入 `WHITELIST`，防止面板访问被自封。

---

## 7. 交付物清单

| 文件 | 角色 | 说明 |
|---|---|---|
| `/opt/ddos/agent.py` | 服务端 | 抓包/日志/统计/过滤屏蔽/Flask 面板，单文件含内嵌 HTML |
| `/opt/ddos/attacker.py` | 攻击端 | 多向量 + 多端口 + 爆破，argparse 驱动 |
| `/var/log/ddos/packets.jsonl` | 服务端 | L4 包日志 |
| `/var/log/ddos/http.jsonl` | 服务端 | HTTP 请求日志 |
| `/var/log/ddos/auth.jsonl` | 服务端 | SSH 失败日志 |
| `/var/log/ddos/blocks.jsonl` | 服务端 | 封禁审计日志 |
| Nginx 配置片段 | 服务端 | `log_format ddos` + `access_log` |

---

## 8. 给 Agent 的生成要求摘要

- 语言：Python 3.6 兼容（CentOS 7），单文件、无额外框架（除 scapy/flask/requests/paramiko）。
- agent.py：4 线程（sniff / nginx tail / secure tail / blocker）+ Flask；滑动窗口统计；iptables 调 `subprocess`；HTML 内嵌 `Response(HTML, mimetype="text/html")`。
- attacker.py：`multiprocessing.Process` + `threading.Thread` 混合并发，统一 stop Event，`argparse` 参数如第 4 节。
- 所有日志 JSON Lines，字段名严格按第 3.5 节。
- API 路径与返回结构严格按第 3.6 节，面板字段严格按第 3.7 节。
- 代码需包含：启动清理 iptables 残留、白名单、封禁上限、TTL 自动解封、手动解封、自动开关。
- 输出中文注释，关键参数集中在文件顶部常量区便于调参。