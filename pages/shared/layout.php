<?php
function renderHeader($title = "Axis OS") {
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($title) ?></title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: #050505;
            --surface-color: #0a0a0a;
            --border-color: #222;
            --text-primary: #e0e0e0;
            --text-secondary: #888;
            --accent-color: #00bcd4;
            --accent-glow: rgba(0, 188, 212, 0.4);
            --accent-dim: rgba(0, 188, 212, 0.1);
            --success-color: #55ff55;
            --error-color: #ff5555;
            --font-mono: 'JetBrains Mono', monospace;
            --font-sans: 'Inter', sans-serif;
            --card-gradient: linear-gradient(145deg, var(--surface-color), var(--bg-color));
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background-color: var(--bg-color); color: var(--text-primary); font-family: var(--font-sans); min-height: 100vh; display: flex; flex-direction: column; overflow-x: hidden; }
        
        /* Canvas BG */
        #bgCanvas { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; z-index: -1; pointer-events: none; opacity: 0.6; }

        /* UI Elements */
        .container { max-width: 800px; margin: 0 auto; padding: 2rem; width: 100%; position: relative; z-index: 2; flex: 1; display: flex; flex-direction: column; justify-content: center; }
        
        h1, h2, h3 { font-family: var(--font-mono); color: var(--text-primary); margin-bottom: 1rem; text-transform: uppercase; letter-spacing: -1px; }
        h1 span { color: var(--accent-color); }
        
        .card { background: var(--card-gradient); border: 1px solid var(--border-color); padding: 2rem; border-radius: 4px; position: relative; overflow: hidden; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        .card::before { content: ''; position: absolute; top: 0; left: 0; width: 100%; height: 2px; background: var(--accent-color); }

        .btn { display: inline-flex; align-items: center; justify-content: center; padding: 0.8rem 1.5rem; background: var(--accent-dim); color: var(--accent-color); border: 1px solid var(--accent-color); font-family: var(--font-mono); cursor: pointer; transition: all 0.2s; text-decoration: none; font-size: 0.9rem; margin-top: 1rem; }
        .btn:hover { background: var(--accent-color); color: #000; box-shadow: 0 0 15px var(--accent-glow); }
        .btn-danger { border-color: var(--error-color); color: var(--error-color); background: rgba(255, 85, 85, 0.1); }
        .btn-danger:hover { background: var(--error-color); color: #000; box-shadow: 0 0 15px rgba(255, 85, 85, 0.4); }

        input { width: 100%; background: #000; border: 1px solid var(--border-color); color: var(--text-primary); padding: 10px; font-family: var(--font-mono); margin-bottom: 15px; outline: none; transition: border-color 0.3s; }
        input:focus { border-color: var(--accent-color); }
        label { display: block; margin-bottom: 5px; color: var(--text-secondary); font-size: 0.8rem; font-family: var(--font-mono); text-transform: uppercase; }

        .token-box { background: #000; border: 1px dashed var(--border-color); padding: 15px; font-family: var(--font-mono); word-break: break-all; color: var(--success-color); cursor: pointer; transition: all 0.2s; position: relative; }
        .token-box:hover { border-color: var(--success-color); background: rgba(85, 255, 85, 0.05); }
        .token-box::after { content: 'CLICK TO COPY'; position: absolute; top: -8px; right: 10px; background: var(--bg-color); color: var(--text-secondary); font-size: 0.6rem; padding: 0 5px; }

        .alert { padding: 10px 15px; margin-bottom: 20px; border-left: 3px solid; font-family: var(--font-mono); font-size: 0.9rem; }
        .alert-error { border-color: var(--error-color); background: rgba(255, 85, 85, 0.1); color: var(--error-color); }
        .alert-success { border-color: var(--success-color); background: rgba(85, 255, 85, 0.1); color: var(--success-color); }

        table { width: 100%; border-collapse: collapse; margin-top: 1rem; font-size: 0.9rem; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid var(--border-color); }
        th { color: var(--text-secondary); font-family: var(--font-mono); text-transform: uppercase; font-size: 0.75rem; }
        tr:hover td { background: rgba(255,255,255,0.02); }
        
        .badge { padding: 2px 6px; border-radius: 2px; font-size: 0.7rem; text-transform: uppercase; font-family: var(--font-mono); }
        .badge-approved { background: rgba(85, 255, 85, 0.15); color: var(--success-color); border: 1px solid var(--success-color); }
        .badge-revoked { background: rgba(255, 85, 85, 0.15); color: var(--error-color); border: 1px solid var(--error-color); }
        .badge-pending { background: rgba(255, 174, 0, 0.15); color: #ffae00; border: 1px solid #ffae00; }

        /* Toast */
        .toast { position: fixed; bottom: 30px; right: 30px; background: var(--surface-color); border-left: 3px solid var(--accent-color); color: var(--text-primary); padding: 1rem 1.5rem; font-family: var(--font-mono); z-index: 200; transform: translateY(100px); opacity: 0; transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1); pointer-events: none; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        .toast.show { transform: translateY(0); opacity: 1; }
    </style>
</head>
<body>
    <canvas id="bgCanvas"></canvas>
    <div class="toast" id="toast">Notification</div>
<?php
}

function renderFooter() {
?>
    <script>
        // Grid Animation
        const canvas = document.getElementById('bgCanvas');
        const ctx = canvas.getContext('2d');
        let width, height;
        
        function resize() { width = canvas.width = window.innerWidth; height = canvas.height = window.innerHeight; draw(); }
        window.addEventListener('resize', resize);
        
        function draw() {
            ctx.clearRect(0,0,width,height);
            ctx.strokeStyle = '#222';
            ctx.lineWidth = 1;
            const step = 40;
            
            for(let x=0; x<width; x+=step) { ctx.beginPath(); ctx.moveTo(x,0); ctx.lineTo(x,height); ctx.stroke(); }
            for(let y=0; y<height; y+=step) { ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(width,y); ctx.stroke(); }
        }
        resize();

        // Sound & Toast Utils
        const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        function playSound(type) {
            if (audioCtx.state === 'suspended') audioCtx.resume();
            const osc = audioCtx.createOscillator();
            const gain = audioCtx.createGain();
            const now = audioCtx.currentTime;
            osc.connect(gain); gain.connect(audioCtx.destination);
            
            if (type === 'success') {
                osc.type = 'sine'; osc.frequency.setValueAtTime(600, now);
                gain.gain.setValueAtTime(0.1, now); gain.gain.exponentialRampToValueAtTime(0.01, now + 0.2);
                osc.start(now); osc.stop(now + 0.2);
            } else if (type === 'click') {
                osc.type = 'square'; osc.frequency.setValueAtTime(200, now);
                gain.gain.setValueAtTime(0.05, now); gain.gain.linearRampToValueAtTime(0, now + 0.05);
                osc.start(now); osc.stop(now + 0.05);
            }
        }

        function showToast(msg) {
            const t = document.getElementById('toast');
            t.innerText = msg;
            t.classList.add('show');
            playSound('success');
            setTimeout(() => t.classList.remove('show'), 3000);
        }

        function copyToClipboard(text) {
            navigator.clipboard.writeText(text).then(() => showToast('COPIED TO CLIPBOARD'));
        }
    </script>
</body>
</html>
<?php
}
?>