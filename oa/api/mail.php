<?php
/**
 * oa/api/mail.php — webmail 后端（ddzt.old 内网邮件，邮件系统唯一后端）
 *
 * 读取：Dovecot IMAP 127.0.0.1:143（php-imap 扩展）
 * 发送：Postfix SMTP 127.0.0.1:25（本机提交免认证，mynetworks 含 127.0.0.0/8）
 * 运行环境：PHP 5.4（CentOS 7），注意不得使用 PHP7 语法（??、类型声明等）
 *
 * API 契约（POST application/x-www-form-urlencoded，响应 JSON）：
 *   action=me                 -> {ok:true,data:{user}} | {ok:false,error:"未登录"}
 *   action=login  username password -> {ok:true,data:{user}}
 *   action=logout             -> {ok:true,data:{message}}
 *   action=list               -> {ok:true,data:{messages:[{uid,subject,from,from_addr,date,seen,snippet}]}}
 *   action=read   uid         -> {ok:true,data:{uid,subject,from,from_addr,to,date,body_text}}
 *   action=send   to subject body -> {ok:true,data:{message:"邮件已发送"}}
 *   action=delete uid         -> {ok:true,data:{message:"已删除"}}
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

/* 递归查找指定 MIME 子类型，返回 array(编号, part对象) 或 false */
function find_part($struct, $want, $prefix = '') {
    if (isset($struct->parts) && is_array($struct->parts)) {
        foreach ($struct->parts as $i => $p) {
            $num = ($prefix === '') ? (string)($i + 1) : $prefix . '.' . ($i + 1);
            $r = find_part($p, $want, $num);
            if ($r !== false) return $r;
        }
        return false;
    }
    $t = strtoupper($struct->type . '/' . $struct->subtype);
    if ($t === $want) return array($prefix, $struct);
    return false;
}

function decode_coded($raw, $enc) {
    switch ((int)$enc) {
        case 2: return base64_decode($raw);
        case 3: return quoted_printable_decode($raw);
        default: return $raw;   /* 0=7bit 1=8bit */
    }
}

/* 提取纯文本正文：优先 TEXT/PLAIN，否则 TEXT/HTML 去标签 */
function get_body($mbox, $uid) {
    $struct = @imap_fetchstructure($mbox, $uid, FT_UID);
    if (!$struct) return '';
    $hit = find_part($struct, 'TEXT/PLAIN');
    if ($hit === false) {
        $hit = find_part($struct, 'TEXT/HTML');
        if ($hit === false) return '（此邮件无文本正文）';
        list($num, $p) = $hit;
        $raw = ($num === '') ? @imap_body($mbox, $uid, FT_UID)
                             : @imap_fetchbody($mbox, $uid, $num, FT_UID);
        $html = decode_coded((string)$raw, $p->encoding);
        $html = preg_replace('/<(br|\/p|\/div|\/tr|\/li)[^>]*>/i', "\n", $html);
        $text = html_entity_decode(strip_tags($html), ENT_QUOTES, 'UTF-8');
        return to_utf8($text, part_charset($p));
    }
    list($num, $p) = $hit;
    $raw = ($num === '') ? @imap_body($mbox, $uid, FT_UID)
                         : @imap_fetchbody($mbox, $uid, $num, FT_UID);
    return to_utf8(decode_coded((string)$raw, $p->encoding), part_charset($p));
}

function overview($mbox, $uid) {
    $list = @imap_fetch_overview($mbox, (string)$uid, FT_UID);
    return (is_array($list) && isset($list[0])) ? $list[0] : false;
}

function mbox_open() {
    $box = '{' . IMAP_HOST . ':' . IMAP_PORT . '/imap/novalidate-cert}INBOX';
    $mbox = @imap_open($box, $_SESSION['mail_user'], $_SESSION['mail_pass']);
    if (!$mbox) throw new Exception('IMAP 连接失败，请重新登录');
    return $mbox;
}

/* ----------------------------- SMTP 发送 ---------------------------- */
function smtp_send($from, $to, $subject, $body) {
    $fp = @fsockopen(SMTP_HOST, SMTP_PORT, $errno, $errstr, 10);
    if (!$fp) throw new Exception('SMTP 连接失败：' . $errstr);
    stream_set_timeout($fp, 10);
    $expect = function ($fp, $code) {
        $reply = '';
        while ($line = fgets($fp, 512)) {
            $reply .= $line;
            if (isset($line[3]) && $line[3] === ' ') break;
        }
        if (strpos($reply, (string)$code) !== 0) {
            throw new Exception('SMTP 服务器拒绝：' . trim($reply));
        }
    };
    $expect($fp, 220);
    fwrite($fp, "EHLO ddzt.old\r\n");            $expect($fp, 250);
    fwrite($fp, "MAIL FROM:<" . $from . ">\r\n"); $expect($fp, 250);
    fwrite($fp, "RCPT TO:<" . $to . ">\r\n");    $expect($fp, 250);
    fwrite($fp, "DATA\r\n");                      $expect($fp, 354);

    $subj = '=?UTF-8?B?' . base64_encode($subject) . '?=';
    $msg  = "From: <" . $from . ">\r\n";
    $msg .= "To: <" . $to . ">\r\n";
    $msg .= "Subject: " . $subj . "\r\n";
    $msg .= "Date: " . date('r') . "\r\n";
    $msg .= "MIME-Version: 1.0\r\n";
    $msg .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $msg .= "Content-Transfer-Encoding: base64\r\n\r\n";
    $msg .= chunk_split(base64_encode($body), 76, "\r\n");
    fwrite($fp, $msg . "\r\n.\r\n");               $expect($fp, 250);
    fwrite($fp, "QUIT\r\n");
    fclose($fp);
}

/* ----------------------------- 派发 -------------------------------- */
$action = isset($_POST['action']) ? $_POST['action']
          : (isset($_GET['action']) ? $_GET['action'] : '');
$user = isset($_SESSION['mail_user']) ? $_SESSION['mail_user'] : '';

try {
    switch ($action) {

        case 'me':
            if ($user === '') jerr('未登录');
            jok(array('user' => $user));

        case 'login': {
            $username = isset($_POST['username']) ? trim($_POST['username']) : '';
            $password = isset($_POST['password']) ? $_POST['password'] : '';
            if ($username === '' || $password === '') jerr('请输入账号和密码');
            if (strpos($username, '@') === false) $username .= '@' . MAIL_DOMAIN;
            $box = '{' . IMAP_HOST . ':' . IMAP_PORT . '/imap/novalidate-cert}INBOX';
            $mbox = @imap_open($box, $username, $password);
            if (!$mbox) jerr('账号或密码错误');
            imap_close($mbox);
            $_SESSION['mail_user'] = $username;
            $_SESSION['mail_pass'] = $password;
            jok(array('user' => $username));
        }

        case 'logout':
            unset($_SESSION['mail_user'], $_SESSION['mail_pass']);
            jok(array('message' => '已退出'));

        case 'list': {
            if ($user === '') jerr('未登录');
            $mbox = mbox_open();
            $uids = imap_search($mbox, 'ALL', SE_UID);
            $messages = array();
            if ($uids) {
                $uids = array_slice(array_reverse($uids), 0, 100);  /* 新邮件在前 */
                foreach ($uids as $uid) {
                    $ov = overview($mbox, $uid);
                    if (!$ov) continue;
                    list($name, $addr) = parse_addr(isset($ov->from) ? $ov->from : '');
                    $snip = preg_replace('/\s+/u', ' ', get_body($mbox, $uid));
                    $snip = function_exists('mb_substr') ? mb_substr($snip, 0, 80)
                                                         : substr($snip, 0, 80);
                    $messages[] = array(
                        'uid'       => (int)$uid,
                        'subject'   => hdr_decode(isset($ov->subject) ? $ov->subject : '(无主题)'),
                        'from'      => ($name !== '' ? $name : $addr),
                        'from_addr' => $addr,
                        'date'      => isset($ov->date) ? date('Y-m-d H:i', strtotime($ov->date)) : '',
                        'seen'      => isset($ov->seen) ? (bool)$ov->seen : true,
                        'snippet'   => $snip,
                    );
                }
            }
            imap_close($mbox);
            jok(array('messages' => $messages));
        }

        case 'read': {
            if ($user === '') jerr('未登录');
            $uid = isset($_POST['uid']) ? intval($_POST['uid']) : 0;
            if ($uid <= 0) jerr('参数错误');
            $mbox = mbox_open();
            $ov = overview($mbox, $uid);
            if (!$ov) { imap_close($mbox); jerr('邮件不存在'); }
            $body = get_body($mbox, $uid);
            @imap_setflag_full($mbox, (string)$uid, '\\Seen', ST_UID);
            list($name, $addr) = parse_addr(isset($ov->from) ? $ov->from : '');
            $data = array(
                'uid'       => $uid,
                'subject'   => hdr_decode(isset($ov->subject) ? $ov->subject : '(无主题)'),
                'from'      => ($name !== '' ? $name : $addr),
                'from_addr' => $addr,
                'to'        => hdr_decode(isset($ov->to) ? $ov->to : ''),
                'date'      => isset($ov->date) ? date('Y-m-d H:i', strtotime($ov->date)) : '',
                'body_text' => $body,
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
            smtp_send($user, $to, $subject, $body);
            jok(array('message' => '邮件已发送'));
        }

        case 'delete': {
            if ($user === '') jerr('未登录');
            $uid = isset($_POST['uid']) ? intval($_POST['uid']) : 0;
            if ($uid <= 0) jerr('参数错误');
            $mbox = mbox_open();
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
