<?php
require_once '/var/www/shared/db.php';
if (isset($_SESSION['session_db_id'])) {
    $stmt = $pdo->prepare("UPDATE admin_sessions SET logout_time = NOW() WHERE id = ?");
    $stmt->execute([$_SESSION['session_db_id']]);
}
session_destroy();
header("Location: /");
?>