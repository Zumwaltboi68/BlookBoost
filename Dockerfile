# ==========================================
# Blooket Game Host Bot with Live Preview
# Complete Automation + Real-time VNC View
# Red & Black Theme - Render Compatible
# ==========================================

FROM python:3.11-slim

# Metadata - Combined into single LABEL for proper syntax
LABEL maintainer="Blooket Host Bot" \
      description="Professional Blooket game host automation with live preview" \
      version="2.0.1"

# Environment Configuration
ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PORT=10000 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    RENDER=true

# Install system dependencies including VNC stack
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    python3-numpy \
    fluxbox \
    curl \
    ca-certificates \
    fonts-liberation \
    fonts-noto-color-emoji \
    supervisor \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Create requirements inline
RUN cat > requirements.txt << 'EOF'
flask==3.0.0
flask-cors==4.0.0
flask-socketio==5.3.5
selenium==4.16.0
webdriver-manager==4.0.1
gunicorn==21.2.0
requests==2.31.0
pillow==10.1.0
python-socketio==5.10.0
eventlet==0.33.3
EOF

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Create the complete application
RUN cat > app.py << 'APPEOF'
from flask import Flask, render_template_string, request, jsonify, Response
from flask_socketio import SocketIO, emit
from flask_cors import CORS
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
import threading
import time
import os
import base64
from io import BytesIO
from PIL import Image

app = Flask(__name__)
app.config['SECRET_KEY'] = 'blooket-host-bot-secret-key'
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

# Global state
browser_instance = None
browser_lock = threading.Lock()
screenshot_thread = None
screenshot_running = False

# HTML Template with Live Preview
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Blooket Host Bot Pro</title>
    <script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a0000 0%, #330000 50%, #000000 100%);
            min-height: 100vh;
            color: #ffffff;
            padding: 20px;
        }

        .container {
            max-width: 1600px;
            margin: 0 auto;
        }

        .header {
            background: linear-gradient(135deg, #ff0000 0%, #cc0000 100%);
            padding: 25px;
            border-radius: 15px;
            box-shadow: 0 10px 40px rgba(255, 0, 0, 0.3);
            margin-bottom: 20px;
            text-align: center;
            border: 2px solid #ff3333;
        }

        .header h1 {
            font-size: 2.5em;
            font-weight: 800;
            text-shadow: 0 0 20px rgba(255, 0, 0, 0.8);
            margin-bottom: 5px;
            letter-spacing: 2px;
        }

        .header .subtitle {
            font-size: 1.1em;
            opacity: 0.9;
        }

        .main-grid {
            display: grid;
            grid-template-columns: 400px 1fr;
            gap: 20px;
            margin-bottom: 20px;
        }

        .card {
            background: rgba(20, 0, 0, 0.8);
            backdrop-filter: blur(10px);
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 8px 32px rgba(255, 0, 0, 0.2);
            border: 1px solid rgba(255, 0, 0, 0.2);
            transition: all 0.3s ease;
        }

        .card:hover {
            box-shadow: 0 12px 48px rgba(255, 0, 0, 0.4);
            border-color: rgba(255, 0, 0, 0.4);
        }

        .card h2 {
            color: #ff3333;
            margin-bottom: 20px;
            font-size: 1.5em;
            font-weight: 700;
            text-shadow: 0 0 10px rgba(255, 0, 0, 0.5);
        }

        .input-group {
            margin-bottom: 15px;
        }

        label {
            display: block;
            margin-bottom: 8px;
            color: #ff6666;
            font-weight: 600;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        input[type="text"] {
            width: 100%;
            padding: 12px;
            background: rgba(0, 0, 0, 0.5);
            border: 2px solid #ff0000;
            border-radius: 10px;
            color: #ffffff;
            font-size: 15px;
            transition: all 0.3s ease;
        }

        input:focus {
            outline: none;
            border-color: #ff3333;
            box-shadow: 0 0 20px rgba(255, 0, 0, 0.3);
            background: rgba(0, 0, 0, 0.7);
        }

        input::placeholder {
            color: #ff6666;
            opacity: 0.5;
        }

        .button {
            width: 100%;
            background: linear-gradient(135deg, #ff0000 0%, #cc0000 100%);
            color: white;
            border: none;
            padding: 14px;
            border-radius: 10px;
            font-size: 16px;
            font-weight: 700;
            cursor: pointer;
            transition: all 0.3s ease;
            text-transform: uppercase;
            letter-spacing: 2px;
            box-shadow: 0 5px 20px rgba(255, 0, 0, 0.4);
            margin-bottom: 10px;
        }

        .button:hover:not(:disabled) {
            background: linear-gradient(135deg, #ff3333 0%, #ff0000 100%);
            transform: translateY(-2px);
            box-shadow: 0 8px 30px rgba(255, 0, 0, 0.6);
        }

        .button:disabled {
            background: #333333;
            cursor: not-allowed;
            box-shadow: none;
            opacity: 0.5;
        }

        .button.secondary {
            background: linear-gradient(135deg, #990000 0%, #660000 100%);
        }

        .button.secondary:hover:not(:disabled) {
            background: linear-gradient(135deg, #cc0000 0%, #990000 100%);
        }

        .status {
            padding: 12px;
            border-radius: 10px;
            margin-bottom: 15px;
            display: none;
            font-weight: 600;
            border: 2px solid;
            animation: fadeIn 0.3s ease;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(-10px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .status.success {
            background: rgba(0, 100, 0, 0.2);
            color: #00ff00;
            border-color: #00ff00;
        }

        .status.error {
            background: rgba(100, 0, 0, 0.3);
            color: #ff6666;
            border-color: #ff0000;
        }

        .status.info {
            background: rgba(255, 0, 0, 0.2);
            color: #ff9999;
            border-color: #ff3333;
        }

        .preview-container {
            background: rgba(0, 0, 0, 0.7);
            border-radius: 15px;
            padding: 15px;
            border: 2px solid #ff0000;
            height: 700px;
            display: flex;
            flex-direction: column;
        }

        .preview-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
            padding-bottom: 10px;
            border-bottom: 2px solid rgba(255, 0, 0, 0.3);
        }

        .preview-title {
            color: #ff3333;
            font-size: 1.3em;
            font-weight: 700;
        }

        .preview-status {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .status-dot {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: #ff0000;
            animation: pulse 2s infinite;
        }

        .status-dot.active {
            background: #00ff00;
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        .preview-screen {
            flex: 1;
            background: #000000;
            border-radius: 10px;
            overflow: hidden;
            display: flex;
            align-items: center;
            justify-content: center;
            border: 2px solid rgba(255, 0, 0, 0.3);
            position: relative;
        }

        .preview-screen img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
        }

        .preview-placeholder {
            color: #666;
            font-size: 1.2em;
            text-align: center;
        }

        .info-box {
            background: rgba(255, 0, 0, 0.1);
            border-left: 4px solid #ff0000;
            padding: 12px;
            margin-bottom: 15px;
            border-radius: 5px;
            font-size: 0.9em;
        }

        .info-box strong {
            color: #ff3333;
        }

        .logs-container {
            background: rgba(0, 0, 0, 0.7);
            border-radius: 10px;
            padding: 15px;
            max-height: 300px;
            overflow-y: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.85em;
            border: 1px solid rgba(255, 0, 0, 0.2);
        }

        .log-entry {
            padding: 5px;
            margin-bottom: 5px;
            border-left: 3px solid #ff0000;
            padding-left: 10px;
        }

        .log-entry.success {
            border-color: #00ff00;
            color: #00ff00;
        }

        .log-entry.error {
            border-color: #ff0000;
            color: #ff6666;
        }

        .log-entry.info {
            border-color: #ff9999;
            color: #ff9999;
        }

        .spinner {
            display: inline-block;
            width: 16px;
            height: 16px;
            border: 3px solid rgba(255, 255, 255, 0.3);
            border-radius: 50%;
            border-top-color: #ff0000;
            animation: spin 1s ease-in-out infinite;
            margin-right: 8px;
        }

        @keyframes spin {
            to { transform: rotate(360deg); }
        }

        .vnc-link {
            display: block;
            background: rgba(255, 165, 0, 0.2);
            border: 2px solid #ff9900;
            color: #ff9900;
            padding: 10px;
            border-radius: 8px;
            text-decoration: none;
            text-align: center;
            margin-top: 10px;
            font-weight: 600;
            transition: all 0.3s ease;
        }

        .vnc-link:hover {
            background: rgba(255, 165, 0, 0.3);
            border-color: #ffaa00;
            color: #ffaa00;
        }

        .glow {
            animation: glow 2s ease-in-out infinite;
        }

        @keyframes glow {
            0%, 100% { text-shadow: 0 0 10px rgba(255, 0, 0, 0.5); }
            50% { text-shadow: 0 0 20px rgba(255, 0, 0, 1); }
        }

        @media (max-width: 1200px) {
            .main-grid {
                grid-template-columns: 1fr;
            }
            
            .preview-container {
                height: 500px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1 class="glow">🎮 BLOOKET HOST BOT PRO</h1>
            <div class="subtitle">Automated Game Hosting with Live Preview</div>
        </div>

        <div class="main-grid">
            <!-- Control Panel -->
            <div class="card">
                <h2>⚙️ Control Panel</h2>
                
                <div class="info-box">
                    <strong>Instructions:</strong> Enter any Blooket game URL (host landing page) and click Host Game to automatically start hosting.
                </div>

                <div id="status" class="status"></div>

                <div class="input-group">
                    <label>🎯 Blooket Game URL</label>
                    <input type="text" id="blooketUrl" placeholder="https://goldquest.blooket.com/gold/host/landing?gid=...">
                </div>

                <button class="button" id="hostBtn" onclick="hostGame()">
                    🚀 HOST GAME
                </button>

                <button class="button secondary" id="clickBtn" onclick="clickHostButton()" disabled>
                    👆 CLICK HOST BUTTON
                </button>

                <button class="button secondary" id="stopBtn" onclick="stopBrowser()" disabled>
                    ⛔ STOP BROWSER
                </button>

                <a href="http://localhost:6080/vnc.html" target="_blank" class="vnc-link">
                    📺 Open Full VNC Viewer
                </a>

                <div style="margin-top: 20px;">
                    <h3 style="color: #ff3333; margin-bottom: 10px; font-size: 1.2em;">📋 Activity Log</h3>
                    <div class="logs-container" id="logsContainer">
                        <div class="log-entry info">System ready. Waiting for commands...</div>
                    </div>
                </div>
            </div>

            <!-- Live Preview -->
            <div class="card">
                <div class="preview-container">
                    <div class="preview-header">
                        <div class="preview-title">📺 Live Browser Preview</div>
                        <div class="preview-status">
                            <div class="status-dot" id="statusDot"></div>
                            <span id="previewStatus">Idle</span>
                        </div>
                    </div>
                    <div class="preview-screen" id="previewScreen">
                        <div class="preview-placeholder">
                            🖥️ Browser preview will appear here<br>
                            <small>Updates every 2 seconds when active</small>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const socket = io();
        let previewActive = false;

        socket.on('connect', () => {
            console.log('Connected to server');
            addLog('Connected to server', 'success');
        });

        socket.on('screenshot', (data) => {
            const img = document.createElement('img');
            img.src = 'data:image/png;base64,' + data.image;
            const screen = document.getElementById('previewScreen');
            screen.innerHTML = '';
            screen.appendChild(img);
        });

        socket.on('log', (data) => {
            addLog(data.message, data.type);
        });

        socket.on('status', (data) => {
            updateStatus(data.active);
        });

        function addLog(message, type = 'info') {
            const container = document.getElementById('logsContainer');
            const entry = document.createElement('div');
            entry.className = 'log-entry ' + type;
            const timestamp = new Date().toLocaleTimeString();
            entry.textContent = `[${timestamp}] ${message}`;
            container.appendChild(entry);
            container.scrollTop = container.scrollHeight;
            
            while (container.children.length > 50) {
                container.removeChild(container.firstChild);
            }
        }

        function updateStatus(active) {
            const dot = document.getElementById('statusDot');
            const status = document.getElementById('previewStatus');
            
            if (active) {
                dot.classList.add('active');
                status.textContent = 'Active';
                document.getElementById('hostBtn').disabled = true;
                document.getElementById('clickBtn').disabled = false;
                document.getElementById('stopBtn').disabled = false;
                previewActive = true;
            } else {
                dot.classList.remove('active');
                status.textContent = 'Idle';
                document.getElementById('hostBtn').disabled = false;
                document.getElementById('clickBtn').disabled = true;
                document.getElementById('stopBtn').disabled = true;
                previewActive = false;
            }
        }

        function showStatus(message, type) {
            const status = document.getElementById('status');
            status.textContent = message;
            status.className = 'status ' + type;
            status.style.display = 'block';
            
            setTimeout(() => {
                status.style.display = 'none';
            }, 5000);
        }

        async function hostGame() {
            const url = document.getElementById('blooketUrl').value.trim();

            if (!url || !url.includes('blooket.com')) {
                showStatus('❌ Please enter a valid Blooket URL', 'error');
                return;
            }

            showStatus('🚀 Starting browser and navigating...', 'info');
            addLog('Initializing browser...', 'info');

            try {
                const response = await fetch('/start-browser', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url })
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus('✅ Browser started! Navigate to host page.', 'success');
                    addLog(data.message, 'success');
                } else {
                    showStatus('❌ Error: ' + data.error, 'error');
                    addLog('Error: ' + data.error, 'error');
                }
            } catch (error) {
                showStatus('❌ Network error: ' + error.message, 'error');
                addLog('Network error: ' + error.message, 'error');
            }
        }

        async function clickHostButton() {
            showStatus('👆 Clicking host button...', 'info');
            addLog('Attempting to click host button...', 'info');

            try {
                const response = await fetch('/click-host', {
                    method: 'POST'
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus('✅ ' + data.message, 'success');
                    addLog(data.message, 'success');
                } else {
                    showStatus('❌ Error: ' + data.error, 'error');
                    addLog('Error: ' + data.error, 'error');
                }
            } catch (error) {
                showStatus('❌ Network error: ' + error.message, 'error');
                addLog('Network error: ' + error.message, 'error');
            }
        }

        async function stopBrowser() {
            showStatus('⛔ Stopping browser...', 'info');
            addLog('Stopping browser...', 'info');

            try {
                const response = await fetch('/stop-browser', {
                    method: 'POST'
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus('✅ Browser stopped', 'success');
                    addLog('Browser stopped', 'success');
                    document.getElementById('previewScreen').innerHTML = 
                        '<div class="preview-placeholder">🖥️ Browser preview will appear here</div>';
                } else {
                    showStatus('❌ Error: ' + data.error, 'error');
                    addLog('Error: ' + data.error, 'error');
                }
            } catch (error) {
                showStatus('❌ Network error: ' + error.message, 'error');
                addLog('Network error: ' + error.message, 'error');
            }
        }

        fetch('/health')
            .then(r => r.json())
            .then(data => {
                console.log('Service healthy:', data);
                addLog('Service initialized successfully', 'success');
            })
            .catch(err => {
                console.error('Health check failed:', err);
                addLog('Warning: Health check failed', 'error');
            });
    </script>
</body>
</html>
"""

def create_driver():
    """Create a Chrome driver with visible window"""
    options = Options()
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--disable-gpu')
    options.add_argument('--window-size=1280,800')
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
    options.add_experimental_option("excludeSwitches", ["enable-automation"])
    options.add_experimental_option('useAutomationExtension', False)
    
    options.binary_location = '/usr/bin/chromium'
    options.add_argument(f'--display={os.environ.get("DISPLAY", ":99")}')
    
    service = Service('/usr/bin/chromedriver')
    driver = webdriver.Chrome(service=service, options=options)
    driver.set_page_load_timeout(60)
    
    driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
    
    return driver

def screenshot_loop():
    """Continuously take screenshots and send to clients"""
    global browser_instance, screenshot_running
    
    while screenshot_running:
        try:
            if browser_instance:
                with browser_lock:
                    screenshot = browser_instance.get_screenshot_as_png()
                
                img = Image.open(BytesIO(screenshot))
                img.thumbnail((1200, 800), Image.Resampling.LANCZOS)
                
                buffered = BytesIO()
                img.save(buffered, format="PNG", optimize=True)
                img_str = base64.b64encode(buffered.getvalue()).decode()
                
                socketio.emit('screenshot', {'image': img_str})
            
            time.sleep(2)
            
        except Exception as e:
            print(f"Screenshot error: {e}")
            time.sleep(2)

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/health')
def health():
    return jsonify({
        'status': 'healthy',
        'browser_active': browser_instance is not None,
        'chromium': '/usr/bin/chromium',
        'display': os.environ.get('DISPLAY', ':99')
    })

@app.route('/start-browser', methods=['POST'])
def start_browser():
    global browser_instance, screenshot_running, screenshot_thread
    
    data = request.json
    url = data.get('url', '')
    
    if not url:
        return jsonify({'error': 'URL is required'}), 400
    
    try:
        with browser_lock:
            if browser_instance:
                browser_instance.quit()
            
            socketio.emit('log', {'message': 'Creating browser instance...', 'type': 'info'})
            browser_instance = create_driver()
            
            socketio.emit('log', {'message': f'Navigating to {url}...', 'type': 'info'})
            browser_instance.get(url)
            
            time.sleep(3)
            
            socketio.emit('log', {'message': 'Page loaded successfully!', 'type': 'success'})
            socketio.emit('status', {'active': True})
            
            if not screenshot_running:
                screenshot_running = True
                screenshot_thread = threading.Thread(target=screenshot_loop, daemon=True)
                screenshot_thread.start()
        
        return jsonify({
            'success': True,
            'message': 'Browser started and navigated to URL',
            'url': url
        })
        
    except Exception as e:
        socketio.emit('log', {'message': f'Error: {str(e)}', 'type': 'error'})
        return jsonify({'error': str(e)}), 500

@app.route('/click-host', methods=['POST'])
def click_host():
    global browser_instance
    
    if not browser_instance:
        return jsonify({'error': 'Browser not started'}), 400
    
    try:
        with browser_lock:
            socketio.emit('log', {'message': 'Looking for host button...', 'type': 'info'})
            
            selectors = [
                "button[class*='host']",
                "button[class*='Host']",
                "//button[contains(text(), 'Host')]",
                "//button[contains(text(), 'host')]",
                "div[class*='hostButton']",
                "//div[contains(@class, 'host')]//button",
                "button.primary",
                "button[type='submit']"
            ]
            
            button_found = False
            
            for selector in selectors:
                try:
                    if selector.startswith('//'):
                        elements = browser_instance.find_elements(By.XPATH, selector)
                    else:
                        elements = browser_instance.find_elements(By.CSS_SELECTOR, selector)
                    
                    if elements:
                        element = elements[0]
                        
                        browser_instance.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
                        time.sleep(0.5)
                        
                        try:
                            element.click()
                        except Exception as click_error:
                            socketio.emit('log', {'message': f'Standard click failed, attempting JS click: {str(click_error)}', 'type': 'info'})
                            browser_instance.execute_script("arguments[0].click();", element)
                        
                        button_found = True
                        socketio.emit('log', {'message': f'Clicked button using selector: {selector}', 'type': 'success'})
                        break
                        
                except Exception as e:
                    socketio.emit('log', {'message': f'Selector {selector} failed: {str(e)}', 'type': 'info'})
                    continue
            
            if not button_found:
                try:
                    buttons = browser_instance.find_elements(By.TAG_NAME, 'button')
                    if buttons:
                        for btn in buttons:
                            try:
                                if btn.is_displayed():
                                    browser_instance.execute_script("arguments[0].scrollIntoView({block: 'center'});", btn)
                                    time.sleep(0.5)
                                    browser_instance.execute_script("arguments[0].click();", btn)
                                    button_found = True
                                    socketio.emit('log', {'message': 'Clicked first visible button', 'type': 'success'})
                                    break
                            except Exception as btn_error:
                                socketio.emit('log', {'message': f'Failed to click button: {str(btn_error)}', 'type': 'info'})
                                continue
                except Exception as e:
                    socketio.emit('log', {'message': f'Last resort button click failed: {str(e)}', 'type': 'error'})
            
            if not button_found:
                socketio.emit('log', {'message': 'No host button found. Try clicking manually via VNC.', 'type': 'error'})
                return jsonify({'error': 'Could not find host button'}), 404
            
            time.sleep(2)
            socketio.emit('log', {'message': 'Host button clicked! Game should be starting...', 'type': 'success'})
        
        return jsonify({
            'success': True,
            'message': 'Host button clicked successfully'
        })
        
    except Exception as e:
        socketio.emit('log', {'message': f'Click error: {str(e)}', 'type': 'error'})
        return jsonify({'error': str(e)}), 500

@app.route('/stop-browser', methods=['POST'])
def stop_browser():
    global browser_instance, screenshot_running
    
    try:
        screenshot_running = False
        
        with browser_lock:
            if browser_instance:
                browser_instance.quit()
                browser_instance = None
        
        socketio.emit('status', {'active': False})
        socketio.emit('log', {'message': 'Browser stopped', 'type': 'info'})
        
        return jsonify({'success': True, 'message': 'Browser stopped'})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 10000))
    print(f"""
╔══════════════════════════════════════════╗
║  Blooket Host Bot Pro - READY           ║
╠══════════════════════════════════════════╣
║  🌐 Server:  http://0.0.0.0:{port}        ║
║  📺 VNC:     http://0.0.0.0:6080        ║
║  🎮 Status:  ACTIVE                      ║
╚══════════════════════════════════════════╝
    """)
    socketio.run(app, host='0.0.0.0', port=port, debug=False, allow_unsafe_werkzeug=True)
APPEOF

# Create supervisor configuration for VNC services
RUN mkdir -p /var/log/supervisor && \
    cat > /etc/supervisor/conf.d/services.conf << 'SUPERVISOREOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:xvfb]
command=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/xvfb.log
stderr_logfile=/var/log/xvfb_err.log

[program:x11vnc]
command=/usr/bin/x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever -shared -repeat
autostart=true
autorestart=true
priority=20
stdout_logfile=/var/log/x11vnc.log
stderr_logfile=/var/log/x11vnc_err.log

[program:novnc]
command=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080
autostart=true
autorestart=true
priority=30
stdout_logfile=/var/log/novnc.log
stderr_logfile=/var/log/novnc_err.log

[program:fluxbox]
command=/usr/bin/fluxbox -display :99
autostart=true
autorestart=true
priority=40
stdout_logfile=/var/log/fluxbox.log
stderr_logfile=/var/log/fluxbox_err.log
environment=DISPLAY=":99"

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
SUPERVISOREOF

# Create startup script
RUN cat > /start.sh << 'STARTEOF'
#!/bin/bash
set -e

echo "=========================================="
echo "  Blooket Host Bot - Starting Services   "
echo "=========================================="

if [ -f "/usr/bin/chromium" ]; then
    echo "✓ Chromium found"
    /usr/bin/chromium --version
else
    echo "✗ Chromium not found!"
    exit 1
fi

if [ -f "/usr/bin/chromedriver" ]; then
    echo "✓ ChromeDriver found"
    /usr/bin/chromedriver --version
else
    echo "✗ ChromeDriver not found!"
    exit 1
fi

export DISPLAY=:99
export PORT=${PORT:-10000}

echo "✓ Display: $DISPLAY"
echo "✓ HTTP Port: $PORT"
echo "✓ VNC Port: 5900"
echo "✓ noVNC Port: 6080"

mkdir -p /var/log/supervisor

echo "Starting all services..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
STARTEOF

RUN chmod +x /start.sh

# Health check script
RUN cat > /healthcheck.sh << 'HEALTHEOF'
#!/bin/bash
PORT=${PORT:-10000}
curl -f http://localhost:$PORT/health || exit 1
HEALTHEOF

RUN chmod +x /healthcheck.sh

# Expose ports
EXPOSE 10000 5900 6080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /healthcheck.sh

# Working directory
WORKDIR /app

# Run
ENTRYPOINT ["/start.sh"]
