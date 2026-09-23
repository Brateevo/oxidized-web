<?php
declare(strict_types=1);

$admin = require_admin();

/* ---------- POST actions ---------- */

if ($method === 'POST') {
    csrf_check();
    $action = (string) ($_POST['action'] ?? '');

    if ($action === 'create') {
        $username = trim((string) ($_POST['username'] ?? ''));
        $password = (string) ($_POST['password'] ?? '');
        $email = trim((string) ($_POST['email'] ?? ''));
        $role = ($_POST['role'] ?? 'user') === 'admin' ? 'admin' : 'user';
        $err = '';
        if (!preg_match('/^[A-Za-z0-9_.-]{3,32}$/', $username)) {
            $err = 'Логин: от 3 до 32 символов (буквы, цифры, _ . -).';
        } elseif (strlen($password) < 8) {
            $err = 'Пароль должен быть не короче 8 символов.';
        } else {
            $st = DB::pdo()->prepare('SELECT 1 FROM users WHERE username = ?');
            $st->execute([$username]);
            if ($st->fetchColumn()) {
                $err = 'Пользователь «' . $username . '» уже существует.';
            } else {
                DB::pdo()->prepare('INSERT INTO users (username, password_hash, role, email) VALUES (?, ?, ?, ?)')
                    ->execute([$username, password_hash($password, PASSWORD_DEFAULT), $role, $email]);
                flash_ok('Пользователь «' . $username . '» создан.');
                redirect('/users');
            }
        }
        flash_err($err);
        redirect('/users');
    }

    if ($action === 'delete') {
        $id = (int) ($_POST['id'] ?? 0);
        if ($id !== (int) $admin['id']) {
            DB::pdo()->prepare('DELETE FROM users WHERE id = ?')->execute([$id]);
            flash_ok('Пользователь удалён.');
        } else {
            flash_err('Нельзя удалить самого себя.');
        }
        redirect('/users');
    }

    if ($action === 'password') {
        $id = (int) ($_POST['id'] ?? 0);
        $pw = (string) ($_POST['password'] ?? '');
        if (strlen($pw) < 8) {
            flash_err('Пароль должен быть не короче 8 символов.');
        } else {
            DB::pdo()->prepare('UPDATE users SET password_hash = ? WHERE id = ?')
                ->execute([password_hash($pw, PASSWORD_DEFAULT), $id]);
            flash_ok('Пароль обновлён.');
        }
        redirect('/users');
    }

    if ($action === 'devices') {
        $id = (int) ($_POST['id'] ?? 0);
        $devices = (array) ($_POST['devices'] ?? []);
        $custom = trim((string) ($_POST['custom_devices'] ?? ''));
        if ($custom !== '') {
            foreach (explode(",", $custom) as $d) {
                $d = trim($d);
                if ($d !== '') {
                    $devices[] = $d;
                }
            }
        }
        $st = DB::pdo()->prepare('DELETE FROM user_devices WHERE user_id = ?');
        $st->execute([$id]);
        $ins = DB::pdo()->prepare('INSERT OR IGNORE INTO user_devices (user_id, device) VALUES (?, ?)');
        foreach (array_unique($devices) as $d) {
            $ins->execute([$id, (string) $d]);
        }
        flash_ok('Доступ к устройствам обновлён.');
        redirect('/users');
    }

    if ($action === 'reset_token') {
        api_token_revoke((int) ($_POST['id'] ?? 0), (int) $admin['id']);
        flash_ok('Токен отозван.');
        redirect('/users');
    }
}

/* ---------- GET: users table ---------- */

$csrf = e(csrf_token());
$users = DB::pdo()->query('SELECT * FROM users ORDER BY id')->fetchAll();

// devices per user
$devMap = [];
$st = DB::pdo()->query('SELECT user_id, device FROM user_devices ORDER BY device');
foreach ($st->fetchAll() as $r) {
    $devMap[(int) $r['user_id']][] = $r['device'];
}

// available devices visible to admin (from Oxidized)
$allNodes = ox_nodes();
$known = array_map(static fn(array $n) => $n['name'], $allNodes);

$rows = '';
$modal = '';
foreach ($users as $u) {
    $uid = (int) $u['id'];
    $devs = $devMap[$uid] ?? [];
    $devStr = $devs
        ? implode(', ', array_map('e', array_map(static fn($d) => $d, $devs)))
        : '<span class="muted">нет доступа</span>';
    $roleBadge = $u['role'] === 'admin'
        ? '<span class="badge admin">admin</span>'
        : '<span class="badge user">user</span>';

    $tokens = api_tokens_list($uid);
    $tokRows = '';
    foreach ($tokens as $t) {
        $tokRows .= '<tr><td class="muted mono">…' . substr((string) $t['token'], -12) . '</td>'
            . '<td class="muted">до ' . fmt_time($t['expires_at']) . '</td>'
            . '<td>'
            . '<form class="inline" method="post" action="/users">'
            . '<input type="hidden" name="csrf" value="' . e(csrf_token()) . '">'
            . '<input type="hidden" name="action" value="reset_token">'
            . '<input type="hidden" name="id" value="' . $uid . '">'
            . '<button class="btn danger btn-sm" type="submit">Отозвать</button>'
            . '</form></td></tr>';
    }

    $rows .= '<tr>'
        . '<td><strong>' . e($u['username']) . '</strong> ' . $roleBadge
        . '<br><span class="muted small">' . e($u['email']) . '</span></td>'
        . '<td class="dev-list">' . $devStr . '</td>'
        . '<td class="muted small">создан: ' . fmt_time($u['created_at']) . '<br>вход: ' . fmt_time($u['last_login']) . '</td>'
        . '<td class="row-actions">'
        . '<button class="btn ghost btn-sm" data-open="edit' . $uid . '">Права</button>'
        . '<button class="btn ghost btn-sm" data-open="pass' . $uid . '">Пароль</button>'
        . '<button class="btn ghost btn-sm" data-open="tok' . $uid . '">Токены</button>'
        . ($uid !== (int) $admin['id']
            ? '<button class="btn danger btn-sm" data-open="del' . $uid . '">Удалить</button>'
            : '<span class="muted small">(вы)</span>')
        . '</td></tr>';

    /* ---------- device access modal ---------- */
    $checked = $devMap[$uid] ?? [];
    $checks = '';
    foreach ($known as $kd) {
        $on = in_array($kd, $checked, true);
        $checks .= '<label class="cb"><input type="checkbox" name="devices[]" value="' . e($kd) . '"' . ($on ? ' checked' : '') . '> ' . e($kd) . '</label>';
    }
    // include devices already assigned even if not in known list (keep them)
    $isAdminUser = $u['role'] === 'admin';
    foreach ($checked as $d) {
        if (!in_array($d, $known, true)) {
            $checks .= '<label class="cb"><input type="checkbox" name="devices[]" value="' . e($d) . '" checked> ' . e($d) . ' <span class="muted small">(не в Oxidized)</span></label>';
        }
    }
    $roleOpts = '<option value="user"' . ($isAdminUser ? '' : ' selected') . '>user</option>'
        . '<option value="admin"' . ($isAdminUser ? ' selected' : '') . '>admin</option>';
    $roleNote = $isAdminUser ? '<br>Пользователь — администратор, видит все устройства.' : '<br>Пользователь — обычный, видит только отмеченные устройства.';
    $modal .= <<<MOD
<div class="modal hidden" id="m{$uid}" data-popup="edit{$uid}">
  <div class="modal-card">
    <h2>Права доступа — {$u['username']}</h2>
    <form method="post" action="/users">
      <input type="hidden" name="csrf" value="{$csrf}">
      <input type="hidden" name="action" value="devices">
      <input type="hidden" name="id" value="{$uid}">
      <label class="field small">Роль
        <select name="role">{$roleOpts}</select>
      </label>
      <div class="cb-filter-wrap"><input type="text" class="cb-filter" placeholder="Фильтр устройств…" data-filter="{$uid}"></div>
      <div class="cb-grid" data-cbgrid="{$uid}">{$checks}<label class="cb"><input type="checkbox" id="selall{$uid}" data-selall="{$uid}"> <strong>выбрать все</strong></label></div>
      <label class="field small">Дополнительно (через запятую)
        <input type="text" name="custom_devices" placeholder="sw-01, sw-02">
      </label>
      <p class="muted small">{$roleNote}</p>
      <div class="row"><button class="btn primary" type="submit">Сохранить</button><button class="btn ghost" type="button" data-close="{$uid}">Закрыть</button></div>
    </form>
  </div>
</div>
MOD;

    /* password modal */
    $modal .= <<<MOD
<div class="modal hidden" id="p{$uid}" data-popup="pass{$uid}">
  <div class="modal-card">
    <h2>Смена пароля — {$u['username']}</h2>
    <form method="post" action="/users">
      <input type="hidden" name="csrf" value="{$csrf}">
      <input type="hidden" name="action" value="password">
      <input type="hidden" name="id" value="{$uid}">
      <label class="field">Новый пароль
        <input type="password" name="password" id="pw{$uid}" required>
        <meter max="10" id="pwmeter{$uid}"></meter>
      </label>
      <div class="row"><button class="btn primary" type="submit">Сохранить</button><button class="btn ghost" type="button" data-close="{$uid}">Закрыть</button></div>
    </form>
  </div>
</div>
MOD;

    /* tokens modal */
    $modal .= <<<MOD
<div class="modal hidden" id="t{$uid}" data-popup="tok{$uid}">
  <div class="modal-card">
    <h2>API-токены — {$u['username']}</h2>
    <table class="table"><thead><tr><th>Токен</th><th>Expires</th><th></th></tr></thead><tbody>{$tokRows}</tbody></table>
    <p class="muted small">Токен выдаётся при входе через API (/api/auth), либо создаёт сам пользователь через приложение.</p>
    <div class="row"><button class="btn ghost" type="button" data-close="{$uid}">Закрыть</button></div>
  </div>
</div>
MOD;

    if ($uid !== (int) $admin['id']) {
        /* delete confirmation modal */
        $modal .= <<<MOD
<div class="modal hidden" id="d{$uid}" data-popup="del{$uid}">
  <div class="modal-card modal-narrow">
    <h2>Удаление пользователя</h2>
    <p class="muted">Удалить пользователя «{$u['username']}»? Это действие нельзя отменить.</p>
    <form method="post" action="/users">
      <input type="hidden" name="csrf" value="{$csrf}">
      <input type="hidden" name="action" value="delete">
      <input type="hidden" name="id" value="{$uid}">
      <div class="row"><button class="btn danger" type="submit">Удалить</button><button class="btn ghost" type="button" data-close="{$uid}">Отмена</button></div>
    </form>
  </div>
</div>
MOD;
    }
}

$createForm = <<<HTML
<div class="card create-card">
  <h2 class="card-title">Новый пользователь</h2>
  <form method="post" action="/users" class="form grid-form">
    <input type="hidden" name="csrf" value="{$csrf}">
    <input type="hidden" name="action" value="create">
    <label class="field">Логин <input type="text" name="username" placeholder="user-name" required></label>
    <label class="field">Email <input type="email" name="email" placeholder="user@example.com"></label>
    <label class="field">Пароль <input type="password" name="password" id="newpw" required></label>
    <label class="field">Роль
      <select name="role">
        <option value="user" selected>user — смотреть назначенные устройства</option>
        <option value="admin">admin — всё + управление</option>
      </select>
    </label>
    <div class="grid-span"><button class="btn primary" type="submit">Создать</button></div>
  </form>
</div>
HTML;

$content = '<h1 class="page-title">Пользователи</h1>'
    . '<div class="note">Создавать и удалять пользователей, менять пароли и назначать устройства может только администратор.</div>'
    . $createForm
    . '<table class="table table-users">'
    . '<thead><tr><th>Пользователь</th><th>Устройства</th><th>Даты</th><th>Действия</th></tr></thead>'
    . '<tbody>' . $rows . '</tbody></table>'
    . $modal;

echo layout('Пользователи — OxidizedWeb', $content, $admin);