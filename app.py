#!/usr/bin/env python3
"""
Private URL Shortener — Zero tracking, zero logs, zero analytics.
Optional: password protection, link expiration, custom domains.
Uses only Python stdlib.
"""

import sqlite3
import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timedelta
from urllib.parse import urlparse
from http.server import HTTPServer, BaseHTTPRequestHandler

DB_PATH = os.environ.get("DB_PATH", "data/urls.db")
BASE_URL = os.environ.get("BASE_URL", "http://localhost:3000")
PORT = int(os.environ.get("PORT", 3000))
CODE_LENGTH = 6
MAX_LINKS = int(os.environ.get("MAX_LINKS", 10000))

os.makedirs(os.path.dirname(DB_PATH) if os.path.dirname(DB_PATH) else ".", exist_ok=True)

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS urls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT UNIQUE NOT NULL,
        url TEXT NOT NULL,
        domain TEXT DEFAULT NULL,
        password_hash TEXT DEFAULT NULL,
        expires_at TIMESTAMP DEFAULT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(code, domain))""")
    conn.commit()
    conn.close()

def generate_code() -> str:
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return ''.join(secrets.choice(chars) for _ in range(CODE_LENGTH))

def hash_password(pwd: str) -> str:
    return hashlib.sha256((pwd + "shorten-salt").encode()).hexdigest()[:32]

def is_valid_url(url: str) -> bool:
    try:
        result = urlparse(url)
        return all([result.scheme in ("http", "https"), result.netloc])
    except:
        return False

def is_valid_domain(domain: str) -> bool:
    if not domain:
        return True
    pattern = r"^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$"
    return bool(re.match(pattern, domain))

def get_domain_from_host(host: str) -> str:
    return host.split(":")[0] if host else ""

def get_link_count():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM urls")
    count = c.fetchone()[0]
    conn.close()
    return count

def cleanup_expired():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("DELETE FROM urls WHERE expires_at IS NOT NULL AND expires_at < datetime('now')")
    deleted = c.rowcount
    conn.commit()
    conn.close()
    return deleted

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _send_html(self, content, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(content.encode())

    def _send_redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.end_headers()

    def _send_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self._send_json({"error": "Not found"}, 404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _get_domain(self):
        return get_domain_from_host(self.headers.get("Host", ""))

    def do_GET(self):
        path = self.path
        host_domain = self._get_domain()
        base_domain = get_domain_from_host(BASE_URL)

        if path == "/api/stats":
            count = get_link_count()
            return self._send_json({"total_links": count, "max_links": MAX_LINKS})

        if path == "/api/urls":
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            if host_domain and host_domain != base_domain:
                c.execute("SELECT code, url, expires_at, created_at, domain, password_hash FROM urls WHERE domain = ? ORDER BY created_at DESC LIMIT 50", (host_domain,))
            else:
                c.execute("SELECT code, url, expires_at, created_at, domain, password_hash FROM urls ORDER BY created_at DESC LIMIT 50")
            rows = c.fetchall()
            conn.close()
            urls = []
            for r in rows:
                d = r[4] or base_domain
                if d != base_domain:
                    short = f"https://{d}/{r[0]}"
                else:
                    short = f"{BASE_URL}/{r[0]}"
                urls.append({
                    "code": r[0], "url": r[1], "expires": r[2], "created": r[3],
                    "domain": d, "short_url": short, "has_password": bool(r[5])
                })
            return self._send_json(urls)

        if path == "/" or path == "/index.html":
            return self._send_file("index.html", "text/html")

        code = path.strip("/")
        if re.match(r"^[a-zA-Z0-9_-]+$", code):
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()

            if host_domain and host_domain != base_domain:
                c.execute("SELECT url, password_hash, expires_at FROM urls WHERE code = ? AND domain = ?", (code, host_domain))
                row = c.fetchone()
                if not row:
                    c.execute("SELECT url, password_hash, expires_at FROM urls WHERE code = ? AND domain IS NULL", (code,))
                    row = c.fetchone()
            else:
                c.execute("SELECT url, password_hash, expires_at FROM urls WHERE code = ? AND (domain IS NULL OR domain = ?)", (code, host_domain))
                row = c.fetchone()

            if row:
                url, pwd_hash, expires = row
                if expires and datetime.fromisoformat(expires) < datetime.now():
                    c.execute("DELETE FROM urls WHERE code = ?", (code,))
                    conn.commit()
                    conn.close()
                    return self._send_json({"error": "Link expired"}, 410)

                conn.close()
                if pwd_hash:
                    return self._send_password_page(code)
                return self._send_redirect(url)
            conn.close()

        self._send_json({"error": "Not found"}, 404)

    def _send_password_page(self, code):
        html = """<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width">
<style>
* { margin:0; padding:0; box-sizing:border-box }
:root { --bg:#0f0f0f; --surface:#1a1a1a; --text:#f3f4f6; --border:#2d2d2d; --primary:#3b82f6; --radius:12px }
body { font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; background:var(--bg); color:var(--text); min-height:100vh; display:flex; align-items:center; justify-content:center; padding:20px }
.card { background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:40px; max-width:420px; width:100%; text-align:center }
h1 { font-size:24px; margin-bottom:8px } p { color:#9ca3af; margin-bottom:24px; font-size:15px }
input { width:100%; padding:14px 18px; border:2px solid var(--border); border-radius:10px; background:var(--bg); color:var(--text); font-size:16px; outline:none; margin-bottom:12px }
input:focus { border-color:var(--primary) }
button { width:100%; padding:14px; background:var(--primary); color:white; border:none; border-radius:10px; font-size:16px; font-weight:600; cursor:pointer }
.error { color:#ef4444; font-size:14px; margin-top:12px; display:none }
.lock { font-size:48px; margin-bottom:16px }
</style></head>
<body>
<div class="card">
<div class="lock">🔒</div>
<h1>Password Protected</h1>
<p>This link requires a password to access.</p>
<form onsubmit="unlock(event)">
<input type="password" id="pwd" placeholder="Enter password" autofocus>
<button type="submit">Unlock Link</button>
<div class="error" id="err"></div>
</form>
</div>
<script>
function unlock(e) {
e.preventDefault();
const pwd = document.getElementById('pwd').value;
const err = document.getElementById('err');
fetch('/api/unlock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:'""" + code + """',password:pwd})})
.then(r=>r.json()).then(d=>{if(d.url)window.location.href=d.url;else{err.textContent=d.error||'Wrong password';err.style.display='block';}})
.catch(()=>{err.textContent='Error unlocking';err.style.display='block';});
}
</script></body></html>"""
        self._send_html(html)

    def do_POST(self):
        if self.path == "/api/shorten":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                url = data.get("url", "").strip()
                custom_domain = data.get("domain", "").strip().lower()
                custom_code = data.get("custom_code", "").strip()
                password = data.get("password", "").strip()
                expires = data.get("expires", "").strip()
            except:
                return self._send_json({"error": "Invalid JSON"}, 400)

            if not url:
                return self._send_json({"error": "URL is required"}, 400)
            if not url.startswith(("http://", "https://")):
                url = "https://" + url
            if not is_valid_url(url):
                return self._send_json({"error": "Invalid URL"}, 400)
            if custom_domain and not is_valid_domain(custom_domain):
                return self._send_json({"error": "Invalid domain"}, 400)
            if custom_code and not re.match(r"^[a-zA-Z0-9_-]+$", custom_code):
                return self._send_json({"error": "Invalid code format"}, 400)

            current_count = get_link_count()
            if current_count >= MAX_LINKS:
                cleanup_expired()
                current_count = get_link_count()
                if current_count >= MAX_LINKS:
                    return self._send_json({"error": f"Max {MAX_LINKS} links reached"}, 429)

            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()

            if custom_domain:
                c.execute("SELECT code FROM urls WHERE url = ? AND domain = ?", (url, custom_domain))
            else:
                c.execute("SELECT code FROM urls WHERE url = ? AND domain IS NULL", (url,))
            existing = c.fetchone()
            if existing:
                code = existing[0]
                short = f"https://{custom_domain}/{code}" if custom_domain else f"{BASE_URL}/{code}"
                conn.close()
                return self._send_json({"short_url": short, "code": code, "domain": custom_domain or None})

            if custom_code:
                code = custom_code
                c.execute("SELECT 1 FROM urls WHERE code = ? AND (domain = ? OR (domain IS NULL AND ? IS NULL))", (code, custom_domain, custom_domain))
                if c.fetchone():
                    conn.close()
                    return self._send_json({"error": "Code already taken"}, 409)
            else:
                code = generate_code()
                while True:
                    c.execute("SELECT 1 FROM urls WHERE code = ? AND (domain = ? OR (domain IS NULL AND ? IS NULL))", (code, custom_domain, custom_domain))
                    if not c.fetchone():
                        break
                    code = generate_code()

            pwd_hash = hash_password(password) if password else None
            expires_at = None
            if expires:
                try:
                    hours = int(expires)
                    expires_at = (datetime.now() + timedelta(hours=hours)).isoformat()
                except:
                    conn.close()
                    return self._send_json({"error": "Invalid expiration"}, 400)

            c.execute("INSERT INTO urls (code, url, domain, password_hash, expires_at) VALUES (?, ?, ?, ?, ?)",
                     (code, url, custom_domain or None, pwd_hash, expires_at))
            conn.commit()
            conn.close()

            short = f"https://{custom_domain}/{code}" if custom_domain else f"{BASE_URL}/{code}"
            return self._send_json({"short_url": short, "code": code, "domain": custom_domain or None})

        if self.path == "/api/unlock":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                code = data.get("code", "").strip()
                password = data.get("password", "").strip()
            except:
                return self._send_json({"error": "Invalid JSON"}, 400)

            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT url, password_hash, expires_at FROM urls WHERE code = ?", (code,))
            row = c.fetchone()
            conn.close()

            if not row:
                return self._send_json({"error": "Not found"}, 404)

            url, pwd_hash, expires = row
            if expires and datetime.fromisoformat(expires) < datetime.now():
                return self._send_json({"error": "Expired"}, 410)

            if pwd_hash and hash_password(password) != pwd_hash:
                return self._send_json({"error": "Wrong password"}, 403)

            return self._send_json({"url": url})

        self._send_json({"error": "Not found"}, 404)

def main():
    init_db()
    cleanup_expired()
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"🔐 Private URL Shortener running at {BASE_URL}")
    print(f"📁 Database: {os.path.abspath(DB_PATH)}")
    print(f"🚫 Zero tracking · Zero analytics · Zero logs")
    print(f"🔢 Max links: {MAX_LINKS}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("
👋 Shutting down...")
        server.shutdown()

if __name__ == "__main__":
    main()
