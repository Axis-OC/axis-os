<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

if (!isAdmin()) { echo json_encode(['error' => 'Auth']); exit; }

// --- 1. System Metrics ---
$start_time = microtime(true);
$stmt = $pdo->query("SELECT 1"); // Пинг базы
$db_latency = round((microtime(true) - $start_time) * 1000, 2); // ms
$load = sys_getloadavg();
$server_load = $load[0]; // Load Avg (1 min)

// --- 2. Counters ---
$counts = [
    'total' => $pdo->query("SELECT COUNT(*) FROM pki_keys")->fetchColumn(),
    'pending' => $pdo->query("SELECT COUNT(*) FROM pki_keys WHERE status IN ('pending', 'revoke_pending')")->fetchColumn(),
    'revoked' => $pdo->query("SELECT COUNT(*) FROM pki_keys WHERE status = 'revoked'")->fetchColumn(),
    'sessions' => $pdo->query("SELECT COUNT(*) FROM admin_sessions WHERE logout_time IS NULL")->fetchColumn()
];

// --- 3. Network Lists ---
$history = $pdo->query("
    SELECT s.*, u.username 
    FROM admin_sessions s
    JOIN users u ON s.user_id = u.id
    ORDER BY s.login_time DESC LIMIT 8
")->fetchAll();

$bans = $pdo->query("SELECT * FROM banned_ips ORDER BY banned_at DESC")->fetchAll();

echo json_encode([
    'meta' => [
        'latency' => $db_latency,
        'load' => $server_load,
        'ram' => round(memory_get_usage() / 1024, 2) . ' KB',
        'time' => gmdate("H:i:s \U\T\C")
    ],
    'counts' => $counts,
    'current_ip' => $_SERVER['REMOTE_ADDR'],
    'history' => $history,
    'bans' => $bans
]);
?>