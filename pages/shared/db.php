<?php

$host = '127.0.0.1';
$db   = 'axis_system';
$user = 'admin';
$pass = 'admin'; 
$charset = 'utf8mb4';

$dsn = "mysql:host=$host;port=3306;dbname=$db;charset=$charset";
$opt = [
    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES   => false,
];

try {
    $pdo = new PDO($dsn, $user, $pass, $opt);
} catch (\PDOException $e) {
    die("SYSTEM ERROR: Database Connection Refused."); 
}

ini_set('session.cookie_httponly', 1);
ini_set('session.use_only_cookies', 1);
// ini_set('session.cookie_secure', 1);

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

function isLoggedIn() {
    return isset($_SESSION['user_id']);
}

function isAdmin() {
    return isset($_SESSION['is_admin']) && $_SESSION['is_admin'] === 1;
}

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

function csrf_field() {
    return '<input type="hidden" name="csrf_token" value="'.$_SESSION['csrf_token'].'">';
}

function check_csrf() {
    if (!isset($_POST['csrf_token']) || $_POST['csrf_token'] !== $_SESSION['csrf_token']) {
        die("Security Check Failed: CSRF Token Mismatch");
    }
}

function logUserAction($pdo, $userId, $action) {
    try {
        $stmt = $pdo->prepare("INSERT INTO user_audit (user_id, action, ip_address) VALUES (?, ?, ?)");
        $stmt->execute([$userId, $action, $_SERVER['REMOTE_ADDR']]);
    } catch (Exception $e) { /* Ignore logging errors */ }
}
?>