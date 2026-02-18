<?php
// /var/www/pki.axis-os.ru/html/api/status.php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

$data = json_decode(file_get_contents('php://input'), true);

if (!isset($data['public_key'])) {
    echo json_encode(['status' => 'unknown', 'message' => 'No key provided']);
    exit;
}

$fingerprint = hash('sha256', $data['public_key']);

$stmt = $pdo->prepare("SELECT status FROM pki_keys WHERE fingerprint = ?");
$stmt->execute([$fingerprint]);
$result = $stmt->fetchColumn();

if ($result) {
    echo json_encode(['status' => $result]);
} else {
    echo json_encode(['status' => 'not_found']);
}
?>