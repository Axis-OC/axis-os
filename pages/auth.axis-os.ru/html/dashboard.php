<?php
require_once '/var/www/shared/db.php';
require_once '/var/www/shared/layout.php';

if (!isLoggedIn()) { header("Location: index.php"); exit; }

$user_id = $_SESSION['user_id'];
$pgp_msg = "";

$stmt = $pdo->prepare("SELECT * FROM users WHERE id = ?");
$stmt->execute([$user_id]);
$userData = $stmt->fetch();

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action']) && $_POST['action'] === 'upload_pgp') {
    check_csrf();
    
    if (!extension_loaded('gnupg')) {
        $pgp_msg = "SERVER ERROR: php-gnupg extension missing.";
    } else {
        try {
            $rawKey = $_POST['pgp_key'];
            $gpg = new gnupg();
            $gpg->seterrormode(gnupg::ERROR_EXCEPTION);
  
            $info = $gpg->import($rawKey);
            
            if ($info['imported'] === 0) {
                $pgp_msg = "INVALID KEY: Not a valid OpenPGP Block.";
            } else {
                $fingerprint = $info['fingerprint'];

                $dup = $pdo->prepare("SELECT id FROM users WHERE pgp_fingerprint = ? AND id != ?");
                $dup->execute([$fingerprint, $user_id]);
                
                if ($dup->fetch()) {
                    $pgp_msg = "ERROR: Key already used by another identity.";
                } else {
                    $stmt = $pdo->prepare("UPDATE users SET pgp_public_key = ?, pgp_fingerprint = ? WHERE id = ?");
                    $stmt->execute([$rawKey, $fingerprint, $user_id]);
                    
                    logUserAction($pdo, $user_id, 'PGP_LINKED');
                    header("Location: dashboard.php");
                    exit;
                }
            }
        } catch (Exception $e) {
            $pgp_msg = "GPG ERROR: " . $e->getMessage();
        }
    }
}

// --- PGP WALL ---
if (empty($userData['pgp_public_key'])) {
    renderHeader("Security Check // " . $userData['username']);
    ?>
    <style>
        body { background-color: #050505; color: #ccc; font-family: 'JetBrains Mono', monospace; display:flex; align-items:center; justify-content:center; height:100vh; overflow:hidden; margin:0; }
        .wall-card { width: 600px; background: rgba(10,10,10,0.95); border: 1px solid #f55; padding: 40px; box-shadow: 0 0 100px rgba(255,0,0,0.15); position:relative; z-index:10; backdrop-filter: blur(10px); }
        .wall-title { color: #f55; font-size: 1.2rem; border-bottom: 1px solid #333; padding-bottom: 15px; margin-bottom: 20px; letter-spacing: 2px; font-weight: bold; }
        textarea { width: 100%; height: 200px; background: #000; border: 1px solid #333; color: #0f0; font-family: monospace; font-size: 0.7rem; padding: 15px; resize: none; outline: none; box-sizing: border-box; }
        textarea:focus { border-color: #f55; }
        .btn-lock { width: 100%; background: rgba(255,0,0,0.1); border: 1px solid #f55; color: #f55; padding: 15px; cursor: pointer; font-weight: bold; margin-top: 20px; transition: 0.2s; }
        .btn-lock:hover { background: #f55; color: #000; }
    </style>
    
    <div class="wall-card">
        <div class="wall-title">PGP Key Required</div>
        
        <?php if($pgp_msg): ?><div class="alert alert-error"><?= $pgp_msg ?></div><?php endif; ?>
        
        <p style="font-size:0.85rem; color:#aaa; line-height:1.6; margin-bottom:20px;">
            Identity Verification Incomplete.<br>
            To access the AXIS API and generate tokens, you must link a valid <b>OpenPGP Public Key</b>.<br><br>
            This establishes a Chain of Trust for all your future OS certificates.
        </p>

        <form method="POST">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="upload_pgp">
            <label style="color:#f55; display:block; margin-bottom:10px; font-size:0.7rem;">PASTE ASCII ARMORED PUBLIC KEY BLOCK:</label>
            <textarea name="pgp_key" placeholder="-----BEGIN PGP PUBLIC KEY BLOCK-----..."></textarea>
            <button class="btn-lock">VERIFY INTEGRITY & LINK</button>
        </form>
        
        <div style="text-align:center; margin-top:20px;">
            <a href="logout.php" style="color:#666; font-size:0.7rem; text-decoration:none;">[ ABORT SESSION ]</a>
        </div>
    </div>
    
    <script>
        // Copy grid from layout for consistency
        const c = document.getElementById('bgCanvas');
        if(c) {
            const x = c.getContext('2d');
            c.width = window.innerWidth; c.height = window.innerHeight;
            x.strokeStyle = '#200'; x.lineWidth=1;
            for(let i=0;i<c.width;i+=40){x.beginPath();x.moveTo(i,0);x.lineTo(i,c.height);x.stroke();}
            for(let i=0;i<c.height;i+=40){x.beginPath();x.moveTo(0,i);x.lineTo(c.width,i);x.stroke();}
        }
    </script>
    <?php
    exit; // STOP EXECUTION OF DASHBOARD
}

// ==========================================================
// STANDARD DASHBOARD CODE STARTS HERE (Only if PGP exists)
// ==========================================================

$view = $_GET['view'] ?? 'overview'; 
$msg = "";

// --- ACTIONS ---
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    
    if ($_POST['action'] === 'regen_token') {
        $newToken = bin2hex(random_bytes(32));
        $stmt = $pdo->prepare("UPDATE users SET api_token = ? WHERE id = ?");
        $stmt->execute([$newToken, $user_id]);
        logUserAction($pdo, $user_id, 'REGEN_TOKEN');
        $userData['api_token'] = $newToken; // Update local var immediately
        $msg = "Token cycled successfully.";
    }
    
    if ($_POST['action'] === 'add_webhook') {
        $url = filter_var($_POST['target_url'], FILTER_VALIDATE_URL);
        if ($url) {
            $secret = bin2hex(random_bytes(16));
            $stmt = $pdo->prepare("INSERT INTO user_webhooks (user_id, target_url, secret) VALUES (?, ?, ?)");
            $stmt->execute([$user_id, $url, $secret]);
            $msg = "Endpoint registered.";
        }
    }
    if ($_POST['action'] === 'del_webhook') {
        $stmt = $pdo->prepare("DELETE FROM user_webhooks WHERE id = ? AND user_id = ?");
        $stmt->execute([$_POST['wh_id'], $user_id]);
        $msg = "Webhook removed.";
    }

    if ($_POST['action'] === 'save_settings') {
        $settings = json_encode([
            'quota_limit' => min(65535, max(1, (int)$_POST['quota_limit'])),
            'auto_revoke' => $_POST['auto_revoke'],
            'sfx' => ['enabled' => isset($_POST['sfx_enabled']), 'vol' => (int)$_POST['sfx_vol']],
            'grid' => [
                'enabled' => isset($_POST['grid_enabled']),
                'effect' => $_POST['grid_effect'],
                'str_v' => (int)$_POST['str_v'],
                'str_h' => (int)$_POST['str_h'],
                'hue'   => (int)$_POST['grid_hue'],
                'blur'  => (int)$_POST['grid_blur']
            ]
        ]);

        $stmt = $pdo->prepare("UPDATE users SET full_name=?, bio=?, region=?, timezone=?, settings=? WHERE id=?");
        $stmt->execute([
            substr($_POST['full_name'], 0, 100),
            substr($_POST['bio'], 0, 700),
            substr($_POST['region'], 0, 50),
            $_POST['timezone'],
            $settings,
            $user_id
        ]);
        logUserAction($pdo, $user_id, 'UPDATE_PROFILE');
        // Refresh Data
        $stmt = $pdo->prepare("SELECT * FROM users WHERE id = ?");
        $stmt->execute([$user_id]);
        $userData = $stmt->fetch();
        $msg = "Configuration saved & applied.";
    }
}

// --- PREP VIEW DATA ---
$userSettings = json_decode($userData['settings'] ?? '{}', true);
$gridCfg = $userSettings['grid'] ?? ['enabled'=>true, 'effect'=>'gravity', 'str_v'=>50, 'str_h'=>50, 'hue'=>180, 'blur'=>0];
$sfxCfg  = $userSettings['sfx'] ?? ['enabled'=>true, 'vol'=>15];
$quotaLimit = $userSettings['quota_limit'] ?? 1000;

$uid_hash = strtoupper(substr(md5("axis_salt_" . $userData['id']), 0, 4) . '-' . substr(md5("uid" . $userData['id']), 0, 4));
$display_uid = "AX-" . $uid_hash;

if ($view === 'overview') {
    $stmt = $pdo->prepare("SELECT * FROM pki_keys WHERE user_id = ? ORDER BY created_at DESC");
    $stmt->execute([$user_id]);
    $myKeys = $stmt->fetchAll();

    $stmt = $pdo->prepare("SELECT FLOOR(UNIX_TIMESTAMP(created_at)/3600) as time_slot, COUNT(*) as cnt FROM user_audit WHERE user_id = ? AND created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR) GROUP BY time_slot");
    $stmt->execute([$user_id]);
    $rows = $stmt->fetchAll(PDO::FETCH_KEY_PAIR);
    $graphData = array_fill(0, 24, 0);
    $current_slot = floor(time() / 3600);
    for ($i = 0; $i < 24; $i++) {
        $ts = $current_slot - (23 - $i);
        if (isset($rows[$ts])) $graphData[$i] = (int)$rows[$ts];
    }
    $dailyRequests = array_sum($graphData);
}

if ($view === 'webhooks') {
    $stmt = $pdo->prepare("SELECT * FROM user_webhooks WHERE user_id = ? ORDER BY created_at DESC");
    $stmt->execute([$user_id]);
    $webhooks = $stmt->fetchAll();
}

if ($view === 'audit') {
    $stmt = $pdo->prepare("SELECT * FROM user_audit WHERE user_id = ? ORDER BY created_at DESC LIMIT 50");
    $stmt->execute([$user_id]);
    $fullAudit = $stmt->fetchAll();
}

renderHeader("Console // " . $userData['username']);
?>
<style>
    /* === CORE & TRANSPARENCY === */
    body { background-color: #050505; color: #ccc; margin: 0; overflow: hidden; font-family: 'JetBrains Mono', monospace; }
    #bgCanvas { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; z-index: 0; pointer-events: none; transition: filter 0.5s; }
    
    .console-layout { 
        display: grid; grid-template-columns: 280px 1fr; 
        height: 100vh; width: 95vw; margin: 0 auto; 
        border-left: 1px solid rgba(255,255,255,0.1); border-right: 1px solid rgba(255,255,255,0.1); 
        background: rgba(5, 5, 5, 0.4); backdrop-filter: blur(4px); 
        position: relative; z-index: 1;
    }
    
    .sidebar { background: rgba(8, 8, 8, 0.85); border-right: 1px solid rgba(255,255,255,0.1); padding: 30px; display: flex; flex-direction: column; }
    .dash-card { background: rgba(20, 20, 20, 0.6); border: 1px solid rgba(255,255,255,0.1); padding: 25px; margin-bottom: 0; backdrop-filter: blur(10px); }
    
    /* ANIMATIONS */
    @keyframes slideIn { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
    .animate-enter { animation: slideIn 0.4s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

    /* UI ELEMENTS */
    .user-card { margin-bottom: 40px; padding-bottom: 20px; border-bottom: 1px solid rgba(255,255,255,0.1); }
    .avatar { width: 54px; height: 54px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); display: flex; align-items: center; justify-content: center; color: var(--accent-color); font-weight: bold; font-size: 1.4rem; }
    .uid-badge { font-family: var(--font-mono); font-size: 0.75rem; color: #888; background: rgba(0,0,0,0.5); padding: 3px 8px; border-radius: 2px; border: 1px solid rgba(255,255,255,0.1); display: inline-block; }
    
    .nav-label { font-size: 0.7rem; color: #666; text-transform: uppercase; margin: 30px 0 10px 0; font-weight: bold; letter-spacing: 1px; }
    .nav-item { padding: 10px 15px; color: #999; cursor: pointer; border-radius: 2px; margin-bottom: 4px; transition: 0.2s; font-size: 0.85rem; display: flex; justify-content: space-between; align-items: center; text-decoration: none; }
    .nav-item:hover { background: rgba(255,255,255,0.05); color: #fff; }
    .nav-item.active { background: rgba(255,255,255,0.1); color: #fff; border-left: 2px solid var(--accent-color); }
    .nav-item.danger:hover { background: rgba(255, 85, 85, 0.1); border-left-color: #d33; color: #f55; }

    .content { padding: 40px; overflow-y: auto; display: grid; grid-template-columns: 2fr 1fr; gap: 40px; align-content: start; opacity: 0; }
    .full-width { grid-column: 1 / -1; }
    
    .section-header { display: flex; justify-content: space-between; align-items: end; margin-bottom: 15px; border-bottom: 1px solid rgba(255,255,255,0.1); padding-bottom: 8px; }
    .section-title { font-size: 0.8rem; color: var(--accent-color); text-transform: uppercase; letter-spacing: 1px; font-weight: bold; }
    
    /* === CONTROLS === */
    .input-dark, select, textarea { 
        background: rgba(0,0,0,0.5); border: 1px solid rgba(255,255,255,0.15); 
        padding: 10px; color: #fff; width: 100%; font-family: var(--font-mono); 
        font-size: 0.85rem; box-sizing: border-box; transition: all 0.2s; 
    }
    .input-dark:focus { border-color: var(--accent-color); background: rgba(0,0,0,0.8); outline: none; }
    label { font-size: 0.7rem; color: #888; text-transform: uppercase; display: block; margin-bottom: 5px; margin-top: 15px; }

    /* TECH CHECKBOX */
    input[type="checkbox"] {
        appearance: none; -webkit-appearance: none;
        width: 18px; height: 18px; background: #000; border: 1px solid #444;
        display: inline-grid; place-content: center; margin-right: 8px; cursor: pointer; transition: 0.2s;
    }
    input[type="checkbox"]::before {
        content: ""; width: 8px; height: 8px; background: var(--accent-color);
        transform: scale(0); transition: 0.1s transform ease-in-out; box-shadow: 0 0 8px var(--accent-color);
    }
    input[type="checkbox"]:checked { border-color: var(--accent-color); }
    input[type="checkbox"]:checked::before { transform: scale(1); }

    /* TECH SLIDER (FILLED) */
    input[type=range] {
        -webkit-appearance: none; width: 100%; background: transparent; cursor: pointer; height: 20px; vertical-align: middle;
    }
    input[type=range]:focus { outline: none; }
    
    input[type=range]::-webkit-slider-runnable-track {
        width: 100%; height: 4px; cursor: pointer;
        background: #222; border: none;
        /* FILL LOGIC */
        background-image: linear-gradient(var(--accent-color), var(--accent-color));
        background-size: var(--percent, 0%) 100%;
        background-repeat: no-repeat;
    }
    
    input[type=range]::-webkit-slider-thumb {
        -webkit-appearance: none;
        height: 14px; width: 8px; 
        background: #000; border: 1px solid var(--accent-color);
        margin-top: -5px; /* (trackHeight / 2) - (thumbHeight / 2) */
        box-shadow: 0 0 5px var(--accent-color);
        transition: transform 0.1s;
    }
    input[type=range]::-webkit-slider-thumb:hover { transform: scale(1.1); background: var(--accent-color); }

    /* MISC CONTROLS */
    .num-spinner { display: flex; border: 1px solid #444; background: rgba(0,0,0,0.5); }
    .num-spinner input { border: none; text-align: center; -moz-appearance: textfield; background: transparent; }
    .num-spinner input:focus { border:none; outline:none; }
    .spin-btn { width: 40px; background: rgba(255,255,255,0.05); border: none; color: var(--accent-color); cursor: pointer; font-weight: bold; transition: 0.2s; font-family: monospace; font-size: 1.2rem; }
    .spin-btn:hover { background: rgba(255,255,255,0.1); color: #fff; }
    
    .date-trigger { background: rgba(0,0,0,0.5); border: 1px solid #444; padding: 10px; color: #fff; font-family: var(--font-mono); font-size: 0.85rem; cursor: pointer; display: flex; justify-content: space-between; align-items: center; transition: border-color 0.2s; }
    .date-trigger:hover { border-color: var(--accent-color); }
    
    .tech-calendar { display: none; position: absolute; z-index: 100; background: #0a0a0a; border: 1px solid var(--accent-color); padding: 10px; width: 220px; box-shadow: 0 5px 20px rgba(0,0,0,0.8); }
    .cal-header { display: flex; justify-content: space-between; margin-bottom: 10px; align-items: center; }
    .cal-btn { background: transparent; border: 1px solid #333; color: var(--accent-color); cursor: pointer; padding: 2px 8px; }
    .cal-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 2px; }
    .cal-day { padding: 5px; text-align: center; font-size: 0.75rem; cursor: pointer; color: #888; }
    .cal-day:hover { background: #222; color: #fff; }
    .cal-day.active { background: var(--accent-color); color: #000; font-weight: bold; }
    .cal-head-day { text-align: center; font-size: 0.6rem; color: #555; padding-bottom: 5px; }

    .settings-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 30px; }
    .showcase-container { width: 100%; height: 200px; border: 1px solid #333; margin-top: 20px; position: relative; overflow: hidden; background: rgba(0,0,0,0.5); }
    
    .secret-field { display: flex; border: 1px solid #333; background: #000; margin-top: 10px; height: 42px; }
    .secret-val { flex-grow: 1; font-family: var(--font-mono); color: #fff; background: transparent; border: none; font-size: 0.9rem; padding: 0 15px; filter: blur(5px); transition: 0.3s; cursor: text; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; outline: none; }
    .secret-val:hover, .secret-val:focus { filter: blur(0); }
    .secret-btn { border: none; border-left: 1px solid #333; background: #111; color: #888; padding: 0 20px; cursor: pointer; font-size: 0.75rem; font-weight: bold; height: 100%; transition: 0.2s; }
    .secret-btn:hover { background: #222; color: #fff; }
    
    table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
    th { text-align: left; padding: 10px; border-bottom: 1px solid #333; color: #666; text-transform: uppercase; font-size: 0.7rem; }
    td { padding: 10px; border-bottom: 1px solid #222; color: #aaa; }
    .graph-container { position: relative; height: 150px; width: 100%; margin-top: 20px; border-bottom: 1px solid #333; }
    canvas { width: 100%; height: 100%; display: block; }
    .char-count { font-size: 0.7rem; color: #555; text-align: right; margin-top: 2px; }
    .char-count.limit { color: #f55; }
    .btn { padding: 10px 20px; border: 1px solid var(--accent-color); color: var(--accent-color); background: rgba(0, 188, 212, 0.1); cursor: pointer; font-weight: bold; }
    .btn:hover { background: var(--accent-color); color: #000; }
</style>

<canvas id="bgCanvas"></canvas>

<div class="console-layout">
    <div class="sidebar">
        <div class="user-card">
            <div style="display:flex; gap:15px; align-items:center; margin-bottom:15px;">
                <div class="avatar"><?= substr($userData['username'], 0, 1) ?></div>
                <div>
                    <div style="color:#fff; font-weight:bold; font-size:1.1rem;"><?= htmlspecialchars($userData['username']) ?></div>
                    <div class="uid-badge"><?= $display_uid ?></div>
                </div>
            </div>
            <div style="font-size:0.8rem; color:#888;">
                Region: <span style="color:#fff"><?= htmlspecialchars($userData['region']) ?></span>
            </div>
        </div>
        
        <div class="nav-label">Platform</div>
        <a href="?view=overview" onclick="navClick()" class="nav-item <?= $view=='overview'?'active':'' ?>"><span>Overview</span> <span>[ ]</span></a>
        <a href="?view=webhooks" onclick="navClick()" class="nav-item <?= $view=='webhooks'?'active':'' ?>"><span>Webhooks</span> <span>⚡</span></a>
        <a href="?view=settings" onclick="navClick()" class="nav-item <?= $view=='settings'?'active':'' ?>"><span>Settings</span> <span>⚙️</span></a>

        <div class="nav-label">Security</div>
        <a href="?view=audit" onclick="navClick()" class="nav-item <?= $view=='audit'?'active':'' ?>"><span>Audit Logs</span></a>
        <?php if($userData['is_admin']): ?>
            <a href="https://pki.axis-os.ru" class="nav-item" style="color:var(--accent-color);"><span>PKI Admin</span> <span>⚙️</span></a>
        <?php endif; ?>
        
        <a href="logout.php" class="nav-item danger">Log Out</a>
    </div>

    <div class="content animate-enter">
        <?php if($msg): ?><div class="full-width alert alert-success"><?= $msg ?></div><?php endif; ?>

        <?php if ($view === 'overview'): ?>
            <div class="full-width">
                <div class="section-header"><span class="section-title">Identity Token</span></div>
                <div class="dash-card">
                    <p style="font-size:0.9rem; color:#aaa; margin:0;">Authentication key for Lua scripts.</p>
                    <div class="secret-field">
                        <input type="text" readonly class="secret-val" value="<?= $userData['api_token'] ?>" id="apiToken">
                        <button class="secret-btn" onclick="copyToken()">COPY</button>
                        <form method="POST" style="margin:0; height:100%; display:block;" onsubmit="return confirm('Cycling token breaks scripts. Continue?');">
                            <?= csrf_field() ?>
                            <button name="action" value="regen_token" class="secret-btn" title="Regenerate">🔧</button>
                        </form>
                    </div>
                </div>
            </div>

            <div class="full-width">
                <div class="section-header"><span class="section-title">PGP Identity</span></div>
                <div class="dash-card" style="border-left:3px solid #0f0; display:flex; justify-content:space-between; align-items:center;">
                    <div>
                        <div style="color:#fff; font-weight:bold; font-size:0.9rem;">CHAIN OF TRUST ESTABLISHED</div>
                        <div style="color:#0f0; font-family:monospace; font-size:0.8rem; margin-top:5px;"><?= $userData['pgp_fingerprint'] ?></div>
                    </div>
                    <div style="color:#0f0;">✅</div>
                </div>
            </div>

            <div>
                <div class="section-header"><span class="section-title">Traffic</span> <span class="section-meta">24H</span></div>
                <div class="dash-card">
                    <div style="display:flex; justify-content:space-between; margin-bottom:10px;">
                        <div style="font-size:2rem; color:#fff; font-family:var(--font-mono);"><?= $dailyRequests ?></div>
                        <div style="text-align:right; font-size:0.75rem; color:var(--accent-color);">LIMIT: <?= $quotaLimit ?></div>
                    </div>
                    <div class="graph-container"><canvas id="trafficChart"></canvas></div>
                </div>
            </div>

            <div>
                <div class="section-header"><span class="section-title">Certificates</span></div>
                <div class="dash-card" style="padding:15px;">
                    <?php if(empty($myKeys)): ?><div style="text-align:center; padding:10px; color:#444;">No Certificates</div><?php else: ?>
                    <?php foreach($myKeys as $k): 
                        $col = $k['status']=='approved'?'#0f0':($k['status']=='revoked'?'#f55':'#fa0'); 
                    ?>
                    <div style="display:flex; justify-content:space-between; border-bottom:1px solid #333; padding:10px 0;">
                        <div style="font-family:var(--font-mono); color:<?= $col ?>; font-size:0.8rem;"><?= substr($k['fingerprint'], 0, 10) ?>...</div>
                        <div style="font-size:0.7rem; color:#666;"><?= strtoupper($k['status']) ?></div>
                    </div>
                    <?php endforeach; endif; ?>
                </div>
            </div>

        <?php elseif ($view === 'audit'): ?>
            <div class="full-width">
                <div class="section-header"><span class="section-title">Security Audit Log</span></div>
                <div class="dash-card">
                    <table>
                        <thead><tr><th>Action</th><th>IP Address</th><th>Time (UTC)</th></tr></thead>
                        <tbody>
                        <?php foreach($fullAudit as $log): ?>
                        <tr>
                            <td style="color:var(--accent-color); font-family:var(--font-mono);"><?= $log['action'] ?></td>
                            <td style="font-family:var(--font-mono);"><?= $log['ip_address'] ?></td>
                            <td><?= $log['created_at'] ?></td>
                        </tr>
                        <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </div>

        <?php elseif ($view === 'settings'): ?>
            <form method="POST" class="full-width settings-grid">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="save_settings">
                
                <div>
                    <div class="section-header"><span class="section-title">Profile Data</span></div>
                    <div class="dash-card">
                        <label>UID</label>
                        <input type="text" class="input-dark" value="<?= $display_uid ?>" disabled style="color:#555;">
                        
                        <label>Display Name</label>
                        <input type="text" name="full_name" class="input-dark" value="<?= htmlspecialchars($userData['full_name'] ?? '') ?>">
                        
                        <div style="display:grid; grid-template-columns: 1fr 1fr; gap:10px;">
                            <div>
                                <label>Region</label>
                                <input type="text" name="region" class="input-dark" value="<?= htmlspecialchars($userData['region']) ?>">
                            </div>
                            <div>
                                <label>Timezone</label>
                                <select name="timezone" class="input-dark">
                                    <option value="UTC" <?= $userData['timezone']=='UTC'?'selected':'' ?>>UTC</option>
                                    <option value="EST" <?= $userData['timezone']=='EST'?'selected':'' ?>>EST</option>
                                    <option value="PST" <?= $userData['timezone']=='PST'?'selected':'' ?>>PST</option>
                                    <option value="CET" <?= $userData['timezone']=='CET'?'selected':'' ?>>CET</option>
                                </select>
                            </div>
                        </div>

                        <label>Bio</label>
                        <textarea name="bio" id="bioInput" class="input-dark" rows="4" maxlength="700"><?= htmlspecialchars($userData['bio'] ?? '') ?></textarea>
                        <div class="char-count" id="bioCounter">0/700</div>
                    </div>
                </div>

                <div>
                    <div class="section-header"><span class="section-title">System Preferences</span></div>
                    <div class="dash-card">
                        <div style="display:grid; grid-template-columns: 1fr 1fr; gap:10px;">
                            <div>
                                <label>Daily Quota Limit</label>
                                <div class="num-spinner">
                                    <button type="button" class="spin-btn" onclick="spin('quota', -100)">-</button>
                                    <input type="number" id="quota" name="quota_limit" class="input-dark" value="<?= $quotaLimit ?>" min="1" max="65535" style="border:none;">
                                    <button type="button" class="spin-btn" onclick="spin('quota', 100)">+</button>
                                </div>
                            </div>
                            <div>
                                <label>Auto-Revoke Date</label>
                                <div class="date-trigger" id="dateTrigger" onclick="toggleCalendar(event)">
                                    <span id="dateDisplay"><?= $userSettings['auto_revoke'] ?: 'YYYY-MM-DD' ?></span>
                                    <span style="color:var(--accent-color)">📅</span>
                                </div>
                                <input type="hidden" name="auto_revoke" id="realDateInput" value="<?= $userSettings['auto_revoke'] ?? '' ?>">
                                
                                <div class="tech-calendar" id="techCal">
                                    <div class="cal-header">
                                        <button type="button" class="cal-btn" onclick="changeMonth(-1)"><</button>
                                        <span id="calMonthYear" style="font-size:0.8rem; font-weight:bold; color:#fff;"></span>
                                        <button type="button" class="cal-btn" onclick="changeMonth(1)">></button>
                                    </div>
                                    <div class="cal-grid" id="calDays"></div>
                                </div>
                            </div>
                        </div>
                        
                        <div style="margin-top:20px; border-top:1px solid #444; padding-top:10px;">
                            <label style="color:var(--accent-color)">Visual & Audio</label>
                            
                            <div style="display:flex; gap:15px; margin-top:10px; align-items:center;">
                                <label style="margin:0; display:flex; align-items:center; gap:10px; cursor:pointer;">
                                    <input type="checkbox" name="sfx_enabled" id="sfxEnable" <?= $sfxCfg['enabled']?'checked':'' ?> onchange="playToggle(this)"> <span>SFX</span>
                                </label>
                                <div style="flex:1; display:flex; align-items:center; gap:10px;">
                                    <span style="font-size:0.7rem; color:#666">VOL</span>
                                    <input type="range" class="range-slider" name="sfx_vol" id="sfxVol" min="0" max="100" value="<?= $sfxCfg['vol'] ?>">
                                </div>
                            </div>

                            <label style="margin-top:20px; display:flex; align-items:center; gap:10px; cursor:pointer;">
                                <input type="checkbox" name="grid_enabled" id="gridEnable" <?= $gridCfg['enabled']?'checked':'' ?> onchange="playToggle(this)"> <span>Background Grid</span>
                            </label>
                            
                            <label>Effect Type</label>
                            <select name="grid_effect" id="gridEffect" class="input-dark">
                                <option value="gravity" <?= $gridCfg['effect']=='gravity'?'selected':'' ?>>Gravity Well</option>
                                <option value="lens" <?= $gridCfg['effect']=='lens'?'selected':'' ?>>Optical Lens</option>
                                <option value="distortion" <?= $gridCfg['effect']=='distortion'?'selected':'' ?>>Wave Distortion</option>
                                <option value="none" <?= $gridCfg['effect']=='none'?'selected':'' ?>>Static Grid</option>
                            </select>

                            <div style="display:grid; grid-template-columns: 1fr 1fr; gap:10px; margin-top:10px;">
                                <div><label>V-Strength</label><input type="range" class="range-slider" name="str_v" id="strV" min="0" max="100" value="<?= $gridCfg['str_v'] ?>"></div>
                                <div><label>H-Strength</label><input type="range" class="range-slider" name="str_h" id="strH" min="0" max="100" value="<?= $gridCfg['str_h'] ?>"></div>
                            </div>

                            <div style="display:grid; grid-template-columns: 1fr 1fr; gap:10px; margin-top:10px;">
                                <div><label>Grid Hue</label><input type="range" class="range-slider" name="grid_hue" id="gridHue" min="160" max="220" value="<?= $gridCfg['hue'] ?? 180 ?>"></div>
                                <div><label>Blur Factor</label><input type="range" class="range-slider" name="grid_blur" id="gridBlur" min="0" max="10" value="<?= $gridCfg['blur'] ?? 0 ?>"></div>
                            </div>
                            
                            <div class="showcase-container">
                                <canvas id="previewCanvas"></canvas>
                                <div style="position:absolute; bottom:5px; right:5px; font-size:0.6rem; color:#555;">PREVIEW</div>
                            </div>
                        </div>
                    </div>
                    <button class="btn" style="width:100%; margin-top:20px;">SAVE CONFIGURATION</button>
                </div>
            </form>
        <?php endif; ?>
        
        <?php if ($view === 'webhooks'): ?>
            <div class="full-width">
                <div class="section-header"><span class="section-title">Webhooks</span></div>
                <div class="dash-card">
                    <form method="POST" style="display:flex; gap:10px; margin-bottom:20px;">
                        <?= csrf_field() ?>
                        <input type="text" name="target_url" class="input-dark" placeholder="https://" required>
                        <button name="action" value="add_webhook" class="btn" style="width:auto;">ADD</button>
                    </form>
                    <?php if(empty($webhooks)): ?>
                        <div style="text-align:center; padding:30px; color:#444;">No endpoints</div>
                    <?php else: foreach($webhooks as $wh): ?>
                        <div style="display:flex; justify-content:space-between; border-bottom:1px solid #333; padding:10px 0;">
                            <div>
                                <div style="color:#ccc; font-family:var(--font-mono);"><?= htmlspecialchars($wh['target_url']) ?></div>
                                <div style="font-size:0.7rem; color:#555;">SECRET: <?= $wh['secret'] ?></div>
                            </div>
                            <form method="POST"><input type="hidden" name="wh_id" value="<?= $wh['id'] ?>"><button name="action" value="del_webhook" class="btn btn-danger" style="font-size:0.7rem; padding:5px 10px;">DEL</button></form>
                        </div>
                    <?php endforeach; endif; ?>
                </div>
            </div>
        <?php endif; ?>
    </div>
</div>

<script>
// --- AUDIO ENGINE ---
const sfxConfig = <?= json_encode($sfxCfg) ?>;
const audioCtx = new (window.AudioContext || window.webkitAudioContext)();

function playSound(type) {
    if (!sfxConfig.enabled || audioCtx.state === 'suspended') audioCtx.resume();
    if (!sfxConfig.enabled) return;

    const gainNode = audioCtx.createGain();
    gainNode.connect(audioCtx.destination);
    gainNode.gain.value = sfxConfig.vol / 100;

    const osc = audioCtx.createOscillator();
    osc.connect(gainNode);
    
    if (type === 'copy') {
        osc.type = 'sine';
        osc.frequency.setValueAtTime(800, audioCtx.currentTime);
        osc.frequency.exponentialRampToValueAtTime(1200, audioCtx.currentTime + 0.1);
        gainNode.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.1);
        osc.start(); osc.stop(audioCtx.currentTime + 0.1);
    } else if (type === 'nav') {
        osc.type = 'triangle';
        osc.frequency.setValueAtTime(200, audioCtx.currentTime);
        gainNode.gain.value = (sfxConfig.vol / 100) * 0.5; 
        gainNode.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.05);
        osc.start(); osc.stop(audioCtx.currentTime + 0.05);
    } else if (type === 'toggle_on') {
        osc.type = 'square';
        osc.frequency.setValueAtTime(400, audioCtx.currentTime);
        osc.frequency.linearRampToValueAtTime(600, audioCtx.currentTime + 0.05);
        gainNode.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.05);
        osc.start(); osc.stop(audioCtx.currentTime + 0.05);
    } else if (type === 'toggle_off') {
        osc.type = 'square';
        osc.frequency.setValueAtTime(400, audioCtx.currentTime);
        osc.frequency.linearRampToValueAtTime(200, audioCtx.currentTime + 0.05);
        gainNode.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.05);
        osc.start(); osc.stop(audioCtx.currentTime + 0.05);
    }
}

function navClick() { playSound('nav'); }
function playToggle(el) { playSound(el.checked ? 'toggle_on' : 'toggle_off'); }

function copyToken() {
    const el = document.getElementById('apiToken');
    el.select();
    navigator.clipboard.writeText(el.value);
    showToast('Token copied'); 
    playSound('copy');
}

// --- SLIDER FILL LOGIC ---
function initSliders() {
    document.querySelectorAll('input[type="range"]').forEach(range => {
        const updateFill = () => {
            const val = (range.value - range.min) / (range.max - range.min) * 100;
            range.style.setProperty('--percent', val + '%');
        };
        range.addEventListener('input', updateFill);
        updateFill();
    });
}
initSliders();

// --- BIO COUNTER ---
const bioInput = document.getElementById('bioInput');
if(bioInput) {
    const counter = document.getElementById('bioCounter');
    const updateCount = () => {
        const len = bioInput.value.length;
        counter.innerText = len + "/700";
        if(len >= 700) counter.classList.add('limit'); else counter.classList.remove('limit');
    }
    bioInput.addEventListener('input', updateCount);
    updateCount();
}

function spin(id, val) {
    const el = document.getElementById(id);
    let n = parseInt(el.value) + val;
    if(n < 1) n = 1; if(n > 65535) n = 65535;
    el.value = n;
}

// --- TECH CALENDAR ---
let calDate = new Date();
const monthNames = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];

function toggleCalendar(e) {
    const cal = document.getElementById('techCal');
    if(cal.style.display === 'block') { cal.style.display = 'none'; return; }
    cal.style.display = 'block';
    renderCalendar();
    e.stopPropagation();
}

function changeMonth(delta) { calDate.setMonth(calDate.getMonth() + delta); renderCalendar(); }

function selectDate(d) {
    calDate.setDate(d);
    const dateStr = calDate.toISOString().split('T')[0];
    document.getElementById('realDateInput').value = dateStr;
    document.getElementById('dateDisplay').innerText = dateStr;
    document.getElementById('techCal').style.display = 'none';
}

function renderCalendar() {
    const y = calDate.getFullYear(), m = calDate.getMonth();
    document.getElementById('calMonthYear').innerText = monthNames[m] + " " + y;
    const firstDay = new Date(y, m, 1).getDay();
    const daysInMonth = new Date(y, m+1, 0).getDate();
    let html = '';
    const days = ['SU','MO','TU','WE','TH','FR','SA'];
    days.forEach(d => html += `<div class="cal-head-day">${d}</div>`);
    for(let i=0; i<firstDay; i++) html += `<div></div>`;
    for(let i=1; i<=daysInMonth; i++) {
        const isActive = (i === calDate.getDate()) ? 'active' : '';
        html += `<div class="cal-day ${isActive}" onclick="selectDate(${i})">${i}</div>`;
    }
    document.getElementById('calDays').innerHTML = html;
}

window.onclick = function(event) {
    if (!event.target.matches('.date-trigger') && !event.target.closest('.date-trigger') && !event.target.closest('.tech-calendar')) {
        const cal = document.getElementById('techCal');
        if(cal) cal.style.display = 'none';
    }
}

// --- GRID ENGINE ---
class GridNetwork {
    constructor(canvasId, config) {
        this.canvas = document.getElementById(canvasId);
        if(!this.canvas) return;
        this.ctx = this.canvas.getContext('2d');
        this.config = config;
        this.mouseX = -1000; this.mouseY = -1000;
        this.points = []; this.spacing = 40;
        this.init();
        
        const resizeObs = new ResizeObserver(() => this.resize());
        resizeObs.observe(this.canvas.parentElement || document.body);
        
        window.addEventListener('mousemove', (e) => {
            if(canvasId === 'bgCanvas') {
                this.mouseX = e.clientX; this.mouseY = e.clientY;
            } else {
                const rect = this.canvas.getBoundingClientRect();
                this.mouseX = e.clientX - rect.left; this.mouseY = e.clientY - rect.top;
            }
        });
        
        if(canvasId === 'bgCanvas') this.canvas.style.filter = `blur(${this.config.blur}px)`;
        this.animate();
    }
    init() { this.resize(); }
    resize() {
        const parent = this.canvas.parentElement || document.body;
        this.width = this.canvas.width = parent.offsetWidth;
        this.height = this.canvas.height = parent.offsetHeight;
        this.points = [];
        const cols = Math.ceil(this.width/this.spacing)+1;
        const rows = Math.ceil(this.height/this.spacing)+1;
        for(let y=0; y<rows; y++) for(let x=0; x<cols; x++) this.points.push({ox:x*this.spacing, oy:y*this.spacing, x:0, y:0});
    }
    updateConfig(cfg) { 
        this.config = {...this.config, ...cfg}; 
        if(this.canvas.id === 'bgCanvas') this.canvas.style.filter = `blur(${this.config.blur}px)`;
    }
    animate() {
        this.ctx.clearRect(0,0,this.width,this.height);
        if(!this.config.enabled) { requestAnimationFrame(()=>this.animate()); return; }
        
        const influence = 250;
        const sV = this.config.str_v/20; const sH = this.config.str_h/20;
        
        this.points.forEach(p => {
            let tx = p.ox, ty = p.oy;
            const dx = this.mouseX - p.ox, dy = this.mouseY - p.oy;
            const dist = Math.sqrt(dx*dx+dy*dy);
            
            if(dist < influence && this.config.effect !== 'none') {
                const f = (influence - dist) / influence;
                if(this.config.effect === 'gravity') { tx += dx*f*sH*0.5; ty += dy*f*sV*0.5; }
                else if(this.config.effect === 'lens') { tx -= dx*f*sH*0.5; ty -= dy*f*sV*0.5; }
                else if(this.config.effect === 'distortion') { tx += Math.sin(dy*0.05)*20*f*sH; ty += Math.cos(dx*0.05)*20*f*sV; }
            }
            p.x += (tx - p.x) * 0.1; p.y += (ty - p.y) * 0.1;
        });

        const hue = this.config.hue || 180;
        const alpha = (this.canvas.id === 'bgCanvas') ? 0.2 : 0.6;
        this.ctx.strokeStyle = `hsla(${hue}, 100%, 50%, ${alpha})`;
        this.ctx.lineWidth = 1;
        this.ctx.beginPath();
        
        const cols = Math.ceil(this.width/this.spacing)+1;
        for(let i=0; i<this.points.length; i++) {
            if((i+1)%cols !== 0 && this.points[i+1]) { this.ctx.moveTo(this.points[i].x, this.points[i].y); this.ctx.lineTo(this.points[i+1].x, this.points[i+1].y); }
            if(this.points[i+cols]) { this.ctx.moveTo(this.points[i].x, this.points[i].y); this.ctx.lineTo(this.points[i+cols].x, this.points[i+cols].y); }
        }
        this.ctx.stroke();
        requestAnimationFrame(()=>this.animate());
    }
}

// Init BG Grid (Static, doesn't react to input)
const userCfg = <?= json_encode($gridCfg) ?>;
const bgGrid = new GridNetwork('bgCanvas', userCfg);

// Init Preview Grid (Dynamic)
if(document.getElementById('previewCanvas')) {
    const prevGrid = new GridNetwork('previewCanvas', userCfg);
    ['gridEnable','gridEffect','strV','strH','gridHue','gridBlur'].forEach(id => {
        document.getElementById(id).addEventListener('input', () => {
            const cfg = {
                enabled: document.getElementById('gridEnable').checked,
                effect: document.getElementById('gridEffect').value,
                str_v: parseInt(document.getElementById('strV').value),
                str_h: parseInt(document.getElementById('strH').value),
                hue: parseInt(document.getElementById('gridHue').value),
                blur: parseInt(document.getElementById('gridBlur').value)
            };
            prevGrid.updateConfig(cfg);
            // BG Grid NOT updated here to prevent flicker/distraction until save
        });
    });
}

const chartC = document.getElementById('trafficChart');
if(chartC) {
    const ctx = chartC.getContext('2d'); const dpr = window.devicePixelRatio||1;
    const r = chartC.getBoundingClientRect(); chartC.width=r.width*dpr; chartC.height=r.height*dpr; ctx.scale(dpr,dpr);
    const p = [<?= implode(',', $graphData ?? [0]) ?>]; const max=Math.max(...p,5); const w=r.width, h=r.height, step=w/(Math.max(p.length,1)-1);
    ctx.beginPath(); ctx.moveTo(0,h); p.forEach((v,i)=>ctx.lineTo(i*step,h-(v/max*h*0.8))); ctx.lineTo(w,h); ctx.closePath();
    const g=ctx.createLinearGradient(0,0,0,h); g.addColorStop(0,"rgba(0,188,212,0.2)"); g.addColorStop(1,"transparent"); ctx.fillStyle=g; ctx.fill();
    ctx.beginPath(); p.forEach((v,i)=>{const x=i*step, y=h-(v/max*h*0.8); if(i==0)ctx.moveTo(x,y);else ctx.lineTo(x,y)}); ctx.strokeStyle="#00bcd4"; ctx.lineWidth=2; ctx.stroke();
}
</script>
<?php renderFooter(); ?>