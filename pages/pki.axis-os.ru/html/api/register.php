<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');

ini_set('display_errors', 0);

$token = $_SERVER['HTTP_X_API_TOKEN'] ?? '';
$input = file_get_contents('php://input');
$data = json_decode($input, true);

if (!$token || !isset($data['public_key'])) {
    http_response_code(400); 
    echo json_encode(['error' => 'Missing token or public_key']); 
    exit;
}

$stmt = $pdo->prepare("SELECT id, pgp_public_key FROM users WHERE api_token = ?");
$stmt->execute([$token]);
$user = $stmt->fetch();

if (!$user) {
    http_response_code(403); 
    echo json_encode(['error' => 'Invalid Token']); 
    exit;
}

// === MANDATORY PGP CHECK ===
if (empty($user['pgp_public_key'])) {
    http_response_code(403);
    echo json_encode(['error' => 'ACCESS DENIED: PGP Key required on Web Dashboard first.']);
    exit;
}

$fingerprint = hash('sha256', $data['public_key']);
try {
    $stmt = $pdo->prepare("INSERT INTO pki_keys (user_id, public_key, fingerprint, key_type) VALUES (?, ?, ?, ?)");
    $stmt->execute([$user['id'], $data['public_key'], $fingerprint, $data['type'] ?? 'ED25519']);
    echo json_encode(['status' => 'success', 'message' => 'Key queued for approval']);
} catch (Exception $e) {
    http_response_code(409); 
    echo json_encode(['error' => 'Key already registered']);
}
?>