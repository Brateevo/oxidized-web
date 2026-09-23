<?php
declare(strict_types=1);

require_once __DIR__ . '/view.php';

function flash_ok(string $msg): void
{
    $_SESSION['flash'] = ['msg' => $msg, 'type' => 'ok'];
}

function flash_err(string $msg): void
{
    $_SESSION['flash'] = ['msg' => $msg, 'type' => 'error'];
}

function render_flash(): string
{
    if (empty($_SESSION['flash'])) {
        return '';
    }
    $f = $_SESSION['flash'];
    unset($_SESSION['flash']);
    $cls = $f['type'] === 'error' ? 'error' : 'ok';
    return '<div class="flash ' . $cls . '" id="flash">' . e($f['msg']) . '</div>';
}

function layout(string $title, string $content, ?array $user): string
{
    $nav = '';
    $who = 'гость';
    if ($user) {
        $nav .= '<a class="nav-link" href="/">Устройства</a>';
        if (is_admin_user($user)) {
            $nav .= '<a class="nav-link" href="/users">Пользователи</a>';
        }
        $badge = is_admin_user($user) ? '<span class="badge admin">admin</span>' : '<span class="badge user">user</span>';
        $who = '<span class="who">' . e($user['username']) . ' ' . $badge . '</span>';
        $nav .= $who
            . '<form class="inline" method="post" action="/logout">'
            . '<input type="hidden" name="csrf" value="' . e(csrf_token()) . '">'
            . '<button class="btn ghost btn-sm" type="submit">Выйти</button>'
            . '</form>';
    }
    $flash = render_flash();
    $css = '/assets/app.css';
    return <<<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{$title}</title>
<link rel="icon" type="image/svg+xml" href="/assets/logo.svg">
<link rel="stylesheet" href="{$css}">
</head>
<body>
<div class="page">
<header class="topbar">
  <div class="brand">
    <svg class="logo" viewBox="0 0 32 32" aria-hidden="true"><path d="M5 6l6 8-6 8M16 22h11" stroke="currentColor" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
    <span class="brand-name">Oxidized<span class="brand-accent">Web</span></span>
  </div>
  <nav class="nav">{$nav}</nav>
</header>
{$flash}
<main class="content">
{$content}
</main>
</div>
<script src="/assets/app.js"></script>
</body>
</html>
HTML;
}

function login_layout(string $title, string $content): string
{
    session_start_ox();
    $flash = render_flash();
    return <<<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{$title}</title>
<link rel="icon" type="image/svg+xml" href="/assets/logo.svg">
<link rel="stylesheet" href="/assets/app.css">
</head>
<body class="auth-body">
<div class="auth-wrap">
{$flash}
{$content}
</div>
<script src="/assets/app.js"></script>
</body>
</html>
HTML;
}

function card(string $inner, string $extraClass = ''): string
{
    return '<div class="card ' . e($extraClass) . '">' . $inner . '</div>';
}