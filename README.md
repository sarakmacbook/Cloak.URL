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
  <a href="#-manual-install">Manual</a> ·
  <a href="#-custom-domains">Domains</a> ·
  <a href="#-api">API</a>
</p>

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🛡️ **Zero Tracking** | No IP logging, no User-Agent logging, no referer logging, no click counters |
| 🔒 **Password Protection** | Lock links behind a password — visitors must unlock before redirect |
| ⏱️ **Auto-Expiration** | Links self-destruct after 1 hour to 1 month — no ghost data remains |
| 🌐 **Custom Domains** | Brand your short links with up to 10 domains |
| 🏷️ **Custom Codes** | Choose memorable slugs like `launch2026` instead of random hashes |
| 📦 **Zero Dependencies** | Python stdlib only — no pip install, no external packages |
| 🐳 **One-Command Deploy** | Interactive installer handles everything |
| 🌙 **Dark Mode** | Respects `prefers-color-scheme` automatically |
| 📱 **Responsive** | Works on mobile, tablet, and desktop |

---

## 🚀 One-Command Install (Ubuntu)

```bash
# 1. Clone the repo
git clone https://github.com/yourusername/cloak.link.git
cd cloak.link

# 2. Run the interactive installer
bash install.sh
```

The installer will ask you:
1. **Which port?** — Default is `3000`, enter any valid port
2. **Custom domains?** — Optional, add up to 10 (press Enter to skip)

That's it. Docker, config files, and nginx are all handled automatically.

### Example Install Flow

```
🔗  Welcome to cloak.link installer
    Private URL shortener — zero tracking, zero logs

📡  Step 1: Choose your port
    Default: 3000
    Enter port number (press Enter for 3000): 8080
✅  Port set to: 8080

🌐  Step 2: Custom Domains (Optional)
    You can add up to 10 custom domains.
    Press Enter to skip and use localhost only.

    Domain 1 (or press Enter to finish): go.mybrand.com
✅  Primary domain set: go.mybrand.com
    Domain 2 (or press Enter to finish): s.mybrand.com
✅  Additional domain: s.mybrand.com
    Domain 3 (or press Enter to finish):

    Configured domains:
      • go.mybrand.com
      • s.mybrand.com

🐳  Step 3: Installing Docker
✅  Docker & Docker Compose already installed

📦  Step 4: Generating config files
✅  docker-compose.yml created

🌐  Step 5: Generating Nginx configs
✅  nginx/go.mybrand.com.conf
✅  nginx/s.mybrand.com.conf

    📋 Next steps for domains:
       1. Point DNS A records to this server's IP
       2. Run: sudo bash nginx/install-nginx.sh
       3. (Optional) Enable HTTPS: sudo certbot --nginx

🚀  Step 6: Building & Starting cloak.link
...

═══════════════════════════════════════════════════
  ✅  cloak.link is running!
═══════════════════════════════════════════════════

    Local URL:     http://localhost:8080
    Public URL:    https://go.mybrand.com

    Don't forget to point DNS to this server!

    Useful commands:
      View logs:     docker compose logs -f
      Stop:          docker compose down
      Restart:       docker compose restart
      Update:        git pull && docker compose up -d --build

    Built for privacy. No analytics. No tracking. Just links.
```

---

## 🐧 Manual Install (Ubuntu)

If you prefer to set things up manually:

### 1. Install Docker & Docker Compose

```bash
sudo apt update && sudo apt install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
sudo usermod -aG docker $USER
newgrp docker
```

### 2. Configure & Run

```bash
# Edit docker-compose.yml with your settings
#   - Change port mapping (default: "3000:3000")
#   - Set BASE_URL to your domain
#   - Adjust MAX_LINKS if needed

nano docker-compose.yml
docker compose up -d
```

---

## 🌐 Custom Domains

### DNS Setup

Point an A record from your domain to your server's IP:

```
Type    Name              Value
A       go.yourbrand.com  YOUR_SERVER_IP
```

### Nginx Reverse Proxy

If you used the installer, configs are already in `nginx/`. Just run:

```bash
sudo bash nginx/install-nginx.sh
```

Or manually:

```bash
sudo apt install nginx -y
```

Create `/etc/nginx/sites-available/cloak.link`:

```nginx
server {
    listen 80;
    server_name go.yourbrand.com;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable:

```bash
sudo ln -s /etc/nginx/sites-available/cloak.link /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

### HTTPS with Let's Encrypt

```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d go.yourbrand.com
```

---

## ⚙️ Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server port inside container |
| `BASE_URL` | `http://localhost:3000` | Your main domain |
| `DB_PATH` | `/app/data/urls.db` | SQLite database path |
| `MAX_LINKS` | `10000` | Hard cap on total links |

The installer generates `docker-compose.yml` automatically, but you can edit it anytime:

```yaml
services:
  cloak:
    build: .
    ports:
      - "8080:3000"          # Host port : Container port
    environment:
      - PORT=3000
      - BASE_URL=https://go.mybrand.com
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```

---

## 🔌 API

### Create a short link

```bash
curl -X POST http://localhost:3000/api/shorten   -H "Content-Type: application/json"   -d '{
    "url": "https://example.com/very/long/path",
    "custom_code": "launch",
    "domain": "go.mybrand.com",
    "password": "secret123",
    "expires": "24"
  }'
```

**Response:**

```json
{
  "short_url": "https://go.mybrand.com/launch",
  "code": "launch",
  "domain": "go.mybrand.com"
}
```

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/shorten` | POST | Create a short link |
| `/api/urls` | GET | List your links |
| `/api/stats` | GET | Link count & limit |

---

## 🛡️ Privacy Guarantees

```
❌ No IP address logging
❌ No User-Agent logging
❌ No Referer logging
❌ No click analytics or counters
❌ No third-party scripts
❌ No cookies
❌ No external APIs
❌ No tracking pixels
```

---

## 📁 Project Structure

```
cloak.link/
├── app.py              # Python backend (stdlib only)
├── index.html          # Privacy-first SPA frontend
├── Dockerfile          # Alpine Python container
├── docker-compose.yml  # Docker Compose config (auto-generated)
├── install.sh          # Interactive installer
├── nginx/              # Nginx configs (auto-generated if domains set)
│   ├── go.mybrand.com.conf
│   ├── s.mybrand.com.conf
│   └── install-nginx.sh
└── data/               # SQLite database (persistent volume)
```

---

## 🧪 Development (no Docker)

```bash
python3 app.py
# Requires Python 3.11+
```

---

## 📝 License

MIT — use it, fork it, self-host it.

---

<p align="center">
  Built for privacy. No analytics. No tracking. Just links.
</p>
