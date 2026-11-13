#!/bin/bash
# =============================================================================
#  OA 系统（前端演示版）+ 邮件系统（完整可用）部署脚本 — 服务端 192.168.1.137
# =============================================================================
#  前置: 1_server_deps.sh 已执行（nginx/php-fpm/mariadb/postfix/dovecot/php-imap）
#  内容: (1) 邮件域 ddzt.old + 用户 eva@/kk@（postfix/dovecot）
#        (2) OA 应用部署 /var/www/oa（除邮件外均为前端演示，无业务后端）
#        (3) 示例邮件投递 + 全量校验
#  特点: 幂等，可重复执行；--check 仅校验不改动
#  用法: bash 4_oa_mail_setup.sh            部署 + 校验
#        bash 4_oa_mail_setup.sh --check    仅校验
#  账号: eva@ddzt.old / eva    kk@ddzt.old / kk   （演示口令）
# =============================================================================
set -u

SERVER_IP="${SERVER_IP:-192.168.1.137}"
MAIL_DOMAIN="${MAIL_DOMAIN:-ddzt.old}"
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

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# =============================================================================
#  一、部署（--check 跳过）
# =============================================================================
if [ "$CHECK_ONLY" = "0" ]; then

    say "===== [1/5] 邮件域 $MAIL_DOMAIN 与用户 eva/kk ====="
    # postfix: 接收 ddzt.old 本地邮件 + Maildir 投递格式
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, $MAIL_DOMAIN, mail.$MAIL_DOMAIN"
    postconf -e 'home_mailbox = Maildir/'
    postfix check && ok "postfix 配置合法 (mydestination + home_mailbox=Maildir/)"
    systemctl restart postfix && ok "postfix 已重启"
    for u in eva kk; do
        if id -u "$u" >/dev/null 2>&1; then
            ok "用户 $u 已存在 ($u@$MAIL_DOMAIN)"
        else
            useradd -m -s /bin/bash "$u" || die "创建用户 $u 失败"
            echo "$u:$u" | chpasswd
            ok "已创建用户 $u@$MAIL_DOMAIN（口令 $u）"
        fi
    done

    say "===== [2/5] dovecot 邮箱格式与认证 ====="
    # Maildir 格式与 postfix home_mailbox 对齐
    sed -i 's|^#\?[[:space:]]*mail_location[[:space:]]*=.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
    grep -q '^mail_location = maildir:~/Maildir' /etc/dovecot/conf.d/10-mail.conf \
        || echo 'mail_location = maildir:~/Maildir' >> /etc/dovecot/conf.d/10-mail.conf
    # 内网演示环境允许明文认证（Thunderbird/IMAP 143 直连）
    sed -i 's|^#\?[[:space:]]*disable_plaintext_auth[[:space:]]*=.*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
    grep -q '^disable_plaintext_auth = no' /etc/dovecot/conf.d/10-auth.conf \
        || echo 'disable_plaintext_auth = no' >> /etc/dovecot/conf.d/10-auth.conf
    # 允许 eva@ddzt.old 全名登录（%n 取 @ 前本地部分做系统认证）
    sed -i 's|^#\?[[:space:]]*auth_username_format[[:space:]]*=.*|auth_username_format = %n|' /etc/dovecot/conf.d/10-auth.conf
    grep -q '^auth_username_format = %n' /etc/dovecot/conf.d/10-auth.conf \
        || echo 'auth_username_format = %n' >> /etc/dovecot/conf.d/10-auth.conf
    doveconf -n >/dev/null 2>&1 && ok "dovecot 配置合法 (maildir + 明文认证 + %n)"
    systemctl restart dovecot && ok "dovecot 已重启"

    say "===== [3/5] php-imap（webmail 后端读取 IMAP）====="
    rpm -q php-imap >/dev/null 2>&1 || yum install -y php-imap || warn "php-imap 安装失败"
    systemctl restart php-fpm && ok "php-fpm 已重启（加载 imap 扩展）"

    say "===== [4/5] OA 应用部署 -> $WEB_ROOT ====="
    [ -d "$DEPLOY_SRC" ] || die "未找到 $DEPLOY_SRC，请先用 tools/push_deploy.py 上传"
    rm -rf "$WEB_ROOT"
    cp -r "$DEPLOY_SRC" "$WEB_ROOT" || die "复制 OA 文件失败"
    find "$WEB_ROOT" -type d -exec chmod 755 {} \;
    find "$WEB_ROOT" -type f -exec chmod 644 {} \;
    ok "OA 文件已部署到 $WEB_ROOT"
    cat > /etc/nginx/conf.d/oa.conf <<NGINX_CONF
server {
    listen 80;
    server_name $MAIL_DOMAIN oa.$MAIL_DOMAIN www.$MAIL_DOMAIN $SERVER_IP;
    root $WEB_ROOT;
    index index.html;
    charset utf-8;
    client_max_body_size 20m;

    location /static/ {
        expires 7d;
        access_log off;
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
    nginx -t && systemctl restart nginx && ok "nginx OA 站点已启用 (server_name: $MAIL_DOMAIN)"

    say "===== [5/5] 示例邮件投递 ====="
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
    ok "已投递 2 封示例邮件 (eva <-> kk)"
fi

# =============================================================================
#  二、校验
# =============================================================================
say "===== 校验开始 ====="

say "-- [邮件域] postfix --"
vver "postfix" postconf mail_version
vcmd "postfix mydestination 含 $MAIL_DOMAIN" bash -c "postconf -n | grep '^mydestination' | grep -q '$MAIL_DOMAIN'"
vcmd "postfix home_mailbox = Maildir/" bash -c "postconf -n | grep -q '^home_mailbox = Maildir/'"
vcmd "postfix inet_interfaces=all（LAN 可达）" bash -c "postconf -n | grep -q '^inet_interfaces = all'"

say "-- [邮件域] dovecot --"
vver "dovecot" dovecot --version
vcmd "dovecot mail_location = maildir" bash -c "doveconf -n | grep -q 'mail_location = maildir'"
vcmd "dovecot 允许明文认证（内网演示）" bash -c "doveconf -n | grep -q 'disable_plaintext_auth = no'"

say "-- [邮件用户] --"
vcmd "用户 eva 存在（eva@$MAIL_DOMAIN）" id eva
vcmd "用户 kk 存在（kk@$MAIL_DOMAIN）"  id kk

say "-- [webmail 后端] --"
vcmd "php imap 扩展已加载" bash -c "php -m | grep -qi imap"

say "-- [OA 应用] --"
vcmd "nginx 配置合法" nginx -t
vcmd "OA 首页文件存在 ($WEB_ROOT/index.html)" test -f "$WEB_ROOT/index.html"
vcmd "webmail API 文件存在 ($WEB_ROOT/api/mail.php)" test -f "$WEB_ROOT/api/mail.php"
vcmd "OA 首页可访问 http://$MAIL_DOMAIN/" bash -c "curl -s -m 5 http://$MAIL_DOMAIN/ | grep -qi 'oa'"
vcmd "webmail API 响应正常" bash -c "curl -s -m 5 -X POST -d 'action=me' http://$MAIL_DOMAIN/api/mail.php | grep -q '\"ok\"'"

say "-- [邮件收发链路] --"
vport 25  "postfix SMTP"
vport 143 "dovecot IMAP"
vcmd "IMAP 登录 eva@$MAIL_DOMAIN 可用" bash -c "python3 -c \"import imaplib; M=imaplib.IMAP4('127.0.0.1'); M.login('eva@$MAIL_DOMAIN','eva'); print('IMAP_OK')\""
vcmd "SMTP 本机提交可用" bash -c "python3 -c \"import smtplib; s=smtplib.SMTP('127.0.0.1'); s.ehlo(); s.quit(); print('SMTP_OK')\""
for u in eva kk; do
    n=$(ls "/home/$u/Maildir/new" 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        ok "$u@$MAIL_DOMAIN 收件箱含 $n 封邮件"; PASS=$((PASS+1))
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
ok "访问入口: http://$MAIL_DOMAIN/  （邮件模块账号 eva@$MAIL_DOMAIN / eva、kk@$MAIL_DOMAIN / kk）"
exit 0
