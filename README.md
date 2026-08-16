<p align="center">
  <img src="https://img.shields.io/badge/privacy-first-10b981?style=flat-square&logo=shield&logoColor=white" alt="Privacy First">
  <img src="https://img.shields.io/badge/zero-tracking-1a1a1a?style=flat-square" alt="Zero Tracking">
  <img src="https://img.shields.io/badge/docker-ready-2496ed?style=flat-square&logo=docker&logoColor=white" alt="Docker Ready">
  <img src="https://img.shields.io/badge/python-3.11+-3776ab?style=flat-square&logo=python&logoColor=white" alt="Python 3.11+">
</p>

<h1 align="center">🔗 cloak.link</h1>
<p align="center"><strong>Private, self-hosted URL shortener — zero tracking, zero logs, zero analytics.</strong></p>

<p align="center">
  <a href="#-one-command-install">Install</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-deployment-methods">Methods</a> ·
  <a href="#-api">API</a>
</p>

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🛡️ **Zero Tracking** | No IP logging, no User-Agent logging, no referer logging, no click counters |
| 🔒 **Password Protection** | Lock links behind a password — visitors must unlock before redirect |
| ⏱️ **Auto-Expiration** | Links self-destruct after 1 hour to 1 month |
| 🌐 **Custom Domains** | Brand your short links with your own domain |
| 🏷️ **Custom Codes** | Choose memorable slugs like `launch2026` |
| 📦 **Zero Dependencies** | Python stdlib only — no pip install |
| 🐳 **One-Command Deploy** | Interactive installer handles everything |
| 🌙 **Dark Mode** | Respects `prefers-color-scheme` |
| 📱 **Responsive** | Works on all devices |

---

## 🚀 One-Command Install

```bash
git clone https://github.com/yourusername/cloak.link.git
cd cloak.link
bash install.sh
```

The installer will ask:
1. **Deployment method** — Cloudflare Tunnel or Nginx
2. **Port** — Internal port (default `3000`)
3. **Cloudflare token** — (if Tunnel selected)
4. **Domain** — Add 1, then "add more?" up to 10 total

---

## 🌐 Deployment Methods

### Option 1: Cloudflare Tunnel ⭐ Recommended

**Best for:** Home servers, dynamic IPs, CGNAT, no port forwarding

- **No open ports** — outbound WebSocket tunnel only
- **No nginx** — Cloudflare handles TLS, DDoS, caching
- **No static IP** — works behind any router

**Setup:**
1. Run `bash install.sh` → select `1) Cloudflare Tunnel`
2. Paste your tunnel token from [one.dash.cloudflare.com](https://one.dash.cloudflare.com)
3. In Cloudflare dashboard → **Public Hostnames** → add `http://cloak:3000`

### Option 2: Nginx

**Best for:** VPS with static IP, full control, traditional stack

- **Port 80/443** exposed to internet
- **Nginx reverse proxy** handles routing
- **Let's Encrypt** for HTTPS

**Setup:**
1. Run `bash install.sh` → select `2) Nginx`
2. Point DNS A record to your server IP
3. Run `sudo bash nginx/install-nginx.sh`
4. (Optional) `sudo certbot --nginx` for HTTPS

---

## ⚙️ Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Internal port |
| `BASE_URL` | `http://localhost:3000` | Your public domain |
| `DB_PATH` | `/app/data/urls.db` | SQLite path |
| `MAX_LINKS` | `10000` | Hard cap on links |
| `TUNNEL_TOKEN` | — | Cloudflare token (Tunnel only) |

Edit `.env` and restart: `docker compose up -d`

---

## 🔌 API

```bash
curl -X POST https://go.yourdomain.com/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","password":"secret","expires":"24"}'
```

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/shorten` | POST | Create short link |
| `/api/urls` | GET | List links |
| `/api/stats` | GET | Link count & limit |

---

## 🛡️ Privacy Guarantees

```
❌ No IP logging
❌ No User-Agent logging
❌ No Referer logging
❌ No click counters
❌ No third-party scripts
❌ No cookies
❌ No external APIs
❌ No tracking pixels
```

---

## 📁 Project Structure

```
cloak.link/
├── app.py              # Backend (stdlib only)
├── index.html          # SPA frontend
├── Dockerfile
├── docker-compose.yml  # Docker config
├── install.sh          # Interactive installer
├── .env                # Your config (auto-generated)
├── nginx/              # Nginx configs (if nginx method)
│   ├── yourdomain.conf
│   └── install-nginx.sh
└── data/               # SQLite database
```

---

## 📝 License

MIT — use it, fork it, self-host it.

---

<p align="center">Built for privacy. No analytics. No tracking. Just links.</p>
