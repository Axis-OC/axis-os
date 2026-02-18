<?php
require_once '/var/www/shared/db.php';
require_once '/var/www/shared/layout.php';

if (isLoggedIn()) { header("Location: dashboard.php"); exit; }

$ip = $_SERVER['REMOTE_ADDR'];
$msg = "";
$msgType = "";
$is_locked = false;

// --- ACL CHECK ---
$stmt = $pdo->prepare("SELECT * FROM access_control WHERE ip_address = ?");
$stmt->execute([$ip]);
$acl = $stmt->fetch();

if ($acl && $acl['locked_until'] && strtotime($acl['locked_until']) > time()) {
    $is_locked = true;
    $msg = "TERMINAL LOCKED due to excessive failures.";
    $msgType = "error";
}

// --- ACTIONS ---
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $action = $_POST['action'];

    // 1. EMERGENCY BYPASS (UNLOCK)
    if ($is_locked) {
        if ($action === 'bypass') {
            $token = trim($_POST['bypass_token']);
            $stmt = $pdo->prepare("SELECT * FROM users WHERE api_token = ?");
            $stmt->execute([$token]);
            $u = $stmt->fetch();

            if ($u) {
                $stmt = $pdo->prepare("DELETE FROM access_control WHERE ip_address = ?");
                $stmt->execute([$ip]);
                
                session_regenerate_id(true);
                $_SESSION['user_id'] = $u['id'];
                $_SESSION['username'] = $u['username'];
                $_SESSION['is_admin'] = $u['is_admin'];
                
                $stmt = $pdo->prepare("INSERT INTO admin_sessions (user_id, ip_address, user_agent) VALUES (?, ?, ?)");
                $stmt->execute([$u['id'], $ip, $_SERVER['HTTP_USER_AGENT']]);
                
                header("Location: dashboard.php"); exit;
            } else {
                sleep(2); // Delay penalty
                $msg = "Invalid Token. Access remains restricted.";
            }
        }
    } 
    // 2. NORMAL OPERATIONS
    else {
        $user = trim($_POST['username'] ?? '');
        $pass = $_POST['password'] ?? '';

        if ($action === 'login') {
            $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ?");
            $stmt->execute([$user]);
            $u = $stmt->fetch();

            if ($u && password_verify($pass, $u['password_hash'])) {
                // Success: Reset Failures
                $stmt = $pdo->prepare("DELETE FROM access_control WHERE ip_address = ?");
                $stmt->execute([$ip]);

                session_regenerate_id(true);
                $_SESSION['user_id'] = $u['id'];
                $_SESSION['username'] = $u['username'];
                $_SESSION['is_admin'] = $u['is_admin'];
                
                $stmt = $pdo->prepare("INSERT INTO admin_sessions (user_id, ip_address, user_agent) VALUES (?, ?, ?)");
                $stmt->execute([$u['id'], $ip, $_SERVER['HTTP_USER_AGENT']]);
                
                header("Location: dashboard.php"); exit;
            } else {
                // Fail: Increment Counter
                handleAuthFailure($pdo, $ip);
                $msg = "Invalid Credentials.";
                $msgType = "error";
            }
        } 
        elseif ($action === 'register') {
            if (strlen($user) < 3 || strlen($pass) < 6) {
                $msg = "Invalid input requirements."; $msgType = "error";
            } else {
                $token = bin2hex(random_bytes(32));
                $hash = password_hash($pass, PASSWORD_DEFAULT);
                try {
                    $stmt = $pdo->prepare("INSERT INTO users (username, password_hash, api_token) VALUES (?, ?, ?)");
                    $stmt->execute([$user, $hash, $token]);
                    $msg = "Identity created."; $msgType = "success";
                } catch (Exception $e) {
                    $msg = "Identity conflict."; $msgType = "error";
                }
            }
        }
        elseif ($action === 'rotate') {
            $old_pass = $_POST['old_password'];
            $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ?");
            $stmt->execute([$user]);
            $u = $stmt->fetch();
            
            if ($u && password_verify($old_pass, $u['password_hash'])) {
                if (strlen($pass) < 6) { $msg = "Weak key."; $msgType = "error"; }
                else {
                    $newHash = password_hash($pass, PASSWORD_DEFAULT);
                    $stmt = $pdo->prepare("UPDATE users SET password_hash = ? WHERE id = ?");
                    $stmt->execute([$newHash, $u['id']]);
                    $msg = "Credentials updated."; $msgType = "success";
                }
            } else {
                handleAuthFailure($pdo, $ip);
                $msg = "Authorization failed."; $msgType = "error";
            }
        }
    }
}

function handleAuthFailure($pdo, $ip) {
    sleep(1); // Basic slow-down
    $stmt = $pdo->prepare("INSERT INTO access_control (ip_address, failed_count) VALUES (?, 1) ON DUPLICATE KEY UPDATE failed_count = failed_count + 1");
    $stmt->execute([$ip]);
    
    // Check lock condition
    $stmt = $pdo->prepare("SELECT failed_count FROM access_control WHERE ip_address = ?");
    $stmt->execute([$ip]);
    $count = $stmt->fetchColumn();
    
    if ($count >= 5) {
        $stmt = $pdo->prepare("UPDATE access_control SET locked_until = DATE_ADD(NOW(), INTERVAL 24 HOUR) WHERE ip_address = ?");
        $stmt->execute([$ip]);
        global $is_locked, $msg, $msgType;
        $is_locked = true;
        $msg = "Security Breach Detected. Terminal Locked.";
        $msgType = "error";
    }
}

// System Metrics
$start = microtime(true); $pdo->query("SELECT 1"); $latency = round((microtime(true)-$start)*1000, 2);
$load = sys_getloadavg();
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Axis ID // Gateway</title>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Inter:wght@400;600&display=swap" rel="stylesheet">
    <style>
        :root { --bg: #050505; --panel: rgba(10,10,10,0.85); --border: rgba(255,255,255,0.15); --accent: #00bcd4; --err: #f55; --ok: #0f0; }
        body { background: var(--bg); color: #ccc; font-family: 'JetBrains Mono', monospace; margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; }
        
        #bgCanvas { position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: 0; pointer-events: none; opacity: 0.3; }
        
        .gateway-container {
            display: grid; grid-template-columns: 1.2fr 0.8fr;
            width: 900px; height: 520px;
            background: var(--panel); border: 1px solid var(--border);
            backdrop-filter: blur(12px);
            position: relative; z-index: 1;
            box-shadow: 0 30px 60px rgba(0,0,0,0.6);
        }
        
        /* LEFT: FORM */
        .auth-pane { padding: 50px; display: flex; flex-direction: column; border-right: 1px solid var(--border); position: relative; }
        
        .brand { font-size: 1.5rem; color: #fff; margin-bottom: 5px; letter-spacing: -1px; }
        .brand span { color: var(--accent); }
        .subtitle { font-size: 0.75rem; color: #666; margin-bottom: 40px; text-transform: uppercase; letter-spacing: 1px; }
        
        .tabs { display: flex; gap: 20px; margin-bottom: 30px; border-bottom: 1px solid var(--border); }
        .tab { padding-bottom: 10px; cursor: pointer; font-size: 0.8rem; color: #666; transition: 0.2s; }
        .tab:hover { color: #fff; }
        .tab.active { color: var(--accent); border-bottom: 2px solid var(--accent); }
        
        .input-group { margin-bottom: 20px; }
        label { display: block; font-size: 0.7rem; color: #555; margin-bottom: 8px; text-transform: uppercase; font-weight: bold; }
        input { 
            width: 100%; background: rgba(0,0,0,0.4); border: 1px solid #333; 
            color: #fff; padding: 14px; font-family: inherit; font-size: 0.9rem; 
            box-sizing: border-box; transition: 0.2s; 
        }
        input:focus { border-color: var(--accent); outline: none; background: rgba(0,0,0,0.6); }
        
        .btn { 
            width: 100%; padding: 14px; background: rgba(0, 188, 212, 0.1); 
            border: 1px solid var(--accent); color: var(--accent); 
            font-weight: bold; cursor: pointer; margin-top: 10px; transition: 0.2s; 
        }
        .btn:hover { background: var(--accent); color: #000; }
        
        /* LOCKED STATE */
        .locked-mode input { border-color: var(--err); color: var(--err); }
        .locked-mode .btn { border-color: var(--err); color: var(--err); background: rgba(255, 85, 85, 0.1); }
        .locked-mode .btn:hover { background: var(--err); color: #000; }
        
        .alert { 
            padding: 12px; margin-bottom: 25px; font-size: 0.8rem; 
            border-left: 3px solid; background: rgba(0,0,0,0.3);
        }
        .alert.error { border-color: var(--err); color: var(--err); }
        .alert.success { border-color: var(--ok); color: var(--ok); }

        /* RIGHT: STATUS */
        .info-pane { padding: 50px; display: flex; flex-direction: column; justify-content: center; position: relative; background: rgba(0,0,0,0.2); }
        .stat-row { display: flex; justify-content: space-between; border-bottom: 1px solid #222; padding: 15px 0; font-size: 0.8rem; }
        .stat-label { color: #666; }
        .stat-val { color: #ccc; font-family: inherit; }
        
        /* HEARTBEAT CANVAS */
        .pulse-container { height: 80px; width: 100%; margin-top: auto; position: relative; border-bottom: 1px solid #222; opacity: 0.7; }
        #pulseCanvas { width: 100%; height: 100%; display: block; }
        
        /* UTILS */
        .hidden { display: none !important; }
        .fade-in { animation: fadeIn 0.4s ease; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }
    </style>
</head>
<body>

<canvas id="bgCanvas"></canvas>

<div class="gateway-container">
    <!-- LEFT: INTERACTIONS -->
    <div class="auth-pane">
        <div>
            <div class="brand">AXIS <span>ID</span></div>
            <div class="subtitle">Secure Developer Gateway</div>
        </div>

        <?php if($msg): ?>
            <div class="alert <?= $msgType ?>"><?= $msg ?></div>
        <?php endif; ?>

        <?php if($is_locked): ?>
            <!-- LOCKED UI -->
            <form method="POST" class="locked-mode fade-in">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="bypass">
                
                <div style="color: #f55; font-size: 0.8rem; margin-bottom: 20px; line-height: 1.5;">
                    ACCESS SUSPENDED (24H).<br>
                    ENTER IDENTITY TOKEN TO OVERRIDE.
                </div>
                
                <div class="input-group">
                    <label style="color:#f55">Identity Token</label>
                    <input type="password" name="bypass_token" required placeholder="Paste your API Token here">
                </div>
                
                <button class="btn">VERIFY IDENTITY</button>
            </form>
        <?php else: ?>
            <!-- NORMAL UI -->
            <div class="tabs">
                <div class="tab active" onclick="setMode('login')">LOGIN</div>
                <div class="tab" onclick="setMode('register')">REGISTER</div>
                <div class="tab" onclick="setMode('rotate')">ROTATE</div>
            </div>

            <form method="POST" id="mainForm" class="fade-in">
                <?= csrf_field() ?>
                <input type="hidden" name="action" id="formAction" value="login">
                
                <div class="input-group">
                    <label>Identity</label>
                    <input type="text" name="username" required autocomplete="off" placeholder="username">
                </div>

                <!-- Shown for Rotate Only -->
                <div class="input-group hidden" id="oldPassField">
                    <label>Current Credential</label>
                    <input type="password" name="old_password" placeholder="••••••">
                </div>

                <div class="input-group">
                    <label id="passLabel">Credential</label>
                    <input type="password" name="password" required placeholder="••••••">
                </div>

                <button class="btn" id="submitBtn">AUTHENTICATE</button>
            </form>
        <?php endif; ?>
        
        <div style="margin-top: auto; font-size: 0.65rem; color: #444;">
            SYSTEM SECURE. ALL ATTEMPTS LOGGED.
        </div>
    </div>

    <!-- RIGHT: METRICS -->
    <div class="info-pane">
        <h3 style="color:#fff; font-size:0.9rem; margin-bottom:20px; text-transform:uppercase; letter-spacing:1px;">Node Status</h3>
        
        <div class="stat-row">
            <span class="stat-label">UPLINK</span>
            <span class="stat-val" style="color:var(--ok)">ESTABLISHED</span>
        </div>
        <div class="stat-row">
            <span class="stat-label">LATENCY</span>
            <span class="stat-val"><?= $latency ?>ms</span>
        </div>
        <div class="stat-row">
            <span class="stat-label">LOAD AVG</span>
            <span class="stat-val"><?= $load[0] ?></span>
        </div>
        <div class="stat-row">
            <span class="stat-label">CLIENT IP</span>
            <span class="stat-val"><?= $_SERVER['REMOTE_ADDR'] ?></span>
        </div>

        <div class="pulse-container">
            <canvas id="pulseCanvas"></canvas>
        </div>
    </div>
</div>

<script>
// --- UI LOGIC (Normal Mode) ---
function setMode(mode) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    event.target.classList.add('active');
    
    const form = document.getElementById('mainForm');
    if(!form) return; // If locked
    
    const act = document.getElementById('formAction');
    const btn = document.getElementById('submitBtn');
    const oldPass = document.getElementById('oldPassField');
    const passLbl = document.getElementById('passLabel');
    
    form.classList.remove('fade-in');
    void form.offsetWidth; 
    form.classList.add('fade-in');

    act.value = mode;
    oldPass.classList.add('hidden');
    document.querySelector('[name="old_password"]').required = false;

    if (mode === 'login') {
        btn.innerText = "AUTHENTICATE";
        passLbl.innerText = "Credential";
    } else if (mode === 'register') {
        btn.innerText = "INITIALIZE IDENTITY";
        passLbl.innerText = "Set Credential";
    } else if (mode === 'rotate') {
        btn.innerText = "UPDATE CREDENTIALS";
        oldPass.classList.remove('hidden');
        document.querySelector('[name="old_password"]').required = true;
        passLbl.innerText = "New Credential";
    }
}

// --- PULSE GRAPH (HEARTBEAT) ---
const pCanvas = document.getElementById('pulseCanvas');
const pCtx = pCanvas.getContext('2d');
let pW, pH;

function resizePulse() {
    const r = pCanvas.parentElement.getBoundingClientRect();
    pW = pCanvas.width = r.width;
    pH = pCanvas.height = r.height;
}
window.addEventListener('resize', resizePulse);
resizePulse();

let t = 0;
function drawPulse() {
    pCtx.clearRect(0, 0, pW, pH);
    
    pCtx.beginPath();
    pCtx.strokeStyle = "#00bcd4";
    pCtx.lineWidth = 2;
    
    const baseline = pH * 0.8;
    pCtx.moveTo(0, baseline);
    
    for(let x=0; x<pW; x++) {
        // Create a moving "window" for the beat
        const pos = (x + t) % pW;
        
        // The heartbeat shape logic
        let y = baseline;
        
        // Define a beat zone every 200px
        const beatZone = x % 200;
        
        if (beatZone > 100 && beatZone < 130) {
            // P wave
            if(beatZone < 110) y -= 5;
            // QRS complex
            else if(beatZone < 115) y += 5;
            else if(beatZone < 120) y -= 25; // Spike up
            else if(beatZone < 125) y += 10; // Spike down
        }
        
        // Moving point of drawing (scanline effect)
        // We actually want the wave to move left.
        // Let's simplify: static wave, moving scanline
        
    }
    
    // Simpler approach: Draw the wave once, shift x offset
    const offset = t % 200; // Cycle length
    
    for (let x = 0; x < pW; x++) {
        // Map x to a "phase" in the beat cycle
        const phase = (x - t) % 300; 
        // Normalize negative modulo
        const pNorm = phase < 0 ? phase + 300 : phase;
        
        let y = baseline;
        
        // Draw beat at specific phase 150-200
        if(pNorm > 150 && pNorm < 200) {
            const localX = pNorm - 150;
            if(localX < 10) y -= localX * 0.5; // P
            else if(localX < 20) y += (localX-10); // Q
            else if(localX < 30) y -= (localX-20)*4; // R (Up)
            else if(localX < 40) y += (localX-30)*4; // S (Down)
            else y = baseline;
        }
        
        if (x===0) pCtx.moveTo(x, y); else pCtx.lineTo(x, y);
    }
    pCtx.stroke();
    
    // Draw "Leading dot"
    pCtx.fillStyle = "#fff";
    pCtx.beginPath();
    // Use fixed position, animate wave instead
    
    t += 2;
    requestAnimationFrame(drawPulse);
}
drawPulse();

// --- BACKGROUND GRID ---
class Grid {
    constructor() {
        this.c = document.getElementById('bgCanvas');
        this.ctx = this.c.getContext('2d');
        this.resize();
        window.onresize = () => this.resize();
        this.animate();
    }
    resize() { this.w = this.c.width = window.innerWidth; this.h = this.c.height = window.innerHeight; }
    animate() {
        this.ctx.clearRect(0,0,this.w,this.h);
        this.ctx.strokeStyle = 'rgba(0, 188, 212, 0.1)';
        this.ctx.lineWidth = 1;
        this.ctx.beginPath();
        const time = Date.now() * 0.005;
        const space = 80;
        const offY = time % space;
        
        // Vertical perspective lines
        const cx = this.w / 2;
        const cy = this.h / 2;
        
        for(let x=0; x<=this.w; x+=space) {
            this.ctx.moveTo(x, 0); this.ctx.lineTo(x, this.h);
        }
        for(let y=offY; y<this.h; y+=space) {
            this.ctx.moveTo(0, y); this.ctx.lineTo(this.w, y);
        }
        this.ctx.stroke();
        requestAnimationFrame(()=>this.animate());
    }
}
new Grid();
</script>
</body>
</html>