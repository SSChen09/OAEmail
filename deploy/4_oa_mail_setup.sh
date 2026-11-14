#!/bin/bash
# =============================================================================
#  OA 系统（前端演示版）+ 邮件系统（完整可用）部署脚本 — 服务端 192.168.3.152
# =============================================================================
#  前置: 1_server_deps.sh 已执行（nginx/php-fpm/mariadb/postfix/dovecot/php-imap）
#  内容: (1) 邮件域 ddzt.old + 用户 eva@/kk@/admin@（postfix/dovecot）
#        (2) OA 应用部署 /var/www/oa（除邮件外均为前端演示，无业务后端）
#        (3) 示例邮件投递 + 全量校验
#  特点: 幂等，可重复执行；--check 仅校验不改动
#  用法: bash 4_oa_mail_setup.sh            部署 + 校验
#        bash 4_oa_mail_setup.sh --check    仅校验
#  账号: eva@ddzt.old / rei   kk@ddzt.old / zmjjkk   admin@ddzt.old / admin
#        （邮箱口令与 OA 门户一致，登录 OA 后邮件模块自动关联）
# =============================================================================
set -u

SERVER_IP="${SERVER_IP:-192.168.3.152}"
MAIL_DOMAIN="${MAIL_DOMAIN:-ddzt.old}"
# 账号口令（与 OA 门户一致；可用环境变量覆盖）
EVAPASS="${EVAPASS:-rei}"
KKPASS="${KKPASS:-zmjjkk}"
ADMINPASS="${ADMINPASS:-admin}"
# 校验用解释器：IMAP/SMTP 检查需要 python（py2/py3 均可）
PYBIN="${PYBIN:-$(command -v python3 || command -v python36 || command -v python2 || command -v python || echo python3)}"
WEB_ROOT="${WEB_ROOT:-/var/www/oa}"
# OA 源文件默认取脚本同目录下的 oa/（/opt/deploy 或 /root/test 均可运行）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SRC="${DEPLOY_SRC:-$SCRIPT_DIR/oa}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ------------------------- 输出/校验辅助函数 -------------------------------
say()  { echo -e "\033[1;36m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

PASS=0; FAIL=0; WARNS=0
vcmd() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"; PASS=$((PASS+1))
    else
        echo -e "\033[1;31m[x]\033[0m $desc  (命令: $*)"; FAIL=$((FAIL+1))
    fi
}
vver() {
    local desc="$1"; shift
    local out rc
    out=$("$@" 2>&1); rc=$?
    out=$(printf '%s\n' "$out" | sed -n '/./{p;q}')   # 第一个非空行
    if [ "$rc" = "0" ] && [ -n "$out" ]; then
        ok "$desc : $out"; PASS=$((PASS+1))
    else
        echo -e "\033[1;31m[x]\033[0m $desc : 获取版本失败 ($*)"; FAIL=$((FAIL+1))
    fi
}
vport() {
    local p="$1" desc="$2" i
    for i in $(seq 1 15); do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
            ok "端口 $p 监听 — $desc"; PASS=$((PASS+1)); return 0
        fi
        sleep 1
    done
    echo -e "\033[1;31m[x]\033[0m 端口 $p 未监听 — $desc"; FAIL=$((FAIL+1))
}
# 幂等设置 dovecot 配置项：先删掉所有非注释的同名行，再追加一条
# （直接 sed 替换 "=" 之前的前缀会把旧值留在行尾，重复执行还会叠加多条配置）
set_dovecot_opt() {
    local file="$1" key="$2" value="$3"
    sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$file"
    printf '%s = %s\n' "$key" "$value" >> "$file"
}

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# 前置依赖断言：本脚本只负责业务配置，缺依赖时越早失败越好
for _c in nginx php-fpm postconf doveconf sendmail useradd; do
    command -v "$_c" >/dev/null 2>&1 || die "缺少命令 $_c，请先执行 deploy/1_server_deps.sh"
done
systemctl is-enabled nginx >/dev/null 2>&1 || warn "nginx 未设置开机自启（建议先跑 1_server_deps.sh）"

# =============================================================================
#  一、部署（--check 跳过）
# =============================================================================
if [ "$CHECK_ONLY" = "0" ]; then

    say "===== [1/5] 邮件域 $MAIL_DOMAIN 与用户 eva/kk/admin ====="
    # postfix: 接收 ddzt.old 本地邮件 + Maildir 投递格式
    # mydestination 采用「读现状 + 追加缺失项」而非整行覆盖，避免丢掉主机原有本地域
    _mydest=$(postconf -h mydestination 2>/dev/null || true)
    for _d in "$MAIL_DOMAIN" "mail.$MAIL_DOMAIN"; do
        case ",$_mydest," in
            *",$_d,"*) : ;;
            *) _mydest="${_mydest:+$_mydest, }$_d" ;;
        esac
    done
    postconf -e "mydestination = $_mydest"
    postconf -e 'home_mailbox = Maildir/'
    # 附件上限：20MB 二进制经 base64 膨胀约 1.37 倍，CentOS7 默认 message_size_limit≈10MB 会 552 拒收
    postconf -e 'message_size_limit = 35840000'
    postfix check || die "postfix 配置非法（检查 /etc/postfix/main.cf）"
    systemctl restart postfix || die "postfix 启动失败（journalctl -u postfix 查看）"
    ok "postfix 已配置并重启 (mydestination + home_mailbox=Maildir/)"
    for u in eva kk admin; do
        case "$u" in
            eva) _pass="$EVAPASS" ;;
            kk)  _pass="$KKPASS" ;;
            *)   _pass="$ADMINPASS" ;;
        esac
        if id -u "$u" >/dev/null 2>&1; then
            usermod -s /bin/bash -d "/home/$u" "$u" 2>/dev/null || true
            echo "$u:$_pass" | chpasswd || die "重置用户 $u 口令失败"
            ok "用户 $u 已存在，口令已重置（$u@$MAIL_DOMAIN）"
        else
            useradd -m -s /bin/bash "$u" || die "创建用户 $u 失败"
            echo "$u:$_pass" | chpasswd || die "设置用户 $u 口令失败"
            ok "已创建用户 $u@$MAIL_DOMAIN"
        fi
    done

    say "===== [2/5] dovecot 邮箱格式与认证 ====="
    # Maildir 格式与 postfix home_mailbox 对齐
    set_dovecot_opt /etc/dovecot/conf.d/10-mail.conf mail_location 'maildir:~/Maildir'
    # 内网演示环境允许明文认证（Thunderbird/IMAP 143 直连）
    set_dovecot_opt /etc/dovecot/conf.d/10-auth.conf disable_plaintext_auth 'no'
    # 允许 eva@ddzt.old 全名登录（%n 取 @ 前本地部分做系统认证）
    set_dovecot_opt /etc/dovecot/conf.d/10-auth.conf auth_username_format '%n'
    # CentOS7 默认 ssl = required：即使允许明文认证，也会拒绝 143 端口上的 PLAIN 登录
    set_dovecot_opt /etc/dovecot/conf.d/10-ssl.conf ssl 'no'
    # 断言关键项各只有一条（重复项 dovecot 2.2 会告警/后者覆盖前者）
    for _k in mail_location disable_plaintext_auth auth_username_format; do
        _n=$(doveconf -n 2>/dev/null | grep -c "^$_k[[:space:]]*=")
        [ "$_n" -le 1 ] || die "dovecot 配置项 $_k 出现 $_n 次，请手工合并 /etc/dovecot/conf.d 下的重复设置"
    done
    doveconf -n >/dev/null 2>&1 || die "dovecot 配置非法（doveconf -n 查看详情）"
    systemctl restart dovecot || die "dovecot 启动失败（journalctl -u dovecot 查看）"
    ok "dovecot 配置合法并已重启（maildir + 明文认证 + %n）"

    say "===== [3/5] php-imap（webmail 后端读取 IMAP）====="
    rpm -q php-imap >/dev/null 2>&1 || yum install -y php-imap || warn "php-imap 安装失败"
    systemctl restart php-fpm && ok "php-fpm 已重启（加载 imap 扩展）"

    say "===== [4/5] OA 应用部署 -> $WEB_ROOT ====="
    [ -d "$DEPLOY_SRC" ] || die "未找到 $DEPLOY_SRC，请先用 tools/push_deploy.py 上传"
    case "$WEB_ROOT" in
        /var/www/*) : ;;
        *) die "WEB_ROOT=$WEB_ROOT 不在 /var/www 下，拒绝执行（请用 /var/www/oa 这类子目录）" ;;
    esac
    # 原子替换：先复制到 .new，成功后再换目录，避免 cp 失败/磁盘满导致站点目录已空
    NEW_ROOT="${WEB_ROOT}.new.$$"
    rm -rf "$NEW_ROOT"
    if ! cp -r "$DEPLOY_SRC" "$NEW_ROOT"; then
        rm -rf "$NEW_ROOT"
        die "复制 OA 文件失败（检查磁盘空间与 $DEPLOY_SRC）"
    fi
    find "$NEW_ROOT" -type d -exec chmod 755 {} \;
    find "$NEW_ROOT" -type f -exec chmod 644 {} \;
    rm -rf "$WEB_ROOT"
    mv "$NEW_ROOT" "$WEB_ROOT" || { rm -rf "$NEW_ROOT"; die "切换 OA 目录失败"; }
    ok "OA 文件已部署到 $WEB_ROOT"
    # 文件共享存储目录（php-fpm 以 apache 运行，必须提前建好并授权，否则上传失败）
    install -d -o apache -g apache -m 775 /var/www/oa-share /var/www/oa-share/files /var/www/oa-share/data
    ok "文件共享存储: /var/www/oa-share（apache:apache）"
    # 公告/日程内容存储：JSON 放在 web 根外，apache 可写；首次部署用默认内容初始化，重跑保留已有数据
    install -d -o apache -g apache -m 775 /var/www/oa-data
    if [ ! -f /var/www/oa-data/content.json ]; then
        install -o apache -g apache -m 664 "$WEB_ROOT/api/content_defaults.json" /var/www/oa-data/content.json \
            && ok "公告/日程默认内容已初始化: /var/www/oa-data/content.json" \
            || warn "公告/日程默认内容初始化失败（检查 $WEB_ROOT/api/content_defaults.json）"
    else
        chown apache:apache /var/www/oa-data/content.json 2>/dev/null || true
        ok "公告/日程数据已存在，保留现有内容（/var/www/oa-data/content.json）"
    fi
    # PHP 上传上限：files.php 允许 20MB，webmail 附件合计 20MB；PHP 默认 upload_max_filesize=2M，不改则 3MB 就失败
    cat > /etc/php.d/99-oa-upload.ini <<'PHP_INI'
; 由 deploy/4_oa_mail_setup.sh 生成：文件共享/邮件附件需要与 nginx client_max_body_size 匹配
upload_max_filesize = 20M
post_max_size = 26M
memory_limit = 256M
max_execution_time = 120
max_input_time = 120
PHP_INI
    if systemctl restart php-fpm; then
        ok "PHP 上传上限已设为 20M、post_max_size=26M（/etc/php.d/99-oa-upload.ini）"
    else
        warn "php-fpm 重启失败，文件共享/邮件附件上传可能仍受 2M 限制"
    fi
    cat > /etc/nginx/conf.d/oa.conf.new <<NGINX_CONF
server {
    listen 80;
    server_name $MAIL_DOMAIN oa.$MAIL_DOMAIN www.$MAIL_DOMAIN $SERVER_IP;
    root $WEB_ROOT;
    index index.html;
    charset utf-8;
    client_max_body_size 26m;

    location /static/ {
        expires 7d;
        access_log off;
    }
    # ---- 安全防护：把 DDoS 监控面板（Flask :5000）反代进 OA 同源路径 /ddos/ ----
    location = /ddos {
        return 301 /ddos/;
    }
    location /ddos/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 30s;
    }
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
NGINX_CONF
    # 备份旧配置 → 试运行校验 → 失败自动回滚，避免留下坏配置导致站点/整机重启后挂掉
    if [ -f /etc/nginx/conf.d/oa.conf ]; then
        cp -a /etc/nginx/conf.d/oa.conf "/etc/nginx/conf.d/oa.conf.bak.$(date +%F-%H%M%S)"
    fi
    mv /etc/nginx/conf.d/oa.conf.new /etc/nginx/conf.d/oa.conf
    if nginx -t; then
        systemctl restart nginx || die "nginx 重启失败（journalctl -u nginx 查看）"
        ok "nginx OA 站点已启用 (server_name: $MAIL_DOMAIN)"
    else
        _bak=$(ls -1t /etc/nginx/conf.d/oa.conf.bak.* 2>/dev/null | head -1)
        if [ -n "$_bak" ]; then
            cp -a "$_bak" /etc/nginx/conf.d/oa.conf
            die "nginx 配置检查失败（见上），已恢复备份 $_bak；修复后重跑本脚本"
        fi
        rm -f /etc/nginx/conf.d/oa.conf
        die "nginx 配置检查失败（见上），已移除坏配置；修复后重跑本脚本"
    fi

    say "===== [5/5] 示例邮件投递 ====="
    # 只投递一次：用标记文件，避免每次重跑都往 Maildir 里堆积重复示例邮件
    if [ -f /var/lib/oa-seeded ]; then
        ok "示例邮件已投递过（/var/lib/oa-seeded），跳过"
    else
    sendmail -t <<'SEED1'
From: eva@ddzt.old
To: kk@ddzt.old
Subject: 欢迎使用 ddzt.old 内网邮件系统
Content-Type: text/plain; charset=UTF-8

kk，你好：

这是 ddzt.old 内网邮件系统的第一封邮件。
你可以登录 OA 系统的「邮件」模块回复本邮件。

-- eva@ddzt.old
SEED1
    sendmail -t <<'SEED2'
From: kk@ddzt.old
To: eva@ddzt.old
Subject: Re: 欢迎使用 ddzt.old 内网邮件系统
Content-Type: text/plain; charset=UTF-8

eva，收到！

邮件收发正常。后续 OA 上的邮件都走这个系统。

-- kk@ddzt.old
SEED2
    sleep 2
    date > /var/lib/oa-seeded
    ok "已投递 2 封示例邮件 (eva <-> kk)"
    fi

    # admin 邮箱单独用标记文件，兼容此前已投递过 eva/kk 示例邮件的服务器
    if [ -f /var/lib/oa-seeded-admin ]; then
        ok "admin 示例邮件已投递过（/var/lib/oa-seeded-admin），跳过"
    else
    sendmail -t <<'SEED3'
From: eva@ddzt.old
To: admin@ddzt.old
Subject: 欢迎使用 ddzt.old 内网邮件系统（管理员）
Content-Type: text/plain; charset=UTF-8

admin，你好：

这是给管理员的示例邮件，用于验证 admin@ddzt.old 邮箱。
OA 门户与邮箱使用同一套账号口令，登录 OA 后进入「邮件」模块会自动关联，无需再次登录。

-- eva@ddzt.old
SEED3
    sleep 1
    date > /var/lib/oa-seeded-admin
    ok "已投递 admin 示例邮件"
    fi
fi

# =============================================================================
#  二、校验
# =============================================================================
say "===== 校验开始 ====="

say "-- [邮件域] postfix --"
vver "postfix" postconf mail_version
vcmd "postfix mydestination 含 $MAIL_DOMAIN" bash -c "postconf -n | grep '^mydestination' | grep -q '$MAIL_DOMAIN'"
vcmd "postfix home_mailbox = Maildir/" bash -c "postconf -n | grep -q '^home_mailbox = Maildir/'"
vcmd "postfix 允许 30MB+ 邮件（附件）" bash -c "postconf -h message_size_limit | awk '\$1 >= 30000000 {found=1} END {exit !found}'"
vcmd "postfix inet_interfaces=all（LAN 可达）" bash -c "postconf -n | grep -q '^inet_interfaces = all'"

say "-- [邮件域] dovecot --"
vver "dovecot" dovecot --version
vcmd "dovecot mail_location = maildir" bash -c "doveconf -n | grep -q 'mail_location = maildir'"
vcmd "dovecot 允许明文认证（内网演示）" bash -c "doveconf -n | grep -q 'disable_plaintext_auth = no'"
vcmd "dovecot 关闭强制 SSL（143 端口可明文登录）" bash -c "doveconf -n | grep -q '^ssl = no'"

say "-- [邮件用户] --"
vcmd "用户 eva 存在（eva@$MAIL_DOMAIN）" id eva
vcmd "用户 kk 存在（kk@$MAIL_DOMAIN）"  id kk
vcmd "用户 admin 存在（admin@$MAIL_DOMAIN）" id admin

say "-- [webmail 后端] --"
vcmd "php imap 扩展已加载" bash -c "php -m | grep -qi imap"

say "-- [OA 应用] --"
vcmd "nginx 配置合法" nginx -t
vcmd "OA 首页文件存在 ($WEB_ROOT/index.html)" test -f "$WEB_ROOT/index.html"
vcmd "webmail API 文件存在 ($WEB_ROOT/api/mail.php)" test -f "$WEB_ROOT/api/mail.php"
vcmd "文件共享 API 文件存在 ($WEB_ROOT/api/files.php)" test -f "$WEB_ROOT/api/files.php"
vcmd "OA 登录 API 文件存在 ($WEB_ROOT/api/auth.php)" test -f "$WEB_ROOT/api/auth.php"
vcmd "OA 账号配置文件存在 ($WEB_ROOT/api/users.php)" test -f "$WEB_ROOT/api/users.php"
vcmd "文件共享存储属主 apache" bash -c "test -d /var/www/oa-share/files && [ \"\$(stat -c %U /var/www/oa-share/files)\" = apache ]"
vcmd "PHP 上传上限 20M" bash -c "php -i 2>/dev/null | grep -q 'upload_max_filesize => 20M'"
vcmd "PHP post_max_size 26M（含附件）" bash -c "php -i 2>/dev/null | grep -q 'post_max_size => 26M'"
vcmd "nginx 允许 26m 请求体（含附件）" bash -c "grep -q 'client_max_body_size 26m' /etc/nginx/conf.d/oa.conf"
vcmd "OA 首页可访问 http://$MAIL_DOMAIN/" bash -c "curl -s -m 5 http://$MAIL_DOMAIN/ | grep -qi 'oa'"
vcmd "webmail API 响应正常" bash -c "curl -s -m 5 -X POST -d 'action=me' http://$MAIL_DOMAIN/api/mail.php | $PYBIN -c 'import sys,json; d=json.load(sys.stdin); assert \"ok\" in d'"
vcmd "文件共享 API 未登录 401" bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -d 'action=list' http://$MAIL_DOMAIN/api/files.php | grep -qx 401"
vcmd "OA 登录接口响应正常（未登录 401）" bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -d 'action=me' http://$MAIL_DOMAIN/api/auth.php | grep -qx 401"
vcmd "OA 登录返回管理员角色（admin）" bash -c "curl -s -m 5 -X POST -d 'action=login&username=admin@ddzt.old&password=$ADMINPASS' http://$MAIL_DOMAIN/api/auth.php | grep -q '\"role\":\"admin\"'"
vcmd "文件共享上传未登录被拒绝（401）" bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -d 'action=upload' http://$MAIL_DOMAIN/api/files.php | grep -qx 401"
vcmd "公告/日程 API 文件存在 ($WEB_ROOT/api/content.php)" test -f "$WEB_ROOT/api/content.php"
vcmd "公告/日程默认内容文件存在" test -f "$WEB_ROOT/api/content_defaults.json"
vcmd "个人待办 API 文件存在 ($WEB_ROOT/api/todos.php)" test -f "$WEB_ROOT/api/todos.php"
vcmd "公告/日程数据目录属主 apache" bash -c "test -d /var/www/oa-data && [ \"\$(stat -c %U /var/www/oa-data)\" = apache ]"
vcmd "公告/日程接口未登录 401" bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' 'http://$MAIL_DOMAIN/api/content.php?action=data' | grep -qx 401"
vcmd "个人待办接口未登录 401" bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' 'http://$MAIL_DOMAIN/api/todos.php?action=list' | grep -qx 401"
vcmd "公告/日程接口登录后可读" bash -c "curl -s -m 5 -c /tmp/oa_content_ck -X POST -d 'action=login&username=admin@ddzt.old&password=$ADMINPASS' http://$MAIL_DOMAIN/api/auth.php >/dev/null; curl -s -m 5 -b /tmp/oa_content_ck 'http://$MAIL_DOMAIN/api/content.php?action=data' | grep -q '\"notices\"'; rm -f /tmp/oa_content_ck"
vcmd "个人待办接口登录后可读" bash -c "curl -s -m 5 -c /tmp/oa_todo_ck -X POST -d 'action=login&username=admin@ddzt.old&password=$ADMINPASS' http://$MAIL_DOMAIN/api/auth.php >/dev/null; curl -s -m 5 -b /tmp/oa_todo_ck 'http://$MAIL_DOMAIN/api/todos.php?action=list' | grep -q '\"todos\"'; rm -f /tmp/oa_todo_ck"
vcmd "个人待办数据库属主 apache" bash -c "test -f /var/www/oa-data/todos.sqlite && [ \"\$(stat -c %U /var/www/oa-data/todos.sqlite)\" = apache ]"

say "-- [邮件收发链路] --"
vport 25  "postfix SMTP"
vport 143 "dovecot IMAP"
vcmd "IMAP 登录 eva@$MAIL_DOMAIN 可用" env IMAP_USER="eva@$MAIL_DOMAIN" IMAP_PASS="$EVAPASS" "$PYBIN" -c "import os,imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login(os.environ['IMAP_USER'], os.environ['IMAP_PASS']); print('IMAP_OK')"
vcmd "IMAP 登录 admin@$MAIL_DOMAIN 可用" env IMAP_USER="admin@$MAIL_DOMAIN" IMAP_PASS="$ADMINPASS" "$PYBIN" -c "import os,imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login(os.environ['IMAP_USER'], os.environ['IMAP_PASS']); print('IMAP_OK')"
vcmd "SMTP 本机提交可用" "$PYBIN" -c "import smtplib; s=smtplib.SMTP('127.0.0.1'); s.ehlo(); s.quit(); print('SMTP_OK')"
for u in eva kk admin; do
    # 已读邮件会从 new/ 移到 cur/，只数 new/ 会在读过邮件后误报「收件箱为空」
    n=$(find "/home/$u/Maildir/new" "/home/$u/Maildir/cur" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        ok "$u@$MAIL_DOMAIN 收件箱含 $n 封邮件（new+cur）"; PASS=$((PASS+1))
    else
        warn "$u@$MAIL_DOMAIN 收件箱为空（若刚部署请稍候重试）"; WARNS=$((WARNS+1))
    fi
done

# =============================================================================
#  三、汇总
# =============================================================================
echo
say "===== 校验汇总: PASS=$PASS  FAIL=$FAIL  WARN=$WARNS ====="
if [ "$FAIL" -gt 0 ]; then
    die "存在 $FAIL 项失败，请按上方 [x] 标记逐项排查"
fi
ok "OA 系统 + 邮件系统部署/校验通过"
ok "访问入口: http://$MAIL_DOMAIN/  （登录账号即邮箱：eva@ddzt.old/rei、kk@ddzt.old/zmjjkk、admin@ddzt.old/admin）"
exit 0
