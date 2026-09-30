#!/usr/bin/env python3
"""
Private URL Shortener — Zero tracking, zero logs, zero analytics.
Supports custom domains AND custom paths.
Uses only Python stdlib.
"""

import sqlite3
import hashlib
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import ssl
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from urllib.parse import urlparse, parse_qs
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

VERSION = "1.2.0"

# Resolve everything relative to this file so the app works from any cwd
# (docker WORKDIR /app, a systemd unit, or `python3 app.py` from elsewhere).
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_HTML = os.path.join(BASE_DIR, "index.html")

DB_PATH = os.path.abspath(os.environ.get("DB_PATH") or os.path.join(BASE_DIR, "data", "urls.db"))
PORT = int(os.environ.get("PORT", 3000))
# BASE_URL drives the short links we hand back; derive it from PORT when unset so
# links never point at the wrong port.
BASE_URL = os.environ.get("BASE_URL") or f"http://localhost:{PORT}"
CODE_LENGTH = 6
MAX_LINKS = int(os.environ.get("MAX_LINKS", 10000))

# ── Cloudflare Tunnel / custom domain connect ──
# The service address the tunnel should forward to (Docker network name + container port).
TUNNEL_SERVICE = os.environ.get("TUNNEL_SERVICE", "http://cloak:3000")
TUNNEL_NAME = os.environ.get("TUNNEL_NAME", "cloak-url")
# Optional Zero Trust account tag. When set, "open in Cloudflare" links deep-link
# straight into the account instead of the account picker. Never a secret.
CF_ACCOUNT_TAG = os.environ.get("CLOUDFLARE_ACCOUNT_TAG", "").strip().strip("/")
# Seconds allowed for a single outbound domain check (DNS + HTTPS probe).
DOMAIN_CHECK_TIMEOUT = float(os.environ.get("DOMAIN_CHECK_TIMEOUT", "6"))
# Minimum seconds between two checks of the same domain (keeps the app from being
# used as a port scanner and keeps Cloudflare's rate limits out of our way).
DOMAIN_CHECK_COOLDOWN = float(os.environ.get("DOMAIN_CHECK_COOLDOWN", "5"))
# A verify() remembers the hostname so its status shows in the domain list; cap the
# table so an unauthenticated visitor can't grow it forever.
MAX_DOMAINS = int(os.environ.get("MAX_DOMAINS", "100"))
MAX_JSON_BYTES = 64 * 1024

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
    # Saved custom domains. No secrets here — only hostnames plus the last check result.
    c.execute("""CREATE TABLE IF NOT EXISTS domains (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL UNIQUE,
        zone TEXT DEFAULT NULL,
        service TEXT DEFAULT NULL,
        note TEXT DEFAULT NULL,
        is_primary INTEGER NOT NULL DEFAULT 0,
        last_state TEXT DEFAULT NULL,
        last_ok INTEGER DEFAULT NULL,
        last_checked_at TIMESTAMP DEFAULT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    c.execute("""CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY, value TEXT NOT NULL)""")
    conn.commit()
    conn.close()


def get_meta(key: str, default: str = None) -> str:
    conn = connect_db()
    c = conn.cursor()
    c.execute("SELECT value FROM meta WHERE key = ?", (key,))
    row = c.fetchone()
    conn.close()
    return row[0] if row else default


def set_meta(key: str, value: str):
    conn = connect_db()
    c = conn.cursor()
    c.execute("INSERT INTO meta (key, value) VALUES (?, ?) "
              "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
    conn.commit()
    conn.close()


def get_instance_id() -> str:
    """Stable per-install ID. Lets a domain check prove the hostname reaches *this*
    Cloak.URL instance rather than some other server."""
    instance_id = get_meta("instance_id")
    if not instance_id:
        instance_id = secrets.token_hex(8)
        set_meta("instance_id", instance_id)
    return instance_id

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
    """Hostname without port or path.

    Accepts both a bare ``Host`` header (``example.com:3000``) and a full URL
    (``https://example.com``) — the old ``split(":")[0]`` returned ``"https"``
    for BASE_URL, which broke every base-domain comparison.
    """
    if not host:
        return ""
    value = str(host).strip()
    if "://" in value:
        value = value.split("://", 1)[1]
    value = value.split("/")[0]
    if "@" in value:
        value = value.rsplit("@", 1)[1]
    if value.startswith("["):  # IPv6 literal, e.g. [::1]:3000
        return value.split("]")[0].strip("[]")
    return value.split(":")[0].strip("[]")


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


# ═════════════════════════════════════════════════════════════════════════════
# Custom domains → Cloudflare Tunnel connect links + verification
#
# Nothing here talks to Cloudflare's API and no credentials are stored: the app
# builds ready-to-open dashboard links for the domain you typed, then verifies
# the result by resolving the hostname and probing it once over HTTPS.
# ═════════════════════════════════════════════════════════════════════════════

CF_ZERO_TRUST = "https://one.dash.cloudflare.com"
CF_DASH = "https://dash.cloudflare.com"

# Second-level labels that usually sit *above* the real registrable domain,
# so the zone for "links.example.co.uk" is "example.co.uk", not "co.uk".
MULTI_LABEL_TLDS = {
    "ac", "asn", "co", "com", "edu", "gob", "go", "gov", "id", "in", "ltd",
    "me", "mil", "ne", "net", "nom", "or", "org", "pl", "res", "sch", "tm", "web",
}

# Cloudflare edge ranges (IPv4 + IPv6) — used only to say "this hostname is
# proxied through Cloudflare", nothing else.
CLOUDFLARE_NETS = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
    "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
]
_CLOUDFLARE_NETS = [ipaddress.ip_network(n) for n in CLOUDFLARE_NETS]

# Cloudflare's own 1xxx codes, mapped to what they mean for a tunnel hostname.
CF_ERROR_HINTS = {
    "1016": "Origin DNS error — the hostname has no tunnel route/record yet.",
    "1033": "Tunnel error — Cloudflare found no healthy cloudflared connector.",
    "1034": "Too many hostnames point at this tunnel.",
    "1035": "The connector's cert is not valid for this tunnel.",
    "2034": "The connector rejected the request (check the tunnel token).",
    "521": "Origin refused the connection — is the cloak container up?",
    "522": "Origin timed out — cloudflared cannot reach http://cloak:3000.",
    "523": "Origin is unreachable.",
    "525": "SSL handshake with the origin failed.",
    "530": "Origin DNS error / tunnel not routing this hostname.",
}

_check_cooldown = {}


def normalize_domain(raw) -> str:
    """'https://Links.Example.com:8443/foo/' → 'links.example.com'."""
    if not raw:
        return ""
    value = str(raw).strip().lower()
    if not value:
        return ""
    if "://" not in value:
        value = "//" + value.lstrip("/")
    try:
        host = urlparse(value).hostname or ""
    except ValueError:
        return ""
    return host.rstrip(".")


def zone_from_domain(domain: str) -> str:
    """Best-effort registrable zone for dashboard deep links."""
    labels = domain.split(".")
    if len(labels) <= 2:
        return domain
    if labels[-2] in MULTI_LABEL_TLDS and len(labels) >= 3:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def cloudflare_links(domain: str, zone: str) -> dict:
    """Deep links into the Cloudflare dashboard for this domain.

    Zero Trust links include the account tag when CLOUDFLARE_ACCOUNT_TAG is set;
    otherwise they land on the account picker, which still works for everyone.
    """
    zt_base = f"{CF_ZERO_TRUST}/{CF_ACCOUNT_TAG}" if CF_ACCOUNT_TAG else CF_ZERO_TRUST
    create_suffix = "/networks/tunnels/create/launcher" if CF_ACCOUNT_TAG else "/networks/tunnels/create"
    return {
        "tunnel_create": zt_base + create_suffix,
        "tunnel_list": zt_base + "/networks/tunnels",
        "tunnel_routes": zt_base + "/networks/routes",
        "zone_dns": f"{CF_DASH}/?to=/:account/{zone or ':zone'}/dns",
        "zone_ssl": f"{CF_DASH}/?to=/:account/{zone or ':zone'}/ssl-tls",
        "add_site": f"{CF_DASH}/?to=/:account/add-site",
        "docs_tunnel": "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/",
        "docs_routes": "https://developers.cloudflare.com/cloudflare-one/networks/routes/add-routes/",
        "docs_1033": "https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1033/",
        "status": "https://www.cloudflarestatus.com",
        "account_tag_configured": bool(CF_ACCOUNT_TAG),
    }


def tunnel_snippets(domain: str, service: str = None) -> dict:
    """Copy-pasteable bits for the tunnel, docker compose and cloudflared config."""
    service = service or TUNNEL_SERVICE
    hostname = domain or "yourdomain.com"
    compose = (
        "services:\n"
        "  tunnel:\n"
        "    image: cloudflare/cloudflared:latest\n"
        "    restart: unless-stopped\n"
        "    command: tunnel run\n"
        "    environment:\n"
        "      - TUNNEL_TOKEN=<token from the Cloudflare create-tunnel wizard>\n"
    )
    yml = (
        "tunnel: <tunnel-uuid>\n"
        "credentials-file: /etc/cloudflared/<tunnel-uuid>.json\n"
        "ingress:\n"
        f"  - hostname: {hostname}\n"
        f"    service: {service}\n"
        "  - service: http_status:404\n"
    )
    steps = [
        {
            "id": "tunnel",
            "title": "Create (or pick) a Cloudflare Tunnel",
            "body": "Zero Trust → Networks → Tunnels → Create a tunnel. Choose Docker as the connector and copy the token — "
                    "Cloak.URL runs `cloudflared tunnel run` with it, so no ports are opened.",
        },
        {
            "id": "hostname",
            "title": f"Add the hostname {hostname}",
            "body": f"Open the tunnel → Routes → Add a route → Published application: subdomain/hostname "
                    f"for {hostname}, Type HTTP, URL {service}. Cloudflare creates the proxied DNS record for you.",
        },
        {
            "id": "compose",
            "title": "Give Cloak.URL the token",
            "body": "Paste the token into docker-compose.yml (tunnel service) or export TUNNEL_TOKEN, then run "
                    "`docker compose up -d`. Set BASE_URL to https://" + hostname + " so shortened links use it.",
        },
        {
            "id": "verify",
            "title": "Verify",
            "body": "Hit Verify below. Cloak.URL resolves the hostname and probes https://" + hostname +
                    "/api/health once to confirm the tunnel actually lands on this instance.",
        },
    ]
    return {
        "hostname": hostname,
        "service": service,
        "compose": compose,
        "cloudflared_yml": yml,
        "steps": steps,
    }


def resolve_ips(host: str, port: int = 443):
    """System-resolver lookup (no third-party DNS API). Returns (ips, error)."""
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except socket.gaierror as exc:
        return [], f"DNS lookup failed: {exc.strerror or exc}"
    except Exception as exc:  # pragma: no cover - defensive
        return [], f"DNS lookup failed: {exc}"
    ips = []
    for info in infos:
        ip = info[4][0]
        if ip not in ips:
            ips.append(ip)
    return ips, None


def ip_is_private(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return (addr.is_private or addr.is_loopback or addr.is_link_local
            or addr.is_reserved or addr.is_multicast or addr.is_unspecified)


def ip_is_cloudflare(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr.version == net.version and addr in net for net in _CLOUDFLARE_NETS)


def http_probe(url: str, timeout: float = None) -> dict:
    """Single GET, no cookies, no redirect chasing, capped body."""
    timeout = timeout or DOMAIN_CHECK_TIMEOUT
    request = urllib.request.Request(
        url,
        headers={"User-Agent": f"cloak-url/{VERSION} +domain-check", "Accept": "application/json"},
    )
    try:
        context = ssl.create_default_context()
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            body = response.read(4096)
            return {"status": response.status, "body": body.decode("utf-8", "replace"),
                    "final_url": response.geturl(), "error": None}
    except urllib.error.HTTPError as exc:
        body = b""
        try:
            body = exc.read(4096)
        except Exception:
            pass
        return {"status": exc.code, "body": body.decode("utf-8", "replace"),
                "final_url": exc.url, "error": None}
    except ssl.SSLCertVerificationError as exc:
        return {"status": None, "body": "", "final_url": url, "error": f"TLS verify failed: {exc.verify_message if hasattr(exc, 'verify_message') else exc}"}
    except ssl.SSLError as exc:
        return {"status": None, "body": "", "final_url": url, "error": f"TLS error: {exc.reason or exc}"}
    except (socket.timeout, TimeoutError):
        return {"status": None, "body": "", "final_url": url, "error": f"No response within {timeout:g}s"}
    except urllib.error.URLError as exc:
        return {"status": None, "body": "", "final_url": url, "error": f"Connection failed: {exc.reason}"}
    except Exception as exc:  # pragma: no cover - defensive
        return {"status": None, "body": "", "final_url": url, "error": f"{type(exc).__name__}: {exc}"}


def classify_domain_check(domain: str, service: str = None) -> dict:
    """Resolve + probe a hostname once and explain what is missing."""
    now = datetime.now()
    result = {
        "domain": domain,
        "zone": zone_from_domain(domain),
        "checked_at": now.isoformat(timespec="seconds"),
        "ok": False,
        "state": "unknown",
        "dns": {},
        "http": {},
        "next_step": "",
    }

    ips, dns_error = resolve_ips(domain)
    private = [ip for ip in ips if ip_is_private(ip)]
    result["dns"] = {
        "resolves": bool(ips),
        "ips": ips,
        "cloudflare": bool(ips) and any(ip_is_cloudflare(ip) for ip in ips),
        "private": private,
        "error": dns_error,
    }

    if not ips:
        result["state"] = "dns_missing"
        result["next_step"] = (f"`{domain}` does not resolve. Add it to the zone {result['zone']} in Cloudflare "
                               "DNS (proxied) — or let the tunnel route create the record.")
        return result

    if len(private) == len(ips):
        # /etc/hosts entries, LAN IPs, link-local metadata IPs: never fetch those.
        result["state"] = "blocked"
        result["next_step"] = (f"`{domain}` resolves only to private/internal addresses ({', '.join(ips[:3])}). "
                               "Cloudflare cannot publish an internal-only name, and Cloak.URL will not probe it. "
                               "Use a real public hostname, or test locally with curl.")
        return result

    probe = http_probe(f"https://{domain}/api/health")
    result["http"] = {
        "status": probe["status"],
        "error": probe["error"],
        "cf_error": None,
        "app": None,
        "same_instance": False,
    }

    if probe["status"] is None:
        error_text = probe["error"] or "no response"
        if "TLS" in error_text:
            result["state"] = "tls_error"
            if "verify failed" in error_text:
                result["next_step"] = (f"TLS failed: the certificate presented for {domain} is not valid for it. "
                                       f"Cloudflare's Universal SSL covers `{result['zone']}` and `*.{result['zone']}` "
                                       "only — a deeper hostname (or >50 hostnames) needs an Advanced Certificate.")
            else:
                result["next_step"] = (f"TLS handshake with {domain} did not complete ({error_text}). Usually that "
                                       "means Cloudflare has no certificate for this hostname yet: add the tunnel "
                                       "route (which provisions the record + cert), or use an Advanced Certificate "
                                       "for hostnames below the apex/one wildcard.")
        else:
            result["state"] = "unreachable"
            result["next_step"] = (f"Could not reach https://{domain}: {error_text}. Check that cloudflared is "
                                   "running (`docker compose logs tunnel`) and that the hostname is proxied (orange cloud).")
        return result

    cf_error = re.search(r"Error\s*?(\d{4})", probe["body"] or "")
    cf_code = cf_error.group(1) if cf_error else None
    result["http"]["cf_error"] = cf_code
    if cf_code:
        result["http"]["cf_hint"] = CF_ERROR_HINTS.get(cf_code, f"Cloudflare error {cf_code}.")

    payload = None
    if probe["status"] == 200:
        try:
            parsed = json.loads(probe["body"])
            if isinstance(parsed, dict):
                payload = parsed
        except (ValueError, TypeError):
            payload = None

    if payload is not None and payload.get("app") == "cloak-url":
        result["http"]["app"] = payload.get("app")
        result["http"]["same_instance"] = payload.get("instance_id") == get_instance_id()
        result["state"] = "live"
        result["ok"] = True
        result["next_step"] = ("Connected — the hostname reaches Cloak.URL through Cloudflare."
                               if result["http"]["same_instance"] else
                               "Connected to a *different* Cloak.URL instance (different install id). "
                               "The tunnel hostname is pointing at another server.")
        result["instance_match"] = result["http"]["same_instance"]
        return result

    if probe["status"] == 200:
        result["state"] = "foreign_origin"
        result["next_step"] = ("Something answers on this hostname, but it is not Cloak.URL. Point the tunnel "
                               f"route's service at {service or TUNNEL_SERVICE} and remove other routes for it.")
        return result

    result["state"] = "tunnel_down" if cf_code in ("1033", "1034", "1035", "2034") else "no_route"
    if result["state"] == "tunnel_down":
        result["next_step"] = ("Cloudflare is serving the hostname but no healthy connector is attached: start "
                               "`docker compose up -d tunnel` (or check `docker compose logs tunnel`).")
    else:
        result["next_step"] = (f"HTTP {probe['status']}{f' ({cf_code})' if cf_code else ''}: the hostname is on Cloudflare "
                               f"but no tunnel route maps it to {service or TUNNEL_SERVICE}. Add the published "
                               "application route.")
    return result


def count_domains() -> int:
    conn = connect_db()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM domains")
    count = c.fetchone()[0]
    conn.close()
    return count


def get_domain_row(domain: str) -> dict:
    conn = connect_db()
    c = conn.cursor()
    c.execute("""SELECT domain, zone, service, note, is_primary, last_state, last_ok,
                 last_checked_at, created_at FROM domains WHERE domain = ?""", (domain,))
    row = c.fetchone()
    conn.close()
    if not row:
        return None
    return {
        "domain": row[0], "zone": row[1], "service": row[2] or TUNNEL_SERVICE,
        "note": row[3], "is_primary": bool(row[4]), "last_state": row[5],
        "last_ok": None if row[6] is None else bool(row[6]),
        "last_checked_at": row[7], "created_at": row[8],
    }


def save_domain(domain: str, service: str = None, note: str = None, set_primary: bool = False) -> dict:
    zone = zone_from_domain(domain)
    conn = connect_db()
    c = conn.cursor()
    c.execute("""INSERT INTO domains (domain, zone, service, note, is_primary)
                 VALUES (?, ?, ?, ?, ?)
                 ON CONFLICT(domain) DO UPDATE SET
                   zone = excluded.zone,
                   service = COALESCE(excluded.service, domains.service),
                   note = COALESCE(excluded.note, domains.note)""",
              (domain, zone, service, note, 1 if set_primary else 0))
    if set_primary:
        c.execute("UPDATE domains SET is_primary = 0 WHERE domain <> ?", (domain,))
    conn.commit()
    conn.close()
    return get_domain_row(domain)


def delete_domain(domain: str) -> int:
    conn = connect_db()
    c = conn.cursor()
    c.execute("DELETE FROM domains WHERE domain = ?", (domain,))
    deleted = c.rowcount
    conn.commit()
    conn.close()
    return deleted


def set_primary_domain(domain: str = None):
    """Mark one saved domain as the default (prefilled in the UI), or clear all."""
    conn = connect_db()
    c = conn.cursor()
    c.execute("UPDATE domains SET is_primary = 0")
    updated = 0
    if domain:
        c.execute("UPDATE domains SET is_primary = 1 WHERE domain = ?", (domain,))
        updated = c.rowcount
    conn.commit()
    conn.close()
    return updated


def list_domains() -> list:
    conn = connect_db()
    c = conn.cursor()
    c.execute("""SELECT domain, zone, service, note, is_primary, last_state, last_ok,
                 last_checked_at, created_at FROM domains ORDER BY is_primary DESC, created_at ASC""")
    rows = c.fetchall()
    c.execute("SELECT domain, COUNT(*) FROM urls GROUP BY domain")
    counts = {row[0] or "": row[1] for row in c.fetchall()}
    conn.close()
    base_domain = get_domain_from_host(BASE_URL)
    out = []
    for row in rows:
        out.append({
            "domain": row[0], "zone": row[1] or zone_from_domain(row[0]),
            "service": row[2] or TUNNEL_SERVICE, "note": row[3],
            "is_primary": bool(row[4]), "last_state": row[5],
            "last_ok": None if row[6] is None else bool(row[6]),
            "last_checked_at": row[7], "created_at": row[8],
            "link_count": counts.get(row[0], 0),
            "is_base_url": row[0] == base_domain,
        })
    return out


def primary_domain() -> str:
    conn = connect_db()
    c = conn.cursor()
    c.execute("SELECT domain FROM domains WHERE is_primary = 1 ORDER BY last_ok DESC LIMIT 1")
    row = c.fetchone()
    conn.close()
    return row[0] if row else None


def domain_status(domain: str) -> dict:
    """Status for one hostname: saved record first, otherwise infer from BASE_URL."""
    row = get_domain_row(domain)
    if row:
        return {"domain": domain, "saved": True, "state": row["last_state"],
                "ok": row["last_ok"], "last_checked_at": row["last_checked_at"]}
    base_domain = get_domain_from_host(BASE_URL)
    if domain and domain == base_domain:
        return {"domain": domain, "saved": False, "state": "base_url", "ok": True,
                "last_checked_at": None}
    return {"domain": domain, "saved": False, "state": None, "ok": None,
            "last_checked_at": None}


def domain_advice(domain: str) -> dict:
    """Connect links for a hostname that is not proven live yet (None if N/A)."""
    domain = normalize_domain(domain or "")
    if "." not in domain:
        return None
    status = domain_status(domain)
    advice = {
        "domain": domain,
        "state": status["state"],
        "verified": bool(status["ok"]),
        "checked_at": status["last_checked_at"],
    }
    if not status["ok"]:
        advice["reason"] = ("This domain has not been verified yet." if status["state"] is None
                            else f"Last check said: {status['state']}.")
        advice["links"] = cloudflare_links(domain, zone_from_domain(domain))
        advice["service"] = TUNNEL_SERVICE
    return advice


def check_domain_with_cooldown(domain: str, service: str = None, persist: bool = True) -> dict:
    """classify_domain_check + a per-domain cooldown so the probe can't be spammed."""
    now = datetime.now().timestamp()
    last = _check_cooldown.get(domain, 0)
    if now - last < DOMAIN_CHECK_COOLDOWN:
        wait = round(DOMAIN_CHECK_COOLDOWN - (now - last), 1)
        row = get_domain_row(domain)
        cached = domain_status(domain)
        return {
            "throttled": True,
            "retry_in": wait,
            "domain": domain,
            "state": cached["state"],
            "ok": cached["ok"],
            "checked_at": cached["last_checked_at"],
            "next_step": (f"Last check was {wait:g}s ago — try again in {wait:g}s."
                          if cached["state"] else "Never checked yet."),
        }
    _check_cooldown[domain] = now
    result = classify_domain_check(domain, service)
    result["throttled"] = False
    if persist and (get_domain_row(domain) or count_domains() < MAX_DOMAINS):
        conn = connect_db()
        c = conn.cursor()
        c.execute("""INSERT INTO domains (domain, zone, service, last_state, last_ok, last_checked_at)
                     VALUES (?, ?, ?, ?, ?, ?)
                     ON CONFLICT(domain) DO UPDATE SET
                       last_state = excluded.last_state,
                       last_ok = excluded.last_ok,
                       last_checked_at = excluded.last_checked_at""",
                  (domain, result["zone"], service, result["state"],
                   1 if result["ok"] else 0, result["checked_at"]))
        conn.commit()
        conn.close()
    return result


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

    def _read_json(self, limit: int = MAX_JSON_BYTES) -> dict:
        """Parse a small JSON body. Returns {} when absent or malformed."""
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            length = 0
        if length <= 0:
            return {}
        if length > limit:
            raise ValueError(f"Body too large (max {limit} bytes)")
        raw = self.rfile.read(length).decode("utf-8", "replace").strip()
        if not raw:
            return {}
        return json.loads(raw)

    def _query(self) -> dict:
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query, keep_blank_values=True).items()}

    def _get_domain(self):
        return get_domain_from_host(self.headers.get("Host", ""))

    def _get_base_domain(self):
        return get_domain_from_host(BASE_URL)

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
        path = self.path
        route = urlparse(path).path
        host_domain = self._get_domain()
        base_domain = self._get_base_domain()

        if route == "/api/health":
            # Public, non-secret fingerprint used by the domain check to confirm a
            # hostname really lands on *this* install (there is no auth in Cloak.URL).
            return self._send_json({
                "status": "ok",
                "app": "cloak-url",
                "version": VERSION,
                "instance_id": get_instance_id(),
                # Always the configured BASE_URL host, never the request's Host header:
                # two installs answering identically is what makes the check meaningful.
                "base_domain": base_domain or get_domain_from_host(BASE_URL),
                "domains": [d["domain"] for d in list_domains()],
                "tunnel_service": TUNNEL_SERVICE,
                "tracking": "none",
            })

        if route == "/api/cloudflare/setup":
            query = self._query()
            domain = normalize_domain(query.get("domain", ""))
            service = (query.get("service") or "").strip() or None
            if domain and not is_valid_domain(domain):
                return self._send_json({"error": f"Invalid domain: {domain}"}, 400)
            zone = zone_from_domain(domain) if domain else ""
            return self._send_json({
                "domain": domain or None,
                "zone": zone or None,
                "links": cloudflare_links(domain, zone),
                "tunnel": tunnel_snippets(domain, service),
                "status": domain_status(domain) if domain else None,
                "tunnel_name": TUNNEL_NAME,
                "version": VERSION,
            })

        if route == "/api/domains":
            return self._send_json({
                "domains": list_domains(),
                "primary": primary_domain(),
                "base_domain": base_domain,
                "default_service": TUNNEL_SERVICE,
                "tunnel_name": TUNNEL_NAME,
            })

        if route == "/api/stats":
            count = get_link_count()
            return self._send_json({"total_links": count, "max_links": MAX_LINKS})

        if route == "/api/urls":
            conn = connect_db()
            c = conn.cursor()
            if host_domain and host_domain != base_domain:
                # A hostname serves its own links *plus* the global (NULL-domain) bucket —
                # same priority as the redirect path, so the list never disagrees with what
                # actually resolves on this host.
                c.execute("""SELECT code, url, path_prefix, expires_at, created_at, domain, password_hash 
                    FROM urls WHERE domain = ? OR domain IS NULL ORDER BY created_at DESC LIMIT 50""",
                    (host_domain,))
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

        if route in ("/", "/index.html"):
            return self._send_file(INDEX_HTML, "text/html; charset=utf-8")

        # Parse path: could be /CODE or /PREFIX/CODE. Uses `route`, so a query
        # string no longer breaks the lookup (/code?utm=x resolved to 404);
        # the query is forwarded to the destination below.
        query = urlparse(path).query
        path_parts = [p for p in route.strip("/").split("/") if p]

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
        # 1. Exact match: code + prefix + the domain in the Host header
        #    (covers links explicitly bound to BASE_URL's domain too)
        # 2. Exact match: code + prefix + NULL domain (the legacy/global bucket)
        # 3. Fallback: code + NULL prefix + Host domain
        # 4. Fallback: code + NULL prefix + NULL domain

        if prefix:
            if host_domain:
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
            if host_domain:
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

    def _handle_domain_post(self, route: str):
        """Custom-domain bookkeeping: save / verify / remove / pick default.

        Only hostnames are stored — no Cloudflare tokens, no API keys.
        """
        try:
            data = self._read_json()
        except json.JSONDecodeError:
            return self._send_json({"error": "Invalid JSON"}, 400)
        except ValueError as exc:
            return self._send_json({"error": str(exc)}, 413)
        if not isinstance(data, dict):
            return self._send_json({"error": "Expected a JSON object"}, 400)

        domain = normalize_domain(data.get("domain", ""))
        service = (data.get("service") or "").strip() or None
        note = (data.get("note") or "").strip()[:120] or None

        if route == "/api/domains/primary":
            if domain:
                if not is_valid_domain(domain):
                    return self._send_json({"error": f"Invalid domain: {domain}"}, 400)
                if not get_domain_row(domain):
                    return self._send_json({"error": f"{domain} is not saved yet"}, 404)
            set_primary_domain(domain or None)
            return self._send_json({"primary": domain or None, "domains": list_domains()})

        if not domain:
            return self._send_json({"error": "domain is required (e.g. links.example.com)"}, 400)
        if not is_valid_domain(domain):
            return self._send_json({"error": f"Invalid domain: {domain}"}, 400)
        if service and not re.match(r"^https?://[A-Za-z0-9._:-]+(:[0-9]{1,5})?/?$", service):
            return self._send_json({"error": "Service must look like http://cloak:3000"}, 400)

        if route == "/api/domains/delete":
            return self._send_json({"deleted": delete_domain(domain), "domains": list_domains()})

        if route in ("/api/domains/verify", "/api/domains/check"):
            result = check_domain_with_cooldown(domain, service, persist=(route == "/api/domains/verify"))
            if not result.get("throttled") and not result.get("next_step"):
                result["next_step"] = "Everything looks good — no action needed."
            result["links"] = cloudflare_links(domain, zone_from_domain(domain))
            result["saved"] = bool(get_domain_row(domain))
            result["domains"] = list_domains()
            return self._send_json(result)

        row = save_domain(domain, service, note, bool(data.get("is_primary")))
        zone = row["zone"] or zone_from_domain(domain)
        check = (check_domain_with_cooldown(domain, row["service"], persist=True)
                 if data.get("check_now") else None)
        return self._send_json({
            "domain": row,
            "domains": list_domains(),
            "links": cloudflare_links(domain, zone),
            "tunnel": tunnel_snippets(domain, row["service"]),
            "check": check,
        })

    def _send_password_page(self, code, prefix=None, domain=None):

        # JSON-encode every interpolated value so the page can never be turned
        # into script injection, even if a future validator gets looser.
        prefix_path = f"{prefix}/" if prefix else ""
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
        route = urlparse(self.path).path
        base_domain = self._get_base_domain()

        if route in ("/api/domains", "/api/domains/verify", "/api/domains/check",
                     "/api/domains/delete", "/api/domains/primary"):
            return self._handle_domain_post(route)

        if self.path == "/api/shorten":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                url = data.get("url", "").strip()
                custom_domain = normalize_domain(data.get("domain", ""))
                custom_code = data.get("custom_code", "").strip()
                path_prefix = data.get("path_prefix", "").strip().lower()
                password = data.get("password", "").strip()
                expires = data.get("expires", "").strip()
            except:
                return self._send_json({"error": "Invalid JSON"}, 400)

            if not url:
                return self._send_json({"error": "URL is required"}, 400)
            # Only add https:// when there is no scheme at all. Blindly prefixing
            # turned "ftp://x" into "https://ftp://x" and stored it.
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
                return self._send_json({
                    "short_url": short, "code": code, "domain": existing_domain,
                    "path_prefix": existing_prefix,
                    "domain_advice": domain_advice(existing_domain or base_domain),
                })

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
                "path_prefix": path_prefix or None,
                "domain_advice": domain_advice(custom_domain or base_domain),
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
    print(f"🔢 Max links: {MAX_LINKS}")
    base_domain = get_domain_from_host(BASE_URL)
    if base_domain and "." in base_domain:
        links = cloudflare_links(base_domain, zone_from_domain(base_domain))
        print(f"🌐 Domain: {base_domain} → service {TUNNEL_SERVICE}")
        print(f"   Connect on Cloudflare: {links['tunnel_create']}")
        print(f"   DNS for the zone:       {links['zone_dns']}")
    else:
        print(f"🌐 No custom domain yet → {cloudflare_links('', '')['tunnel_create']}")
    server.serve_forever(poll_interval=0.2)
    server.server_close()

if __name__ == "__main__":
    main()
