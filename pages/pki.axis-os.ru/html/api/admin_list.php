<?php
require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

if (!isAdmin()) { http_response_code(403); exit; }

$stmt = $pdo->query("
    SELECT 
        k.id, 
        k.fingerprint, 
        k.key_type, 
        k.status, 
        k.created_at,
        u.username,
        u.pgp_fingerprint as user_pgp_fp
    FROM pki_keys k
    JOIN users u ON k.user_id = u.id
    ORDER BY FIELD(k.status, 'pending', 'revoke_pending', 'approved', 'revoked'), k.created_at DESC
");

echo json_encode($stmt->fetchAll());
?>