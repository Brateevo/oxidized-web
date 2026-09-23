<?php
declare(strict_types=1);

final class DB
{
    private static ?PDO $pdo = null;

    public static function pdo(): PDO
    {
        if (self::$pdo === null) {
            $dir = dirname(__DIR__) . '/data';
            if (!is_dir($dir)) {
                mkdir($dir, 0770, true);
            }
            $db = $dir . '/oxidized.db';
            self::$pdo = new PDO('sqlite:' . $db);
            self::$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
            self::$pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
            self::$pdo->exec('PRAGMA journal_mode=WAL');
            self::$pdo->exec('PRAGMA foreign_keys=ON');
            self::schema();
        }
        return self::$pdo;
    }

    private static function schema(): void
    {
        self::$pdo->exec("CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user',
            email TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_login TEXT DEFAULT NULL
        )");

        self::$pdo->exec("CREATE TABLE IF NOT EXISTS login_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            identifier TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_attempt TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(identifier)
        )");

        self::$pdo->exec("CREATE TABLE IF NOT EXISTS user_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            device TEXT NOT NULL,
            UNIQUE(user_id, device),
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )");

        self::$pdo->exec("CREATE TABLE IF NOT EXISTS api_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            token TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            expires_at TEXT NOT NULL,
            last_used TEXT DEFAULT NULL,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )");

        self::$pdo->exec('CREATE INDEX IF NOT EXISTS idx_ud_user ON user_devices(user_id)');
        self::$pdo->exec('CREATE INDEX IF NOT EXISTS idx_ud_device ON user_devices(device)');
        self::$pdo->exec('CREATE INDEX IF NOT EXISTS idx_tok_user ON api_tokens(user_id)');
    }
}