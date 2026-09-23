<?php
declare(strict_types=1);

if (!$method === false && $method === 'POST') {
    csrf_check();
    $username = trim((string) ($_POST['username'] ?? ''));
    $password = (string) ($_POST['password'] ?? '');
    $password2 = (string) ($_POST['password2'] ?? '');
    $email = trim((string) ($_POST['email'] ?? ''));

    $err = '';
    if (!preg_match('/^[A-Za-z0-9_.-]{3,32}$/', $username)) {
        $err = 'Логин: от 3 до 32 символов (буквы, цифры, _ . -).';
    } elseif (strlen($password) < 8) {
        $err = 'Пароль должен быть не короче 8 символов.';
    } elseif ($password !== $password2) {
        $err = 'Пароли не совпадают.';
    } else {
        DB::pdo()->prepare('INSERT INTO users (username, password_hash, role, email) VALUES (?, ?, ?, ?)')
            ->execute([$username, password_hash($password, PASSWORD_DEFAULT), 'admin', $email]);
        $_SESSION['flash'] = ['msg' => 'Администратор создан. Войдите.', 'type' => 'ok'];
        redirect('/login');
    }
    $_SESSION['flash'] = ['msg' => $err, 'type' => 'error'];
}

$form = <<<HTML
<div class="auth-card">
  <div class="auth-logo"><span class="logo-big">O</span></div>
  <h1>Начальная настройка</h1>
  <p class="sub">Создайте первого администратора</p>
  <form method="post" action="/setup" class="form">
    <input type="hidden" name="csrf" value="{csrf}">
    <label class="field">Логин
      <input type="text" name="username" required autofocus>
    </label>
    <label class="field">Пароль
      <input type="password" name="password" id="pw" required>
    </label>
    <label class="field">Повторите пароль
      <input type="password" name="password2" required>
    </label>
    <label class="field">Email (необязательно)
      <input type="email" name="email">
    </label>
    <button type="submit" class="btn primary btn-block">Создать администратора</button>
  </form>
</div>
HTML;
$form = str_replace('{csrf}', e(csrf_token()), $form);

echo login_layout('Настройка — OxidizedWeb', $form);