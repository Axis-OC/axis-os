<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

$token = $_SERVER['HTTP_X_API_TOKEN'] ?? '';
$data = json_decode(file_get_contents('php://input'), true);

if (!$token || !isset($data['public_key'])) {
    http_response_code(400); echo json_encode(['error' => 'Missing data']); exit;
}

$stmt = $pdo->prepare("SELECT id FROM users WHERE api_token = ?");
$stmt->execute([$token]);
$user_id = $stmt->fetchColumn();

if (!$user_id) {
    http_response_code(403); echo json_encode(['error' => 'Invalid Token']); exit;
}

$fingerprint = hash('sha256', $data['public_key']);

$check = $pdo->prepare("SELECT status FROM pki_keys WHERE user_id = ? AND fingerprint = ?");
$check->execute([$user_id, $fingerprint]);
$current = $check->fetch();

if (!$current) {
    echo json_encode(['error' => 'Key not found']); exit;
}

if ($current['status'] === 'revoked') {
    echo json_encode(['error' => 'Key already revoked']); exit;
}

if ($current['status'] === 'revoke_pending') {
    echo json_encode(['error' => 'Request already pending']); exit;
}

$stmt = $pdo->prepare("UPDATE pki_keys SET status = 'revoke_pending' WHERE user_id = ? AND fingerprint = ?");
$stmt->execute([$user_id, $fingerprint]);

echo json_encode(['status' => 'success', 'message' => 'Revocation request submitted']);
?>