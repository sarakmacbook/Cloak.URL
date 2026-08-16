<p align="center">
  <img src="https://img.shields.io/badge/privacy-first-10b981?style=flat-square&logo=shield&logoColor=white" alt="Privacy First">
  <img src="https://img.shields.io/badge/zero-tracking-1a1a1a?style=flat-square" alt="Zero Tracking">
  <img src="https://img.shields.io/badge/docker-ready-2496ed?style=flat-square&logo=docker&logoColor=white" alt="Docker Ready">
  <img src="https://img.shields.io/badge/python-3.11+-3776ab?style=flat-square&logo=python&logoColor=white" alt="Python 3.11+">
</p>

<h1 align="center">🔗 Cloak.URL</h1>
<p align="center"><strong>Private, self-hosted URL shortener — zero tracking, zero logs, zero analytics.</strong></p>
<p align="center"><code>yourdomain.com/blog/code</code> not <code>blog.yourdomain.com/code</code></p>

---

## 🚀 One-Click Install

```bash
# Download
curl -fsSL https://raw.githubusercontent.com/you/Cloak.URL/main/install.sh -o install.sh
bash install.sh
```

Or clone and run:

```bash
git clone https://github.com/yourusername/Cloak.URL.git
cd Cloak.URL
bash install.sh
```

The installer asks **3 questions** (all have defaults):

| Question | Default | What it does |
|----------|---------|--------------|
| **Deployment method** | Cloudflare Tunnel | `1` = Tunnel (no open ports), `2` = Nginx |
| **Port** | `3000` | Internal Docker port |
| **Database location** | `./data` | Where SQLite DB lives |
| **Domain** | `localhost` | Your public domain |

Press **Enter** to accept defaults. Done in 30 seconds.

---

## 💾 Database Location Options

During install, pick where your SQLite database lives:

### Option 1: Project Folder (Default)
```
./data/urls.db
```
- **Pros:** Easy to backup, visible files, portable
- **Cons:** Deleted if you delete the project folder
- **Best for:** Development, small deployments

### Option 2: Docker Volume
```
Docker named volume: cloak-url-data
```
- **Pros:** Survives container deletion, managed by Docker
- **Cons:** Hidden path, harder to backup manually
- **Best for:** Production, automated backups

### Option 3: Custom Path
```
/var/lib/cloak-url/data/urls.db
/mnt/external-drive/cloak-url/data/urls.db
```
- **Pros:** Full control, can mount external drives, easy to back up
- **Cons:** You manage permissions
- **Best for:** Servers with dedicated storage, NAS, external drives

**Change later:** Edit `docker-compose.yml` → `volumes:` section, then `docker compose up -d`.

---

## 🌐 Deployment Methods

### Cloudflare Tunnel (Recommended)

No open ports. No static IP. Works behind any router.

```bash
bash install.sh
# → Press Enter (selects Cloudflare Tunnel)
# → Paste your Cloudflare token
# → Enter domain: mybrand.com
```

**Get token:** [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → Networks → Tunnels → Create → Docker → Copy token

**Add hostname:** In Cloudflare dashboard → Public Hostname → `mybrand.com` → `http://cloak:3000`

### Nginx

For VPS with static IP.

```bash
bash install.sh
# → Type 2 (selects Nginx)
# → Enter domain: mybrand.com
# → sudo bash nginx/install-nginx.sh
# → sudo certbot --nginx  # optional HTTPS
```

**Point DNS:** `A  mybrand.com  YOUR_SERVER_IP`

---

## 📁 URL Examples

```
Simple:          mybrand.com/abc123
With prefix:     mybrand.com/blog/post-2026
With password:   mybrand.com/secret/doc
With expiration: mybrand.com/go/sale
```

---

## ⚙️ Configuration

Edit `.env` and restart:

```bash
nano .env
docker compose up -d
```

| Variable | Default | Description |
|----------|---------|-------------|
| `METHOD` | `cloudflare` | `cloudflare` or `nginx` |
| `BASE_URL` | `http://localhost:3000` | Your domain |
| `PORT` | `3000` | Internal port |
| `DB_PATH` | `./data` | Database location |
| `TUNNEL_TOKEN` | — | Cloudflare token |

---

## 🔌 API

```bash
curl -X POST https://mybrand.com/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","path_prefix":"blog","custom_code":"post-2026"}'
```

---

## 🛡️ Privacy

```
✓ No IP logging        ✓ No click counters
✓ No User-Agent logs   ✓ No third-party scripts
✓ No Referer logs      ✓ No cookies
✓ No analytics         ✓ No external APIs
```

---

## 📝 License

MIT — free to use, modify, and self-host.

---

<p align="center">Built for privacy. No analytics. No tracking. Just links.</p>
