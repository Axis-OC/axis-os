<?php
// /var/www/pki.axis-os.ru/html/api/attest.php
// Machine Remote Attestation Protocol

require_once '/var/www/shared/db.php';
header('Content-Type: application/json');
ini_set('display_errors', 0);

$data = json_decode(file_get_contents('php://input'), true);
$action = $data['action'] ?? '';

// === CHALLENGE ===
if ($action === 'challenge') {
    $machine_id = $data['machine_id'] ?? 'unknown';
    $nonce = bin2hex(random_bytes(32));
    $challenge_id = bin2hex(random_bytes(16));
    
    // Store challenge (expires in 30 seconds)
    $stmt = $pdo->prepare("
        INSERT INTO attestation_challenges (challenge_id, nonce, machine_id, expires_at)
        VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL 30 SECOND))
    ");
    $stmt->execute([$challenge_id, $nonce, $machine_id]);
    
    echo json_encode([
        'nonce' => $nonce,
        'challenge_id' => $challenge_id
    ]);
    exit;
}

// === ATTEST ===
if ($action === 'attest') {
    $challenge_id = $data['challenge_id'] ?? '';
    $nonce = $data['nonce'] ?? '';
    
    // Validate challenge exists and is fresh
    $stmt = $pdo->prepare("
        SELECT * FROM attestation_challenges 
        WHERE challenge_id = ? AND nonce = ? AND expires_at > NOW()
    ");
    $stmt->execute([$challenge_id, $nonce]);
    $challenge = $stmt->fetch();
    
    if (!$challenge) {
        echo json_encode(['status' => 'rejected', 'reason' => 'Challenge expired or invalid']);
        exit;
    }
    
    // Delete used challenge (one-time use)
    $pdo->prepare("DELETE FROM attestation_challenges WHERE challenge_id = ?")->execute([$challenge_id]);
    
    // Verify machine identity
    $machine_binding = $data['machine_binding'] ?? '';
    $kernel_hash = $data['kernel_hash'] ?? '';
    $public_key = $data['public_key'] ?? '';
    $signature = $data['signature'] ?? '';
    $sealed = $data['sealed'] ?? false;
    $verified = $data['verified'] ?? false;
    
    // Check if this machine is registered
    $stmt = $pdo->prepare("SELECT * FROM registered_machines WHERE machine_binding = ?");
    $stmt->execute([$machine_binding]);
    $machine = $stmt->fetch();
    
    if (!$machine) {
        // New machine — register it
        $stmt = $pdo->prepare("
            INSERT INTO registered_machines 
            (machine_binding, public_key, kernel_hash, first_seen_ip, sealed, last_attestation)
            VALUES (?, ?, ?, ?, ?, NOW())
        ");
        $stmt->execute([$machine_binding, $public_key, $kernel_hash, $_SERVER['REMOTE_ADDR'], $sealed]);
        
        $session_token = bin2hex(random_bytes(32));
        echo json_encode([
            'status' => 'attested',
            'first_boot' => true,
            'session_token' => $session_token,
            'message' => 'Machine registered. Pending admin approval for elevated privileges.'
        ]);
        exit;
    }
    
    // Known machine — verify kernel hash matches expected
    $expected_hash = $machine['kernel_hash'];
    if ($expected_hash && $kernel_hash !== $expected_hash) {
        // Log security event
        $stmt = $pdo->prepare("
            INSERT INTO attestation_log 
            (machine_binding, event_type, details, ip_address)
            VALUES (?, 'KERNEL_MISMATCH', ?, ?)
        ");
        $stmt->execute([
            $machine_binding,
            json_encode(['expected' => $expected_hash, 'actual' => $kernel_hash]),
            $_SERVER['REMOTE_ADDR']
        ]);
        
        echo json_encode([
            'status' => 'rejected',
            'reason' => 'Kernel hash mismatch. Expected: ' . substr($expected_hash, 0, 16) . '...'
        ]);
        exit;
    }
    
    // TODO: Verify ECDSA signature server-side if php-gnupg/openssl available
    // For now, trust the binding + hash match
    
    // Update last attestation
    $pdo->prepare("UPDATE registered_machines SET last_attestation = NOW(), last_ip = ? WHERE machine_binding = ?")
         ->execute([$_SERVER['REMOTE_ADDR'], $machine_binding]);
    
    $session_token = bin2hex(random_bytes(32));
    
    // Store session
    $pdo->prepare("INSERT INTO attestation_sessions (machine_binding, session_token, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 24 HOUR))")
         ->execute([$machine_binding, $session_token]);
    
    echo json_encode([
        'status' => 'attested',
        'session_token' => $session_token,
        'sealed' => $machine['sealed'],
        'trust_level' => $sealed ? 'hardware' : ($verified ? 'software' : 'unverified')
    ]);
    exit;
}

echo json_encode(['error' => 'Unknown action']);