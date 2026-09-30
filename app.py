#!/usr/bin/env python3
"""
Private URL Shortener — Zero tracking, zero logs, zero analytics.
Supports custom domains AND custom paths.
Uses only Python stdlib.
"""

import sqlite3
import hashlib
import json
import os
import re
import secrets
import signal
import sys
import threading
from datetime import datetime, timedelta
from urllib.parse import urlparse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# Resolve everything relative to this file so the app works from any cwd
# (docker WORKDIR /app, a systemd unit, or `python3 app.py` from elsewhere).
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_HTML = os.path.join(BASE_DIR, "index.html")

DB_PATH = os.path.abspath(os.environ.get("DB_PATH") or os.path.join(BASE_DIR, "data", "urls.db"))
PORT = int(os.environ.get("PORT", 3000))
# BASE_URL drives the short links we hand back. If it is not set, derive it
# from PORT so links never point at the wrong port.
BASE_URL = os.environ.get("BASE_URL") or f"http://localhost:{PORT}"
CODE_LENGTH = 6
MAX_LINKS = int(os.environ.get("MAX_LINKS", 10000))


def ensure_data_dir():
    """Fail early (and loudly) if the database directory is not writable."""
    data_dir = os.path.dirname(DB_PATH) or "."
    try:
        os.makedirs(data_dir, exist_ok=True)
        probe = os.path.join(data_dir, ".write-test")
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
    except OSError as exc:
        sys.stderr.write(
            f"\n✗ Cannot write to the database directory: {data_dir}\n"
            f"  {exc.__class__.__name__}: {exc}\n"
            f"  The container/process runs as uid={os.getuid()}.\n"
            f"  Fix it with one of:\n"
            f"    sudo chown -R {os.getuid()}:{os.getgid()} {data_dir}\n"
            f"    sudo chmod -R 777 {data_dir}\n"
            f"    DB_PATH=/somewhere/writable/urls.db python3 app.py\n\n"
        )
        sys.exit(1)


ensure_data_dir()


def connect_db():
    """SQLite connection with a busy timeout (the server is multi-threaded)."""
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.execute("PRAGMA busy_timeout = 15000")
    return conn


def init_db():
    conn = connect_db()
    c = conn.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS urls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL,
        url TEXT NOT NULL,
        domain TEXT DEFAULT NULL,
        path_prefix TEXT DEFAULT NULL,
        password_hash TEXT DEFAULT NULL,
        expires_at TIMESTAMP DEFAULT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(code, domain, path_prefix))""")
    conn.commit()
    conn.close()

def generate_code() -> str:
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return ''.join(secrets.choice(chars) for _ in range(CODE_LENGTH))

def hash_password(pwd: str) -> str:
    return hashlib.sha256((pwd + "shorten-salt").encode()).hexdigest()[:32]

def is_valid_url(url: str) -> bool:
    if not url or len(url) > 2048:
        return False
    # Reject whitespace and control characters. Without this, a URL containing
    # \r\n gets stored and later written straight into the Location header —
    # i.e. HTTP response splitting / header injection.
    for ch in url:
        if ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F:
            return False
    try:
        result = urlparse(url)
        return all([result.scheme in ("http", "https"), result.netloc])
    except Exception:
        return False

def is_valid_domain(domain: str) -> bool:
    if not domain:
        return True
    pattern = r"^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$"
    return bool(re.match(pattern, domain))

def is_valid_path_prefix(path: str) -> bool:
    if not path:
        return True
    pattern = r"^[a-zA-Z0-9][-a-zA-Z0-9_]*$"
    return bool(re.match(pattern, path))

def get_domain_from_host(host: str) -> str:
    return host.split(":")[0] if host else ""

def get_link_count():
    conn = connect_db()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM urls")
    count = c.fetchone()[0]
    conn.close()
    return count

def cleanup_expired():
    conn = connect_db()
    c = conn.cursor()
    c.execute("DELETE FROM urls WHERE expires_at IS NOT NULL AND expires_at < datetime('now')")
    deleted = c.rowcount
    conn.commit()
    conn.close()
    return deleted

def get_base_url_protocol():
    """Extract protocol from BASE_URL for consistency."""
    parsed = urlparse(BASE_URL)
    return parsed.scheme or "https"

def append_query(url: str, query: str) -> str:
    """Forward a short link's query string to its destination."""
    if not query:
        return url
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}{query}"

class Handler(BaseHTTPRequestHandler):
    # Keep-alive: every response below sets Content-Length, so persistent
    # connections are safe and healthchecks never hang waiting for EOF.
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Zero logs by design — no IP, no User-Agent, no Referer.
        pass

    def _write_body(self, body: bytes):
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # Client went away mid-response. Nothing to log, nothing to fix.
            self.close_connection = True

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self._write_body(body)

    def _send_html(self, content, status=200):
        body = content.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self._write_body(body)

    def _send_redirect(self, url):
        # Defence in depth: strip CR/LF so a value stored before validation was
        # tightened can never split the response.
        url = url.replace("\r", "").replace("\n", "")
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _send_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self._write_body(content)
        except OSError:
            self._send_json({"error": "Not found"}, 404)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        # Cheap liveness probe for load balancers / uptime monitors.
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _get_domain(self):
        return get_domain_from_host(self.headers.get("Host", ""))

    def _get_base_domain(self):
        return get_domain_from_host(BASE_URL)

    def _is_admin_host(self, host_domain):
        """True when the caller is on the app's own host and should therefore
        see every link, not just the ones belonging to one custom domain.

        Without this, opening http://127.0.0.1:PORT while BASE_URL says
        http://localhost:PORT returned an empty list — the UI looked broken
        right after a successful install.
        """
        if not host_domain:
            return True
        if host_domain == self._get_base_domain():
            return True
        return host_domain in ("localhost", "127.0.0.1", "0.0.0.0", "::1")

    def _build_short_url(self, code, domain=None, path_prefix=None):
        """Build a short URL consistently using the same protocol as BASE_URL."""
        protocol = get_base_url_protocol()
        if domain:
            if path_prefix:
                return f"{protocol}://{domain}/{path_prefix}/{code}"
            return f"{protocol}://{domain}/{code}"
        else:
            parsed = urlparse(BASE_URL)
            base = f"{parsed.scheme}://{parsed.netloc}" if parsed.scheme else BASE_URL.rstrip("/")
            if path_prefix:
                return f"{base}/{path_prefix}/{code}"
            return f"{base}/{code}"

    def do_GET(self):
        # Split off any query string: /code?utm=x must still resolve to /code,
        # and the query is forwarded to the destination URL.
        raw_path = self.path
        path, _, query = raw_path.partition("?")
        host_domain = self._get_domain()
        base_domain = self._get_base_domain()

        if path in ("/api/health", "/healthz", "/api/stats"):
            if path == "/api/stats":
                count = get_link_count()
                return self._send_json({"status": "ok", "total_links": count, "max_links": MAX_LINKS})
            return self._send_json({"status": "ok"})

        if path == "/api/urls":
            conn = connect_db()
            c = conn.cursor()
            if not self._is_admin_host(host_domain):
                c.execute("""SELECT code, url, path_prefix, expires_at, created_at, domain, password_hash 
                    FROM urls WHERE domain = ? ORDER BY created_at DESC LIMIT 50""", (host_domain,))
            else:
                c.execute("""SELECT code, url, path_prefix, expires_at, created_at, domain, password_hash 
                    FROM urls ORDER BY created_at DESC LIMIT 50""")
            rows = c.fetchall()
            conn.close()
            urls = []
            for r in rows:
                d = r[5] or base_domain
                prefix = r[2]
                short = self._build_short_url(r[0], d, prefix)
                urls.append({
                    "code": r[0], "url": r[1], "path_prefix": r[2],
                    "expires": r[3], "created": r[4], "domain": d,
                    "short_url": short, "has_password": bool(r[6])
                })
            return self._send_json(urls)

        if path in ("/", "/index.html"):
            return self._send_file(INDEX_HTML, "text/html; charset=utf-8")

        # Parse path: could be /CODE or /PREFIX/CODE
        path_parts = [p for p in path.strip("/").split("/") if p]

        if len(path_parts) == 1:
            code = path_parts[0]
            prefix = None
        elif len(path_parts) == 2:
            prefix = path_parts[0]
            code = path_parts[1]
        else:
            self._send_json({"error": "Not found"}, 404)
            return

        if not re.match(r"^[a-zA-Z0-9_-]+$", code) or not is_valid_path_prefix(prefix):
            self._send_json({"error": "Not found"}, 404)
            return

        conn = connect_db()
        c = conn.cursor()
        row = None

        # Priority order for lookup:
        # 1. Exact match: code + prefix + domain (if custom domain accessed)
        # 2. Exact match: code + prefix + NULL domain
        # 3. Fallback: code + NULL prefix + domain (if custom domain accessed)
        # 4. Fallback: code + NULL prefix + NULL domain

        if prefix:
            if host_domain and host_domain != base_domain:
                c.execute("""SELECT url, password_hash, expires_at, domain FROM urls 
                    WHERE code = ? AND path_prefix = ? AND domain = ?""",
                    (code, prefix, host_domain))
                row = c.fetchone()

            if not row:
                c.execute("""SELECT url, password_hash, expires_at, domain FROM urls 
                    WHERE code = ? AND path_prefix = ? AND domain IS NULL""",
                    (code, prefix))
                row = c.fetchone()
        else:
            if host_domain and host_domain != base_domain:
                c.execute("""SELECT url, password_hash, expires_at, domain FROM urls 
                    WHERE code = ? AND path_prefix IS NULL AND domain = ?""",
                    (code, host_domain))
                row = c.fetchone()

            if not row:
                c.execute("""SELECT url, password_hash, expires_at, domain FROM urls 
                    WHERE code = ? AND path_prefix IS NULL AND domain IS NULL""",
                    (code,))
                row = c.fetchone()

        if row:
            url, pwd_hash, expires, link_domain = row
            if expires:
                try:
                    exp_dt = datetime.fromisoformat(expires)
                    if exp_dt < datetime.now():
                        c.execute("DELETE FROM urls WHERE code = ? AND path_prefix IS ? AND domain IS ?", 
                                  (code, prefix, link_domain))
                        conn.commit()
                        conn.close()
                        return self._send_json({"error": "Link expired"}, 410)
                except (ValueError, TypeError):
                    pass

            conn.close()
            if pwd_hash:
                return self._send_password_page(code, prefix, link_domain)
            return self._send_redirect(append_query(url, query))

        conn.close()
        self._send_json({"error": "Not found"}, 404)

    def _send_password_page(self, code, prefix=None, domain=None):
        # JSON-encode every interpolated value so the page can never be turned
        # into script injection, even if a future validator gets looser.
        code_json = json.dumps(code or "")
        prefix_json = json.dumps(prefix or "")
        domain_json = json.dumps(domain or "")
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
fetch('/api/unlock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:""" + code_json + """,prefix:""" + prefix_json + """,domain:""" + domain_json + """,password:pwd})})
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
                path_prefix = data.get("path_prefix", "").strip().lower()
                password = data.get("password", "").strip()
                expires = data.get("expires", "").strip()
            except:
                return self._send_json({"error": "Invalid JSON"}, 400)

            if not url:
                return self._send_json({"error": "URL is required"}, 400)
            # Only add https:// when there is no scheme at all. Blindly
            # prefixing turned "ftp://x" into "https://ftp://x" and stored it.
            scheme = re.match(r"^([a-zA-Z][a-zA-Z0-9+.\-]*):", url)
            if scheme:
                if scheme.group(1).lower() not in ("http", "https"):
                    return self._send_json({"error": "Only http and https URLs are supported"}, 400)
            else:
                url = "https://" + url
            if not is_valid_url(url):
                return self._send_json({"error": "Invalid URL"}, 400)
            if custom_domain and not is_valid_domain(custom_domain):
                return self._send_json({"error": "Invalid domain format"}, 400)
            if path_prefix and not is_valid_path_prefix(path_prefix):
                return self._send_json({"error": "Invalid path prefix. Use letters, numbers, hyphens, underscores only."}, 400)
            if custom_code and not re.match(r"^[a-zA-Z0-9_-]+$", custom_code):
                return self._send_json({"error": "Invalid code format"}, 400)

            conn = connect_db()
            c = conn.cursor()

            # Check duplicate - use proper NULL-safe comparison
            c.execute("""SELECT code, domain, path_prefix FROM urls WHERE url = ? 
                AND ((domain = ?) OR (domain IS NULL AND ? = ''))
                AND ((path_prefix = ?) OR (path_prefix IS NULL AND ? = ''))""",
                (url, custom_domain or None, custom_domain, path_prefix or None, path_prefix))
            existing = c.fetchone()
            if existing:
                code = existing[0]
                existing_domain = existing[1]
                existing_prefix = existing[2]
                short = self._build_short_url(code, existing_domain, existing_prefix)
                conn.close()
                return self._send_json({"short_url": short, "code": code, "domain": existing_domain, "path_prefix": existing_prefix})

            # Enforce the cap only for links that would actually be created, so
            # re-shortening an existing URL keeps working at MAX_LINKS.
            current_count = get_link_count()
            if current_count >= MAX_LINKS:
                cleanup_expired()
                current_count = get_link_count()
                if current_count >= MAX_LINKS:
                    conn.close()
                    return self._send_json({"error": f"Max {MAX_LINKS} links reached"}, 429)

            # Generate or use custom code
            if custom_code:
                code = custom_code
                c.execute("""SELECT 1 FROM urls WHERE code = ? 
                    AND ((domain = ?) OR (domain IS NULL AND ? = ''))
                    AND ((path_prefix = ?) OR (path_prefix IS NULL AND ? = ''))""",
                    (code, custom_domain or None, custom_domain, path_prefix or None, path_prefix))
                if c.fetchone():
                    conn.close()
                    return self._send_json({"error": "This code is already taken"}, 409)
            else:
                code = generate_code()
                while True:
                    c.execute("""SELECT 1 FROM urls WHERE code = ? 
                        AND ((domain = ?) OR (domain IS NULL AND ? = ''))
                        AND ((path_prefix = ?) OR (path_prefix IS NULL AND ? = ''))""",
                        (code, custom_domain or None, custom_domain, path_prefix or None, path_prefix))
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

            c.execute("""INSERT INTO urls (code, url, domain, path_prefix, password_hash, expires_at) 
                VALUES (?, ?, ?, ?, ?, ?)""",
                (code, url, custom_domain or None, path_prefix or None, pwd_hash, expires_at))
            conn.commit()
            conn.close()

            short = self._build_short_url(code, custom_domain or None, path_prefix or None)

            return self._send_json({
                "short_url": short,
                "code": code,
                "domain": custom_domain or None,
                "path_prefix": path_prefix or None
            })

        if self.path == "/api/unlock":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                code = data.get("code", "").strip()
                prefix = data.get("prefix", "").strip() or None
                domain = data.get("domain", "").strip() or None
                password = data.get("password", "").strip()
            except:
                return self._send_json({"error": "Invalid JSON"}, 400)

            if not code:
                return self._send_json({"error": "Code is required"}, 400)

            conn = connect_db()
            c = conn.cursor()

            # Look up with domain awareness
            c.execute("""SELECT url, password_hash, expires_at FROM urls 
                WHERE code = ? 
                AND ((path_prefix = ?) OR (path_prefix IS NULL AND ? IS NULL))
                AND ((domain = ?) OR (domain IS NULL AND ? IS NULL))""",
                (code, prefix, prefix, domain, domain))
            row = c.fetchone()

            # Fallback: if no domain specified, try to find any matching link
            if not row and not domain:
                c.execute("""SELECT url, password_hash, expires_at FROM urls 
                    WHERE code = ? 
                    AND ((path_prefix = ?) OR (path_prefix IS NULL AND ? IS NULL))
                    AND domain IS NULL""",
                    (code, prefix, prefix))
                row = c.fetchone()

            conn.close()

            if not row:
                return self._send_json({"error": "Not found"}, 404)

            url, pwd_hash, expires = row
            if expires:
                try:
                    exp_dt = datetime.fromisoformat(expires)
                    if exp_dt < datetime.now():
                        return self._send_json({"error": "Expired"}, 410)
                except (ValueError, TypeError):
                    pass

            if pwd_hash and hash_password(password) != pwd_hash:
                return self._send_json({"error": "Wrong password"}, 403)

            return self._send_json({"url": url})

        self._send_json({"error": "Not found"}, 404)

class Server(ThreadingHTTPServer):
    """Threaded so one slow client (or a healthcheck) never blocks the rest."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    init_db()
    cleanup_expired()

    try:
        server = Server(("0.0.0.0", PORT), Handler)
    except PermissionError:
        sys.stderr.write(
            f"\n✗ Cannot bind to port {PORT} — ports below 1024 need root.\n"
            f"  Fix: PORT=3000 python3 app.py   (or run behind a reverse proxy)\n\n"
        )
        sys.exit(1)
    except OSError as exc:
        sys.stderr.write(
            f"\n✗ Cannot bind to port {PORT}: {exc}\n"
            f"  Something else is probably already listening on it.\n"
            f"  Find it:  lsof -i :{PORT}   (Linux/macOS)  |  netstat -ano | findstr :{PORT}  (Windows)\n"
            f"  Or run on another port: PORT=3001 python3 app.py\n\n"
        )
        sys.exit(1)

    def shutdown(signum, _frame):
        print("\n👋 Shutting down...", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(f"🔐 Cloak.URL running at {BASE_URL}")
    print(f"👂 Listening on 0.0.0.0:{PORT}")
    print(f"📁 Database: {DB_PATH}")
    print(f"🚫 Zero tracking · Zero analytics · Zero logs")
    print(f"🔢 Max links: {MAX_LINKS}", flush=True)

    server.serve_forever(poll_interval=0.2)
    server.server_close()


if __name__ == "__main__":
    main()
