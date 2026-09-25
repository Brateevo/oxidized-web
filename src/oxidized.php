<?php
declare(strict_types=1);

const OX_API = 'http://127.0.0.1:8888';

/**
 * GET an Oxidized REST endpoint. Returns decoded JSON array or [].
 */
function ox_get(string $path): array
{
    $ch = curl_init(OX_API . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_HTTPHEADER => ['Accept: application/json'],
    ]);
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !is_string($body)) {
        return [];
    }
    $data = json_decode($body, true);
    return is_array($data) ? $data : [];
}

/**
 * List of nodes from Oxidized: array of [name, model, group, status, ...].
 * Prefers /nodes.json (stable), falls back to /nodes.
 */
function ox_nodes(): array
{
    $nodes = ox_get('/nodes.json');
    if (!$nodes) {
        $nodes = ox_get('/nodes');
    }
    if (!$nodes) {
        return [];
    }
    // /nodes returns {nodes: [...]}, /nodes.json returns plain array
    if (isset($nodes['nodes']) && is_array($nodes['nodes'])) {
        $nodes = $nodes['nodes'];
    }
    $out = [];
    foreach ($nodes as $n) {
        if (!is_array($n)) {
            continue;
        }
        $out[] = [
            'name'     => (string) ($n['name'] ?? $n['full_name'] ?? ''),
            'full_name'=> (string) ($n['full_name'] ?? $n['name'] ?? ''),
            'model'    => (string) ($n['model'] ?? ''),
            'group'    => (string) ($n['group'] ?? ''),
            'status'   => (string) ($n['status'] ?? 'unknown'),
            'ip'       => (string) ($n['ip'] ?? ''),
            'time'     => (string) ($n['time'] ?? ''),
        ];
    }
    return $out;
}

/**
 * Current (latest) config of a node. Oxidized returns a JSON array of lines —
 * joined here into one text.
 */
function ox_fetch_config(string $name): string
{
    $url = OX_API . '/node/fetch/' . rawurlencode($name);
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_HTTPHEADER => ['Accept: application/json'],
    ]);
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !is_string($body)) {
        return '';
    }
    $data = json_decode($body, true);
    if (is_array($data)) {
        if (isset($data['config']) && is_string($data['config'])) {
            return $data['config'];
        }
        return implode("\n", array_map(static fn($l) => (string) $l, $data));
    }
    return (string) $body;
}

/**
 * Version list of a node: [{oid, date, message, author}, ...] newest first.
 */
function ox_versions(string $name): array
{
    $data = ox_get('/node/version.json?node_full=' . rawurlencode($name));
    if (!$data) {
        return [];
    }
    // Response shape: list of strings in newer API, or list of objects
    $out = [];
    foreach ($data as $item) {
        if (is_string($item)) {
            // "oid date\nmessage" — keep raw, build as best effort
            $out[] = [
                'oid'     => $item,
                'date'    => '',
                'message' => '',
                'author'  => '',
            ];
        } elseif (is_array($item)) {
            $oid = (string) ($item['oid'] ?? $item['id'] ?? $item['commit'] ?? '');
            $msg = (string) ($item['message'] ?? $item['subject'] ?? '');
            if (!$msg && isset($item['title'])) {
                $msg = (string) $item['title'];
            }
            $date = (string) ($item['date'] ?? $item['time'] ?? $item['timestamp'] ?? '');
            $author = (string) ($item['author'] ?? $item['committer'] ?? $item['email'] ?? '');
            $out[] = [
                'oid'     => $oid,
                'date'    => $date,
                'message' => $msg,
                'author'  => $author,
            ];
        }
    }
    return $out;
}

/** Raw content of a specific version blob. */
function ox_version_view(string $name, string $oid): string
{
    $url = OX_API . '/node/version/view?node=' . rawurlencode($name) . '&oid=' . rawurlencode($oid) . '&format=json';
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 30,
    ]);
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !is_string($body)) {
        return '';
    }
    $data = json_decode($body, true);
    if (is_array($data)) {
        if (isset($data['content']) && is_string($data['content'])) {
            return $data['content'];
        }
        return implode("\n", array_map(static fn($l) => (string) $l, $data));
    }
    return (string) $body;
}

/** Unified diff between two version blobs (implemented locally). */
function ox_diff(string $name, string $oid, string $oid2): string
{
    $a = explode("\n", ox_version_view($name, $oid));
    $b = explode("\n", ox_version_view($name, $oid2));
    return render_unified_diff($a, $b);
}

/**
 * Simple unified diff of two line arrays (LCS-based), git-style.
 */
function render_unified_diff(array $a, array $b): string
{
    $n = count($a);
    $m = count($b);

    // LCS table
    $lcs = array_fill(0, $n + 1, array_fill(0, $m + 1, 0));
    for ($i = $n - 1; $i >= 0; $i--) {
        for ($j = $m - 1; $j >= 0; $j--) {
            $lcs[$i][$j] = $a[$i] === $b[$j]
                ? $lcs[$i + 1][$j + 1] + 1
                : max($lcs[$i + 1][$j], $lcs[$i][$j + 1]);
        }
    }

    if ($n === 0 && $m === 0) {
        return '';
    }

    $out = ["--- a/{$name} (oid1)", "+++ b/{$name} (oid2)"];
    $i = 0;
    $j = 0;
    $hunk = [];
    $hunkStart = [$i + 1, $j + 1];
    $flush = function () use (&$hunk, &$out, &$hunkStart): void {
        if (!$hunk) {
            return;
        }
        [$ha, $hb] = $hunkStart;
        $out[] = sprintf("@@ -%d,%d +%d,%d @@", $ha, count($hunk), $hb, count($hunk));
        foreach ($hunk as $line) {
            $out[] = $line;
        }
        $hunk = [];
    };

    while ($i < $n || $j < $m) {
        if ($i < $n && $j < $m && $a[$i] === $b[$j]) {
            $flush();
            // context: keep a few unchanged lines
            if (!empty($out[$seq = count($out) - 1]) && str_starts_with($out[count($out) - 1] ?? '', ' ') === false) {
                $ctx = [];
                for ($k = 0; $k < 3 && $i + $k < $n && $a[$i + $k] === $b[$j + $k]; $k++) {
                    $ctx[] = ' ' . $a[$i + $k];
                }
                array_push($out, ...$ctx);
                $i += count($ctx);
                $j += count($ctx);
                $hunkStart = [$i + 1, $j + 1];
                continue;
            }
            $i++;
            $j++;
            continue;
        }
        if ($hunk === []) {
            $hunkStart = [$i + 1, $j + 1];
        }
        if ($lcs[$i][$j] === 0) {
            // complete divergence — dump all remaining
            while ($i < $n) {
                $hunk[] = '-' . $a[$i++];
            }
            while ($j < $m) {
                $hunk[] = '+' . $b[$j++];
            }
            break;
        }
        if ($j < $m && ($i === $n || $lcs[$i][$j + 1] >= $lcs[$i + 1][$j])) {
            $hunk[] = '+' . $b[$j++];
        } else {
            $hunk[] = '-' . $a[$i++];
        }
    }
    $flush();
    return (count($out) > 2) ? implode("\n", $out) : '';
}
function oxz_sysname(string $ip): string
{
    static $cache = array();
    if (isset($cache[$ip])) { return $cache[$ip]; }
    if (!defined('OX_LX_HOST') || !defined('OX_LX_USER') || !defined('OX_LX_PASS')) {
        return $cache[$ip] = $ip;
    }
    $name = $ip;
    try {
        $pdo = new PDO('mysql:host=' . OX_LX_HOST . ';dbname=' . OX_LX_DB . ';charset=utf8mb4', OX_LX_USER, OX_LX_PASS, array(
            PDO::ATTR_TIMEOUT => 2,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ));
        $st = $pdo->prepare('SELECT COALESCE(NULLIF(sysName, ""), hostname) FROM devices WHERE ip = ? OR hostname = ? LIMIT 1');
        $st->execute(array($ip, $ip));
        $v = $st->fetchColumn();
        if ($v && $v !== '') { $name = (string)$v; }
    } catch (Throwable $e) {
        $name = $ip;
    }
    return $cache[$ip] = $name;
}

function oxz_location(string $ip): string
{
    static $cache = [];
    if (isset($cache[$ip])) { return $cache[$ip]; }
    if (!defined('OX_LX_HOST') || !defined('OX_LX_USER') || !defined('OX_LX_PASS')) {
        return $cache[$ip] = '-';
    }
    $v = '-';
    try {
        $pdo = new PDO('mysql:host=' . OX_LX_HOST . ';dbname=' . OX_LX_DB . ';charset=utf8mb4', OX_LX_USER, OX_LX_PASS, [
            PDO::ATTR_TIMEOUT => 2,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);
        $st = $pdo->prepare(
            "SELECT COALESCE(NULLIF(l.location, ''), '-') "
            . "FROM devices d "
            . "LEFT JOIN locations l ON l.id = d.location_id "
            . "WHERE d.ip = ? OR d.hostname = ? LIMIT 1"
        );
        $st->execute([$ip, $ip]);
        $r = $st->fetchColumn();
        if ($r && $r !== '') {
            $v = (string)$r;
            // LibreNMS stores locations as "name [lat, lng]" when the device
            // has coordinates; show only the name, drop the bracketed pair.
            $v = trim((string)preg_replace(
                '~\[\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\]$~u', '', $v
            ));
            if ($v === '') { $v = '-'; }
        }
    } catch (Throwable $e) {
        $v = '-';
    }
    return $cache[$ip] = $v;
}
