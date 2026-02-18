<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

if (!isAdmin()) { http_response_code(403); exit; }

$data = json_decode(file_get_contents('php://input'), true);
$keyId = $data['key_id'] ?? null;
$action = $data['action'] ?? null;

if (!$keyId || !$action) { echo json_encode(['status' => 'error']); exit; }

if ($action === 'delete') {
    $password = $data['password'] ?? '';
    
    $stmt = $pdo->prepare("SELECT password_hash FROM users WHERE id = ?");
    $stmt->execute([$_SESSION['user_id']]);
    $hash = $stmt->fetchColumn();
    
    if (!password_verify($password, $hash)) {
        echo json_encode(['status' => 'error', 'message' => 'Incorrect Password']); exit;
    }
    
    $stmt = $pdo->prepare("DELETE FROM pki_keys WHERE id = ?");
    $stmt->execute([$keyId]);
    echo json_encode(['status' => 'success']);
    exit;
}
// ========================

if ($action === 'approve') {
    $stmt = $pdo->prepare("UPDATE pki_keys SET status = 'approved' WHERE id = ?");
    $stmt->execute([$keyId]);
} elseif ($action === 'revoke') {
    $stmt = $pdo->prepare("UPDATE pki_keys SET status = 'revoked' WHERE id = ?");
    $stmt->execute([$keyId]);
}

echo json_encode(['status' => 'success']);
?>