<?php
declare(strict_types=1);

function e(mixed $v): string
{
    return htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
}

function fmt_time(?string $t): string
{
    if (!$t || trim($t) === '' || in_array($t, ['unknown', '0000-00-00 00:00:00'], true)) {
        return '—';
    }
    $ts = strtotime($t);
    if ($ts === false) {
        return e($t);
    }
    try {
        $d = new DateTime('@' . $ts);
        $d->setTimezone(new DateTimeZone('Europe/Moscow'));
        return $d->format('d.m.Y H:i:s');
    } catch (Throwable) {
        return e($t);
    }
}

function status_icon(string $status): string
{
    return match ($status) {
        'success'      => '🟢',
        'no_connection'=> '🔴',
        'updating'     => '🟡',
        'no_config'    => '⚫',
        default        => '⚪',
    };
}

function render_diff_lines(string $diff): string
{
    $lines = preg_split('/\r?\n/', $diff) ?: [];
    $out = '';
    foreach ($lines as $line) {
        if ($line === '') {
            $out .= '<span class="dl ctx"></span>' . "\n";
            continue;
        }
        $ch = $line[0] ?? '';
        $cls = 'ctx';
        if ($ch === '+' && ($line[1] ?? '') === '+' && ($line[2] ?? '') === '+') {
            $cls = 'head';
        } elseif ($ch === '-' && ($line[1] ?? '') === '-' && ($line[2] ?? '') === '-') {
            $cls = 'head';
        } elseif ($ch === '@') {
            $cls = 'hunk';
        } elseif ($ch === '\\') {
            $cls = 'head';
        } elseif ($ch === '+') {
            $cls = 'add';
        } elseif ($ch === '-') {
            $cls = 'del';
        }
        $out .= '<span class="dl ' . $cls . '">' . e($line) . '</span>' . "\n";
    }
    return $out;
}