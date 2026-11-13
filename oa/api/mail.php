<?php
/**
 * oa/api/mail.php — webmail 后端（ddzt.old 内网邮件，邮件系统唯一后端）
 *
 * 读取：Dovecot IMAP 127.0.0.1:143（php-imap 扩展）
 * 发送：Postfix SMTP 127.0.0.1:25（本机提交免认证，mynetworks 含 127.0.0.0/8）
 * 附件：写信时随 multipart/form-data 上传，后端拼 multipart/mixed 交给 SMTP；
 *       发件副本用 imap_append 存入 Sent 箱，所以「已发送」里的附件也能查看/下载。
 * 运行环境：PHP 5.4（CentOS 7），注意不得使用 PHP7 语法（??、类型声明等）
 *
 * API 契约（POST application/x-www-form-urlencoded；带附件时 multipart/form-data）：
 *   action=me                 -> {ok:true,data:{user}} | {ok:false,error:"未登录"}
 *   action=login  username password -> {ok:true,data:{user}}
 *   action=logout             -> {ok:true,data:{message}}
 *   action=list   [folder]    -> {ok:true,data:{messages:[{uid,subject,from,from_addr,to,to_addr,
 *                                date,seen,snippet,has_attachment,attachment_count}],folder,
 *                                counts:{INBOX,Sent}}}
 *   action=read   uid [folder] -> {ok:true,data:{uid,subject,from,from_addr,to,date,folder,
 *                                body_text,attachments:[{part,filename,size,mime}]}}
 *   action=send   to subject body [attachments[]] -> {ok:true,data:{message,saved,attachments:[name]}}
 *   action=delete uid [folder] -> {ok:true,data:{message:"已删除"}}
 *   action=attachment（GET） folder uid part -> 附件文件流（强制 attachment 下载）
 *
 * folder 只允许 INBOX / Sent（缺省 INBOX），part 为 IMAP MIME 段号（如 2、1.2）。
 */
error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED);
ini_set('display_errors', '0');
session_start();
header('Content-Type: application/json; charset=utf-8');

define('IMAP_HOST', '127.0.0.1');
define('IMAP_PORT', 143);
define('SMTP_HOST', '127.0.0.1');
define('SMTP_PORT', 25);
define('MAIL_DOMAIN', 'ddzt.old');
define('FOLDER_INBOX', 'INBOX');
define('FOLDER_SENT', 'Sent');
define('MAX_ATTACH_TOTAL', 20 * 1024 * 1024);   /* 全部附件合计 20MB */
define('MAX_ATTACH_FILES', 10);

/* ----------------------------- 基础输出 ----------------------------- */
function jout($arr) { echo json_encode($arr, JSON_UNESCAPED_UNICODE); exit; }
function jok($data) { jout(array('ok' => true, 'data' => $data)); }
function jerr($msg) { jout(array('ok' => false, 'error' => $msg)); }

/* ----------------------------- 编解码辅助 --------------------------- */
function to_utf8($s, $charset) {
    if ($s === '' || $s === null) return '';
    $c = strtoupper(trim((string)$charset));
    if ($c === '' || $c === 'UTF-8' || $c === 'UTF8' || $c === 'DEFAULT' || $c === 'US-ASCII') {
        return $s;
    }
    if ($c === 'GB2312' || $c === 'GB18030') $c = 'GBK';
    $t = @iconv($c, 'UTF-8//IGNORE', $s);
    if ($t !== false && $t !== '') return $t;
    if (function_exists('mb_convert_encoding')) {
        $t = @mb_convert_encoding($s, 'UTF-8', $charset);
        if ($t !== false) return $t;
    }
    return $s;
}

function hdr_decode($s) {
    if ($s === '' || $s === null) return '';
    $parts = @imap_mime_header_decode($s);
    if (!is_array($parts)) return $s;
    $out = '';
    foreach ($parts as $p) {
        $text = $p->text;
        $cs = isset($p->charset) ? $p->charset : 'default';
        $out .= to_utf8($text, $cs);
    }
    return $out;
}

function parse_addr($s) {
    $s = trim(hdr_decode($s));
    if (preg_match('/^(.*)<([^>]+)>$/s', $s, $m)) {
        return array(trim(trim($m[1]), '"'), trim($m[2]));
    }
    return array($s, $s);
}

function part_charset($part) {
    if (isset($part->parameters) && is_array($part->parameters)) {
        foreach ($part->parameters as $p) {
            if (strtolower($p->attribute) === 'charset') return $p->value;
        }
    }
    return 'UTF-8';
}

/* RFC2231 参数值（filename*=UTF-8''%E4%B8%AD）去掉 charset'' 并解码 */
function rfc2231_value($value) {
    $v = preg_replace("/^[^']*'[^']*'/", '', (string)$value);
    return rawurldecode($v);
}

/* 取 MIME 段文件名：优先 dparameters(filename* / filename)，再 parameters(name* / name) */
function part_filename($part) {
    $cands = array();
    if (isset($part->dparameters) && is_array($part->dparameters)) {
        foreach ($part->dparameters as $p) {
            $a = strtolower($p->attribute);
            if ($a === 'filename*') {
                $n = trim(rfc2231_value($p->value));
                if ($n !== '') return $n;
            } elseif ($a === 'filename') {
                $cands[] = $p->value;
            }
        }
    }
    if (isset($part->parameters) && is_array($part->parameters)) {
        foreach ($part->parameters as $p) {
            $a = strtolower($p->attribute);
            if ($a === 'name*') {
                $n = trim(rfc2231_value($p->value));
                if ($n !== '') return $n;
            } elseif ($a === 'name') {
                $cands[] = $p->value;
            }
        }
    }
    foreach ($cands as $c) {
        $n = trim(hdr_decode($c));
        if ($n !== '') return $n;
    }
    return '';
}

/* 是否附件段：有文件名、显式 disposition=attachment，或内嵌 message/rfc822 */
function is_attachment_part($part) {
    if (part_filename($part) !== '') return true;
    if (isset($part->disposition) && strtoupper($part->disposition) === 'ATTACHMENT') return true;
    if (isset($part->type) && (int)$part->type === 2) return true;   /* TYPEMESSAGE(message/rfc822) */
    return false;
}

/* PHP 的 imap_fetchstructure 把主类型返回成数字常量（0=TEXT…），这里转成 "TEXT/PLAIN" 形式 */
function part_type($part) {
    static $map = array(
        0 => 'TEXT', 1 => 'MULTIPART', 2 => 'MESSAGE', 3 => 'APPLICATION',
        4 => 'AUDIO', 5 => 'IMAGE', 6 => 'VIDEO', 7 => 'OTHER',
    );
    $type = isset($part->type) ? (int)$part->type : 0;
    $main = isset($map[$type]) ? $map[$type] : 'OTHER';
    $sub  = isset($part->subtype) ? strtoupper($part->subtype) : 'OCTET-STREAM';
    return $main . '/' . $sub;
}

function part_decoded_size($part) {
    $bytes = isset($part->bytes) ? (int)$part->bytes : 0;
    if ($bytes <= 0) return 0;
    $enc = isset($part->encoding) ? (int)$part->encoding : 0;
    if ($enc === 3) {
        /* $bytes 是 base64 文本（含每 76 字符的 CRLF），先折算成纯 base64 字符数再 ×3/4；
           仅用于界面展示，允许 1 字节级误差 */
        $chars = (int)round($bytes * 76 / 78);
        return (int)floor($chars * 3 / 4);
    }
    if ($enc === 4) return (int)floor($bytes * 0.97);   /* quoted-printable 近似 */
    return $bytes;
}

/* 递归查找指定 MIME 子类型，返回 array(编号, part对象) 或 false；跳过带文件名的附件段 */
function find_part($struct, $want, $prefix = '') {
    if (isset($struct->parts) && is_array($struct->parts)) {
        foreach ($struct->parts as $i => $p) {
            $num = ($prefix === '') ? (string)($i + 1) : $prefix . '.' . ($i + 1);
            $r = find_part($p, $want, $num);
            if ($r !== false) return $r;
        }
        return false;
    }
    $t = part_type($struct);
    if ($t === $want && part_filename($struct) === '') return array($prefix, $struct);
    return false;
}

function decode_coded($raw, $enc) {
    switch ((int)$enc) {
        case 3: return base64_decode($raw);
        case 4: return quoted_printable_decode($raw);
        default: return $raw;   /* 0=7bit 1=8bit 2=binary */
    }
}

function fetch_part($mbox, $uid, $num, $part, $peek) {
    $opt = FT_UID | ($peek ? FT_PEEK : 0);
    $raw = ($num === '') ? @imap_body($mbox, $uid, $opt)
                         : @imap_fetchbody($mbox, $uid, $num, $opt);
    $enc = isset($part->encoding) ? $part->encoding : 0;
    return decode_coded((string)$raw, $enc);
}

/* 提取纯文本正文：优先 TEXT/PLAIN，否则 TEXT/HTML 去标签；均跳过附件段 */
function get_body($mbox, $uid, $struct, $peek) {
    if (!$struct) return '';
    $hit = find_part($struct, 'TEXT/PLAIN');
    if ($hit === false) {
        $hit = find_part($struct, 'TEXT/HTML');
        if ($hit === false) return '（此邮件无文本正文）';
        list($num, $p) = $hit;
        $html = fetch_part($mbox, $uid, $num, $p, $peek);
        $html = preg_replace('/<(br|\/p|\/div|\/tr|\/li)[^>]*>/i', "\n", $html);
        $text = html_entity_decode(strip_tags($html), ENT_QUOTES, 'UTF-8');
        return to_utf8($text, part_charset($p));
    }
    list($num, $p) = $hit;
    return to_utf8(fetch_part($mbox, $uid, $num, $p, $peek), part_charset($p));
}

/* 递归收集附件元数据（part 为 IMAP 段号，下载时沿用） */
function collect_attachments($struct, $prefix = '') {
    $out = array();
    if (is_attachment_part($struct)) {
        $num = ($prefix === '') ? '1' : $prefix;
        $name = part_filename($struct);
        if ($name === '') $name = 'attachment';
        $out[] = array(
            'part'     => $num,
            'filename' => $name,
            'size'     => part_decoded_size($struct),
            'mime'     => part_type($struct),
        );
        return $out;
    }
    if (isset($struct->parts) && is_array($struct->parts)) {
        foreach ($struct->parts as $i => $p) {
            $num = ($prefix === '') ? (string)($i + 1) : $prefix . '.' . ($i + 1);
            $sub = collect_attachments($p, $num);
            foreach ($sub as $a) $out[] = $a;
        }
    }
    return $out;
}

/* 按段号 1 / 2 / 1.2 取回 MIME 节点 */
function find_part_by_number($struct, $num) {
    if ($num === '' || !preg_match('/^\d+(\.\d+)*$/', $num)) return false;
    $node = $struct;
    foreach (explode('.', $num) as $idx) {
        $i = ((int)$idx) - 1;
        if ($i < 0) return false;
        if (!isset($node->parts) || !is_array($node->parts)) {
            return ($node === $struct && $num === '1') ? $struct : false;   /* 单段邮件 */
        }
        if (!isset($node->parts[$i])) return false;
        $node = $node->parts[$i];
    }
    return $node;
}

function overview($mbox, $uid) {
    $list = @imap_fetch_overview($mbox, (string)$uid, FT_UID);
    return (is_array($list) && isset($list[0])) ? $list[0] : false;
}

/* ----------------------------- 邮箱 / 目录 -------------------------- */
function norm_folder($folder) {
    return (isset($folder) && strcasecmp(trim((string)$folder), FOLDER_SENT) === 0)
        ? FOLDER_SENT : FOLDER_INBOX;
}

function imap_box($folder) {
    $name = ($folder === FOLDER_SENT) ? FOLDER_SENT : FOLDER_INBOX;
    return '{' . IMAP_HOST . ':' . IMAP_PORT . '/imap/novalidate-cert}' . $name;
}

function mbox_open($folder) {
    $box = imap_box($folder);
    $mbox = @imap_open($box, $_SESSION['mail_user'], $_SESSION['mail_pass']);
    if (!$mbox && $folder === FOLDER_SENT) {
        /* 已发送箱可能尚未创建：先用 INBOX 连接 CREATE + SUBSCRIBE 再重试 */
        $inbox = @imap_open(imap_box(FOLDER_INBOX), $_SESSION['mail_user'], $_SESSION['mail_pass']);
        if ($inbox) {
            @imap_createmailbox($inbox, $box);
            @imap_subscribe($inbox, $box);
            imap_close($inbox);
            $mbox = @imap_open($box, $_SESSION['mail_user'], $_SESSION['mail_pass']);
        }
    }
    if (!$mbox) throw new Exception('IMAP 连接失败，请重新登录');
    return $mbox;
}

function folder_count($mbox, $folder) {
    $st = @imap_status($mbox, imap_box($folder), SA_MESSAGES);
    if ($st && isset($st->messages)) return (int)$st->messages;
    return 0;
}

/* ----------------------------- 附件上传 ----------------------------- */
function upload_error_message($code) {
    $map = array(
        UPLOAD_ERR_INI_SIZE  => '附件超过 PHP 上传大小限制',
        UPLOAD_ERR_FORM_SIZE => '附件超过表单大小限制',
        UPLOAD_ERR_PARTIAL   => '附件只上传了一部分，请重试',
        UPLOAD_ERR_NO_FILE   => '未选择附件',
        UPLOAD_ERR_NO_TMP_DIR => '服务器临时目录不可用',
        UPLOAD_ERR_CANT_WRITE => '服务器写入临时文件失败',
        UPLOAD_ERR_EXTENSION => '上传被扩展中断',
    );
    return isset($map[$code]) ? $map[$code] : '附件上传失败';
}

function sanitize_filename($name) {
    $name = str_replace('\\', '/', (string)$name);
    $name = basename($name);
    $name = preg_replace('/[\x00-\x1f\x7f]/', '', $name);
    $name = trim($name);
    if ($name === '' || $name === '.' || $name === '..') $name = 'attachment';
    if (function_exists('mb_substr')) {
        $name = mb_substr($name, 0, 120, 'UTF-8');
    } else {
        $name = substr($name, 0, 120);
    }
    return $name;
}

function sanitize_mime($type) {
    $type = trim((string)$type);
    if (preg_match('#^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$#', $type)) return $type;
    return 'application/octet-stream';
}

function gather_uploads() {
    if (!isset($_FILES['attachments'])) return array();
    $raw = $_FILES['attachments'];
    $files = array();
    if (is_array($raw['name'])) {
        $n = count($raw['name']);
        for ($i = 0; $i < $n; $i++) {
            $files[] = array(
                'name'     => $raw['name'][$i],
                'type'     => $raw['type'][$i],
                'tmp_name' => $raw['tmp_name'][$i],
                'error'    => $raw['error'][$i],
                'size'     => $raw['size'][$i],
            );
        }
    } else {
        $files[] = $raw;
    }
    return $files;
}

/* 读取并校验全部上传附件，返回 array(array(name,type,data))；失败抛异常 */
function read_uploads() {
    $inputs = gather_uploads();
    $files = array();
    $total = 0;
    foreach ($inputs as $f) {
        $err = (int)$f['error'];
        if ($err === UPLOAD_ERR_NO_FILE) continue;
        if ($err !== UPLOAD_ERR_OK) throw new Exception(upload_error_message($err));
        $size = (int)$f['size'];
        if ($size <= 0) throw new Exception('附件不能是空文件：' . sanitize_filename($f['name']));
        $total += $size;
        if ($total > MAX_ATTACH_TOTAL) throw new Exception('全部附件合计不能超过 20MB');
        if (!is_uploaded_file($f['tmp_name'])) throw new Exception('附件上传校验失败，请重试');
        $data = @file_get_contents($f['tmp_name']);
        if ($data === false) throw new Exception('读取附件失败，请重试');
        $files[] = array(
            'name' => sanitize_filename($f['name']),
            'type' => sanitize_mime($f['type']),
            'data' => $data,
        );
    }
    if (count($files) > MAX_ATTACH_FILES) {
        throw new Exception('最多添加 ' . MAX_ATTACH_FILES . ' 个附件');
    }
    return $files;
}

/* ----------------------------- MIME 构造 ---------------------------- */
function mime_param($name) {
    $name = preg_replace('/[\r\n"]/', '', (string)$name);
    return '=?UTF-8?B?' . base64_encode($name) . '?=';
}

function ascii_filename($name) {
    $f = preg_replace('/[^\x20-\x7e]/', '_', (string)$name);
    $f = preg_replace('/["\\\\\r\n]/', '_', $f);
    return $f === '' ? 'attachment' : $f;
}

function build_mime_message($from, $to, $subject, $body, $files) {
    $boundary = '=_oa_' . md5(uniqid('', true));
    $msg  = 'From: <' . $from . ">\r\n";
    $msg .= 'To: <' . $to . ">\r\n";
    $msg .= 'Subject: =?UTF-8?B?' . base64_encode($subject) . "?=\r\n";
    $msg .= 'Date: ' . date('r') . "\r\n";
    $msg .= 'Message-ID: <' . md5(uniqid('', true)) . '@' . MAIL_DOMAIN . ">\r\n";
    $msg .= "MIME-Version: 1.0\r\n";
    $msg .= 'Content-Type: multipart/mixed; boundary="' . $boundary . "\"\r\n\r\n";
    $msg .= "This is a multi-part message in MIME format.\r\n";
    $msg .= '--' . $boundary . "\r\n";
    $msg .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $msg .= "Content-Transfer-Encoding: base64\r\n\r\n";
    $msg .= chunk_split(base64_encode($body), 76, "\r\n");
    foreach ($files as $f) {
        $msg .= '--' . $boundary . "\r\n";
        $msg .= 'Content-Type: ' . $f['type'] . '; name="' . mime_param($f['name']) . "\"\r\n";
        $msg .= "Content-Transfer-Encoding: base64\r\n";
        $msg .= 'Content-Disposition: attachment; filename="' . mime_param($f['name']) . "\"\r\n\r\n";
        $msg .= chunk_split(base64_encode($f['data']), 76, "\r\n");
    }
    $msg .= '--' . $boundary . "--\r\n";
    return $msg;
}

/* ----------------------------- SMTP 发送 ---------------------------- */
function smtp_send($from, $to, $raw) {
    $fp = @fsockopen(SMTP_HOST, SMTP_PORT, $errno, $errstr, 10);
    if (!$fp) throw new Exception('SMTP 连接失败：' . $errstr);
    stream_set_timeout($fp, 20);
    $expect = function ($fp, $code) {
        $reply = '';
        while ($line = fgets($fp, 2048)) {
            $reply .= $line;
            if (isset($line[3]) && $line[3] === ' ') break;
        }
        if (strpos($reply, (string)$code) !== 0) {
            throw new Exception('SMTP 服务器拒绝：' . trim($reply));
        }
    };
    $expect($fp, 220);
    fwrite($fp, "EHLO ddzt.old\r\n");              $expect($fp, 250);
    fwrite($fp, 'MAIL FROM:<' . $from . ">\r\n");  $expect($fp, 250);
    fwrite($fp, 'RCPT TO:<' . $to . ">\r\n");      $expect($fp, 250);
    fwrite($fp, "DATA\r\n");                        $expect($fp, 354);

    /* SMTP 点填充：正文里以 "." 开头的行前面再加一个 "."，避免被当成结束符 */
    $data = preg_replace('/^\./m', '..', $raw);
    if (substr($data, -2) !== "\r\n") $data .= "\r\n";
    fwrite($fp, $data . ".\r\n");                   $expect($fp, 250);
    fwrite($fp, "QUIT\r\n");
    fclose($fp);
}

/* 发件副本存入 Sent 箱（失败不影响已投递的邮件，仅标记 saved=false） */
function save_to_sent($raw) {
    $mbox = mbox_open(FOLDER_INBOX);
    $sent = imap_box(FOLDER_SENT);
    @imap_createmailbox($mbox, $sent);
    @imap_subscribe($mbox, $sent);
    $ok = @imap_append($mbox, $sent, $raw, '\\Seen');
    imap_close($mbox);
    return (bool)$ok;
}

/* ----------------------------- 附件下载 ----------------------------- */
function mail_attachment_download($user) {
    if ($user === '') {
        http_response_code(401);
        jerr('未登录');
    }
    $folder = norm_folder(isset($_GET['folder']) ? $_GET['folder'] : '');
    $uid    = isset($_GET['uid']) ? intval($_GET['uid']) : 0;
    $part   = isset($_GET['part']) ? trim((string)$_GET['part']) : '';
    if ($uid <= 0 || !preg_match('/^\d+(\.\d+)*$/', $part)) {
        http_response_code(400);
        jerr('参数错误');
    }
    $mbox = mbox_open($folder);
    $struct = @imap_fetchstructure($mbox, $uid, FT_UID);
    if (!$struct) {
        imap_close($mbox);
        http_response_code(404);
        jerr('邮件不存在');
    }
    $node = find_part_by_number($struct, $part);
    if (!$node || !is_attachment_part($node)) {
        imap_close($mbox);
        http_response_code(404);
        jerr('附件不存在或已被删除');
    }
    $fetchNum = $part;
    if ($fetchNum === '1' && !isset($struct->parts)) $fetchNum = '';
    $data = fetch_part($mbox, $uid, $fetchNum, $node, true);
    imap_close($mbox);

    $filename = part_filename($node);
    if ($filename === '') $filename = 'attachment';
    $fallback = ascii_filename($filename);
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . strlen($data));
    header('Content-Disposition: attachment; filename="' . $fallback . '"; filename*=UTF-8\'\'' . rawurlencode($filename));
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: private, no-store');
    echo $data;
    exit;
}

/* ----------------------------- 派发 -------------------------------- */
$action = isset($_POST['action']) ? $_POST['action']
          : (isset($_GET['action']) ? $_GET['action'] : '');
$user = isset($_SESSION['mail_user']) ? $_SESSION['mail_user'] : '';

/* post_max_size 超限时 PHP 会丢弃整个 POST，这里给出可读提示而不是「未知操作」 */
if ($action === '' && isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST'
    && empty($_POST) && empty($_FILES) && !empty($_SERVER['CONTENT_LENGTH'])) {
    jerr('提交内容超过服务器限制，请压缩附件或减少附件数量后重试');
}

// 会改变状态的动作只接受 POST：避免 <img src=".../mail.php?action=delete&uid=1"> 这类 CSRF
$MUTATING = array('login', 'logout', 'send', 'delete', 'mark');
if (in_array($action, $MUTATING) && (!isset($_SERVER['REQUEST_METHOD']) || $_SERVER['REQUEST_METHOD'] !== 'POST')) {
    jerr('该操作只接受 POST 请求');
}

try {
    if ($action === 'attachment') {
        mail_attachment_download($user);
    }

    switch ($action) {

        case 'me':
            if ($user === '') jerr('未登录');
            jok(array('user' => $user));

        case 'login': {
            $username = isset($_POST['username']) ? trim($_POST['username']) : '';
            $password = isset($_POST['password']) ? $_POST['password'] : '';
            if ($username === '' || $password === '') jerr('请输入账号和密码');
            if (strpos($username, '@') === false) {
                $username .= '@' . MAIL_DOMAIN;
            } elseif (strcasecmp(substr($username, strpos($username, '@') + 1), MAIL_DOMAIN) !== 0) {
                // Dovecot 用 %n 剥域后按系统账号认证，不限制域等于允许任意系统用户登录
                jerr('只允许 ' . MAIL_DOMAIN . ' 的邮箱登录');
            }
            $box = imap_box(FOLDER_INBOX);
            $mbox = @imap_open($box, $username, $password);
            if (!$mbox) jerr('账号或密码错误');
            /* 提前创建「已发送」箱，保证登录后能直接查看发件附件 */
            @imap_createmailbox($mbox, imap_box(FOLDER_SENT));
            @imap_subscribe($mbox, imap_box(FOLDER_SENT));
            imap_close($mbox);
            session_regenerate_id(true);       // 防会话固定
            $_SESSION['mail_user'] = $username;
            $_SESSION['mail_pass'] = $password;
            jok(array('user' => $username));
        }

        case 'logout':
            unset($_SESSION['mail_user'], $_SESSION['mail_pass']);
            jok(array('message' => '已退出'));

        case 'list': {
            if ($user === '') jerr('未登录');
            $folder = norm_folder(isset($_POST['folder']) ? $_POST['folder'] : '');
            $mbox = mbox_open($folder);
            $uids = imap_search($mbox, 'ALL', SE_UID);
            $total = $uids ? count($uids) : 0;
            $messages = array();
            if ($uids) {
                $uids = array_slice(array_reverse($uids), 0, 100);  /* 新邮件在前 */
                foreach ($uids as $uid) {
                    $ov = overview($mbox, $uid);
                    if (!$ov) continue;
                    $struct = @imap_fetchstructure($mbox, $uid, FT_UID);
                    list($name, $addr) = parse_addr(isset($ov->from) ? $ov->from : '');
                    list($tname, $taddr) = parse_addr(isset($ov->to) ? $ov->to : '');
                    $snip = preg_replace('/\s+/u', ' ', get_body($mbox, $uid, $struct, true));
                    $snip = function_exists('mb_substr') ? mb_substr($snip, 0, 80)
                                                         : substr($snip, 0, 80);
                    $atts = collect_attachments($struct);
                    $row = array(
                        'uid'       => (int)$uid,
                        'subject'   => hdr_decode(isset($ov->subject) ? $ov->subject : '(无主题)'),
                        'from'      => ($name !== '' ? $name : $addr),
                        'from_addr' => $addr,
                        'to'        => ($tname !== '' ? $tname : $taddr),
                        'to_addr'   => $taddr,
                        'date'      => isset($ov->date) ? date('Y-m-d H:i', strtotime($ov->date)) : '',
                        'seen'      => isset($ov->seen) ? (bool)$ov->seen : true,
                        'snippet'   => $snip,
                        'has_attachment'    => count($atts) > 0,
                        'attachment_count'  => count($atts),
                    );
                    $messages[] = $row;
                }
            }
            $counts = array(FOLDER_INBOX => 0, FOLDER_SENT => 0);
            $counts[$folder] = $total;
            $other = ($folder === FOLDER_SENT) ? FOLDER_INBOX : FOLDER_SENT;
            $counts[$other] = folder_count($mbox, $other);
            imap_close($mbox);
            jok(array('messages' => $messages, 'folder' => $folder, 'counts' => $counts));
        }

        case 'read': {
            if ($user === '') jerr('未登录');
            $uid = isset($_POST['uid']) ? intval($_POST['uid']) : 0;
            if ($uid <= 0) jerr('参数错误');
            $folder = norm_folder(isset($_POST['folder']) ? $_POST['folder'] : '');
            $mbox = mbox_open($folder);
            $ov = overview($mbox, $uid);
            if (!$ov) { imap_close($mbox); jerr('邮件不存在'); }
            $struct = @imap_fetchstructure($mbox, $uid, FT_UID);
            $body = get_body($mbox, $uid, $struct, false);
            if ($folder === FOLDER_INBOX) {
                @imap_setflag_full($mbox, (string)$uid, '\\Seen', ST_UID);
            }
            list($name, $addr) = parse_addr(isset($ov->from) ? $ov->from : '');
            $data = array(
                'uid'       => $uid,
                'subject'   => hdr_decode(isset($ov->subject) ? $ov->subject : '(无主题)'),
                'from'      => ($name !== '' ? $name : $addr),
                'from_addr' => $addr,
                'to'        => hdr_decode(isset($ov->to) ? $ov->to : ''),
                'date'      => isset($ov->date) ? date('Y-m-d H:i', strtotime($ov->date)) : '',
                'folder'    => $folder,
                'body_text' => $body,
                'attachments' => collect_attachments($struct),
            );
            imap_close($mbox);
            jok($data);
        }

        case 'send': {
            if ($user === '') jerr('未登录');
            $to      = isset($_POST['to']) ? trim($_POST['to']) : '';
            $subject = isset($_POST['subject']) ? trim($_POST['subject']) : '';
            $body    = isset($_POST['body']) ? $_POST['body'] : '';
            if (!preg_match('/^[^@\s]+@[^@\s]+$/', $to)) jerr('收件人格式不正确');
            if ($subject === '') jerr('请填写主题');
            $subject = str_replace(array("\r", "\n"), ' ', $subject);
            $files = read_uploads();                       // 先校验附件，避免发出半成品
            $raw = build_mime_message($user, $to, $subject, $body, $files);
            smtp_send($user, $to, $raw);
            $saved = false;
            try {
                $saved = save_to_sent($raw);
            } catch (Exception $e) {
                $saved = false;                            // 已投递成功，存档失败只提示
            }
            $names = array();
            foreach ($files as $f) $names[] = $f['name'];
            jok(array('message' => '邮件已发送', 'saved' => $saved, 'attachments' => $names));
        }

        case 'delete': {
            if ($user === '') jerr('未登录');
            $uid = isset($_POST['uid']) ? intval($_POST['uid']) : 0;
            if ($uid <= 0) jerr('参数错误');
            $folder = norm_folder(isset($_POST['folder']) ? $_POST['folder'] : '');
            $mbox = mbox_open($folder);
            @imap_setflag_full($mbox, (string)$uid, '\\Deleted', ST_UID);
            imap_expunge($mbox);
            imap_close($mbox);
            jok(array('message' => '已删除'));
        }

        default:
            jerr('未知操作');
    }
} catch (Exception $e) {
    jerr($e->getMessage());
}
