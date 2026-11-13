<?php
/**
 * ddzt.old 协同办公 OA —— 公告 / 日程内容接口
 *
 * 所有登录用户可读；仅 admin 可新增、修改、删除。
 * 数据保存在 /var/www/oa-data/content.json（php-fpm 以 apache 运行，
 * 部署脚本会创建该目录并授权）。首次访问时用同目录 content_defaults.json 初始化。
 *
 * API：
 *   GET  ?action=data                                -> {notices:[...], schedule:[...]}
 *   POST action=notice_save   id,title,dept,date,pinned,body
 *   POST action=notice_delete id
 *   POST action=schedule_save id,day,time,title,place
 *   POST action=schedule_delete id
 */

ini_set('session.cookie_httponly', '1');
session_start();

require_once dirname(__FILE__) . '/users.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

define('CONTENT_DIR', '/var/www/oa-data');
define('CONTENT_FILE', CONTENT_DIR . '/content.json');
define('CONTENT_DEFAULTS', dirname(__FILE__) . '/content_defaults.json');

function jout($code, $payload) {
    http_response_code($code);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE);
    exit;
}

function jok($data) { jout(200, array('ok' => true, 'data' => $data)); }
function jerr($code, $message) { jout($code, array('ok' => false, 'error' => $message)); }

function post_only() {
    if (strtoupper($_SERVER['REQUEST_METHOD']) !== 'POST') {
        jerr(405, '该操作仅支持 POST 请求');
    }
}

function content_user() {
    if (empty($_SESSION['oa_user'])) {
        jerr(401, '请先登录 OA 账号');
    }
    return $_SESSION['oa_user'];
}

function content_role($user) {
    if (!empty($_SESSION['oa_role'])) return $_SESSION['oa_role'];
    global $OA_ROLES;
    $name = strtolower($user);
    if (strpos($name, '@') !== false) $name = substr($name, 0, strpos($name, '@'));
    return (isset($OA_ROLES[$name]) && $OA_ROLES[$name] === 'admin') ? 'admin' : 'user';
}

function content_require_admin() {
    $user = content_user();
    if (content_role($user) !== 'admin') {
        jerr(403, '仅管理员可新增、修改或删除公告与日程');
    }
    return $user;
}

function valid_date($value) {
    if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $value, $m)) return false;
    return checkdate((int)$m[2], (int)$m[3], (int)$m[1]);
}

function clean_text($value, $maxBytes) {
    $value = trim((string)$value);
    $value = str_replace("\0", '', $value);
    if ($maxBytes <= 0) return '';
    if (strlen($value) <= $maxBytes) return $value;
    if (function_exists('mb_strcut')) {
        return mb_strcut($value, 0, $maxBytes, 'UTF-8');
    }
    $value = substr($value, 0, $maxBytes);
    /* 去掉可能被截断的半个 UTF-8 字符，避免 json_encode 失败写坏数据文件 */
    while ($value !== '' && (ord(substr($value, -1)) & 0xC0) === 0x80) {
        $value = substr($value, 0, -1);
    }
    return $value;
}

function read_defaults() {
    if (!is_readable(CONTENT_DEFAULTS)) return array('notices' => array(), 'schedule' => array());
    $raw = file_get_contents(CONTENT_DEFAULTS);
    $data = json_decode($raw, true);
    if (!is_array($data)) return array('notices' => array(), 'schedule' => array());
    return array(
        'notices' => isset($data['notices']) && is_array($data['notices']) ? $data['notices'] : array(),
        'schedule' => isset($data['schedule']) && is_array($data['schedule']) ? $data['schedule'] : array()
    );
}

function load_data() {
    if (is_readable(CONTENT_FILE)) {
        $raw = file_get_contents(CONTENT_FILE);
        $data = json_decode($raw, true);
        if (is_array($data) && isset($data['notices']) && isset($data['schedule'])) {
            return $data;
        }
    }
    /* 首次访问/文件损坏：用默认内容初始化 */
    $data = read_defaults();
    @mkdir(CONTENT_DIR, 0775, true);
    @file_put_contents(CONTENT_FILE, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), LOCK_EX);
    return $data;
}

function save_data($data) {
    @mkdir(CONTENT_DIR, 0775, true);
    $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    if ($json === false) {
        jerr(500, '内容编码失败：文本包含无法识别的字符，请修改后重试');
    }
    $ok = @file_put_contents(CONTENT_FILE, $json, LOCK_EX);
    if ($ok === false) {
        jerr(500, '内容保存失败，请检查服务器数据目录权限');
    }
}

function next_id($list) {
    $max = 0;
    foreach ($list as $item) {
        if (isset($item['id']) && (int)$item['id'] > $max) $max = (int)$item['id'];
    }
    return $max + 1;
}

function index_of($list, $id) {
    foreach ($list as $i => $item) {
        if (isset($item['id']) && (int)$item['id'] === (int)$id) return $i;
    }
    return -1;
}

function sort_notices(&$notices) {
    usort($notices, function ($a, $b) {
        $pa = !empty($a['pinned']) ? 1 : 0;
        $pb = !empty($b['pinned']) ? 1 : 0;
        if ($pa !== $pb) return $pb - $pa;
        $cmp = strcmp(isset($b['date']) ? $b['date'] : '', isset($a['date']) ? $a['date'] : '');
        if ($cmp !== 0) return $cmp;
        return (int)$b['id'] - (int)$a['id'];
    });
}

$action = isset($_REQUEST['action']) ? (string)$_REQUEST['action'] : 'data';
if ($action === '') $action = 'data';

if ($action === 'data') {
    content_user();
    $data = load_data();
    sort_notices($data['notices']);
    jok(array('notices' => $data['notices'], 'schedule' => $data['schedule']));
}

/* 以下均为写操作：仅 POST + 管理员 */
post_only();
content_require_admin();
$data = load_data();

if ($action === 'notice_save') {
    $id = isset($_POST['id']) ? (int)$_POST['id'] : 0;
    $title = clean_text(isset($_POST['title']) ? $_POST['title'] : '', 300);
    $dept = clean_text(isset($_POST['dept']) ? $_POST['dept'] : '', 90);
    $date = clean_text(isset($_POST['date']) ? $_POST['date'] : '', 10);
    $pinned = (isset($_POST['pinned']) && (string)$_POST['pinned'] === '1') ? 1 : 0;
    $bodyRaw = isset($_POST['body']) ? (string)$_POST['body'] : '';
    if ($title === '') jerr(400, '请填写公告标题');
    if ($dept === '') jerr(400, '请填写发布部门');
    if (!valid_date($date)) jerr(400, '发布日期格式应为 YYYY-MM-DD');
    if (strlen($bodyRaw) > 20000) jerr(400, '公告正文过长（最多 20000 字节）');
    $paragraphs = array();
    foreach (preg_split('/\r\n|\r|\n/', $bodyRaw) as $line) {
        $line = trim($line);
        if ($line !== '') $paragraphs[] = $line;
    }
    if (count($paragraphs) > 60) $paragraphs = array_slice($paragraphs, 0, 60);

    if ($id > 0) {
        $idx = index_of($data['notices'], $id);
        if ($idx < 0) jerr(404, '公告不存在或已被删除');
        $data['notices'][$idx]['title'] = $title;
        $data['notices'][$idx]['dept'] = $dept;
        $data['notices'][$idx]['date'] = $date;
        $data['notices'][$idx]['pinned'] = $pinned;
        $data['notices'][$idx]['body'] = $paragraphs;
        $message = '公告已保存';
    } else {
        if (count($data['notices']) >= 300) jerr(400, '公告数量已达上限');
        $new = array(
            'id' => next_id($data['notices']),
            'title' => $title,
            'dept' => $dept,
            'date' => $date,
            'pinned' => $pinned,
            'body' => $paragraphs
        );
        $data['notices'][] = $new;
        $id = $new['id'];
        $message = '公告已发布';
    }
    sort_notices($data['notices']);
    save_data($data);
    jok(array('message' => $message, 'id' => $id, 'notices' => $data['notices'], 'schedule' => $data['schedule']));
}

if ($action === 'notice_delete') {
    $id = isset($_POST['id']) ? (int)$_POST['id'] : 0;
    if ($id <= 0) jerr(400, '参数不完整');
    $idx = index_of($data['notices'], $id);
    if ($idx < 0) jerr(404, '公告不存在或已被删除');
    array_splice($data['notices'], $idx, 1);
    save_data($data);
    jok(array('message' => '公告已删除', 'notices' => $data['notices'], 'schedule' => $data['schedule']));
}

if ($action === 'schedule_save') {
    $id = isset($_POST['id']) ? (int)$_POST['id'] : 0;
    $day = clean_text(isset($_POST['day']) ? $_POST['day'] : '', 120);
    $time = clean_text(isset($_POST['time']) ? $_POST['time'] : '', 120);
    $title = clean_text(isset($_POST['title']) ? $_POST['title'] : '', 300);
    $place = clean_text(isset($_POST['place']) ? $_POST['place'] : '', 300);
    if ($day === '') jerr(400, '请填写日期或星期');
    if ($time === '') jerr(400, '请填写时间');
    if ($title === '') jerr(400, '请填写日程事项');
    $item = array('id' => 0, 'day' => $day, 'time' => $time, 'title' => $title, 'place' => $place);
    if ($id > 0) {
        $idx = index_of($data['schedule'], $id);
        if ($idx < 0) jerr(404, '日程不存在或已被删除');
        $item['id'] = $id;
        $data['schedule'][$idx] = $item;
        $message = '日程已保存';
    } else {
        if (count($data['schedule']) >= 800) jerr(400, '日程数量已达上限');
        $item['id'] = next_id($data['schedule']);
        $data['schedule'][] = $item;
        $id = $item['id'];
        $message = '日程已添加';
    }
    save_data($data);
    jok(array('message' => $message, 'id' => $id, 'notices' => $data['notices'], 'schedule' => $data['schedule']));
}

if ($action === 'schedule_delete') {
    $id = isset($_POST['id']) ? (int)$_POST['id'] : 0;
    if ($id <= 0) jerr(400, '参数不完整');
    $idx = index_of($data['schedule'], $id);
    if ($idx < 0) jerr(404, '日程不存在或已被删除');
    array_splice($data['schedule'], $idx, 1);
    save_data($data);
    jok(array('message' => '日程已删除', 'notices' => $data['notices'], 'schedule' => $data['schedule']));
}

jerr(400, '未知操作');
