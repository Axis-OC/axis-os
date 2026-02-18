<?php
// /var/www/pki.axis-os.ru/html/api/verify_hash.php
// Verify if a file hash matches an approved signed artifact

require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

$data = json_decode(file_get_contents('php://input'), true);
$hash = $data['hash'] ?? '';
$filename = $data['filename'] ?? '';

if (!$hash) {
    echo json_encode(['status' => 'error', 'message' => 'No hash']);
    exit;
}

// Check against signed_artifacts table
$stmt = $pdo->prepare("
    SELECT sa.*, u.username 
    FROM signed_artifacts sa 
    JOIN users u ON sa.signer_id = u.id 
    WHERE sa.hash = ? AND sa.status = 'approved'
");
$stmt->execute([$hash]);
$artifact = $stmt->fetch();

if ($artifact) {
    echo json_encode([
        'status' => 'approved',
        'signer' => $artifact['username'],
        'signed_at' => $artifact['created_at'],
        'filename' => $artifact['filename']
    ]);
} else {
    echo json_encode(['status' => 'unverified']);
}