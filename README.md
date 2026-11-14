# ddzt 内网 OA 综合系统 + DDoS 模拟与防护演练平台

> 网络安全赛项 · 隔离内网综合演练仓库 ｜ 环境：纯内网 192.168.3.0/24，无公网 DNS
> 三台 CentOS 7 虚拟机，SSH 账号/口令均为 `root/root` ｜ 目标浏览器：Firefox 115

本仓库包含比赛所需的全部交付物：**内网 OA 协同办公系统（含邮件系统与文件共享）**、
**多向量 DDoS / 端口扫描 / 弱口令爆破模拟攻击端**、**Python 自动过滤审计防护端（带可视化面板）**，
以及一键部署脚本与 Windows 侧运维工具。

---

## 1. 主机与角色

| 端 | IP | 角色 | 用途 |
|---|---|---|---|
| 服务端（靶机） | `192.168.3.152` | OA + 邮件 + 文件共享 + DDoS 防护 | nginx 托管 OA；postfix/dovecot 邮件；`agent.py` 检测封禁 + 面板 |
| 客户端（管理机） | `192.168.3.155` | 浏览器访问端 | Firefox 访问 OA、Thunderbird 收发邮件、查看 DDoS 面板 |
| 攻击端（兼备用客户端） | `192.168.3.153` | DDoS 攻击模拟 | `attacker.py` 发起多向量攻击；也可浏览器查看面板 |

- 内网域名（各端 `/etc/hosts` 已写入，依赖脚本自动配置）：
  `ddzt.old / mail.ddzt.old / www.ddzt.old / oa.ddzt.old → 192.168.3.152`
- **入口**：http://ddzt.old/ （或 http://192.168.3.152/）；登录后左侧「🛡️ 安全防护」内嵌 DDoS 面板；
  也可直连 http://192.168.3.152:5000/ 或经 OA 反代 http://ddzt.old/ddos/
- ⚠️ 当前三台均为 **DHCP 自动获取**（上表为 2026-11-13 实测 IP）。IP 再变也不用手工改：
  执行 `python tools\net_sync.py --apply` 自动识别并同步全仓库与三台机器，见 [§11](#11-ip-变了怎么办自动同步)。
- 注：[配置.md](配置.md) 记录各成员分管的机器与服务，角色以本文档与 [使用文档.md](使用文档.md) 为准。

---

## 2. 仓库结构

```
├── README.md                     本文件（总览与导航）
├── 使用文档.md                    OA/邮件/文件共享系统说明、API 契约、文件布局、排障
├── 使用教程与注意事项.md           面向操作者的分步教程（部署/访问/收发邮件/验收）+ 注意事项
├── ddos.md                       DDoS 系统需求规格（阈值/检测规则/API/面板要求）
├── 配置.md                       各成员分管的机器与服务（IP 以 netenv.json 为准）
├── netenv.json                   三台 IP 的唯一事实来源（角色→IP、网段、SSH 口令、域名）
├── oa/                           OA 系统源码
│   ├── index.html                  单页前端（10 个模块；邮件/文件共享/公告/日程/个人待办/安全防护为真实功能）
│   ├── static/app.js               前端逻辑 + 演示数据；公告/日程走 content.php，个人待办走 todos.php，安全防护页内嵌 DDoS 面板
│   ├── static/style.css
│   └── api/                        auth.php（登录/角色）、users.php（账号）、mail.php（webmail）、
│                                   files.php（文件共享）、content.php（公告/日程）、todos.php（个人待办）
├── ddos/                         DDoS 模拟与防护系统（详见 ddos/README.md）
│   ├── target/                     靶机 152：agent.py（采集/检测/封禁/Flask API）、index.html
│   │                                 面板、nginx 日志片段、systemd 单元、1_setup_target.sh、
│   │                                 5_cleanup_target.sh
│   ├── attacker/                   攻击机 153：attacker.py、2_setup_attacker.sh、
│   │                                 5_cleanup_attacker.sh、add_ips.sh（多源别名 IP）
│   ├── admin/                      管理机 154：3_setup_admin.sh（连通性自检）
│   ├── common/4_verify_lib.sh      公共自检函数库
│   └── docs/netplan.md             目录/端口/封禁规则/网卡/传输规划
├── deploy/                       一键系统依赖安装 + 校验脚本（详见 deploy/README.md）
│   ├── 1_server_deps.sh            152：nginx/mariadb/php-fpm/php-imap/postfix/dovecot/
│   │                                 redis/python36 等 + /etc/hosts
│   ├── 2_client_deps.sh            154：firefox/thunderbird/curl/jq 等
│   ├── 3_attacker_deps.sh          153：hping3/nmap/scapy/paramiko + 客户端工具集
│   ├── 4_oa_mail_setup.sh          152：OA 部署 + 邮件域 ddzt.old + 文件共享 + 示例邮件
│   └── 5_oa_mail_ctl.sh            152：OA+邮箱一键启停（带真实链路自检）
├── netlab/                       实验网辅助工具（Node.js + shell）
│   ├── probe.mjs / run.mjs         ssh2 批量探测主机信息 / 批量执行命令（root/root）
│   ├── setup_mirrors.sh            CentOS 7 yum + pip 源统一为阿里云镜像（带备份）
│   ├── check_sources.sh            镜像源配置检查
│   └── cleanup_mirrors.sh          清理残留 repo 文件
├── tools/                        Windows 侧运维工具（详见各脚本 docstring）
│   ├── net_sync.py                 IP 变化后一键自适应：扫描识别三台角色 + 全仓库改写 + 远程落地
│   ├── push_deploy.py              一键上传 + 执行 deploy/ 依赖脚本（支持 --check/--oa/all）
│   ├── push_ddos.py                按角色分发 ddos/ 到三台 /root/test/ddos/
│   ├── ssh_run.py                  SSH 远程执行 / 上传文件 / 批量探测（root/root）
│   ├── e2e_mail_test.py            邮件全流程端到端验收（登录→收→读→发→删→附件往返）
│   ├── e2e_oa_auth_test.py         OA 登录/角色/文件写权限端到端验收
│   ├── e2e_content_test.py         公告/日程增删改与权限端到端验收
│   ├── e2e_share_test.py           文件共享：上传者/说明/到期/权限/下载端到端验收
│   └── smtp_probe.py               LAN 直连 25 端口无认证发信验证
├── _pycompat.py / _py2lint.py    开发辅助：Python 3.6 语法兼容性检查
└── 比赛/                          赛场机器备份 zip（backup_130 / backup_232，不入 git）
```

---

## 3. 子系统说明

### 3.1 OA 系统 + 邮件系统 + 文件共享（`oa/` + `deploy/4_oa_mail_setup.sh`）

- **OA 前端**：单页 10 模块（工作台 / 公告 / 流程审批 / 人事 / 日程 / 文件共享 / 通讯录 / 邮件 / 安全防护 / 系统设置）。
  其中**邮件**、**文件共享**、**公告通知**、**日程安排**与**个人待办**为真实功能（数据落盘到服务器），其余为前端演示。
  门户登录为**服务端会话认证**（`oa/api/auth.php`，bcrypt 存密码），账号见第 7 节。
- **OA 账号**：登录页走 `api/auth.php` 服务端会话（`login` / `me` / `logout`），
  **登录账号就是邮箱地址**：`eva@ddzt.old/rei`、`kk@ddzt.old/zmjjkk`、`admin@ddzt.old/admin`；
  短账号 `eva` 不再接受，非 `ddzt.old` 域一律拒绝。密码只存 bcrypt 哈希，错误口令返回 401，退出销毁会话。
  账号表在 `oa/api/users.php`。
- **修改权限**：`admin@ddzt.old` 可维护公告与日程（新增/编辑/删除）并审批；
  **个人待办每个账号独立**，所有登录用户都能添加/编辑/删除自己的待办，管理员也不能修改他人的待办；
  `eva@`、`kk@` 为普通账号，页面顶部标「普通用户」，公告/日程/审批按钮禁用并提示“仅管理员可操作”。
  文件共享另外放开：所有登录用户都能上传，上传者本人或管理员可删除。
  `auth.php` 的 `me`/`login` 返回 `role`；`content.php` 的写操作在服务端二次校验角色（未登录 401、非管理员 403），
  `files.php` 校验登录态与文件归属，`todos.php` 只允许读写本人待办。
- **公告通知 / 日程安排**：数据存 `/var/www/oa-data/content.json`（首次部署用 `oa/api/content_defaults.json` 初始化，重跑保留）；
  所有登录用户可读，仅管理员可新增/编辑/删除；API `/api/content.php`（`data` / `notice_save` / `notice_delete` / `schedule_save` / `schedule_delete`）。
- **个人待办**：每个账号独立，数据存 `/var/www/oa-data/todos.sqlite`；首次访问自动生成 8 条默认待办；
  登录用户只能查看/添加/编辑/删除自己的待办（管理员也不能改他人的），工作台统计卡显示未完成数量；
  API `/api/todos.php`（`list` / `save` / `delete`，全部要求登录；操作他人待办按 404 处理）。
- **邮件系统**（完整可用）：
  - 后端 postfix（投递，`home_mailbox = Maildir/`）+ dovecot（IMAP 读取）；
    Webmail 后端 `oa/api/mail.php`：php-imap 读 Dovecot + fsockopen SMTP 发 Postfix（PHP 5.4 兼容）。
  - **与 OA 登录关联**：登录 OA 成功后，服务端用同一口令建立邮箱会话，进入「邮件」无需再次登录；
    邮箱账号 `eva@ddzt.old`、`kk@ddzt.old`、`admin@ddzt.old`，口令与 OA 相同；只在 ddzt.old 本地域内收发。
  - **附件**：写信可添加最多 10 个附件、合计 ≤20MB；收件与发件双方都能在阅读面板查看并下载；
    发件副本自动存入 `Sent`（已发送）箱，目录栏可切换「收件箱 / 已发送」。
  - Thunderbird 直连：IMAP `192.168.3.152:143`（明文认证）、SMTP `192.168.3.152:25`（LAN 无认证放行）。
  - API 契约（`/api/mail.php`：me / login / logout / list / read / send / delete / attachment）见 [使用文档.md](使用文档.md) 第五节。
- **文件共享**：任何登录用户可上传（≤20MB、禁可执行扩展名），可填写说明（≤200 字）与到期时间（留空=永久）；
  列表显示文件大小、上传者、上传时间、说明和到期时间；到期后文件保留但**禁止下载**并标注「已过期」；
  上传者本人可删除自己的文件，管理员可删除任意文件。下载强制 `attachment`。
  存储 `/var/www/oa-share/`（实体 `files/` + 元数据 `data/files.sqlite`）；API `/api/files.php`
  （`list` / `upload` / `download` / `delete`，全部要求登录）。

### 3.2 DDoS 模拟与防护（`ddos/`，需求规格见 [ddos.md](ddos.md)）

- **攻击端** `ddos/attacker/attacker.py`（root 运行，Scapy）：
  - 模式：`syn` / `udp` / `http` / `multi-port`（23 个常见端口）/ `brute`（ssh/ftp/redis/telnet）/ `mixed` / `dry-run`。
  - 特性：多源 IP 模拟（`--src-ips/--src-range` + `add_ips.sh` 绑定别名 IP）、自定义发包大小（`--pkt-size`，MB，自动拆包）、伪造源（syn/udp/multi-port 用 RandIP）。
- **防护端** `ddos/target/agent.py`（root 运行，4 线程 + Flask `:5000`）：
  - 采集：Scapy 抓包、tail Nginx access.log、tail `/var/log/secure`（SSH 失败）；滑动窗口统计。
  - 检测阈值：SYN/UDP 80pps、HTTP 20req/s、5s 内 >10 端口=扫描、60s 内 >5 次 SSH 失败=爆破。
  - 自动封禁：iptables 规则带 `DDoS_BLOCK` 注释；flood 只封 tcp/80+udp/53（**不碰 SSH 22**），
    扫描源全端口 DROP、爆破源只封 tcp/22；`BLOCK_TTL=60s` 自动解封、`MAX_BLOCKED=200`、白名单、手动解封、自动开关。
  - 面板 `ddos/target/index.html`：五分类 120s 流量趋势图、来源分类、速率/端口/扫描/爆破/被屏蔽 IP/事件表。
  - 审计日志：`/var/log/ddos/{packets,http,auth,blocks}.jsonl`。
- 详细命令参数、部署/清理步骤见 **[ddos/README.md](ddos/README.md)**；网段/端口/规则规划见 [ddos/docs/netplan.md](ddos/docs/netplan.md)。

### 3.3 部署与运维

- `deploy/`：1~3 号脚本装系统依赖（幂等、`--check` 只读校验、PASS/FAIL/WARN 汇总、FAIL 退出码非 0），
  4 号部署 OA+邮件业务，5 号一键启停。环境变量 `SERVER_IP / CLIENT_IP / ATTACKER_IP / MAIL_DOMAIN / NO_FIREWALL_CHANGE / PIP_INDEX` 可覆盖默认值。
- `tools/`（Windows 侧）：`push_deploy.py` 一键全传全部署；`push_ddos.py` 分发 DDoS 项目；
  `ssh_run.py` 远程命令/传文件；`preview_oa.py` 本地预览 OA（静态取本地 `oa/`，API 与 `/ddos/` 代理到 152）；
  `e2e_mail_test.py`、`e2e_oa_auth_test.py`、`e2e_content_test.py`、`e2e_share_test.py`、`e2e_todos_test.py`、`smtp_probe.py` 验收测试。
- 本地改前端预览：`python tools/preview_oa.py` → <http://127.0.0.1:8123/>（不用本地装 PHP，登录/数据仍走 152）。
- `netlab/`：`ssh2` 批量探测/执行（`node probe.mjs <ip…>` / `node run.mjs "<cmd>" <ip…>`），
  以及 yum/pip 阿里云镜像源统一与检查脚本。

---

## 4. 快速开始（新环境从零部署）

```bash
# ① 三端装依赖（分别在对应主机执行，幂等可重复）
bash /root/test/1_server_deps.sh        # 服务端 152
bash /root/test/2_client_deps.sh        # 客户端 154
bash /root/test/3_attacker_deps.sh      # 攻击端 153

# ② 服务端部署 OA + 邮件 + 文件共享（仅 152）
bash /root/test/4_oa_mail_setup.sh

# ③ 校验（任何脚本都支持 --check，只查不改）
bash /root/test/4_oa_mail_setup.sh --check
```

Windows 侧批量操作（可选）：

```powershell
python tools\push_deploy.py all --upload           # 全端上传依赖脚本
python tools\push_deploy.py 192.168.3.152 --oa     # 上传 + 部署 + 校验
python tools\push_ddos.py 192.168.3.152 --upload   # 分发 DDoS 防护端文件
```

DDoS 演练（先关防护跑基线，再开防护重跑对比）：

```bash
ddos-attack dry-run
curl -X POST http://192.168.3.152:5000/api/auto -H 'Content-Type: application/json' -d '{"enabled":false}'
ddos-attack multi-port --mp-rate 50 --duration 20
ddos-attack brute --brute-kinds ssh,ftp,redis,telnet --duration 40
ddos-attack mixed --syn-procs 4 --syn-rate 200 --udp-procs 2 --udp-rate 200 \
           --http-threads 20 --mp-rate 50 --brute-kinds ssh --duration 40
curl -X POST http://192.168.3.152:5000/api/auto -H 'Content-Type: application/json' -d '{"enabled":true}'
# 重复上述三条命令，在面板观察"被屏蔽 IP"与速率回落
```

> 顺序建议：**先测爆破/扫描（真实 IP；扫描源会被全端口封 60s），再测伪造源 flood**，避免攻击端先被封。

---

## 5. 验收测试（部署后必跑）

| 测试 | 命令 | 位置 | 预期 |
|---|---|---|---|
| 邮件全流程 | `python3 /root/test/e2e_mail_test.py` | 154 | `E2E_MAIL_TEST_ALL_PASS` |
| OA 登录与权限 | `python3 /root/test/tools/e2e_oa_auth_test.py` | 154 | `E2E_OA_AUTH_ALL_PASS`（三角色、文件写权限 401/403） |
| 公告/日程 CRUD | `python3 /root/test/tools/e2e_content_test.py` | 154 | `E2E_CONTENT_TEST_ALL_PASS`（管理员增删改、普通账号 403、落盘） |
| 文件共享全流程 | `python3 /root/test/tools/e2e_share_test.py` | 152 | `E2E_SHARE_TEST_ALL_PASS`（说明/到期/归属删除/过期 410） |
| 跨端下载 | `python3 /root/test/tools/test_clients.py` | 152 | 154/153 下载成功 |
| 终检汇总 | `python3 /root/test/tools/final_check.py` | 152 | 各项正常 |
| SMTP 直连发信 | `python3 tools\smtp_probe.py`（上传至 154 跑） | 154 | `SMTP_RELAY_OK` |
| DDoS 防护验证 | 见上文「DDoS 演练」 | 152 面板 | 扫描源被全端口封、爆破源被封 22，速率回落 |
| 面板已接入 OA | `curl -s http://ddzt.old/ddos/api/stats` | 任意客户端 | 返回 JSON；浏览器打开 `http://ddzt.old/#/security` 可见实时数据 |

---

## 6. 常用端口与流量方向

| 方向 | 端口 | 用途 |
|---|---|---|
| 客户端/攻击端 → 152 | 80/tcp | OA / Webmail / 文件共享（nginx） |
| 客户端 → 152 | 25/tcp、143/tcp | SMTP 发信、IMAP 收信（Thunderbird） |
| 客户端/攻击端 → 152 | 80/tcp | OA 与 `/ddos/`（nginx 反代到本机 Flask `:5000`，同源、免开端口） |
| 客户端/攻击端 → 152 | 5000/tcp | DDoS 监控面板与 API 直连（**客户端 IP 必须在 WHITELIST**） |
| 任意 → 152 | 22/tcp | SSH 维护（flood 封禁规则永远不含 22） |
| 攻击端 → 152 | 53/udp、21/23/6379 等 | UDP flood、FTP/Telnet/Redis 爆破、多端口扫描 |

---

## 7. 账号一览

| 系统 | 账号 | 口令 | 说明 |
|---|---|---|---|
| OA 门户 / Web 邮件 | eva@ddzt.old | rei | 邮箱即登录账号 |
| OA 门户 / Web 邮件 | kk@ddzt.old | zmjjkk | 邮箱即登录账号 |
| OA 门户 / Web 邮件 | admin@ddzt.old | admin | 管理员；邮箱即登录账号 |
| 系统 (SSH) | root | root | 三端登录 |
| DDoS 面板 | — | — | OA 内「安全防护」http://ddzt.old/#/security ；或 http://ddzt.old/ddos/ ；直连 :5000（无鉴权，仅内网） |

---

## 8. 安全与边界（务必遵守）

1. **演示口令，禁止暴露公网** —— eva/kk/admin/root 均为弱口令，系统假定纯内网运行。
2. **DDoS 攻击仅限 192.168.3.152** —— 硬约束，绝不可把攻击流量指向其他 IP（含网关/公网）。
3. **每轮短时低强度**，实验前对虚拟机做快照；Scapy 伪造源 IP 仅限内网短时使用。
4. **上传限制不可放开** —— 20MB 上限 + 禁传可执行扩展（php/phtml/phar/jsp/asp/cgi/pl 等）是防 WebShell 底线。
5. **firewalld / SELinux 停用是演示约定**（保证与 DDoS agent 的 iptables 规则共存）；
   生产化恢复：`ddos/5_cleanup_target.sh --restore-firewall`、`ddos/5_cleanup_attacker.sh --restore-firewall`。
6. **邮件仅在 ddzt.old 本地域内收发**（eva ↔ kk ↔ admin），发往外域失败属预期；明文认证为内网演示配置。
7. 全端口封禁会阻断该源所有流量（含 SSH），只对判定为**端口扫描**的源使用；爆破源只封 22。

---

## 9. 文档索引

| 文档 | 内容 |
|---|---|
| [使用文档.md](使用文档.md) | 系统说明、API 契约、各端文件布局、运维工具、排障表 |
| [使用教程与注意事项.md](使用教程与注意事项.md) | 分步操作教程（部署/访问/邮件/文件共享/更新/验收）+ 安全与操作注意事项 |
| [ddos.md](ddos.md) | DDoS 系统需求规格（架构/阈值/检测规则/API/面板/交付物清单） |
| [ddos/README.md](ddos/README.md) | DDoS 部署与使用（快速开始/攻击命令参考/多源 IP/发包大小/清理/阈值） |
| [ddos/docs/netplan.md](ddos/docs/netplan.md) | 目录布局、端口与流量方向、封禁规则语义、网卡探测 |
| [deploy/README.md](deploy/README.md) | 依赖脚本职责、OA+邮件部署、启停脚本、环境变量、防火墙约定 |
| [配置.md](配置.md) | 各成员分管的机器与服务（IP 以 netenv.json 为准） |

---

## 10. 故障速查

| 现象 | 先查什么 |
|---|---|
| 打不开 http://ddzt.old/ | `/etc/hosts` 映射、nginx/php-fpm 状态 |
| 邮件发不出去 | `postfix inet_interfaces = all`、`systemctl restart postfix` |
| 文件上传失败 | 大小 ≤20MB？扩展名在黑名单？`/var/www/oa-share` 属主 apache？ |
| 25/80/5000 端口不通 | firewalld 是否被重新启用（约定是停用） |
| 面板打不开 / 被自封 | 客户端 IP 是否在 `/etc/ddos/whitelist.txt`；`POST /api/unblock` 解封 |
| 校验报 FAIL | 按 FAIL 文案逐项排查；服务类先 `systemctl restart` 后 `--check` 复跑 |
| 全量复检 | 各端 `bash /root/test/<脚本> --check`，或 Windows 侧 `push_deploy.py <ip> --check` |
| 三台 IP 又变了 | `python tools\net_sync.py --apply`（见 §11） |

---

## 11. IP 变了怎么办（自动同步）

三台机器用 DHCP，IP 可能每次开赛都变。仓库内置「按角色识别 + 全仓库改写」工具，
**不用再手工搜改近 30 个文件**：

```powershell
# 1) 预览：扫描网段识别三台角色，打印将改动的文件与远程操作（不做任何修改）
python tools\net_sync.py

# 2) 执行：改仓库 + 远程刷新三台 hosts/白名单/靶机地址 + 重启 ddos-agent
python tools\net_sync.py --apply
```

工作原理：

- **角色识别**：部署脚本在每台写入 `/etc/ddzt-role`（`server`/`client`/`attacker`），工具 SSH 登录读取；
  标记缺失时按 `/opt/ddos/agent.py`、`/opt/ddos/attacker.py`、hostname 推断；同步时会把正确标记补写回三台，
  下次扫描即可稳定识别（客户端最容易漏写）。
- **仓库改写**：以 [netenv.json](netenv.json) 记录的旧 IP 为基准，替换全部文件中出现的 IP
  （代码/脚本/文档一并更新），网段整体变化（192.168.3.x → 192.168.4.x）也支持，最后写回 netenv.json。
- **远程落地**（不必重新部署）：三台 `/etc/hosts` 重建 `ddzt.old` 四域名映射；
  服务端重写 `/etc/ddos/whitelist.txt` 并重启 `ddos-agent`（agent.py 启动时加载，支持 IP/CIDR）；
  攻击端重写 `/etc/ddos/target`（`ddos-attack` 与 `attacker.py` 运行时读取，不再写死 IP）。
- **无法扫描时**手工指定：`python tools\net_sync.py --map server=IP,client=IP,attacker=IP --apply`。
- 扫描不到的机器默认算「IP 未确认」，工具会**中止**而不是沿用旧 IP（避免把白名单/hosts 写到错的机器上）；确认该机器 IP 没变时加 `--allow-stale` 放行。
- **网段里有别的机器**（第四台虚拟机、NAS、打印服务器）不用管：角色无法判定会被忽略；
  输出太吵或怕选错时用 `--ignore 192.168.3.155` 跳过。

**长期方案（建议至少做第 1 条）**：

1. **DHCP 保留**：在路由器/虚拟网络编辑器里按 MAC 绑定固定 IP —— 一次配好，永久生效；
2. **工具兜底**：IP 一变就跑 `net_sync.py --apply`，约 30 秒完成全量适配。

> 提示：`net_sync.py --apply` 同步的是「配置」。若 `agent.py`/`attacker.py`/部署脚本本身有代码更新，
> 仍建议按 §4 重新上传并重跑部署脚本（工具结尾会打印对应的上传命令）。
