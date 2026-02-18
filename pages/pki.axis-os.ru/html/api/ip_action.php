<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

if (!isAdmin()) { http_response_code(403); exit; }

$data = json_decode(file_get_contents('php://input'), true);
$ip = $data['ip'] ?? '';
$action = $data['action'] ?? '';

if (!$ip) { echo json_encode(['status'=>'error']); exit; }

if ($action === 'ban') {
    if ($ip === $_SERVER['REMOTE_ADDR']) {
        echo json_encode(['status'=>'error', 'message'=>'Suicide prevention protocol active']); exit;
    }
    $stmt = $pdo->prepare("INSERT IGNORE INTO banned_ips (ip_address, banned_by) VALUES (?, ?)");
    $stmt->execute([$ip, $_SESSION['user_id']]);
} elseif ($action === 'unban') {
    $stmt = $pdo->prepare("DELETE FROM banned_ips WHERE ip_address = ?");
    $stmt->execute([$ip]);
}

echo json_encode(['status'=>'success']);
?>