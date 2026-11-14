<?php
/**
 * ddzt.old 协同办公 OA —— 个人待办接口
 *
 * 每个账号（OA 邮箱）拥有独立的待办清单，数据保存在服务端 SQLite：
 *   /var/www/oa-data/todos.sqlite
 *
 * API（均需登录 OA，未登录 401）：
 *   GET  ?action=list                         -> {ok:true,data:{todos:[...],count}}
 *   POST action=save   id,text,done,due       -> {ok:true,data:{todos:[...],message}}
 *        id 为空/0 表示新增；id 有值表示编辑自己的待办
 *   POST action=delete id                     -> {ok:true,data:{todos:[...],message}}
 *
 * 权限：只能读写自己的待办；id 不属于当前账号时按“不存在”返回 404。
 * 首次访问时，为当前账号写入一份与旧版演示一致的默认待办，之后完全独立。
 * 运行环境：PHP 5.4（CentOS 7），不得使用 PHP7 语法
 */

error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED);
ini_set('display_errors', '0');
date_default_timezone_set('Asia/Shanghai');
ini_set('session.cookie_httponly', '1');
session_start();

require_once dirname(__FILE__) . '/users.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

define('TODO_DIR', '/var/www/oa-data');
define('TODO_DB', TODO_DIR . '/todos.sqlite');
define('TODO_MAX_ITEMS', 200);
define('TODO_MAX_LEN', 200);

set_exception_handler(function ($e) {
    if (headers_sent()) {
        return;
    }
    jerr(500, '服务器内部错误：' . $e->getMessage());
});

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

function todo_user() {
    if (empty($_SESSION['oa_user'])) {
        jerr(401, '请先登录 OA 账号');
    }
    return (string) $_SESSION['oa_user'];
}

function todo_db() {
    static $pdo = null;
    if ($pdo !== null) {
        return $pdo;
    }
    if (!is_dir(TODO_DIR)) {
        @mkdir(TODO_DIR, 0775, true);
    }
    try {
        $pdo = new PDO('sqlite:' . TODO_DB);
    } catch (PDOException $e) {
        jerr(500, '待办数据库打开失败，请检查服务器数据目录权限');
    }
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec('PRAGMA busy_timeout = 5000');
    $pdo->exec('PRAGMA journal_mode = WAL');
    $pdo->exec('CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user TEXT NOT NULL,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        due TEXT NOT NULL DEFAULT \'\',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )');
    $pdo->exec('CREATE INDEX IF NOT EXISTS idx_todos_user ON todos(user)');
    $pdo->exec('CREATE TABLE IF NOT EXISTS todo_seed (user TEXT PRIMARY KEY)');
    return $pdo;
}

/* 首次访问的默认待办（与旧版前端演示数据一致），每个账号各一份 */
function todo_defaults() {
    return array(
        array('提交 11 月部门考勤汇总表', '2026-11-13', 0),
        array('审核办公用品采购申请（3 笔）', '2026-11-12', 0),
        array('准备年度工作总结大会部门汇报材料', '2026-11-17', 0),
        array('回复技术部服务器机房巡检结果', '2026-11-12', 0),
        array('整理新员工入职档案（陈静）', '2026-11-14', 0),
        array('更新内网通讯录分机号', '2026-11-16', 1),
        array('确认生日会场地布置方案', '2026-11-13', 0),
        array('归档 10 月用章审批记录', '2026-11-15', 0)
    );
}

function todo_seed($user) {
    $pdo = todo_db();
    $now = date('Y-m-d H:i:s');
    $pdo->beginTransaction();
    try {
        $stmt = $pdo->prepare('INSERT OR IGNORE INTO todo_seed (user) VALUES (?)');
        $stmt->execute(array($user));
        if ($stmt->rowCount() > 0) {
            $ins = $pdo->prepare('INSERT INTO todos (user, text, done, due, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)');
            foreach (todo_defaults() as $row) {
                $ins->execute(array($user, $row[0], (int) $row[2], $row[1], $now, $now));
            }
        }
        $pdo->commit();
    } catch (Exception $e) {
        $pdo->rollBack();
        jerr(500, '初始化待办失败，请稍后重试');
    }
}

function todo_rows($user) {
    $stmt = todo_db()->prepare('SELECT id, text, done, due FROM todos WHERE user = ?
        ORDER BY done ASC, CASE WHEN due = \'\' THEN 1 ELSE 0 END ASC, due ASC, id ASC');
    $stmt->execute(array($user));
    $rows = array();
    foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $rows[] = array(
            'id' => (int) $row['id'],
            'text' => (string) $row['text'],
            'done' => ((int) $row['done']) === 1,
            'due' => (string) $row['due']
        );
    }
    return $rows;
}

function todo_result($message) {
    $user = todo_user();
    jok(array(
        'todos' => todo_rows($user),
        'message' => $message
    ));
}

function valid_due($value) {
    if ($value === '') {
        return true;
    }
    if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $value, $m)) {
        return false;
    }
    return checkdate((int) $m[2], (int) $m[3], (int) $m[1]);
}

$action = '';
if (isset($_POST['action'])) {
    $action = $_POST['action'];
} elseif (isset($_GET['action'])) {
    $action = $_GET['action'];
}

if ($action === 'list') {
    $user = todo_user();
    todo_seed($user);
    $todos = todo_rows($user);
    jok(array('todos' => $todos, 'count' => count($todos)));
}

if ($action === 'save') {
    post_only();
    $user = todo_user();
    todo_seed($user);
    $id = isset($_POST['id']) ? (int) $_POST['id'] : 0;
    $text = isset($_POST['text']) ? trim((string) $_POST['text']) : '';
    $text = str_replace("\0", '', $text);
    if ($text === '') {
        jerr(400, '待办内容不能为空');
    }
    $len = function_exists('mb_strlen') ? mb_strlen($text, 'UTF-8') : strlen($text);
    if ($len > TODO_MAX_LEN) {
        jerr(400, '待办内容最多 ' . TODO_MAX_LEN . ' 个字');
    }
    $done = (isset($_POST['done']) && (string) $_POST['done'] === '1') ? 1 : 0;
    $due = isset($_POST['due']) ? trim((string) $_POST['due']) : '';
    if (!valid_due($due)) {
        jerr(400, '截止日期格式不正确（示例：2026-11-30）');
    }
    $now = date('Y-m-d H:i:s');
    $pdo = todo_db();
    if ($id > 0) {
        $stmt = $pdo->prepare('SELECT id FROM todos WHERE id = ? AND user = ?');
        $stmt->execute(array($id, $user));
        if (!$stmt->fetch()) {
            jerr(404, '待办不存在或已被删除');
        }
        $upd = $pdo->prepare('UPDATE todos SET text = ?, done = ?, due = ?, updated_at = ? WHERE id = ? AND user = ?');
        $upd->execute(array($text, $done, $due, $now, $id, $user));
        todo_result('待办已更新');
    }
    $stmt = $pdo->prepare('SELECT COUNT(*) AS n FROM todos WHERE user = ?');
    $stmt->execute(array($user));
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if ((int) $row['n'] >= TODO_MAX_ITEMS) {
        jerr(400, '待办最多保存 ' . TODO_MAX_ITEMS . ' 条，请先清理已完成事项');
    }
    $ins = $pdo->prepare('INSERT INTO todos (user, text, done, due, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)');
    $ins->execute(array($user, $text, $done, $due, $now, $now));
    todo_result('待办已添加');
}

if ($action === 'delete') {
    post_only();
    $user = todo_user();
    $id = isset($_POST['id']) ? (int) $_POST['id'] : 0;
    if ($id <= 0) {
        jerr(400, '缺少待办编号');
    }
    $stmt = todo_db()->prepare('SELECT id FROM todos WHERE id = ? AND user = ?');
    $stmt->execute(array($id, $user));
    if (!$stmt->fetch()) {
        jerr(404, '待办不存在或已被删除');
    }
    $del = todo_db()->prepare('DELETE FROM todos WHERE id = ? AND user = ?');
    $del->execute(array($id, $user));
    todo_result('待办已删除');
}

jerr(400, '未知操作');
