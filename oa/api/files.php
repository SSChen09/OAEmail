<?php
/**
 * oa/api/files.php —— 文件共享：分发存储后端
 *
 * 存储位置（服务端 192.168.3.152，Web 根目录之外，只能经本接口下载）：
 *   /var/www/oa-share/files/            文件实体
 *   /var/www/oa-share/data/files.sqlite 元数据（上传者、说明、到期时间、下载次数）
 *
 * API 契约（均需登录 OA；未登录 401）：
 *   POST action=list                    -> {ok:true,data:{files:[],count,total_size}}
 *   POST action=upload (multipart)      -> {ok:true,data:{file:{...}}}
 *        file 文件；note 说明（≤200 字，可空）；expires_at 到期时间（Y-m-dTH:i，可空=永久）
 *   POST action=delete id               -> {ok:true,data:{message:"已删除"}}
 *   GET  action=download&id=N           -> 文件流（Content-Disposition: attachment）
 *
 * 权限：所有登录用户可上传；上传者本人可删除自己的文件，admin 可删除全部。
 *       到期后的文件仍保留在服务器，但下载返回 410，列表标注“已过期”。
 * 运行环境：PHP 5.4（CentOS 7），不得使用 PHP7 语法
 */

error_reporting(E_ALL & ~E_NOTICE & ~E_DEPRECATED);
ini_set('display_errors', '0');
date_default_timezone_set('Asia/Shanghai');
session_start();

define('SHARE_ROOT', '/var/www/oa-share');
define('SHARE_FILES', SHARE_ROOT . '/files');
define('SHARE_DB', SHARE_ROOT . '/data/files.sqlite');
define('MAX_FILE_SIZE', 20 * 1024 * 1024);
define('MAX_NOTE_LEN', 200);

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
        downloads INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        expires_at TEXT
    )');
    // 兼容旧库：早期版本没有 note / expires_at 两列
    $cols = array();
    foreach ($pdo->query('PRAGMA table_info(files)')->fetchAll(PDO::FETCH_ASSOC) as $c) {
        $cols[$c['name']] = true;
    }
    if (!isset($cols['note'])) {
        $pdo->exec('ALTER TABLE files ADD COLUMN note TEXT');
    }
    if (!isset($cols['expires_at'])) {
        $pdo->exec('ALTER TABLE files ADD COLUMN expires_at TEXT');
    }
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

function current_user() {
    if (!isset($_SESSION['oa_user'])) {
        http_response_code(401);
        out_error('请先登录 OA 账号');
    }
    return (string) $_SESSION['oa_user'];
}

function current_role() {
    $role = isset($_SESSION['oa_role']) ? (string) $_SESSION['oa_role'] : '';
    if ($role === '') {
        $user = strtolower((string) $_SESSION['oa_user']);
        $role = (strpos($user, 'admin@') === 0) ? 'admin' : 'user';
    }
    return $role;
}

/* 上传者本人或管理员可删除 */
function share_can_delete($row, $user) {
    if (strcasecmp((string) $row['uploader'], $user) === 0) {
        return true;
    }
    return current_role() === 'admin';
}

function share_expired($expires_at) {
    if ($expires_at === null || $expires_at === '') {
        return false;
    }
    $ts = strtotime((string) $expires_at);
    return $ts !== false && $ts <= time();
}

function file_row($row) {
    $expired = share_expired($row['expires_at']);
    return array(
        'id' => (int) $row['id'],
        'name' => $row['name'],
        'size' => (int) $row['size'],
        'type' => $row['type'],
        'uploader' => $row['uploader'],
        'created_at' => $row['created_at'],
        'downloads' => (int) $row['downloads'],
        'note' => isset($row['note']) ? (string) $row['note'] : '',
        'expires_at' => isset($row['expires_at']) ? (string) $row['expires_at'] : '',
        'expired' => $expired
    );
}

/* 客户端 datetime-local 传 2026-12-01T18:00；也兼容 2026-12-01 18:00(:ss) */
function norm_expires_at($raw) {
    $raw = trim((string) $raw);
    if ($raw === '') {
        return '';
    }
    $raw = str_replace('T', ' ', $raw);
    if (preg_match('/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})(:\d{2})?$/', $raw, $m)) {
        $raw = $m[1];
    } else {
        return null;
    }
    $ts = strtotime($raw . ':00');
    if ($ts === false) {
        return null;
    }
    return date('Y-m-d H:i', $ts);
}

$action = '';
if (isset($_POST['action'])) {
    $action = $_POST['action'];
} elseif (isset($_GET['action'])) {
    $action = $_GET['action'];
}

/* ---------- 下载：直接输出文件流，不进入 JSON 分支 ---------- */
if ($action === 'download') {
    $user = current_user();
    $id = isset($_GET['id']) ? (int) $_GET['id'] : 0;
    $stmt = files_db()->prepare('SELECT * FROM files WHERE id = ?');
    $stmt->execute(array($id));
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        http_response_code(404);
        out_error('文件不存在或已被删除');
    }
    if (share_expired($row['expires_at'])) {
        http_response_code(410);
        out_error('文件已过期（' . $row['expires_at'] . '），无法下载');
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

/* ---------- 以下为 JSON 接口，统一要求登录 ---------- */
$current = current_user();

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
        if (!isset($_FILES['file'])) {
            out_error('未接收到文件');
        }
        $note = isset($_POST['note']) ? trim((string) $_POST['note']) : '';
        if (function_exists('mb_strlen')) {
            if (mb_strlen($note, 'UTF-8') > MAX_NOTE_LEN) {
                out_error('说明最多 ' . MAX_NOTE_LEN . ' 个字');
            }
        } elseif (strlen($note) > MAX_NOTE_LEN * 3) {
            out_error('说明最多 ' . MAX_NOTE_LEN . ' 个字');
        }
        $expires_raw = isset($_POST['expires_at']) ? $_POST['expires_at'] : '';
        $expires_at = norm_expires_at($expires_raw);
        if ($expires_at === null) {
            out_error('到期时间格式不正确（示例：2026-12-01 18:00）');
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
        /* uploader 取自会话，不接受前端伪造 */
        $now = date('Y-m-d H:i:s');
        $pdo = files_db();
        try {
            $pdo->prepare('INSERT INTO files (name, stored, size, type, uploader, created_at, downloads, note, expires_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)')
                ->execute(array($orig, $stored, (int) $file['size'], $ext, $current, $now, $note, $expires_at));
        } catch (PDOException $e) {
            @unlink($dest);          // 入库失败就别留孤儿文件
            out_error('写入数据库失败：' . $e->getMessage());
        }
        $new = array(
            'id' => (int) $pdo->lastInsertId(),
            'name' => $orig,
            'stored' => $stored,
            'size' => (int) $file['size'],
            'type' => $ext,
            'uploader' => $current,
            'created_at' => $now,
            'downloads' => 0,
            'note' => $note,
            'expires_at' => $expires_at
        );
        out_json(array('ok' => true, 'data' => array('file' => file_row($new))));
        break;

    case 'delete':
        $id = isset($_POST['id']) ? (int) $_POST['id'] : 0;
        $stmt = files_db()->prepare('SELECT * FROM files WHERE id = ?');
        $stmt->execute(array($id));
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$row) {
            http_response_code(404);
            out_error('文件不存在或已被删除');
        }
        if (!share_can_delete($row, $current)) {
            http_response_code(403);
            out_error('只能删除自己上传的文件');
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
