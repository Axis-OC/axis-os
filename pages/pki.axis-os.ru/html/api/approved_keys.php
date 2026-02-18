<?php
// /var/www/pki.axis-os.ru/html/api/approved_keys.php
// Returns all approved signing keys for OC clients to sync

require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

$token = $_SERVER['HTTP_X_API_TOKEN'] ?? '';

if (!$token) {
    http_response_code(401);
    echo json_encode(['error' => 'Token required']);
    exit;
}

// Validate token
$stmt = $pdo->prepare("SELECT id FROM users WHERE api_token = ?");
$stmt->execute([$token]);
if (!$stmt->fetch()) {
    http_response_code(403);
    echo json_encode(['error' => 'Invalid token']);
    exit;
}

// Get all approved keys
$stmt = $pdo->query("
    SELECT 
        k.fingerprint,
        k.public_key,
        k.key_type,
        k.status,
        k.created_at,
        u.username,
        u.pgp_fingerprint
    FROM pki_keys k
    JOIN users u ON k.user_id = u.id
    WHERE k.status = 'approved'
    ORDER BY k.created_at DESC
");

$keys = $stmt->fetchAll();
echo json_encode(['keys' => $keys, 'count' => count($keys), 'timestamp' => time()]);