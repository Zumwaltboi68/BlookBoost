FROM python:3.11-slim

LABEL maintainer="Blooket" description="Blooket Host Bot" version="3.0"

ENV PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive DISPLAY=:99 PORT=10000 RENDER=true

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium chromium-driver xvfb curl ca-certificates fonts-liberation supervisor \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.0 flask-cors==4.0.0 flask-socketio==5.3.5 \
    selenium==4.16.0 pillow==10.1.0 eventlet==0.33.3

COPY --chmod=755 <<'PYCODE' /app/app.py
from flask import Flask, render_template_string, request, jsonify
from flask_socketio import SocketIO
from flask_cors import CORS
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoSuchElementException
import threading, time, os, base64, gc
from io import BytesIO
from PIL import Image

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret'
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet', ping_timeout=60, ping_interval=25)

workers = {}  # {worker_id: {'browser': browser, 'running': bool, 'login_mode': bool, 'thread': thread}}
worker_lock = threading.Lock()
next_worker_id = 1

HTML = """<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Blooket Host Bot</title><script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:linear-gradient(135deg,#1a0000,#330000 50%,#000);min-height:100vh;color:#fff;padding:20px}.container{max-width:1900px;margin:0 auto}.header{background:linear-gradient(135deg,#f00,#c00);padding:20px;border-radius:15px;box-shadow:0 10px 40px rgba(255,0,0,.3);margin-bottom:20px;text-align:center;border:2px solid #f33}h1{font-size:2.2em;font-weight:800;text-shadow:0 0 20px rgba(255,0,0,.8);letter-spacing:2px;animation:glow 2s ease-in-out infinite}@keyframes glow{0%,100%{text-shadow:0 0 10px rgba(255,0,0,.5)}50%{text-shadow:0 0 25px #f00}}.grid{display:grid;grid-template-columns:400px 1fr;gap:20px}.card{background:rgba(20,0,0,.85);border-radius:15px;padding:25px;box-shadow:0 8px 32px rgba(255,0,0,.2);border:1px solid rgba(255,0,0,.3)}h2{color:#f33;margin-bottom:20px;font-size:1.4em;font-weight:700}h3{color:#f66;margin:15px 0 10px;font-size:1.1em}input,select{width:100%;padding:12px;background:rgba(0,0,0,.6);border:2px solid #f00;border-radius:10px;color:#fff;font-size:14px;margin-bottom:15px}input:focus,select:focus{outline:none;border-color:#f33;box-shadow:0 0 20px rgba(255,0,0,.4)}select option{background:#1a0000;color:#fff}.btn{width:100%;background:linear-gradient(135deg,#f00,#c00);color:#fff;border:none;padding:13px;border-radius:10px;font-size:15px;font-weight:700;cursor:pointer;text-transform:uppercase;letter-spacing:1.5px;box-shadow:0 5px 20px rgba(255,0,0,.4);margin-bottom:10px;transition:all .3s}.btn:disabled{background:#333;opacity:.5;cursor:not-allowed}.btn:hover:not(:disabled){background:linear-gradient(135deg,#f33,#f00);transform:translateY(-2px)}.btn.sec{background:linear-gradient(135deg,#900,#600)}.btn.login{background:linear-gradient(135deg,#0a0,#070)}.btn.login:hover:not(:disabled){background:linear-gradient(135deg,#0c0,#0a0)}.btn.danger{background:linear-gradient(135deg,#c00,#900)}.btn.danger:hover:not(:disabled){background:linear-gradient(135deg,#f00,#c00)}.status{padding:12px;border-radius:10px;margin-bottom:15px;display:none;font-weight:600;border:2px solid}.status.success{background:rgba(0,100,0,.2);color:#0f0;border-color:#0f0}.status.error{background:rgba(100,0,0,.3);color:#f66;border-color:#f00}.status.info{background:rgba(255,0,0,.2);color:#f99;border-color:#f33}.worker-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:15px;margin-bottom:20px}.worker-card{background:rgba(0,0,0,.6);border:2px solid #f00;border-radius:10px;padding:15px}.worker-card.active{border-color:#0f0}.worker-card.login{border-color:#ff0}.worker-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}.worker-id{color:#f33;font-weight:700;font-size:1.1em}.worker-status{padding:4px 10px;border-radius:15px;font-size:.85em;font-weight:600}.worker-status.idle{background:rgba(100,0,0,.3);color:#f66}.worker-status.login{background:rgba(100,100,0,.3);color:#ff0}.worker-status.active{background:rgba(0,100,0,.3);color:#0f0}.worker-preview{background:#000;border-radius:8px;overflow:hidden;margin:10px 0;height:150px;display:flex;align-items:center;justify-content:center;border:2px solid rgba(255,0,0,.3)}.worker-preview img{max-width:100%;max-height:100%;object-fit:contain}.worker-preview .placeholder{color:#666;font-size:.9em}.worker-controls{display:grid;grid-template-columns:1fr 1fr;gap:8px}.worker-btn{padding:8px;font-size:.85em;border-radius:8px;border:none;cursor:pointer;font-weight:600;transition:all .3s}.worker-btn.login{background:#0a0;color:#fff}.worker-btn.host{background:#f00;color:#fff}.worker-btn.click{background:#900;color:#fff}.worker-btn.stop{background:#600;color:#fff}.worker-btn:disabled{background:#333;opacity:.5;cursor:not-allowed}.worker-btn:hover:not(:disabled){transform:translateY(-2px);opacity:.9}.worker-input{width:100%;padding:8px;background:rgba(0,0,0,.6);border:1px solid #f00;border-radius:6px;color:#fff;font-size:.85em;margin:8px 0}.info-box{background:rgba(255,0,0,.1);border-left:4px solid #f00;padding:12px;margin-bottom:15px;border-radius:5px;font-size:.88em}.login-box{background:rgba(0,100,0,.1);border-left:4px solid #0a0;padding:12px;margin-bottom:15px;border-radius:5px;font-size:.88em;color:#0f0}.logs{background:rgba(0,0,0,.8);border-radius:10px;padding:15px;max-height:400px;overflow-y:auto;font-family:'Courier New',monospace;font-size:.82em;border:2px solid rgba(255,0,0,.3)}.log{padding:6px 10px;margin-bottom:5px;border-left:3px solid #f00;background:rgba(255,0,0,.05);border-radius:3px}.log.success{border-color:#0f0;color:#0f0}.log.error{border-color:#f00;color:#f66}.log.info{border-color:#f99;color:#f99}.log.worker{opacity:.8}@media(max-width:1400px){.grid{grid-template-columns:1fr}.worker-grid{grid-template-columns:repeat(auto-fill,minmax(250px,1fr))}}</style></head><body><div class="container"><div class="header"><h1>🎮 BLOOKET HOST BOT PRO - MULTI-WORKER</h1></div><div class="grid"><div class="card"><h2>⚙️ Control Center</h2><div class="info-box"><strong>Multi-Worker Mode:</strong><br>1. Set number of workers<br>2. Login each worker<br>3. Host games on each worker</div><div id="status" class="status"></div><label style="color:#f66;font-weight:600;display:block;margin-bottom:8px">Number of Workers (Bots):</label><select id="workerCount" onchange="updateWorkerCount()"><option value="1">1 Worker</option><option value="2">2 Workers</option><option value="3">3 Workers</option><option value="4">4 Workers</option><option value="5">5 Workers</option><option value="6">6 Workers</option><option value="8">8 Workers</option><option value="10">10 Workers</option></select><div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:15px"><button class="btn login" onclick="loginAll()">🔑 LOGIN ALL</button><button class="btn danger" onclick="stopAll()">⛔ STOP ALL</button></div><h3>📋 Global Log</h3><div class="logs" id="logs"><div class="log info">[System] Ready - Set workers & login</div></div></div><div class="card"><h2>👥 Workers</h2><div id="workers" class="worker-grid"></div></div></div></div><script>const s=io();let workerData={};s.on('connect',()=>log('[System] WebSocket connected','success'));s.on('workers',data=>{workerData=data;renderWorkers()});s.on('screenshot',data=>{const img=document.querySelector(`#worker-${data.worker_id} .worker-preview`);if(img)img.innerHTML='<img src="data:image/png;base64,'+data.image+'">'});s.on('log',d=>{log(`[W${d.worker_id||'?'}] ${d.message}`,d.type,d.worker_id)});function renderWorkers(){const container=document.getElementById('workers');container.innerHTML='';Object.keys(workerData).sort((a,b)=>parseInt(a)-parseInt(b)).forEach(id=>{const w=workerData[id];const status=w.login_mode?'login':(w.running?'active':'idle');const statusText=w.login_mode?'Login Mode':(w.running?'Active':'Idle');container.innerHTML+=`<div class="worker-card ${status}" id="worker-${id}"><div class="worker-header"><div class="worker-id">Worker #${id}</div><div class="worker-status ${status}">${statusText}</div></div><div class="worker-preview"><div class="placeholder">No preview</div></div><input type="text" class="worker-input" id="url-${id}" placeholder="Game URL..." ${!w.login_mode?'disabled':''}><div class="worker-controls"><button class="worker-btn login" onclick="loginWorker(${id})" ${w.browser?'disabled':''}>Login</button><button class="worker-btn host" onclick="hostWorker(${id})" ${!w.login_mode||!w.browser?'disabled':''}>Host</button><button class="worker-btn click" onclick="clickWorker(${id})" ${!w.running?'disabled':''}>Click</button><button class="worker-btn stop" onclick="stopWorker(${id})" ${!w.browser?'disabled':''}>Stop</button></div></div>`})}async function updateWorkerCount(){const count=parseInt(document.getElementById('workerCount').value);show('Updating workers...','info');try{const r=await fetch('/set_workers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({count})});const d=await r.json();if(r.ok){show(`Set to ${count} workers`,'success');s.emit('get_workers')}else show(d.error,'error')}catch(e){show(e.message,'error')}}async function loginAll(){show('Logging in all workers...','info');try{const r=await fetch('/login_all',{method:'POST'});const d=await r.json();if(r.ok)show('All workers logging in','success');else show(d.error,'error')}catch(e){show(e.message,'error')}}async function stopAll(){if(!confirm('Stop all workers?'))return;show('Stopping all workers...','info');try{const r=await fetch('/stop_all',{method:'POST'});const d=await r.json();if(r.ok)show('All workers stopped','success');else show(d.error,'error')}catch(e){show(e.message,'error')}}async function loginWorker(id){try{const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({worker_id:id})});const d=await r.json();if(!r.ok)show(d.error,'error')}catch(e){show(e.message,'error')}}async function hostWorker(id){const url=document.getElementById(`url-${id}`).value.trim();if(!url||!url.includes('blooket.com')){show('Invalid URL for worker '+id,'error');return}try{const r=await fetch('/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({worker_id:id,url})});const d=await r.json();if(!r.ok)show(d.error,'error')}catch(e){show(e.message,'error')}}async function clickWorker(id){try{const r=await fetch('/click',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({worker_id:id})});const d=await r.json();if(!r.ok)show(d.error,'error')}catch(e){show(e.message,'error')}}async function stopWorker(id){try{const r=await fetch('/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({worker_id:id})});const d=await r.json();if(!r.ok)show(d.error,'error')}catch(e){show(e.message,'error')}}function log(m,t='info',wid=null){const c=document.getElementById('logs'),e=document.createElement('div');e.className='log '+t+(wid?' worker':'');e.textContent='['+new Date().toLocaleTimeString()+'] '+m;c.appendChild(e);c.scrollTop=c.scrollHeight;if(c.children.length>150)c.removeChild(c.firstChild)}function show(m,t){const st=document.getElementById('status');st.textContent=m;st.className='status '+t;st.style.display='block';setTimeout(()=>st.style.display='none',5000)}s.on('connect',()=>{s.emit('get_workers')});setInterval(()=>s.emit('get_workers'),3000);fetch('/health').then(r=>r.json()).then(()=>log('[System] Health check OK','success'))</script></body></html>"""

def driver():
    o = Options()
    o.add_argument('--no-sandbox')
    o.add_argument('--disable-dev-shm-usage')
    o.add_argument('--disable-gpu')
    o.add_argument('--disable-software-rasterizer')
    o.add_argument('--window-size=1024,600')
    o.add_argument('--disable-blink-features=AutomationControlled')
    o.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
    o.add_experimental_option("excludeSwitches", ["enable-automation"])
    o.add_experimental_option('useAutomationExtension', False)
    o.add_argument('--disable-extensions')
    o.add_argument('--disable-images')
    o.add_argument('--blink-settings=imagesEnabled=false')
    o.add_argument('--disk-cache-size=1')
    o.add_argument('--media-cache-size=1')
    o.add_argument('--aggressive-cache-discard')
    o.add_argument('--disable-application-cache')
    o.add_argument('--disable-background-networking')
    o.add_argument('--disable-default-apps')
    o.add_argument('--disable-sync')
    o.binary_location = '/usr/bin/chromium'
    o.add_argument('--display=' + os.environ.get('DISPLAY',':99'))
    d = webdriver.Chrome(service=Service('/usr/bin/chromedriver'), options=o)
    d.set_page_load_timeout(45)
    d.execute_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
    d.execute_script("Object.defineProperty(navigator,'plugins',{get:()=>[1,2,3,4,5]})")
    return d

def handle_cloudflare_checkbox(driver_instance, worker_id, max_attempts=3):
    """Detect and click Cloudflare checkbox with retries"""
    for attempt in range(max_attempts):
        try:
            socketio.emit('log', {'worker_id':worker_id,'message':f'Cloudflare check {attempt+1}/{max_attempts}','type':'info'})
            time.sleep(2)
            
            if "blooket.com" in driver_instance.current_url and "challenges.cloudflare" not in driver_instance.page_source:
                socketio.emit('log', {'worker_id':worker_id,'message':'No Cloudflare challenge','type':'success'})
                return True
            
            iframe_selectors = [
                "//iframe[contains(@src, 'challenges.cloudflare.com')]",
                "//iframe[@title='Widget containing a Cloudflare security challenge']",
                "iframe[src*='cloudflare']",
                "iframe[title*='Cloudflare']",
                "iframe"
            ]
            
            cf_iframe = None
            for selector in iframe_selectors:
                try:
                    if selector.startswith('//'):
                        iframes = driver_instance.find_elements(By.XPATH, selector)
                    else:
                        iframes = driver_instance.find_elements(By.CSS_SELECTOR, selector)
                    
                    for iframe in iframes:
                        if iframe.is_displayed():
                            cf_iframe = iframe
                            break
                    if cf_iframe:
                        break
                except:
                    continue
            
            if not cf_iframe:
                socketio.emit('log', {'worker_id':worker_id,'message':'No iframe found','type':'info'})
                return True
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Cloudflare iframe found','type':'info'})
            
            driver_instance.switch_to.frame(cf_iframe)
            time.sleep(1)
            
            checkbox_selectors = [
                "input[type='checkbox']",
                "//input[@type='checkbox']",
                ".ctp-checkbox-label",
                "//label[contains(@class, 'ctp-checkbox')]",
                "//div[@role='checkbox']",
                "#challenge-stage input",
                "span.mark"
            ]
            
            clicked = False
            for cb_selector in checkbox_selectors:
                try:
                    if cb_selector.startswith('//'):
                        elements = driver_instance.find_elements(By.XPATH, cb_selector)
                    else:
                        elements = driver_instance.find_elements(By.CSS_SELECTOR, cb_selector)
                    
                    for elem in elements:
                        try:
                            if elem.is_displayed() or True:
                                driver_instance.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
                                time.sleep(0.3)
                                
                                try:
                                    elem.click()
                                except:
                                    try:
                                        driver_instance.execute_script("arguments[0].click();", elem)
                                    except:
                                        driver_instance.execute_script("arguments[0].dispatchEvent(new MouseEvent('click', {bubbles: true}));", elem)
                                
                                socketio.emit('log', {'worker_id':worker_id,'message':'✓ Checkbox clicked!','type':'success'})
                                clicked = True
                                break
                        except:
                            continue
                    
                    if clicked:
                        break
                except:
                    continue
            
            driver_instance.switch_to.default_content()
            
            if clicked:
                socketio.emit('log', {'worker_id':worker_id,'message':'Verifying...','type':'info'})
                time.sleep(6)
                
                if "blooket.com" in driver_instance.current_url:
                    socketio.emit('log', {'worker_id':worker_id,'message':'✓ Verification successful!','type':'success'})
                    return True
            
            time.sleep(2)
            
        except Exception as e:
            socketio.emit('log', {'worker_id':worker_id,'message':f'Attempt {attempt+1} error: {str(e)[:50]}','type':'error'})
            try:
                driver_instance.switch_to.default_content()
            except:
                pass
            time.sleep(2)
    
    socketio.emit('log', {'worker_id':worker_id,'message':'Could not bypass Cloudflare','type':'error'})
    return False

def screenshot_loop(worker_id):
    global workers
    while workers.get(worker_id, {}).get('running', False):
        try:
            with worker_lock:
                if worker_id in workers and workers[worker_id].get('browser'):
                    browser = workers[worker_id]['browser']
                    ss = browser.get_screenshot_as_png()
                    
                    img = Image.open(BytesIO(ss))
                    img.thumbnail((800,500), Image.Resampling.LANCZOS)
                    buf = BytesIO()
                    img.save(buf, format="PNG", optimize=True, quality=70)
                    b64 = base64.b64encode(buf.getvalue()).decode()
                    
                    del img, buf, ss
                    gc.collect()
                    
                    socketio.emit('screenshot', {'worker_id': worker_id, 'image': b64})
            
            time.sleep(3)
        except:
            time.sleep(3)

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/health')
def health():
    return jsonify({'status':'ok','workers':len(workers)})

@socketio.on('get_workers')
def get_workers():
    with worker_lock:
        worker_states = {}
        for wid, w in workers.items():
            worker_states[wid] = {
                'browser': w['browser'] is not None,
                'running': w['running'],
                'login_mode': w['login_mode']
            }
        socketio.emit('workers', worker_states)

@app.route('/set_workers', methods=['POST'])
def set_workers():
    global workers, next_worker_id
    count = request.json.get('count', 1)
    
    try:
        with worker_lock:
            # Stop workers beyond new count
            to_remove = [wid for wid in workers.keys() if int(wid) > count]
            for wid in to_remove:
                if workers[wid]['browser']:
                    try:
                        workers[wid]['browser'].quit()
                    except:
                        pass
                workers[wid]['running'] = False
                del workers[wid]
            
            # Add new workers if needed
            for i in range(1, count + 1):
                if i not in workers:
                    workers[i] = {
                        'browser': None,
                        'running': False,
                        'login_mode': False,
                        'thread': None
                    }
            
            gc.collect()
        
        socketio.emit('log', {'message':f'Set to {count} workers','type':'success'})
        return jsonify({'success': True, 'count': count})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/login', methods=['POST'])
def login():
    worker_id = request.json.get('worker_id', 1)
    
    try:
        with worker_lock:
            if worker_id not in workers:
                workers[worker_id] = {'browser': None, 'running': False, 'login_mode': False, 'thread': None}
            
            if workers[worker_id]['browser']:
                try:
                    workers[worker_id]['browser'].quit()
                except:
                    pass
                workers[worker_id]['browser'] = None
                gc.collect()
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Starting browser...','type':'info'})
            workers[worker_id]['browser'] = driver()
            socketio.emit('log', {'worker_id':worker_id,'message':'Opening Blooket login...','type':'info'})
            workers[worker_id]['browser'].get('https://www.blooket.com/login')
            
            handle_cloudflare_checkbox(workers[worker_id]['browser'], worker_id)
            
            time.sleep(2)
            socketio.emit('log', {'worker_id':worker_id,'message':'✓ Ready to login','type':'success'})
            
            workers[worker_id]['login_mode'] = True
            workers[worker_id]['running'] = True
            
            if not workers[worker_id]['thread'] or not workers[worker_id]['thread'].is_alive():
                workers[worker_id]['thread'] = threading.Thread(target=screenshot_loop, args=(worker_id,), daemon=True)
                workers[worker_id]['thread'].start()
        
        return jsonify({'success': True})
    except Exception as e:
        socketio.emit('log', {'worker_id':worker_id,'message':f'Error: {str(e)}','type':'error'})
        return jsonify({'error': str(e)}), 500

@app.route('/login_all', methods=['POST'])
def login_all():
    try:
        with worker_lock:
            worker_ids = list(workers.keys())
        
        for wid in worker_ids:
            threading.Thread(target=lambda w: login_worker_async(w), args=(wid,), daemon=True).start()
            time.sleep(1)  # Stagger starts
        
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def login_worker_async(worker_id):
    try:
        with worker_lock:
            if workers[worker_id]['browser']:
                try:
                    workers[worker_id]['browser'].quit()
                except:
                    pass
                workers[worker_id]['browser'] = None
                gc.collect()
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Starting...','type':'info'})
            workers[worker_id]['browser'] = driver()
            workers[worker_id]['browser'].get('https://www.blooket.com/login')
            
            handle_cloudflare_checkbox(workers[worker_id]['browser'], worker_id)
            
            time.sleep(2)
            socketio.emit('log', {'worker_id':worker_id,'message':'✓ Ready','type':'success'})
            
            workers[worker_id]['login_mode'] = True
            workers[worker_id]['running'] = True
            
            if not workers[worker_id]['thread'] or not workers[worker_id]['thread'].is_alive():
                workers[worker_id]['thread'] = threading.Thread(target=screenshot_loop, args=(worker_id,), daemon=True)
                workers[worker_id]['thread'].start()
    except Exception as e:
        socketio.emit('log', {'worker_id':worker_id,'message':f'Error: {str(e)}','type':'error'})

@app.route('/start', methods=['POST'])
def start():
    worker_id = request.json.get('worker_id', 1)
    url = request.json.get('url', '')
    
    if not url:
        return jsonify({'error': 'URL required'}), 400
    
    try:
        with worker_lock:
            if worker_id not in workers or not workers[worker_id]['browser']:
                return jsonify({'error': 'Please login first'}), 400
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Loading game...','type':'info'})
            workers[worker_id]['browser'].get(url)
            time.sleep(3)
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Handling Cloudflare...','type':'info'})
            cf_success = handle_cloudflare_checkbox(workers[worker_id]['browser'], worker_id)
            
            if cf_success:
                socketio.emit('log', {'worker_id':worker_id,'message':'✓ Game loaded','type':'success'})
            else:
                socketio.emit('log', {'worker_id':worker_id,'message':'Cloudflare may need manual click','type':'error'})
            
            time.sleep(2)
            
            # Auto-click Host Now
            socketio.emit('log', {'worker_id':worker_id,'message':'Auto-clicking Host Now...','type':'info'})
            try:
                selectors = [
                    "//button[contains(text(), 'Host Now')]",
                    "//button[contains(text(), 'HOST NOW')]",
                    "//button[contains(., 'Host')]"
                ]
                
                found = False
                for sel in selectors:
                    try:
                        elems = workers[worker_id]['browser'].find_elements(By.XPATH, sel)
                        for e in elems:
                            if e.is_displayed():
                                workers[worker_id]['browser'].execute_script("arguments[0].scrollIntoView({block:'center'});", e)
                                time.sleep(0.5)
                                try:
                                    e.click()
                                except:
                                    workers[worker_id]['browser'].execute_script("arguments[0].click();", e)
                                socketio.emit('log', {'worker_id':worker_id,'message':'✓ Host Now clicked!','type':'success'})
                                found = True
                                break
                        if found:
                            break
                    except:
                        continue
                
                if not found:
                    socketio.emit('log', {'worker_id':worker_id,'message':'Host Now not found','type':'info'})
            except:
                pass
            
            workers[worker_id]['login_mode'] = False
        
        return jsonify({'success': True})
    except Exception as e:
        socketio.emit('log', {'worker_id':worker_id,'message':f'Error: {str(e)}','type':'error'})
        return jsonify({'error': str(e)}), 500

@app.route('/click', methods=['POST'])
def click():
    worker_id = request.json.get('worker_id', 1)
    
    try:
        with worker_lock:
            if worker_id not in workers or not workers[worker_id]['browser']:
                return jsonify({'error': 'Browser not started'}), 400
            
            socketio.emit('log', {'worker_id':worker_id,'message':'Finding Host Now...','type':'info'})
            found = False
            
            selectors = [
                "//button[contains(text(), 'Host Now')]",
                "//button[contains(text(), 'HOST NOW')]",
                "//button[contains(., 'Host')]",
                "button"
            ]
            
            for sel in selectors:
                try:
                    elems = workers[worker_id]['browser'].find_elements(By.XPATH, sel)
                    for e in elems:
                        if e.is_displayed():
                            workers[worker_id]['browser'].execute_script("arguments[0].scrollIntoView({block:'center'});", e)
                            time.sleep(0.5)
                            try:
                                e.click()
                            except:
                                workers[worker_id]['browser'].execute_script("arguments[0].click();", e)
                            found = True
                            socketio.emit('log', {'worker_id':worker_id,'message':'✓ Clicked!','type':'success'})
                            break
                    if found:
                        break
                except:
                    continue
            
            if not found:
                socketio.emit('log', {'worker_id':worker_id,'message':'Button not found','type':'error'})
                return jsonify({'error': 'Button not found'}), 404
        
        return jsonify({'success': True})
    except Exception as e:
        socketio.emit('log', {'worker_id':worker_id,'message':f'Error: {str(e)}','type':'error'})
        return jsonify({'error': str(e)}), 500

@app.route('/stop', methods=['POST'])
def stop():
    worker_id = request.json.get('worker_id', 1)
    
    try:
        with worker_lock:
            if worker_id in workers:
                workers[worker_id]['running'] = False
                workers[worker_id]['login_mode'] = False
                if workers[worker_id]['browser']:
                    workers[worker_id]['browser'].quit()
                    workers[worker_id]['browser'] = None
                    gc.collect()
        
        socketio.emit('log', {'worker_id':worker_id,'message':'✓ Stopped','type':'info'})
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/stop_all', methods=['POST'])
def stop_all():
    try:
        with worker_lock:
            for wid in list(workers.keys()):
                workers[wid]['running'] = False
                workers[wid]['login_mode'] = False
                if workers[wid]['browser']:
                    try:
                        workers[wid]['browser'].quit()
                    except:
                        pass
                    workers[wid]['browser'] = None
            gc.collect()
        
        socketio.emit('log', {'message':'All workers stopped','type':'success'})
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Initialize with 1 worker by default
    workers[1] = {'browser': None, 'running': False, 'login_mode': False, 'thread': None}
    
    port = int(os.environ.get('PORT', 10000))
    print('Blooket Multi-Worker Host Bot - http://0.0.0.0:' + str(port))
    socketio.run(app, host='0.0.0.0', port=port, debug=False, allow_unsafe_werkzeug=True)
PYCODE

COPY --chmod=755 <<'SUPERVISOR' /etc/supervisor/conf.d/services.conf
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0

[program:xvfb]
command=/usr/bin/Xvfb :99 -screen 0 1280x720x16 -ac +extension GLX +render -noreset
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/null
stderr_logfile=/dev/null

[program:app]
command=python /app/app.py
directory=/app
autostart=true
autorestart=true
priority=50
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
environment=DISPLAY=":99",PORT="%(ENV_PORT)s"
SUPERVISOR

COPY --chmod=755 <<'BASH' /start.sh
#!/bin/bash
set -e
[ -f "/usr/bin/chromium" ] && echo "✓ Chromium OK" || { echo "✗ No Chromium"; exit 1; }
export DISPLAY=:99
export PORT=${PORT:-10000}
echo "Starting Blooket Multi-Worker Bot on port $PORT"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
BASH

RUN mkdir -p /var/log/supervisor

EXPOSE 10000

HEALTHCHECK --interval=45s --timeout=10s --start-period=90s --retries=2 \
    CMD curl -f http://localhost:${PORT:-10000}/health || exit 1

WORKDIR /app

ENTRYPOINT ["/start.sh"]
