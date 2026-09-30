<p align="center">
  <img src="https://img.shields.io/badge/privacy-first-10b981?style=flat-square&logo=shield&logoColor=white" alt="Privacy First">
  <img src="https://img.shields.io/badge/zero-tracking-1a1a1a?style=flat-square" alt="Zero Tracking">
  <img src="https://img.shields.io/badge/docker-ready-2496ed?style=flat-square&logo=docker&logoColor=white" alt="Docker Ready">
  <img src="https://img.shields.io/badge/python-3.8+-3776ab?style=flat-square&logo=python&logoColor=white" alt="Python 3.8+">
</p>

<h1 align="center">🔗 Cloak.URL</h1>
<p align="center"><strong>Private, self-hosted URL shortener — zero tracking, zero logs, zero analytics.</strong></p>
<p align="center"><code>yourdomain.com/blog/code</code> not <code>blog.yourdomain.com/code</code></p>

---

## 🚀 Quick Install

### Option 1: Download ZIP (Recommended)

```bash
wget -q https://github.com/sarakmacbook/Cloak.URL/archive/refs/heads/main.zip -O cloak-url.zip
unzip -q cloak-url.zip
cd Cloak.URL-main
bash install.sh
```

### Option 2: Git Clone

```bash
git clone https://github.com/sarakmacbook/Cloak.URL.git
cd Cloak.URL
bash install.sh
```

### Option 3: No installer, no Docker — just run it

`app.py` uses **only the Python standard library**, so there is nothing to install:

```bash
python3 app.py            # → http://localhost:3000
```

Or with Docker, using the defaults that are already in the repo:

```bash
docker compose up -d --build    # → http://localhost:3000
```

The installer asks **5 questions** (all have defaults — just press Enter):

| # | Question | Default | What it does |
|---|----------|---------|--------------|
| 1 | **How should it run?** | `1` Docker + Tunnel | `2` = Nginx, `3` = Docker only, `4` = no Docker |
| 2 | **Port** | `3000` | Host port (the container always uses 3000) |
| 3 | **Database location** | `./data` | `2` = Docker volume, `3` = custom path |
| 4 | **Cloudflare token** | *(skip)* | Paste it to expose the app with no open ports |
| 5 | **Domain** | `localhost` | Your public domain, used to build short links |

### Non-interactive / scripted installs

Every answer can be passed as a flag (or an environment variable), so the
installer runs unattended in CI, Ansible, or a `curl | bash` one-liner:

```bash
bash install.sh -y                                            # all defaults
bash install.sh -y --port 8080 --domain links.example.com     # custom
bash install.sh -y --method nginx --domain mybrand.com --token "$CF_TOKEN"
bash install.sh --no-docker -y --port 3000                    # plain python3
bash install.sh --dry-run                                     # show the plan, change nothing
bash install.sh --help                                        # every option
```

If stdin is not a terminal, prompts never block — the installer falls back to
the defaults and says so.

---

## 🩺 Troubleshooting an install that fails

Run the installer again with `--verbose` to see every command it executes.
These are the failure modes that used to bite, and what to do about each:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `dependency failed to start: container ... is unhealthy` | The old healthcheck called `wget`, which does **not** exist in `python:3.11-slim` | Fixed — the healthcheck now uses Python. `docker compose up -d --build` |
| Script exits with no message at all | `set -e` + a `read` at EOF (piped/`curl \| bash`, or no TTY) | Fixed — prompts are TTY-safe. Or pass flags with `-y` |
| `apt-get: command not found` on macOS/Fedora/Arch | The old installer only knew Ubuntu's apt repo | Fixed — per-distro install, or `--no-docker` |
| `permission denied ... /var/run/docker.sock` | Your user isn't in the `docker` group yet | `sudo usermod -aG docker $USER`, log out and back in (the installer uses `sudo docker` automatically meanwhile) |
| `Cannot connect to the Docker daemon` | Docker isn't running | Start Docker Desktop (macOS/Windows) or `sudo systemctl start docker` |
| `address already in use` / port busy | Another service owns the port | `bash install.sh --port 8081` |
| `$'\r': command not found` | The script picked up Windows CRLF line endings | `sed -i 's/\r$//' install.sh` |
| `python3: command not found` | No Python 3.8+ | Install Python, or use the Docker path |
| Container restarts in a loop | The mounted DB directory isn't writable | `sudo chown -R $(id -u):$(id -g) ./data` (the app now prints this hint itself) |

Still stuck? These two commands produce everything needed to debug:

```bash
bash install.sh --verbose --dry-run
docker compose logs --tail=50
```

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
/var/lib/cloak-url/urls.db
/mnt/external-drive/cloak-url/urls.db
```
- **Pros:** Full control, can mount external drives, easy to back up
- **Cons:** You manage permissions
- **Best for:** Servers with dedicated storage, NAS, external drives

**Change later:** edit `DB_MOUNT` in `.env`, then `docker compose up -d`.

---

## 🌐 Deployment Methods

### Cloudflare Tunnel (Recommended)

No open ports. No static IP. Works behind any router.

```bash
bash install.sh
# → 1 (Docker + Cloudflare Tunnel)
# → Paste your Cloudflare token
# → Enter domain: mybrand.com
```

**Get token:** [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → Networks → Tunnels → Create → Docker → Copy token

**Add hostname:** In the Cloudflare dashboard → Public Hostname → `mybrand.com` → `http://cloak:3000`

> **Note:** Use container port `3000` for the tunnel, not your custom host port.

The tunnel only starts when it has a token: the installer sets
`COMPOSE_PROFILES=tunnel` in `.env`. No token → no tunnel container, and the
app still runs on `localhost`.

### Nginx

For a VPS with a static IP.

```bash
bash install.sh --method nginx --domain mybrand.com
sudo bash nginx/install-nginx.sh     # installs nginx + enables the site
sudo certbot --nginx -d mybrand.com  # optional HTTPS
```

**Point DNS:** `A  mybrand.com  YOUR_SERVER_IP`

The generated `nginx/install-nginx.sh` supports apt, dnf, yum, zypper, pacman
and apk, and writes to `sites-available/` or `conf.d/` depending on the layout.

### No Docker at all

`app.py` is pure standard library — Python 3.8+ and nothing else:

```bash
bash install.sh --no-docker --port 3000          # starts it, verifies it
bash install.sh --no-docker --systemd            # also writes cloak-url.service
```

Logs go to `cloak-url.log`, the pid to `.cloak-url.pid`, and
`bash install.sh --uninstall` stops it again.

---

## 📁 URL Examples

```
Simple:          mybrand.com/abc123
With prefix:     mybrand.com/blog/post-2026
With password:   mybrand.com/secret/doc
With expiration: mybrand.com/go/sale
Query kept:      mybrand.com/abc123?utm=news → destination?utm=news
```

---

## ⚙️ Configuration

All settings live in **`.env`** (generated by the installer, mode `600` because
it can hold your tunnel token). `docker-compose.yml` is static and reads it.

```bash
nano .env
docker compose up -d
```

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPOSE_PROJECT_NAME` | `cloak-url` | Stable container names, whatever the folder is called |
| `PORT` | `3000` | Host port |
| `BIND_ADDR` | `127.0.0.1` | `0.0.0.0` to expose it on your LAN |
| `BASE_URL` | `http://localhost:3000` | Used to build the short links the API returns |
| `MAX_LINKS` | `10000` | Link cap |
| `DB_MOUNT` | `./data` | `./data`, `cloak-data` (volume), or an absolute path |
| `DB_VOLUME_NAME` | `cloak-url-data` | Name of the Docker volume |
| `TUNNEL_TOKEN` | *(empty)* | Cloudflare tunnel token |
| `COMPOSE_PROFILES` | *(empty)* | `tunnel` to start the tunnel container |

There is a commented `.env.example` you can copy instead of running the
installer: `cp .env.example .env`.

---

## 🔌 API

```bash
# Create
curl -s https://mybrand.com/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","path_prefix":"blog","custom_code":"post-2026"}'

# Inspect
curl -s https://mybrand.com/api/stats     # {"status":"ok","total_links":1,"max_links":10000}
curl -s https://mybrand.com/api/health    # liveness probe
curl -s https://mybrand.com/api/urls      # 50 most recent

# Unlock a password-protected link
curl -s https://mybrand.com/api/unlock \
  -H 'Content-Type: application/json' \
  -d '{"code":"doc","password":"hunter2"}'
```

---

## 🛡️ Privacy

```
✓ No IP logging        ✓ No click counters
✓ No User-Agent logs   ✓ No third-party scripts
✓ No Referer logs      ✓ No cookies
✓ No analytics         ✓ No external APIs
✓ No request logs      ✓ .env is chmod 600
```

The HTTP server overrides `log_message()` to a no-op, so nothing about your
visitors is ever written down — not even to stdout.

---

## 📝 License

MIT — free to use, modify, and self-host.

---

<p align="center">Built for privacy. No analytics. No tracking. Just links.</p>
