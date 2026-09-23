<?php
declare(strict_types=1);

require_once __DIR__ . '/database.php';

/* ---------------- sessions ---------------- */

function session_start_ox(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    session_name('oxidized_sess');
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    session_start();
}

/* ---------------- CSRF ---------------- */

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_check(): void
{
    $t = $_POST['csrf'] ?? '';
    if (!is_string($t) || !hash_equals(csrf_token(), $t)) {
        http_response_code(419);
        exit('419 Page Expired');
    }
}

/* ---------------- current user ---------------- */

function current_user(): ?array
{
    session_start_ox();
    $uid = $_SESSION['user_id'] ?? null;
    if (!$uid) {
        return null;
    }
    $st = DB::pdo()->prepare('SELECT * FROM users WHERE id = ?');
    $st->execute([$uid]);
    $u = $st->fetch();
    return $u ?: null;
}

function require_auth(): array
{
    $u = current_user();
    if (!$u) {
        header('Location: /login');
        exit;
    }
    return $u;
}

function require_admin(): array
{
    $u = current_user();
    if (!$u) {
        header('Location: /login');
        exit;
    }
    if ($u['role'] !== 'admin') {
        http_response_code(403);
        exit('403 Forbidden');
    }
    return $u;
}

function needs_setup(): bool
{
    return (int) DB::pdo()->query('SELECT COUNT(*) FROM users')->fetchColumn() === 0;
}

/* ---------------- brute-force lockout ---------------- */

function login_blocked(string $id): bool
{
    $st = DB::pdo()->prepare('SELECT attempts, last_attempt FROM login_attempts WHERE identifier = ?');
    $st->execute([$id]);
    $row = $st->fetch();
    if (!$row) {
        return false;
    }
    if ((int) $row['attempts'] >= 5) {
        if (time() - strtotime($row['last_attempt'] . ' UTC') < 900) {
            return true;
        }
        DB::pdo()->prepare('DELETE FROM login_attempts WHERE identifier = ?')->execute([$id]);
    }
    return false;
}

function login_fail(string $id): void
{
    DB::pdo()->prepare(
        "INSERT INTO login_attempts (identifier, attempts, last_attempt)
         VALUES (?, 1, datetime('now'))
         ON CONFLICT(identifier) DO UPDATE SET attempts = attempts + 1, last_attempt = datetime('now')"
    )->execute([$id]);
}

function login_clear(string $id): void
{
    DB::pdo()->prepare('DELETE FROM login_attempts WHERE identifier = ?')->execute([$id]);
}

/* ---------------- login ---------------- */

function do_login(string $username, string $password): ?array
{
    $st = DB::pdo()->prepare('SELECT * FROM users WHERE username = ?');
    $st->execute([$username]);
    $u = $st->fetch();
    if ($u && password_verify($password, $u['password_hash'])) {
        return $u;
    }
    return null;
}

/* ---------------- device access ---------------- */

function is_admin_user(array $user): bool
{
    return $user['role'] === 'admin';
}

/** Devices a user is allowed to see. Admin -> null means all. */
function allowed_devices(array $user): ?array
{
    if (is_admin_user($user)) {
        return null;
    }
    $st = DB::pdo()->prepare('SELECT device FROM user_devices WHERE user_id = ? ORDER BY device');
    $st->execute([$user['id']]);
    return array_map('strval', $st->fetchAll(PDO::FETCH_COLUMN));
}

function device_allowed(array $user, string $device): bool
{
    if (is_admin_user($user)) {
        return true;
    }
    $st = DB::pdo()->prepare('SELECT 1 FROM user_devices WHERE user_id = ? AND device = ?');
    $st->execute([$user['id'], $device]);
    return (bool) $st->fetchColumn();
}

/* ---------------- api tokens ---------------- */

function api_token_create(array $user, int $days = 365): string
{
    $token = bin2hex(random_bytes(32));
    DB::pdo()->prepare(
        "INSERT INTO api_tokens (user_id, token, expires_at)
         VALUES (?, ?, datetime('now', ?))"
    )->execute([$user['id'], $token, '+' . $days . ' days']);
    return $token;
}

function api_tokens_list(int $userId): array
{
    $st = DB::pdo()->prepare('SELECT * FROM api_tokens WHERE user_id = ? ORDER BY created_at DESC');
    $st->execute([$userId]);
    return $st->fetchAll();
}

function api_token_revoke(int $tokenId, int $userId): void
{
    $st = DB::pdo()->prepare('DELETE FROM api_tokens WHERE id = ? AND user_id = ?');
    $st->execute([$tokenId, $userId]);
}

/** Resolve Bearer token to a user, or null. */
function api_user(): ?array
{
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (!$auth && function_exists('getallheaders')) {
        foreach (getallheaders() as $k => $v) {
            if (strcasecmp((string) $k, 'Authorization') === 0) {
                $auth = (string) $v;
                break;
            }
        }
    }
    if (!preg_match('/^Bearer\s+([A-Za-z0-9]+)$/', trim($auth), $m)) {
        return null;
    }
    $st = DB::pdo()->prepare("SELECT u.* FROM api_tokens t JOIN users u ON u.id = t.user_id WHERE t.token = ? AND t.expires_at > datetime('now')");
    $st->execute([$m[1]]);
    $u = $st->fetch();
    if ($u) {
        DB::pdo()->prepare("UPDATE api_tokens SET last_used = datetime('now') WHERE token = ?")->execute([$m[1]]);
    }
    return $u ?: null;
}

function api_user_required(): array
{
    $u = api_user();
    if (!$u) {
        http_response_code(401);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'auth_required', 'message' => 'Требуется авторизация']);
        exit;
    }
    return $u;
}

function api_admin_required(): array
{
    $u = api_user_required();
    if (!is_admin_user($u)) {
        http_response_code(403);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'forbidden', 'message' => 'Доступно только администратору']);
        exit;
    }
    return $u;
}