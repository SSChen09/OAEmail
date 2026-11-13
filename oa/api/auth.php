<?php
/**
 * oa/api/auth.php — OA 账号登录（服务端会话，PHP 5.4 兼容）
 *
 * 登录账号就是邮箱地址：eva@ddzt.old / rei、kk@ddzt.old / zmjjkk、admin@ddzt.old / admin。
 * 账号表在 oa/api/users.php，密码只保存 bcrypt 哈希。
 * 会话变量：$_SESSION['oa_user']（完整邮箱）、$_SESSION['oa_role']（admin/user）、$_SESSION['oa_login_at']；
 * 登录成功后同步建立邮箱会话（mail_user/mail_pass），邮件模块无需二次登录。
 *
 * API 契约（响应 {ok:true,data:…} / {ok:false,error:…}）：
 *   action=login   POST username password -> {ok:true,data:{user,role}}；失败 401
 *   action=me              -> {ok:true,data:{user,role}}；未登录 401
 *   action=logout  POST    -> {ok:true,data:{message}}
 *
 * 说明：除 login 外的写操作只接受 POST；未登录一律 401。
 */
error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED);
ini_set('display_errors', '0');
ini_set('session.cookie_httponly', '1');
session_start();
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

require_once dirname(__FILE__) . '/users.php';

function jout($arr) { echo json_encode($arr, JSON_UNESCAPED_UNICODE); exit; }
function jok($data) { jout(array('ok' => true, 'data' => $data)); }
function jerr($msg) { jout(array('ok' => false, 'error' => $msg)); }

/* 常量时间字符串比较（PHP 5.6 起才有 hash_equals） */
function slow_equals($a, $b) {
    if (!is_string($a) || !is_string($b) || strlen($a) !== strlen($b)) return false;
    $diff = 0;
    $len = strlen($a);
    for ($i = 0; $i < $len; $i++) {
        $diff |= ord($a[$i]) ^ ord($b[$i]);
    }
    return $diff === 0;
}

function current_user() {
    $user = isset($_SESSION['oa_user']) ? (string)$_SESSION['oa_user'] : '';
    if ($user !== '' && strpos($user, '@') === false) {
        /* 兼容旧会话：早先保存的是短账号 eva，统一成邮箱 */
        $user .= '@ddzt.old';
        $_SESSION['oa_user'] = $user;
    }
    return $user;
}

/* 当前登录角色：admin 可修改/保存 OA 内容，user 只读 */
function current_role() {
    if (isset($_SESSION['oa_role'])) return (string)$_SESSION['oa_role'];
    $user = current_user();
    if ($user === '') return '';
    global $OA_ROLES;
    $local = substr($user, 0, strpos($user, '@'));
    $role = isset($OA_ROLES[$local]) ? $OA_ROLES[$local] : 'user';
    $_SESSION['oa_role'] = $role;
    return $role;
}

/* 规范化登录账号：只接受 ddzt.old 邮箱，返回小写完整邮箱，非法时返回空串 */
function norm_login_mail($user) {
    $user = strtolower(trim((string)$user));
    $at = strpos($user, '@');
    if ($at === false) return '';
    $local = substr($user, 0, $at);
    $domain = substr($user, $at + 1);
    if ($local === '' || $domain !== 'ddzt.old') return '';
    if (!preg_match('/^[a-z0-9][a-z0-9._-]*$/', $local)) return '';
    return $local . '@ddzt.old';
}

$method = isset($_SERVER['REQUEST_METHOD']) ? strtoupper($_SERVER['REQUEST_METHOD']) : 'GET';
$action = isset($_REQUEST['action']) && is_string($_REQUEST['action']) ? (string)$_REQUEST['action'] : 'me';

/* 未登录时 me 返回 401，前端据此显示登录页 */
if ($action === 'me') {
    $user = current_user();
    if ($user === '') {
        http_response_code(401);
        jerr('未登录');
    }
    jok(array('user' => $user, 'role' => current_role()));
}

if ($action === 'logout') {
    if ($method !== 'POST') {
        http_response_code(405);
        jerr('该操作只允许 POST');
    }
    $_SESSION = array();
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
    }
    @session_destroy();
    jok(array('message' => '已退出登录'));
}

if ($action === 'login') {
    if ($method !== 'POST') {
        http_response_code(405);
        jerr('该操作只允许 POST');
    }
    $username = isset($_POST['username']) && is_string($_POST['username']) ? trim((string)$_POST['username']) : '';
    $password = isset($_POST['password']) && is_string($_POST['password']) ? (string)$_POST['password'] : '';
    if ($username === '' || $password === '') {
        http_response_code(400);
        jerr('请输入邮箱账号和密码');
    }
    $email = norm_login_mail($username);
    $local = $email === '' ? '' : substr($email, 0, strpos($email, '@'));
    if ($email === '' || !isset($OA_USERS[$local]) || !slow_equals(crypt($password, $OA_USERS[$local]), $OA_USERS[$local])) {
        /* 简单延时，降低在线爆破速度 */
        usleep(300000);
        http_response_code(401);
        jerr('邮箱账号或密码错误');
    }
    session_regenerate_id(true);
    $_SESSION['oa_user'] = $email;
    $_SESSION['oa_login_at'] = time();
    $_SESSION['oa_role'] = isset($OA_ROLES[$local]) ? $OA_ROLES[$local] : 'user';
    /* 门户与邮箱联动：同一套账号口令，登录 OA 时顺带建立邮箱会话 */
    unset($_SESSION['mail_user'], $_SESSION['mail_pass']);
    if (isset($OA_MAIL[$local]) && function_exists('imap_open')) {
        $mbox = @imap_open('{127.0.0.1:143/imap/notls}INBOX', $email, $password);
        if ($mbox) {
            imap_close($mbox);
            $_SESSION['mail_user'] = $email;
            $_SESSION['mail_pass'] = $password;
        }
    }
    jok(array('user' => $email, 'role' => $_SESSION['oa_role']));
}

http_response_code(400);
jerr('未知操作');
