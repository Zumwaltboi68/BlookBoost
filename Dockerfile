FROM python:3.11-slim

LABEL maintainer="Blooket" description="Blooket Host Bot" version="3.0"

ENV PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive DISPLAY=:99 PORT=10000 RENDER=true

RUN apt-get update && apt-get install -y --no-install-recommends chromium chromium-driver xvfb x11vnc novnc websockify python3-numpy fluxbox curl ca-certificates fonts-liberation supervisor && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.0 flask-cors==4.0.0 flask-socketio==5.3.5 selenium==4.16.0 pillow==10.1.0 eventlet==0.33.3

COPY --chmod=755 <<'PYCODE' /app/app.py
from flask import Flask, render_template_string, request, jsonify
from flask_socketio import SocketIO
from flask_cors import CORS
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
import threading, time, os, base64
from io import BytesIO
from PIL import Image

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret'
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

browser = None
lock = threading.Lock()
running = False

HTML = """<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Blooket Host Bot</title><script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:linear-gradient(135deg,#1a0000,#330000 50%,#000);min-height:100vh;color:#fff;padding:20px}.container{max-width:1800px;margin:0 auto}.header{background:linear-gradient(135deg,#f00,#c00);padding:20px;border-radius:15px;box-shadow:0 10px 40px rgba(255,0,0,.3);margin-bottom:20px;text-align:center;border:2px solid #f33}h1{font-size:2.2em;font-weight:800;text-shadow:0 0 20px rgba(255,0,0,.8);letter-spacing:2px;animation:glow 2s ease-in-out infinite}@keyframes glow{0%,100%{text-shadow:0 0 10px rgba(255,0,0,.5)}50%{text-shadow:0 0 25px #f00}}.grid{display:grid;grid-template-columns:380px 1fr;gap:20px}.card{background:rgba(20,0,0,.85);border-radius:15px;padding:25px;box-shadow:0 8px 32px rgba(255,0,0,.2);border:1px solid rgba(255,0,0,.3)}h2{color:#f33;margin-bottom:20px;font-size:1.4em;font-weight:700}input{width:100%;padding:12px;background:rgba(0,0,0,.6);border:2px solid #f00;border-radius:10px;color:#fff;font-size:14px;margin-bottom:15px}input:focus{outline:none;border-color:#f33;box-shadow:0 0 20px rgba(255,0,0,.4)}.btn{width:100%;background:linear-gradient(135deg,#f00,#c00);color:#fff;border:none;padding:13px;border-radius:10px;font-size:15px;font-weight:700;cursor:pointer;text-transform:uppercase;letter-spacing:1.5px;box-shadow:0 5px 20px rgba(255,0,0,.4);margin-bottom:10px}.btn:hover:not(:disabled){background:linear-gradient(135deg,#f33,#f00);transform:translateY(-2px)}.btn:disabled{background:#333;opacity:.5;cursor:not-allowed}.btn.sec{background:linear-gradient(135deg,#900,#600)}.status{padding:12px;border-radius:10px;margin-bottom:15px;display:none;font-weight:600;border:2px solid}.status.success{background:rgba(0,100,0,.2);color:#0f0;border-color:#0f0}.status.error{background:rgba(100,0,0,.3);color:#f66;border-color:#f00}.status.info{background:rgba(255,0,0,.2);color:#f99;border-color:#f33}.preview{background:rgba(0,0,0,.8);border-radius:15px;padding:20px;border:2px solid #f00;height:calc(100vh - 150px);display:flex;flex-direction:column}.preview-hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:15px;padding-bottom:12px;border-bottom:2px solid rgba(255,0,0,.3)}.preview-title{color:#f33;font-size:1.4em;font-weight:700}.status-ind{display:flex;align-items:center;gap:10px;background:rgba(0,0,0,.5);padding:8px 15px;border-radius:20px;border:1px solid rgba(255,0,0,.3)}.dot{width:12px;height:12px;border-radius:50%;background:#f00;animation:pulse 2s infinite}.dot.active{background:#0f0;box-shadow:0 0 10px #0f0}@keyframes pulse{0%,100%{opacity:1}50%{opacity:.6}}.screen{flex:1;background:#000;border-radius:12px;overflow:hidden;display:flex;align-items:center;justify-content:center;border:3px solid rgba(255,0,0,.4)}.screen img{max-width:100%;max-height:100%;object-fit:contain}.placeholder{color:#666;font-size:1.3em;text-align:center;line-height:1.8}.logs{background:rgba(0,0,0,.8);border-radius:10px;padding:15px;max-height:250px;overflow-y:auto;font-family:'Courier New',monospace;font-size:.82em;border:2px solid rgba(255,0,0,.3);margin-top:15px}.log{padding:6px 10px;margin-bottom:5px;border-left:3px solid #f00;background:rgba(255,0,0,.05);border-radius:3px}.log.success{border-color:#0f0;color:#0f0}.log.error{border-color:#f00;color:#f66}.log.info{border-color:#f99;color:#f99}.info-box{background:rgba(255,0,0,.1);border-left:4px solid #f00;padding:12px;margin-bottom:15px;border-radius:5px;font-size:.88em}@media(max-width:1400px){.grid{grid-template-columns:1fr}.preview{height:600px}}</style></head><body><div class="container"><div class="header"><h1>🎮 BLOOKET HOST BOT PRO</h1></div><div class="grid"><div class="card"><h2>⚙️ Control</h2><div class="info-box"><strong>Quick:</strong> Paste URL → HOST → AUTO-CLICK</div><div id="status" class="status"></div><input type="text" id="url" placeholder="https://goldquest.blooket.com/gold/host/landing?gid=..."><button class="btn" id="host" onclick="host()">🚀 HOST GAME</button><button class="btn sec" id="click" onclick="click()" disabled>👆 AUTO-CLICK HOST</button><button class="btn sec" id="stop" onclick="stop()" disabled>⛔ STOP</button><h3 style="color:#f33;margin:20px 0 10px;font-size:1.1em">📋 Log</h3><div class="logs" id="logs"><div class="log info">[System] Ready</div></div></div><div class="card"><div class="preview"><div class="preview-hdr"><div class="preview-title">📺 Live</div><div class="status-ind"><div class="dot" id="dot"></div><span id="st">Idle</span></div></div><div class="screen" id="screen"><div class="placeholder">🖥️ Browser view<br><small>Updates every 2s</small></div></div></div></div></div></div><script>const s=io();s.on('connect',()=>log('[WS] OK','success'));s.on('screenshot',d=>document.getElementById('screen').innerHTML='<img src="data:image/png;base64,'+d.image+'">');s.on('log',d=>log(d.message,d.type));s.on('status',d=>{const dot=document.getElementById('dot'),st=document.getElementById('st'),hb=document.getElementById('host'),cb=document.getElementById('click'),sb=document.getElementById('stop');if(d.active){dot.classList.add('active');st.textContent='Active';hb.disabled=true;cb.disabled=false;sb.disabled=false}else{dot.classList.remove('active');st.textContent='Idle';hb.disabled=false;cb.disabled=true;sb.disabled=true}});function log(m,t='info'){const c=document.getElementById('logs'),e=document.createElement('div');e.className='log '+t;e.textContent='['+new Date().toLocaleTimeString()+'] '+m;c.appendChild(e);c.scrollTop=c.scrollHeight;if(c.children.length>100)c.removeChild(c.firstChild)}function show(m,t){const st=document.getElementById('status');st.textContent=m;st.className='status '+t;st.style.display='block';setTimeout(()=>st.style.display='none',5000)}async function host(){const u=document.getElementById('url').value.trim();if(!u||!u.includes('blooket.com')){show('Invalid URL','error');return}show('Starting...','info');try{const r=await fetch('/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:u})});const d=await r.json();if(r.ok)show('Started!','success');else show(d.error,'error')}catch(e){show(e.message,'error')}}async function click(){show('Clicking...','info');try{const r=await fetch('/click',{method:'POST'});const d=await r.json();if(r.ok)show(d.message,'success');else show(d.error,'error')}catch(e){show(e.message,'error')}}async function stop(){try{await fetch('/stop',{method:'POST'});show('Stopped','success');document.getElementById('screen').innerHTML='<div class="placeholder">Stopped</div>'}catch(e){show(e.message,'error')}}fetch('/health').then(r=>r.json()).then(()=>log('[Health] OK','success'))</script></body></html>"""

def driver():
    o = Options()
    o.add_argument('--no-sandbox')
    o.add_argument('--disable-dev-shm-usage')
    o.add_argument('--disable-gpu')
    o.add_argument('--window-size=1280,800')
    o.add_argument('--disable-blink-features=AutomationControlled')
    o.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
    o.add_experimental_option("excludeSwitches", ["enable-automation"])
    o.binary_location = '/usr/bin/chromium'
    o.add_argument('--display=' + os.environ.get('DISPLAY',':99'))
    d = webdriver.Chrome(service=Service('/usr/bin/chromedriver'), options=o)
    d.set_page_load_timeout(60)
    d.execute_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
    return d

def screenshot_loop():
    global browser, running
    while running:
        try:
            if browser:
                with lock:
                    ss = browser.get_screenshot_as_png()
                img = Image.open(BytesIO(ss))
                img.thumbnail((1400,900), Image.Resampling.LANCZOS)
                buf = BytesIO()
                img.save(buf, format="PNG", optimize=True, quality=85)
                socketio.emit('screenshot', {'image': base64.b64encode(buf.getvalue()).decode()})
            time.sleep(2)
        except:
            time.sleep(2)

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/health')
def health():
    return jsonify({'status':'ok','browser':browser is not None})

@app.route('/start', methods=['POST'])
def start():
    global browser, running
    url = request.json.get('url','')
    if not url:
        return jsonify({'error':'URL required'}), 400
    try:
        with lock:
            if browser:
                try: browser.quit()
                except: pass
            socketio.emit('log', {'message':'[Browser] Starting...','type':'info'})
            browser = driver()
            socketio.emit('log', {'message':'[Nav] Opening...','type':'info'})
            browser.get(url)
            time.sleep(3)
            socketio.emit('log', {'message':'[OK] Loaded','type':'success'})
            socketio.emit('status', {'active':True})
            if not running:
                running = True
                threading.Thread(target=screenshot_loop, daemon=True).start()
        return jsonify({'success':True})
    except Exception as e:
        socketio.emit('log', {'message':'[Err] ' + str(e),'type':'error'})
        return jsonify({'error':str(e)}), 500

@app.route('/click', methods=['POST'])
def click():
    global browser
    if not browser:
        return jsonify({'error':'Browser not started'}), 400
    try:
        with lock:
            socketio.emit('log', {'message':'[Search] Finding Host Now...','type':'info'})
            found = False
            for sel in ["//button[contains(text(), 'Host Now')]","//button[contains(text(), 'HOST NOW')]","//button[contains(text(), 'Host now')]","//button[contains(., 'Host')]","button"]:
                try:
                    elems = browser.find_elements(By.XPATH, sel) if sel.startswith('//') else browser.find_elements(By.CSS_SELECTOR, sel)
                    for e in elems:
                        if e.is_displayed():
                            browser.execute_script("arguments[0].scrollIntoView({block:'center'});", e)
                            time.sleep(0.5)
                            try: e.click()
                            except: browser.execute_script("arguments[0].click();", e)
                            found = True
                            socketio.emit('log', {'message':'[Click] Success!','type':'success'})
                            break
                    if found: break
                except: continue
            if not found:
                socketio.emit('log', {'message':'[Warn] Not found','type':'error'})
                return jsonify({'error':'Button not found'}), 404
            time.sleep(2)
            socketio.emit('log', {'message':'[Info] Starting...','type':'info'})
        return jsonify({'success':True,'message':'Clicked!'})
    except Exception as e:
        socketio.emit('log', {'message':'[Err] ' + str(e),'type':'error'})
        return jsonify({'error':str(e)}), 500

@app.route('/stop', methods=['POST'])
def stop():
    global browser, running
    try:
        running = False
        with lock:
            if browser:
                browser.quit()
                browser = None
        socketio.emit('status', {'active':False})
        socketio.emit('log', {'message':'[Stop] Closed','type':'info'})
        return jsonify({'success':True})
    except Exception as e:
        return jsonify({'error':str(e)}), 500

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 10000))
    print('Blooket Host Bot - http://0.0.0.0:' + str(port))
    socketio.run(app, host='0.0.0.0', port=port, debug=False, allow_unsafe_werkzeug=True)
PYCODE

COPY --chmod=755 <<'SUPERVISOR' /etc/supervisor/conf.d/services.conf
[supervisord]
nodaemon=true
user=root
[program:xvfb]
command=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset
autostart=true
autorestart=true
priority=10
[program:x11vnc]
command=/usr/bin/x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever -shared
autostart=true
autorestart=true
priority=20
[program:novnc]
command=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080
autostart=true
autorestart=true
priority=30
[program:fluxbox]
command=/usr/bin/fluxbox -display :99
autostart=true
autorestart=true
priority=40
environment=DISPLAY=":99"
[program:app]
command=python /app/app.py
directory=/app
autostart=true
autorestart=true
priority=50
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
environment=DISPLAY=":99",PORT="%(ENV_PORT)s"
SUPERVISOR

COPY --chmod=755 <<'BASH' /start.sh
#!/bin/bash
set -e
[ -f "/usr/bin/chromium" ] && echo "Chromium OK" || { echo "No Chromium"; exit 1; }
export DISPLAY=:99
export PORT=${PORT:-10000}
echo "Starting on port $PORT"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
BASH

RUN mkdir -p /var/log/supervisor

EXPOSE 10000 5900 6080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD curl -f http://localhost:${PORT:-10000}/health || exit 1

WORKDIR /app

ENTRYPOINT ["/start.sh"]
