<?php
declare(strict_types=1);

if ($method === 'POST') {
    csrf_check();
    $username = trim((string) ($_POST['username'] ?? ''));
    $password = (string) ($_POST['password'] ?? '');
    $id = strtolower($_SERVER['REMOTE_ADDR'] ?? '?') . '|' . strtolower($username);

    if (login_blocked($id)) {
        flash_err('Слишком много неудачных попыток. Подождите 15 минут.');
        redirect('/login');
    }

    $u = $username !== '' && $password !== '' ? do_login($username, $password) : null;
    if ($u) {
        login_clear($id);
        session_regenerate_id(true);
        $_SESSION['user_id'] = (int) $u['id'];
        redirect('/');
    }

    login_fail($id);
    flash_err('Неверный логин или пароль.');
    redirect('/login');
}

if (current_user()) {
    redirect('/');
}

$form = <<<HTML
<div class="auth-card">
  <div class="auth-logo"><span class="logo-big">O</span></div>
  <h1>Oxidized<span class="brand-accent">Web</span></h1>
  <p class="sub">Вход в систему резервных копий конфигураций</p>
  <form method="post" action="/login" class="form">
    <input type="hidden" name="csrf" value="{csrf}">
    <label class="field">Логин
      <input type="text" name="username" autocomplete="username" required autofocus>
    </label>
    <label class="field">Пароль
      <input type="password" name="password" id="pw" autocomplete="current-password" required>
      <button type="button" class="eye" id="btn-eye" title="Показать / скрыть">👁</button>
    </label>
    <button type="submit" class="btn primary btn-block">Войти</button>
  </form>
</div>
HTML;
$form = str_replace('{csrf}', e(csrf_token()), $form);

echo login_layout('Вход — OxidizedWeb', $form);