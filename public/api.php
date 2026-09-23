<?php
declare(strict_types=1);

/* API endpoints for mobile clients (PWA / Android).
 * Auth via Bearer token from /api/auth. Device lists are filtered by access. */

$apiSub = substr($path, 4); // strip "/api"

if ($apiSub === '' || $apiSub === '/') {
    json_out(['service' => 'oxidized-web', 'endpoints' => ['/api/auth', '/api/devices', '/api/config', '/api/versions', '/api/version', '/api/diff']]);
}

/* POST /api/auth  {username, password} -> {username, role, token} */
if ($apiSub === '/auth' && $method === 'POST') {
    $in = json_decode((string) file_get_contents('php://input'), true);
    $username = trim((string) ($in['username'] ?? ''));
    $password = (string) ($in['password'] ?? '');
    $id = strtolower($_SERVER['REMOTE_ADDR'] ?? '?') . '|' . strtolower($username);

    if (login_blocked($id)) {
        json_out(['error' => 'blocked', 'message' => 'Слишком много попыток. Подождите 15 минут.'], 429);
    }

    $u = do_login($username, $password);
    if (!$u) {
        login_fail($id);
        json_out(['error' => 'bad_credentials', 'message' => 'Неверный логин или пароль.'], 401);
    }
    login_clear($id);
    $token = api_token_create($u);
    json_out([
        'username' => $u['username'],
        'role'     => $u['role'],
        'token'    => $token,
        'is_admin' => is_admin_user($u),
    ]);
}

/* GET /api/devices — list of nodes visible to the caller */
if ($apiSub === '/devices') {
    $user = api_user_required();
    $nodes = filter_nodes_by_user(ox_nodes(), $user);
    json_out(['devices' => $nodes]);
}

function api_device_name_param(array $get): string
{
    return (string) ($get['name'] ?? $get['node'] ?? '');
}

function api_require_device(array $user, string $name): string
{
    if ($name === '' || !device_allowed($user, $name)) {
        json_out(['error' => 'not_found', 'message' => 'Устройство не найдено или нет доступа.'], 404);
    }
    return $name;
}

/* GET /api/config?name=X */
if ($apiSub === '/config') {
    $user = api_user_required();
    $name = api_require_device($user, api_device_name_param($_GET));
    json_out(['name' => $name, 'config' => ox_fetch_config($name)]);
}

/* GET /api/versions?name=X */
if ($apiSub === '/versions') {
    $user = api_user_required();
    $name = api_require_device($user, api_device_name_param($_GET));
    json_out(['name' => $name, 'versions' => ox_versions($name)]);
}

/* GET /api/version?name=X&oid=Y */
if ($apiSub === '/version') {
    $user = api_user_required();
    $name = api_require_device($user, api_device_name_param($_GET));
    $oid = (string) ($_GET['oid'] ?? '');
    if ($oid === '') {
        json_out(['error' => 'missing_oid', 'message' => 'Укажите oid.'], 400);
    }
    json_out(['name' => $name, 'oid' => $oid, 'config' => ox_version_view($name, $oid)]);
}

/* GET /api/diff?name=X&oid=Y&oid2=Z */
if ($apiSub === '/diff') {
    $user = api_user_required();
    $name = api_require_device($user, api_device_name_param($_GET));
    $oid = (string) ($_GET['oid'] ?? '');
    $oid2 = (string) ($_GET['oid2'] ?? '');
    if ($oid === '' || $oid2 === '') {
        json_out(['error' => 'missing_params', 'message' => 'Укажите oid и oid2.'], 400);
    }
    json_out(['name' => $name, 'diff' => ox_diff($name, $oid, $oid2)]);
}

/* POST /api/token/revoke {token} - owner can revoke */
if ($apiSub === '/token/revoke' && $method === 'POST') {
    $user = api_user_required();
    $in = json_decode((string) file_get_contents('php://input'), true);
    $t = (string) ($in['token'] ?? '');
    DB::pdo()->prepare('DELETE FROM api_tokens WHERE token = ? AND user_id = ?')->execute([$t, $user['id']]);
    json_out(['ok' => true]);
}

/* Admin: list users & their devices */
if ($apiSub === '/admin/users') {
    $admin = api_admin_required();
    $users = DB::pdo()->query('SELECT id, username, role, email, created_at, last_login FROM users ORDER BY id')->fetchAll();
    foreach ($users as &$u) {
        $st = DB::pdo()->prepare('SELECT device FROM user_devices WHERE user_id = ? ORDER BY device');
        $st->execute([$u['id']]);
        $u['devices'] = $st->fetchAll(PDO::FETCH_COLUMN);
    }
    unset($u);
    json_out(['users' => $users]);
}

/* Admin: create user {username, password, role, devices[]} */
if ($apiSub === '/admin/users' && $method === 'POST') {
    $admin = api_admin_required();
    $in = json_decode((string) file_get_contents('php://input'), true);
    $username = trim((string) ($in['username'] ?? ''));
    $password = (string) ($in['password'] ?? '');
    $role = ($in['role'] ?? 'user') === 'admin' ? 'admin' : 'user';
    $devices = (array) ($in['devices'] ?? []);

    if (!preg_match('/^[A-Za-z0-9_.-]{3,32}$/', $username)) {
        json_out(['error' => 'bad_username', 'message' => 'Некорректный логин.'], 400);
    }
    if (strlen($password) < 8) {
        json_out(['error' => 'short_password', 'message' => 'Пароль слишком короткий.'], 400);
    }
    $st = DB::pdo()->prepare('SELECT 1 FROM users WHERE username = ?');
    $st->execute([$username]);
    if ($st->fetchColumn()) {
        json_out(['error' => 'exists', 'message' => 'Пользователь уже существует.'], 409);
    }
    DB::pdo()->prepare('INSERT INTO users (username, password_hash, role) VALUES (?, ?, ?)')
        ->execute([$username, password_hash($password, PASSWORD_DEFAULT), $role]);
    $uid = (int) DB::pdo()->lastInsertId();
    $ins = DB::pdo()->prepare('INSERT OR IGNORE INTO user_devices (user_id, device) VALUES (?, ?)');
    foreach (array_unique(array_filter(array_map('strval', $devices))) as $d) {
        $ins->execute([$uid, $d]);
    }
    json_out(['ok' => true, 'id' => $uid]);
}

/* Admin: update user devices {id, devices[]} */
if ($apiSub === '/admin/users/devices' && $method === 'POST') {
    $admin = api_admin_required();
    $in = json_decode((string) file_get_contents('php://input'), true);
    $id = (int) ($in['id'] ?? 0);
    $devices = (array) ($in['devices'] ?? []);
    if (!$id) {
        json_out(['error' => 'bad_id'], 400);
    }
    DB::pdo()->prepare('DELETE FROM user_devices WHERE user_id = ?')->execute([$id]);
    $ins = DB::pdo()->prepare('INSERT OR IGNORE INTO user_devices (user_id, device) VALUES (?, ?)');
    foreach (array_unique(array_filter(array_map('strval', $devices))) as $d) {
        $ins->execute([$id, $d]);
    }
    json_out(['ok' => true]);
}

json_out(['error' => 'not_found', 'message' => 'Неизвестный API endpoint.'], 404);