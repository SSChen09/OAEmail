<?php
/**
 * oa/api/users.php — OA 账号与邮箱关联配置（被 auth.php 引用）
 *
 * 密码只保存 bcrypt 哈希（$2a$，PHP 5.4 的 crypt 可校验），不保存明文。
 * 登录账号就是邮箱地址，$OA_USERS 以邮箱本地部分为键：
 *   eva@ddzt.old / rei      -> eva@ddzt.old
 *   kk@ddzt.old / zmjjkk    -> kk@ddzt.old
 *   admin@ddzt.old / admin  -> admin@ddzt.old
 * auth.php 要求输入完整邮箱（短账号 eva 不接受），登录成功后用同一口令
 * 登录对应邮箱并写入 mail_user/mail_pass，因此进入邮件模块无需再次登录。
 */

$OA_USERS = array(
    'eva'   => '$2a$10$3DhdhH2KGa/evr6VvKyh1.uMmhkATQc/1uWoTOdiI2XIhQHFtbcji',   /* rei */
    'kk'    => '$2a$10$im4LA8CNTXQ9n9zSv9nEQOA8hv07NyL4RhoQG.1qPgMju8LZ8o3Em',   /* zmjjkk */
    'admin' => '$2a$10$Mf5MELlyNdsXKlJxpt8WsukfW8Esny.3.nYS4BPaLr7OMg0mvUhfC',   /* admin */
);

/* OA 登录名 => 邮箱地址（系统用户同名，口令相同） */
$OA_MAIL = array(
    'eva'   => 'eva@ddzt.old',
    'kk'    => 'kk@ddzt.old',
    'admin' => 'admin@ddzt.old',
);

/* 角色：只有 admin 可以修改/保存 OA 内容，其余账号只读 */
$OA_ROLES = array(
    'eva'   => 'user',
    'kk'    => 'user',
    'admin' => 'admin',
);
