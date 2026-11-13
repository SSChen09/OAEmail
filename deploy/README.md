# deploy/ — 按《配置.md》一键安装各系统依赖（含校验）

> 对应关系：配置.md 中的角色 → 脚本 → 目标 SSH 主机（用户名/密码均为 root）

| 脚本 | 角色 | 主机 | 职责（配置.md） | 覆盖系统依赖 |
|---|---|---|---|---|
| `1_server_deps.sh` | 服务端 | `192.168.1.137` | OA 部署 + DDoS 防御 + 邮件系统部署 | OA(nginx/mariadb/php-fpm/php-*、JDK1.8)、邮件(postfix/dovecot/sasl/mailx)、DDoS 防御(nginx/redis/iptables/python36/scapy/flask) |
| `2_client_deps.sh` | 客户端 | `192.168.1.130` | 浏览器访问 OA、发送邮件 | firefox、thunderbird、curl/jq/bind-utils、python3+requests（可选） |
| `3_attacker_deps.sh` | 攻击端/备用客户端 | `192.168.1.232` | DDoS 攻击服务器；其余同客户端 | python36/scapy/requests/paramiko、hping3/nmap/iproute、firefox、thunderbird |
| `4_oa_mail_setup.sh` | 服务端 | `192.168.1.137` | OA 系统部署 + 邮件系统部署 | （业务部署）OA 应用 /var/www/oa、邮件域 ddzt.old、用户 eva@/kk@ |

共同项（三个脚本都做）：

- 内网域名 `/etc/hosts`：`ddzt.old / mail.ddzt.old / www.ddzt.old / oa.ddzt.old → 192.168.1.137`（纯内网、无公网 DNS，邮件域名为 `ddzt.old`）
- **校验（含校验）**：每项依赖做 命令/版本 → 服务状态 → 端口监听 → 域名解析 → 本机 IP 自检，
  最后输出 `PASS/FAIL/WARN` 汇总；存在 FAIL 时脚本退出码非 0，可直接用于自动化验收。
- 幂等：可重复执行；`--check` 参数只校验不安装。

## OA 系统 + 邮件系统（4_oa_mail_setup.sh，仅服务端）

- OA 应用源码在仓库 `oa/` 目录，`tools/push_deploy.py` 会一并上传到各机 `/opt/deploy/oa/`，
  由 `4_oa_mail_setup.sh` 部署到 `/var/www/oa` 并启用 nginx 站点（server_name: ddzt.old 等）。
- **仅邮件模块为完整后端**（webmail：php-imap 读 Dovecot IMAP + SMTP 发 Postfix；
  账号 eva@ddzt.old/eva、kk@ddzt.old/kk，演示口令）；其余模块（工作台/公告/审批/人事/
  日程/文档/通讯录等）均为前端演示页面，无业务后端。
- 邮件系统配置：postfix `mydestination` 含 ddzt.old、`home_mailbox = Maildir/`、
  `inet_interfaces = all`；dovecot `mail_location = maildir:~/Maildir`、
  `disable_plaintext_auth = no`（内网明文认证）、`auth_username_format = %n`
  （支持 eva@ddzt.old 全名登录）；系统用户 eva/kk；投递 2 封示例邮件。
- 部署 / 校验：
  ```powershell
  python tools\push_deploy.py 192.168.1.137 --oa          # 上传 + 部署 + 校验
  python tools\push_deploy.py 192.168.1.137 --oa --check  # 仅校验
  ```
- 访问入口：http://ddzt.old/ （或 http://192.168.1.137/），浏览器进「邮件」模块登录收发。
- 客户端 Thunderbird 也可直连：IMAP 192.168.1.137:143、SMTP 192.168.1.137:25（明文认证）；
  仅服务端本机（127.0.0.1）提交免认证，外部客户端发信请走 OA 邮件模块。

## OA + 邮箱系统一键启停（5_oa_mail_ctl.sh，仅服务端）

- 管辖服务：OA = `nginx` `php-fpm` `mariadb`；邮件 = `postfix` `dovecot`。
  **不动** sshd / redis / vsftpd / ddos-agent（DDoS 防护端独立管理）。
- 自检是真实链路（不是只看进程）：服务状态、端口 80/9000/3306/25/110/143、
  OA 首页 HTTP 200、webmail API、文件共享 API、IMAP 登录（eva）、SMTP 本机提交。
- `stop` 后自检期望全部离线（服务停止、端口释放）；汇总 PASS/FAIL/WARN，
  FAIL 时退出码非 0；幂等可反复执行。
- 用法（服务端 137 上执行，当前文件位置 `/root/test/5_oa_mail_ctl.sh`）：
  ```bash
  bash /root/test/5_oa_mail_ctl.sh start     # 启动 + 自检(应在线)
  bash /root/test/5_oa_mail_ctl.sh stop      # 停止 + 自检(应离线)
  bash /root/test/5_oa_mail_ctl.sh restart   # 先停后启 + 自检
  bash /root/test/5_oa_mail_ctl.sh status    # 只读体检（check 同义）
  ```

## 用法

在 Windows 侧（本仓库根目录）：

```powershell
python tools\ssh_run.py 192.168.1.137 putd deploy /opt/deploy   # 上传（或用 tools\push_deploy.py 一键全传）
python tools\ssh_run.py 192.168.1.137 run "bash /opt/deploy/1_server_deps.sh"
python tools\ssh_run.py 192.168.1.137 run "bash /opt/deploy/1_server_deps.sh --check"   # 复检
```

或直接在目标机执行：

```bash
bash /opt/deploy/1_server_deps.sh        # 服务端 137
bash /opt/deploy/2_client_deps.sh        # 客户端 130
bash /opt/deploy/3_attacker_deps.sh      # 攻击端 232
```

## 环境变量（可调）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SERVER_IP` | 192.168.1.137 | 服务端 IP（三个脚本通用） |
| `CLIENT_IP` | 192.168.1.130 | 客户端 IP（2_client_deps.sh 自检用） |
| `ATTACKER_IP` | 192.168.1.232 | 攻击端 IP（3_attacker_deps.sh 自检用） |
| `MAIL_DOMAIN` | ddzt.old | 邮件/OA 域名（纯内网） |
| `PIP_INDEX` | 清华 PyPI 镜像 | 失败自动回退阿里云镜像 |
| `NO_FIREWALL_CHANGE` | 0 | 设为 1 时不改动 firewalld/SELinux（需自行放行端口） |

## 防火墙 / SELinux（服务端、攻击端）

CentOS 7 默认 firewalld 只放行 ssh，80/25/110/143 等服务端口全被拦；且
DDoS 防御 agent 直接写 iptables 规则，与 firewalld 冲突。因此与
`ddos/target/1_setup_target.sh`、`ddos/attacker/2_setup_attacker.sh` 的演示
环境约定保持一致：1_server_deps.sh / 3_attacker_deps.sh 会**停用并取消自启
firewalld、SELinux 设为 permissive**（可 `NO_FIREWALL_CHANGE=1` 跳过，恢复用
`5_cleanup_target.sh --restore-firewall` / `5_cleanup_attacker.sh
--restore-firewall`）。客户端 2_client_deps.sh 不改动防火墙（只发起出向连接）。

## 边界说明

- 1/2/3 号脚本只装**系统依赖并校验**；OA / 邮件业务部署在 `4_oa_mail_setup.sh`，
  DDoS 业务部署在 ddos 项目自带脚本。
- OA 系统除邮件模块外均为**前端演示**（无业务后端），数据为写死演示数据。
- DDoS 攻击组件仅限隔离内网演练，目标只允许 `192.168.1.137`（见 ddos.md 硬性约束）。
