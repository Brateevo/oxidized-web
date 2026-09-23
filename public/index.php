<?php
declare(strict_types=1);
if (is_file(__DIR__ . '/../config.php')) { require_once __DIR__ . '/../config.php'; }


require_once __DIR__ . '/../src/database.php';
require_once __DIR__ . '/../src/auth.php';
require_once __DIR__ . '/../src/oxidized.php';
require_once __DIR__ . '/../src/view.php';
require_once __DIR__ . '/../src/layout.php';

session_start_ox();

/* ============ helpers ============ */

function json_out(array $data, int $code = 200): never
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data);
    exit;
}

function redirect(string $loc): never
{
    header('Location: ' . $loc);
    exit;
}

/**
 * Filter node list for a non-admin user.
 */
function filter_nodes_by_user(array $nodes, array $user): array
{
    if (is_admin_user($user)) {
        return $nodes;
    }
    $allowed = DB::pdo()->prepare('SELECT device FROM user_devices WHERE user_id = ?');
    $allowed->execute([$user['id']]);
    $set = [];
    foreach ($allowed->fetchAll(PDO::FETCH_COLUMN) as $d) {
        $set[(string) $d] = true;
    }
    return array_values(array_filter($nodes, static fn(array $n) => isset($set[$n['name']])));
}

/* ============ router ============ */

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

/* ---- API routes ---- */
if (str_starts_with($path, '/api')) {
    require __DIR__ . '/api.php';
    exit;
}

/* needs setup */
if (needs_setup() && $path !== '/favicon.ico') {
    require __DIR__ . '/setup.php';
    exit;
}

switch ($path) {
    case '/login':
        require __DIR__ . '/login.php';
        break;

    case '/logout':
        csrf_check();
        $_SESSION = [];
        if (ini_get('session.use_cookies')) {
            $p = session_get_cookie_params();
            setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
        }
        session_destroy();
        redirect('/login');
        break;

    case '/':
        $user = require_auth();
        $q = trim((string) ($_GET['q'] ?? ''));
        $nodes = filter_nodes_by_user(ox_nodes(), $user);

        // count helper
        $total = count($nodes);

        $rows = '';
        if (!$nodes) {
            $hint = is_admin_user($user)
                ? 'Устройств нет. Добавьте устройство в LibreNMS — оно появится здесь автоматически.'
                : 'Вам пока не назначены устройства. Обратитесь к администратору.';
            $rows = '<tr class="empty-row"><td colspan="6">' . e($hint) . '</td></tr>';
        } else {
            foreach ($nodes as $n) {
                if ($q !== '' && stripos($n['name'], $q) === false && stripos($n['model'], $q) === false) {
                    continue;
                }
                $rows .= '<tr class="dev-row" data-name="' . e($n['name']) . '">'
                    . '<td><span class="dot ' . e($n['status']) . '"></span>'
                    . '<a class="dev-link" href="/config?name=' . urlencode($n['name']) . '">' . e(oxz_sysname((string)$n['name'])) . '</a></td>'
                    . '<td class="muted">' . e($n['model']) . '</td>' . '<td class="muted">' . e(oxz_location((string)$n['name'])) . '</td>'
                    . '<td class="muted">' . e($n['ip']) . '</td>'
                    . '<td class="muted">' . e($n['group']) . '</td>'
                    . '<td class="btime">' . fmt_time($n['time']) . '</td>'
                    . '<td class="bstatus">' . status_icon($n['status']) . ' ' . e($n['status']) . '</td>'
                    . '</tr>';
            }
        }

        $searchBox = '<div class="search"><input type="search" id="dev-search" placeholder="Поиск по имени или модели…" autocomplete="off" value="' . e($q) . '"></div>';

        $content = '<h1 class="page-title">Устройства <span class="count">' . $total . '</span></h1>'
            . $searchBox
            . '<table class="table" id="dev-table">'
            . '<thead><tr><th>Имя</th><th>Модель</th><th>Локация</th><th>IP</th><th>Группа</th><th>Бэкап</th><th>Статус</th></tr></thead>'
            . '<tbody>' . $rows . '</tbody></table>';

        echo layout('Устройства — OxidizedWeb', $content, $user);
        break;

    case '/config':
        $user = require_auth();
        $name = (string) ($_GET['name'] ?? '');
        if ($name === '' || !device_allowed($user, $name)) {
            http_response_code(404);
            echo layout('Не найдено — OxidizedWeb', '<h1 class="page-title">Устройство не найдено или нет доступа</h1>', $user);
            break;
        }
        $config = ox_fetch_config($name);
        if ($config === '') {
            $body = '<p class="empty-block">Конфиг пуст или ещё не получен.</p>';
        } else {
            $body = '<div class="code-card"><pre class="code" id="config-pre">' . e($config) . '</pre></div>';
        }
        $content = '<div class="toolbar">'
            . '<h1 class="page-title">' . e($name) . '</h1>'
            . '<div class="toolbar-actions">'
            . '<a class="btn ghost" href="/">Назад</a>'
            . '<a class="btn ghost" href="/versions?name=' . urlencode($name) . '">История</a>'
            . '<button class="btn primary" id="btn-copy">Скопировать</button>'
            . '<a class="btn primary" href="/config?name=' . urlencode($name) . '&download=1">Скачать</a>'
            . '</div></div>'
            . $body;
        echo layout('Конфиг — ' . $name, $content, $user);
        break;

    case '/versions':
        $user = require_auth();
        $name = (string) ($_GET['name'] ?? '');
        if ($name === '' || !device_allowed($user, $name)) {
            http_response_code(404);
            echo layout('Не найдено — OxidizedWeb', '<h1 class="page-title">Устройство не найдено или нет доступа</h1>', $user);
            break;
        }
        $versions = ox_versions($name);
        $n = count($versions);
        $rows = '';
        if (!$versions) {
            $rows = '<tr class="empty-row"><td colspan="5">История пуста.</td></tr>';
        } else {
            foreach ($versions as $i => $v) {
                $num = $n - $i;
                $prev = $versions[$i + 1]['oid'] ?? '';
                $diffLink = $prev !== ''
                    ? '<a class="link muted small" href="/diff?name=' . urlencode($name) . '&oid=' . urlencode($v['oid']) . '&oid2=' . urlencode($prev) . '">диф</a>'
                    : '';
                $rows .= '<tr><td><a class="dev-link" href="/version?name=' . urlencode($name) . '&oid=' . urlencode($v['oid']) . '">#' . $num . '</a></td>'
                    . '<td class="muted">' . fmt_time($v['date']) . '</td>'
                    . '<td class="muted commit">' . e($v['message']) . '</td>'
                    . '<td class="muted">' . substr((string) $v['oid'], 0, 8) . '</td>'
                    . '<td>' . $diffLink . '</td></tr>';
            }
        }
        $content = '<div class="toolbar">'
            . '<h1 class="page-title">История — ' . e($name) . '</h1>'
            . '<div class="toolbar-actions">'
            . '<a class="btn ghost" href="/config?name=' . urlencode($name) . '">Конфиг</a>'
            . '<a class="btn ghost" href="/">Назад</a>'
            . '</div></div>'
            . '<table class="table table-versions">'
            . '<thead><tr><th>Версия</th><th>Дата</th><th>Сообщение</th><th>Коммит</th><th></th></tr></thead>'
            . '<tbody>' . $rows . '</tbody></table>';
        echo layout('История — ' . $name, $content, $user);
        break;

    case '/version':
        $user = require_auth();
        $name = (string) ($_GET['name'] ?? '');
        $oid = (string) ($_GET['oid'] ?? '');
        if ($name === '' || $oid === '' || !device_allowed($user, $name)) {
            http_response_code(404);
            echo layout('Не найдено — OxidizedWeb', '<h1 class="page-title">Не найдено или нет доступа</h1>', $user);
            break;
        }
        $blob = ox_version_view($name, $oid);
        $content = '<div class="toolbar">'
            . '<h1 class="page-title">Версия ' . substr($oid, 0, 8) . ' — ' . e($name) . '</h1>'
            . '<div class="toolbar-actions">'
            . '<a class="btn ghost" href="/versions?name=' . urlencode($name) . '">История</a>'
            . '<button class="btn primary" id="btn-copy">Скопировать</button>'
            . '</div></div>'
            . '<div class="code-card"><pre class="code">' . e($blob) . '</pre></div>';
        echo layout('Версия — ' . $name, $content, $user);
        break;

    case '/diff':
        $user = require_auth();
        $name = (string) ($_GET['name'] ?? '');
        $oid = (string) ($_GET['oid'] ?? '');
        $oid2 = (string) ($_GET['oid2'] ?? '');
        if ($name === '' || $oid === '' || !device_allowed($user, $name)) {
            http_response_code(404);
            echo layout('Не найдено — OxidizedWeb', '<h1 class="page-title">Не найдено или нет доступа</h1>', $user);
            break;
        }
        $diff = ox_diff($name, $oid, $oid2 !== '' ? $oid2 : $oid);
        $content = '<div class="toolbar">'
            . '<h1 class="page-title">Сравнение — ' . e($name) . '</h1>'
            . '<div class="toolbar-actions">'
            . '<a class="btn ghost" href="/versions?name=' . urlencode($name) . '">История</a>'
            . '</div></div>'
            . '<div class="code-card"><pre class="code diff">' . render_diff_lines($diff) . '</pre></div>';
        echo layout('Сравнение — ' . $name, $content, $user);
        break;

    case '/users':
        require __DIR__ . '/users.php';
        break;

    default:
        http_response_code(404);
        echo layout('404 — OxidizedWeb', '<h1 class="page-title">404</h1><p class="muted">Страница не найдена.</p>', current_user());
        break;
}