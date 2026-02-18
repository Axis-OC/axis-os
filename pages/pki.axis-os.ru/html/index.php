<?php
require_once '/var/www/shared/db.php';
require_once '/var/www/shared/layout.php';

// --- IP CHECK ---
$ip = $_SERVER['REMOTE_ADDR'];
$stmt = $pdo->prepare("SELECT id FROM banned_ips WHERE ip_address = ?");
$stmt->execute([$ip]);
if ($stmt->fetch()) die("<style>body{background:#000;color:#f00;font-family:monospace;display:flex;height:100vh;justify-content:center;align-items:center;}</style><h1>CONNECTION REFUSED<br><small>IP BLACKLISTED</small></h1>");

// --- META TAGS & FAVICON (Adapted for PKI Context) ---
$metaHeader = '
    <link rel="icon" type="image/x-icon" href="https://axis-os.ru/img/icon.png">
    <meta property="og:type" content="website">
    <meta property="og:url" content="https://axis-os.ru/">
    <meta property="og:title" content="Axis OS | PKI System">
    <meta property="og:description" content="Axis OS Secure Certificate & Access Control">
    <meta property="og:image" content="https://axis-os.ru/img/banner.jpg">
    
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="Axis OS | PKI System">
    <meta name="twitter:description" content="Axis OS Secure Certificate & Access Control">
    <meta name="twitter:image" content="https://axis-os.ru/img/banner.jpg">
';

// --- LOGIN SCREEN ---
if (!isAdmin()) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['adm_user'])) {
        $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ?");
        $stmt->execute([$_POST['adm_user']]);
        $u = $stmt->fetch();
        if ($u && $u['is_admin'] && password_verify($_POST['adm_pass'], $u['password_hash'])) {
            $_SESSION['user_id'] = $u['id'];
            $_SESSION['username'] = $u['username'];
            $_SESSION['is_admin'] = 1;
            $stmt = $pdo->prepare("INSERT INTO admin_sessions (user_id, ip_address, user_agent) VALUES (?, ?, ?)");
            $stmt->execute([$u['id'], $_SERVER['REMOTE_ADDR'], $_SERVER['HTTP_USER_AGENT']]);
            $_SESSION['session_db_id'] = $pdo->lastInsertId();
            header("Location: /"); exit;
        } else { $error = "INVALID CREDENTIALS"; }
    }

    renderHeader("PKI Gateway");
    echo $metaHeader; // Встраиваем мета-теги на странице входа
    
    echo '<div class="container"><div class="card" style="max-width:400px; margin:0 auto; background:#0a0a0a; border:1px solid #333;">
    <h2 style="color:#00bcd4; border-bottom:1px solid #333; padding-bottom:10px;"><div class="logo">ePKI<span style="color: #707070ff;"> //</span><span style="color:#fff;"><small><small>Key Control</small></small></span></div></h2>
    '.(isset($error)?'<div class="alert alert-error">'.$error.'</div>':'').'
    <form method="POST">
    <label>USER KEY</label><input type="text" name="adm_user" style="background:#000; border:1px solid #444; color:#fff;">
    <label>ACCESS KEY</label><input type="password" name="adm_pass" style="background:#000; border:1px solid #444; color:#fff;">
    <button class="btn" style="width:100%; border-color:#00bcd4; color:#00bcd4;">LOG IN</button>
    </form></div></div>';
    renderFooter();
    exit;
}

renderHeader("PKI Management");
echo $metaHeader;
?>
<style>
    /* === GLOBAL & RESET === */
    body { 
        background-color: #050505; 
        color: #e0e0e0; 
        font-family: 'JetBrains Mono', monospace; 
        overflow: hidden; /* Prevent body scroll */
        height: 100vh; 
        width: 100vw;
        margin: 0; padding: 0;
    }
        .logo { font-family: var(--font-mono); font-weight: 700; font-size: 1.2rem; letter-spacing: -1px; cursor: pointer; transition: color 0.3s; }
        .logo:hover { color: var(--accent-color); text-shadow: 0 0 10px var(--accent-glow); }
        .logo span { color: var(--accent-color); }
    
    /* === GRID LAYOUT === */
    .dashboard-grid {
        display: grid;
        grid-template-columns: 1fr 350px; /* Main Content | Sidebar */
        grid-template-rows: 60px 100px 1fr 30px; /* Header | Stats | Content | Footer */
        gap: 15px;
        padding: 15px;
        height: 100vh;
        max-width: 1920px;
        margin: 0 auto;
        box-sizing: border-box;
    }

    /* === HEADER === */
    .dash-header { 
        grid-column: 1 / -1; 
        display: flex; justify-content: space-between; align-items: center; 
        border-bottom: 1px solid #333; 
        background: #050505;
    }
    h1 { font-size: 1.5rem; margin: 0; color: #fff; letter-spacing: 1px; }
    h1 span { color: #00bcd4; }
    .op-badge { font-size: 0.75rem; text-align: right; line-height: 1.2; }
    .op-name { color: #00bcd4; font-weight: bold; }

    /* === STATS CARDS === */
    .stat-row { 
        grid-column: 1 / -1; 
        display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; 
    }
    .stat-card { 
        background: #0a0a0a; border: 1px solid #333; padding: 15px; 
        display: flex; flex-direction: column; justify-content: center;
        position: relative;
    }
    .stat-card::before { content:''; position: absolute; left:0; top:0; bottom:0; width: 3px; background: #444; }
    .stat-card.c-blue::before { background: #00bcd4; }
    .stat-card.c-warn::before { background: #fa0; }
    .stat-card.c-err::before { background: #f55; }
    .stat-card.c-good::before { background: #0f0; }

    .stat-label { font-size: 0.7rem; color: #666; text-transform: uppercase; margin-bottom: 5px; }
    .stat-value { font-size: 2rem; color: #fff; line-height: 1; }

    /* === MAIN PANEL (KEYS) === */
    .main-panel { 
        grid-column: 1 / 2; grid-row: 3 / 4; 
        background: #0a0a0a; border: 1px solid #333; 
        display: flex; flex-direction: column; 
        overflow: hidden; /* Important for inner scroll */
    }
    .panel-head { 
        padding: 10px 15px; background: #111; 
        border-bottom: 1px solid #333; 
        font-size: 0.75rem; font-weight: bold; color: #888; letter-spacing: 1px;
        display: flex; justify-content: space-between;
    }
    .scroll-area { 
        flex: 1; overflow-y: auto; 
    }
    .scroll-area::-webkit-scrollbar { width: 6px; }
    .scroll-area::-webkit-scrollbar-thumb { background: #333; }

    /* === TABLE === */
    table { width: 100%; border-collapse: collapse; }
    thead { position: sticky; top: 0; background: #111; z-index: 5; }
    th { text-align: left; padding: 12px 15px; font-size: 0.7rem; color: #666; text-transform: uppercase; border-bottom: 1px solid #333; }
    td { padding: 10px 15px; border-bottom: 1px solid #222; font-size: 0.85rem; vertical-align: middle; }
    tr:hover { background: #0f0f0f; }

    /* === BADGES & BUTTONS === */
    .badge { 
        display: inline-block; padding: 3px 6px; font-size: 0.7rem; 
        font-weight: bold; border-radius: 2px; line-height: 1; 
        vertical-align: middle;
    }
    .badge-approved { background: rgba(0,255,0,0.1); color: #0f0; border: 1px solid #0f0; }
    .badge-pending { background: rgba(255,170,0,0.1); color: #fa0; border: 1px solid #fa0; }
    .badge-revoked { background: rgba(255,255,255,0.05); color: #666; border: 1px solid #444; text-decoration: line-through; }
    .badge-revoke_pending { 
        background: rgba(255,85,85,0.15); color: #f55; border: 1px solid #f55; 
        animation: pulse 1s infinite alternate; 
    }
    @keyframes pulse { from { opacity: 0.6; } to { opacity: 1; } }

    .btn-xs { padding: 4px 8px; font-size: 0.65rem; background: transparent; border: 1px solid #444; color: #ccc; cursor: pointer; margin-right: 5px; }
    .btn-xs:hover { border-color: #fff; color: #fff; }
    .btn-red { border-color: #522; color: #f55; }
    .btn-red:hover { background: #f55; color: #000; border-color: #f55; }
    .btn-green { border-color: #252; color: #0f0; }
    .btn-green:hover { background: #0f0; color: #000; border-color: #0f0; }

    /* === SIDEBAR === */
    .sidebar { 
        grid-column: 2 / 3; grid-row: 3 / 4; 
        display: flex; flex-direction: column; gap: 15px; 
        overflow: hidden; 
    }
    .side-box { 
        background: #0a0a0a; border: 1px solid #333; 
        display: flex; flex-direction: column; 
        overflow: hidden;
    }
    .side-item { padding: 8px 10px; border-bottom: 1px solid #222; font-size: 0.75rem; display: flex; justify-content: space-between; }
    .side-item:last-child { border: none; }

    /* === FOOTER === */
    .dash-footer { 
        grid-column: 1 / -1; 
        border-top: 1px solid #333; 
        display: flex; align-items: center; justify-content: space-between; 
        font-size: 0.7rem; color: #555;
    }
    .metrics span { margin-left: 15px; }
    .metrics b { color: #888; font-weight: normal; }

    /* === MODAL (FIXED) === */
    .modal-overlay {
        position: fixed; top: 0; left: 0; width: 100%; height: 100%;
        background: rgba(0,0,0,0.85);
        z-index: 9999;
        display: none; /* Hidden by default */
        align-items: center; justify-content: center;
        backdrop-filter: blur(5px);
    }
    .modal-box {
        background: #000; border: 1px solid #f55; 
        padding: 30px; width: 400px; 
        box-shadow: 0 0 50px rgba(255,0,0,0.2); text-align: center;
    }
    .danger-input {
        background: #111; border: 1px solid #444; color: #fff; 
        padding: 10px; width: 100%; text-align: center; margin: 15px 0;
        font-family: monospace; letter-spacing: 2px;
    }
    .danger-input:focus { border-color: #f55; outline: none; }

    /* === UTILS === */
    .text-mono { font-family: 'JetBrains Mono', monospace; }
    .text-accent { color: #00bcd4; }
</style>

<!-- !!! MODAL OUTSIDE GRID !!! -->
<div class="modal-overlay" id="deleteModal">
    <div class="modal-box">
        <h2 style="color:#f55; margin:0 0 10px 0; letter-spacing:2px;">⚠️ DANGER ZONE</h2>
        <p style="color:#aaa; font-size:0.8rem; line-height:1.5;">
            You are initiating a permanent deletion sequence.<br>This action cannot be undone.
        </p>
        <input type="password" id="delPassword" class="danger-input" placeholder="ACCESS KEY REQUIRED">
        <div style="display:flex; gap:10px;">
            <button class="btn" style="flex:1; padding:10px; background:transparent; border:1px solid #444; color:#aaa; cursor:pointer;" onclick="closeModal()">ABORT</button>
            <button class="btn" style="flex:1; padding:10px; background:#f55; border:1px solid #f55; color:#000; font-weight:bold; cursor:pointer;" onclick="confirmDelete()">CONFIRM</button>
        </div>
    </div>
</div>

<div class="dashboard-grid">
    <!-- 1. HEADER -->
    <div class="dash-header">
        <h1>AXIS <span>PKI</span> SYSTEM</h1>
        <div class="op-badge">
            OPERATOR: <span class="op-name"><?= htmlspecialchars($_SESSION['username']) ?></span><br>
            <a href="logout" style="color:#666; text-decoration:none;">[ TERMINATE SESSION ]</a>
        </div>
    </div>

    <!-- 2. STATS -->
    <div class="stat-row">
        <div class="stat-card c-blue">
            <div class="stat-label">Total Certificates</div>
            <div class="stat-value" id="val-total">-</div>
        </div>
        <div class="stat-card" id="card-pending"> <!-- c-warn added by JS -->
            <div class="stat-label">Pending Actions</div>
            <div class="stat-value" id="val-pending">-</div>
        </div>
        <div class="stat-card c-err">
            <div class="stat-label">Revoked Keys</div>
            <div class="stat-value" id="val-revoked">-</div>
        </div>
        <div class="stat-card c-good">
            <div class="stat-label">Active Uplinks</div>
            <div class="stat-value" id="val-sessions">-</div>
        </div>
    </div>

    <!-- 3. MAIN CONTENT -->
    <div class="main-panel">
        <div class="panel-head">
            <span>CERTIFICATE REGISTRY</span>
            <span id="keys-count">LOADING...</span>
        </div>
        <div class="scroll-area">
            <table>
                <thead>
                    <tr>
                        <th width="50">ID</th>
                        <th>Identity</th>
                        <th>Fingerprint</th>
                        <th>Status</th>
                        <th style="text-align:right">Controls</th>
                    </tr>
                </thead>
                <tbody id="keysTable"></tbody>
            </table>
        </div>
    </div>

    <!-- 4. SIDEBAR -->
    <div class="sidebar">
        <!-- Sessions -->
        <div class="side-box" style="flex:2">
            <div class="panel-head" style="color:#00bcd4">SESSION LOG</div>
            <div class="scroll-area" id="sessionList"></div>
        </div>
        <!-- Bans -->
        <div class="side-box" style="flex:1">
            <div class="panel-head" style="color:#f55">BLACKLIST</div>
            <div class="scroll-area" id="banList"></div>
        </div>
    </div>

    <!-- 5. FOOTER -->
    <div class="dash-footer">
        <div>SECURE INFRASTRUCTURE // AXIS OS</div>
        <div class="metrics">
            <span>LATENCY: <b id="met-lat">0ms</b></span>
            <span>LOAD: <b id="met-load">0.0</b></span>
            <span>MEM: <b id="met-ram">0MB</b></span>
        </div>
    </div>
</div>

<script>
// --- CORE LOGIC ---
let currentDeleteId = null;

function closeModal() {
    document.getElementById('deleteModal').style.display = 'none';
    document.getElementById('delPassword').value = '';
    currentDeleteId = null;
}
function askDelete(id) {
    currentDeleteId = id;
    document.getElementById('deleteModal').style.display = 'flex'; // FLEX for centering
    document.getElementById('delPassword').focus();
}
async function confirmDelete() {
    const pwd = document.getElementById('delPassword').value;
    if(!pwd) return alert("ACCESS KEY REQUIRED");
    await sendAction(currentDeleteId, 'delete', pwd);
    closeModal();
}

async function fetchAll() {
    try {
        const [statsRes, keysRes] = await Promise.all([
            fetch('api/admin_stats.php'),
            fetch('api/admin_list.php')
        ]);
        renderStats(await statsRes.json());
        renderKeys(await keysRes.json());
    } catch(e) { console.error(e); }
}

async function sendAction(id, action, password = null) {
    playSound('click');
    const payload = { key_id: id, action: action };
    if(password) payload.password = password;
    try {
        const res = await fetch('api/admin_action.php', {
            method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload)
        });
        const json = await res.json();
        if(json.status === 'success') fetchAll();
        else alert("CMD FAIL: " + json.message);
    } catch(e) { alert("NET ERROR"); }
}

async function ipAction(ip, action) {
    if(!confirm(action.toUpperCase() + " IP " + ip + "?")) return;
    await fetch('api/ip_action.php', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ip, action}) });
    fetchAll();
}

function renderStats(data) {
    // Stats
    document.getElementById('val-total').innerText = data.counts.total;
    document.getElementById('val-pending').innerText = data.counts.pending;
    document.getElementById('val-revoked').innerText = data.counts.revoked;
    document.getElementById('val-sessions').innerText = data.counts.sessions;
    
    // Color logic
    const pCard = document.getElementById('card-pending');
    if(data.counts.pending > 0) { pCard.classList.add('c-warn'); pCard.classList.remove('c-blue'); }
    else { pCard.classList.remove('c-warn'); pCard.classList.add('c-blue'); }

    // Metrics
    document.getElementById('met-lat').innerText = data.meta.latency + "ms";
    document.getElementById('met-load').innerText = data.meta.load;
    document.getElementById('met-ram').innerText = data.meta.ram;

    // Sessions
    let html = '';
    data.history.forEach(s => {
        const isMe = (s.ip_address === data.current_ip && !s.logout_time);
        const col = isMe ? '#0f0' : (s.logout_time ? '#666' : '#fff');
        const banBtn = isMe ? '' : `<span onclick="ipAction('${s.ip_address}','ban')" style="cursor:pointer; color:#f55; margin-left:5px;">×</span>`;
        html += `<div class="side-item">
            <div>
                <div style="font-family:monospace; color:${col}">${s.ip_address} ${banBtn}</div>
                <div style="color:#444; font-size:0.6rem;">${s.username}</div>
            </div>
            <div style="text-align:right; font-size:0.65rem; color:#555;">${s.logout_time ? 'CLOSED' : 'ACTIVE'}<br>${s.login_time.split(' ')[1]}</div>
        </div>`;
    });
    document.getElementById('sessionList').innerHTML = html;

    // Bans
    let bHtml = '';
    data.bans.forEach(b => {
        bHtml += `<div class="side-item">
            <span style="color:#f55; font-family:monospace;">${b.ip_address}</span>
            <span onclick="ipAction('${b.ip_address}','unban')" style="cursor:pointer; color:#0f0;">UNBAN</span>
        </div>`;
    });
    document.getElementById('banList').innerHTML = bHtml || '<div style="padding:20px; text-align:center; color:#333;">NO THREATS</div>';
}

function renderKeys(keys) {
    document.getElementById('keys-count').innerText = keys.length + " ITEMS";
    let html = '';
    if(keys.length === 0) html = '<tr><td colspan="5" style="text-align:center; padding:30px; color:#444">REGISTRY EMPTY</td></tr>';
    
    keys.forEach(k => {
        let status = `<span class="badge" style="color:#888; border:1px solid #444;">${k.status.toUpperCase()}</span>`;
        let btns = '';
        const del = `<button class="btn-xs" style="color:#666; border:none;" onclick="askDelete(${k.id})" title="Purge Record">🗑</button>`;

        if(k.status === 'revoke_pending') {
            status = `<span class="badge badge-revoke_pending">REVOKE REQ</span>`;
            btns = `<button onclick="sendAction(${k.id}, 'revoke')" class="btn-xs btn-red">CONFIRM</button> <button onclick="sendAction(${k.id}, 'approve')" class="btn-xs">CANCEL</button>`;
        } else if (k.status === 'pending') {
            status = `<span class="badge badge-pending">PENDING</span>`;
            btns = `<button onclick="sendAction(${k.id}, 'approve')" class="btn-xs btn-green">APPROVE</button> <button onclick="sendAction(${k.id}, 'reject')" class="btn-xs btn-red">REJECT</button>`;
        } else if (k.status === 'approved') {
            status = `<span class="badge badge-approved">ACTIVE</span>`;
            btns = `<button onclick="sendAction(${k.id}, 'revoke')" class="btn-xs btn-red">REVOKE</button>`;
        } else if (k.status === 'revoked') {
            status = `<span class="badge badge-revoked">REVOKED</span>`;
            btns = `<button onclick="sendAction(${k.id}, 'approve')" class="btn-xs">RESTORE</button>`;
        }

        html += `<tr>
            <td style="color:#444; font-family:monospace;">${k.id}</td>
            <td>
                <div style="font-weight:bold; color:#ccc;">${escapeHtml(k.username)}</div>
                <div style="font-size:0.65rem; color:#555;">${k.created_at}</div>
            </td>
            <td>
                <div style="font-family:monospace; color:#00bcd4; font-size:0.8rem;">${k.fingerprint.substring(0,12)}...</div>
                <div style="font-size:0.65rem; color:#555;">${k.key_type}</div>
            </td>
            <td>${status}</td>
            <td style="text-align:right;">${btns}${del}</td>
        </tr>`;
    });
    
    // Simple update
    const el = document.getElementById('keysTable');
    if(el.innerHTML.length !== html.length) el.innerHTML = html;
}

function escapeHtml(t) { if(!t)return t; return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

fetchAll();
setInterval(fetchAll, 2000);
</script>
<?php renderFooter(); ?>