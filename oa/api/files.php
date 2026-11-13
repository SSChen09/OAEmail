<?php
/**
 * oa/api/files.php —— 文档中心：文件共享 / 分发存储后端
 *
 * 存储位置（服务端 192.168.3.152，Web 根目录之外，只能经本接口下载）：
 *   /var/www/oa-share/files/            文件实体
 *   /var/www/oa-share/data/files.sqlite 元数据
 *
 * API 契约：
 *   POST action=list                    -> {ok:true,data:{files:[],count,total_size}}
 *   POST action=upload (multipart file) -> {ok:true,data:{file:{...}}}
 *   POST action=delete id               -> {ok:true,data:{message:"已删除"}}
 *   GET  action=download&id=N           -> 文件流（Content-Disposition: attachment）
 *
 * 权限：upload / delete 仅管理员可用（需 OA 会话 role=admin）；未登录 401、非管理员 403。
 *       list / download 保持只读开放。
 * 运行环境：PHP 5.4（CentOS 7），不得使用 PHP7 语法
 */

error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED);
ini_set('display_errors', '0');
date_default_timezone_set('Asia/Shanghai');

define('SHARE_ROOT', '/var/www/oa-share');
define('SHARE_FILES', SHARE_ROOT . '/files');
define('SHARE_DB', SHARE_ROOT . '/data/files.sqlite');
define('MAX_FILE_SIZE', 20 * 1024 * 1024);

// 任何未捕获异常都返回 JSON，避免前端收到 500 空响应后 JSON 解析报错
set_exception_handler(function ($e) {
    if (headers_sent()) {
        return;
    }
    out_error('服务器内部错误：' . $e->getMessage());
});

function files_db() {
    static $pdo = null;
    if ($pdo !== null) {
        return $pdo;
    }
    if (!is_dir(SHARE_FILES)) {
        @mkdir(SHARE_FILES, 0755, true);
    }
    if (!is_dir(dirname(SHARE_DB))) {
        @mkdir(dirname(SHARE_DB), 0755, true);
    }
    try {
        $pdo = new PDO('sqlite:' . SHARE_DB);
    } catch (PDOException $e) {
        out_error('数据库打开失败，请检查 ' . SHARE_DB . ' 权限');
    }
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    // 并发上传/下载时会话级锁默认直接报错；等 5s 并开 WAL，减少 "database is locked"
    $pdo->exec('PRAGMA busy_timeout = 5000');
    $pdo->exec('PRAGMA journal_mode = WAL');
    $pdo->exec('CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        stored TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        type TEXT,
        uploader TEXT,
        created_at TEXT NOT NULL,
        downloads INTEGER NOT NULL DEFAULT 0
    )');
    return $pdo;
}

function out_json($payload) {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE);
    exit;
}

function out_error($message) {
    out_json(array('ok' => false, 'error' => $message));
}

function file_row($row) {
    return array(
        'id' => (int) $row['id'],
        'name' => $row['name'],
        'size' => (int) $row['size'],
        'type' => $row['type'],
        'uploader' => $row['uploader'],
        'created_at' => $row['created_at'],
        'downloads' => (int) $row['downloads']
    );
}

$action = '';
if (isset($_POST['action'])) {
    $action = $_POST['action'];
} elseif (isset($_GET['action'])) {
    $action = $_GET['action'];
}

/* 写操作（上传/删除）仅管理员可用；列表/下载保持只读开放 */
function share_require_admin() {
    if (!isset($_SESSION['oa_user'])) {
        http_response_code(401);
        out_error('请先登录 OA 账号');
    }
    $role = isset($_SESSION['oa_role']) ? (string) $_SESSION['oa_role'] : '';
    if ($role === '') {
        $user = strtolower((string) $_SESSION['oa_user']);
        $role = (strpos($user, 'admin@') === 0) ? 'admin' : 'user';
    }
    if ($role !== 'admin') {
        http_response_code(403);
        out_error('仅管理员可上传或删除文件');
    }
    return (string) $_SESSION['oa_user'];
}

if ($action === 'upload' || $action === 'delete') {
    session_start();
}

/* ---------- 下载：直接输出文件流，不进入 JSON 分支 ---------- */
if ($action === 'download') {
    $id = isset($_GET['id']) ? (int) $_GET['id'] : 0;
    $stmt = files_db()->prepare('SELECT * FROM files WHERE id = ?');
    $stmt->execute(array($id));
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        http_response_code(404);
        out_error('文件不存在或已被删除');
    }
    $path = SHARE_FILES . '/' . basename($row['stored']);
    if (!is_file($path)) {
        http_response_code(404);
        out_error('文件实体已丢失，请重新上传');
    }
    files_db()->prepare('UPDATE files SET downloads = downloads + 1 WHERE id = ?')
        ->execute(array($id));
    $filename = preg_replace('/[\x00-\x1f\x7f"\\\\]/', '_', $row['name']);
    $fallback = preg_replace('/[^\x20-\x7e]/', '_', $filename);
    if ($fallback === '') {
        $fallback = 'download';
    }
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . filesize($path));
    header('Content-Disposition: attachment; filename="' . $fallback . '"; filename*=UTF-8\'\'' . rawurlencode($filename));
    readfile($path);
    exit;
}

/* ---------- 以下为 JSON 接口 ---------- */
switch ($action) {
    case 'list':
        $rows = files_db()->query('SELECT * FROM files ORDER BY id DESC')
            ->fetchAll(PDO::FETCH_ASSOC);
        $files = array();
        $total = 0;
        foreach ($rows as $row) {
            $files[] = file_row($row);
            $total += (int) $row['size'];
        }
        out_json(array('ok' => true, 'data' => array(
            'files' => $files,
            'count' => count($files),
            'total_size' => $total
        )));
        break;

    case 'upload':
        $uploader = share_require_admin();
        if (!isset($_FILES['file'])) {
            out_error('未接收到文件');
        }
        $file = $_FILES['file'];
        if ($file['error'] !== UPLOAD_ERR_OK) {
            $errors = array(
                UPLOAD_ERR_INI_SIZE => '文件超过 PHP 上传大小限制',
                UPLOAD_ERR_FORM_SIZE => '文件超过表单大小限制',
                UPLOAD_ERR_PARTIAL => '文件只上传了一部分',
                UPLOAD_ERR_NO_FILE => '未选择文件',
                UPLOAD_ERR_NO_TMP_DIR => '服务器临时目录不可用',
                UPLOAD_ERR_CANT_WRITE => '服务器写入失败',
                UPLOAD_ERR_EXTENSION => '上传被扩展中断'
            );
            out_error(isset($errors[$file['error']]) ? $errors[$file['error']] : '上传失败');
        }
        if ((int) $file['size'] <= 0) {
            out_error('不能上传空文件');
        }
        if ((int) $file['size'] > MAX_FILE_SIZE) {
            out_error('文件超过 20MB 限制');
        }
        $orig = basename($file['name']);
        $orig = preg_replace('/[\x00-\x1f\x7f]/', '', $orig);
        if ($orig === '') {
            $orig = 'unnamed';
        }
        $ext = strtolower(pathinfo($orig, PATHINFO_EXTENSION));
        $blocked = array('php', 'php3', 'php4', 'php5', 'phtml', 'phar', 'jsp', 'jspx', 'asp', 'aspx', 'cgi', 'pl');
        if (in_array($ext, $blocked)) {
            out_error('不允许上传可执行脚本文件（.' . $ext . '）');
        }
        $stored = date('Ymd_His') . '_' . substr(md5(uniqid('', true)), 0, 8);
        if ($ext !== '') {
            $stored .= '.' . $ext;
        }
        $dest = SHARE_FILES . '/' . $stored;
        if (!@move_uploaded_file($file['tmp_name'], $dest)) {
            out_error('保存文件失败，请检查服务端目录权限');
        }
        @chmod($dest, 0644);
        /* uploader 取自当前管理员会话，不接受前端伪造 */
        $now = date('Y-m-d H:i:s');
        $pdo = files_db();
        try {
            $pdo->prepare('INSERT INTO files (name, stored, size, type, uploader, created_at, downloads) VALUES (?, ?, ?, ?, ?, ?, 0)')
                ->execute(array($orig, $stored, (int) $file['size'], $ext, $uploader, $now));
        } catch (PDOException $e) {
            @unlink($dest);          // 入库失败就别留孤儿文件
            out_error('写入数据库失败：' . $e->getMessage());
        }
        out_json(array('ok' => true, 'data' => array('file' => array(
            'id' => (int) $pdo->lastInsertId(),
            'name' => $orig,
            'size' => (int) $file['size'],
            'type' => $ext,
            'uploader' => $uploader,
            'created_at' => $now,
            'downloads' => 0
        ))));
        break;

    case 'delete':
        share_require_admin();
        $id = isset($_POST['id']) ? (int) $_POST['id'] : 0;
        $stmt = files_db()->prepare('SELECT * FROM files WHERE id = ?');
        $stmt->execute(array($id));
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$row) {
            out_error('文件不存在或已被删除');
        }
        $path = SHARE_FILES . '/' . basename($row['stored']);
        if (is_file($path)) {
            @unlink($path);
        }
        files_db()->prepare('DELETE FROM files WHERE id = ?')->execute(array($id));
        out_json(array('ok' => true, 'data' => array('message' => '已删除')));
        break;

    default:
        out_error('未知操作');
}
