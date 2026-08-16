#!/bin/bash
# Cloak.URL One-Click Installer
# Supports both Cloudflare Tunnel and Nginx
# URL format: domain.com/custom (path prefix)

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${BOLD}🔗  Cloak.URL Installer${NC}"
echo -e "${BLUE}    Private URL shortener — zero tracking, zero logs${NC}"
echo ""

# ───────────────────────────────────────────────
# 1. Auto-detect if running as root
# ───────────────────────────────────────────────
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# ───────────────────────────────────────────────
# 2. Choose deployment method (default: Cloudflare Tunnel)
# ───────────────────────────────────────────────
echo -e "${BOLD}🚀  Deployment Method${NC}"
echo -e "    ${CYAN}1) Cloudflare Tunnel${NC} — No open ports, works behind any router [Default]"
echo -e "    ${CYAN}2) Nginx${NC}            — Traditional reverse proxy"
echo ""
read -p "    Press Enter for Cloudflare Tunnel, or type 2 for Nginx: " deploy_method

METHOD="cloudflare"
if [ "$deploy_method" == "2" ]; then
    METHOD="nginx"
    echo -e "${GREEN}✅  Nginx selected${NC}"
else
    echo -e "${GREEN}✅  Cloudflare Tunnel selected${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 3. Port (default: 3000)
# ───────────────────────────────────────────────
echo -e "${BOLD}📡  Port${NC}"
read -p "    Press Enter for 3000, or type a port: " user_port
PORT="${user_port:-3000}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    PORT=3000
fi

echo -e "${GREEN}✅  Port: $PORT${NC}"
echo ""

# ───────────────────────────────────────────────
# 4. Database Location (NEW)
# ───────────────────────────────────────────────
echo -e "${BOLD}💾  Database Location${NC}"
echo "    Where should the SQLite database be stored?"
echo -e "    ${CYAN}1) Inside project folder${NC} — ./data/urls.db [Default, easy backup]"
echo -e "    ${CYAN}2) Docker volume${NC}       — Named volume, survives container deletion"
echo -e "    ${CYAN}3) Custom path${NC}         — e.g. /var/lib/cloak-url/data"
echo ""
read -p "    Press Enter for project folder, or type 2/3: " db_choice

DB_PATH="./data"
DB_VOLUME=""

if [ "$db_choice" == "2" ]; then
    DB_PATH="/app/data"
    DB_VOLUME="cloak-url-data"
    echo -e "${GREEN}✅  Docker volume: cloak-url-data${NC}"
elif [ "$db_choice" == "3" ]; then
    read -p "    Enter full path (e.g. /var/lib/cloak-url/data): " custom_db_path
    if [ -z "$custom_db_path" ]; then
        DB_PATH="./data"
        echo -e "${YELLOW}    Empty path, using default: ./data${NC}"
    else
        DB_PATH="$custom_db_path"
        $SUDO mkdir -p "$DB_PATH"
        echo -e "${GREEN}✅  Custom path: $DB_PATH${NC}"
    fi
else
    mkdir -p ./data
    echo -e "${GREEN}✅  Project folder: ./data${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 5. Cloudflare Tunnel Token (if method 1)
# ───────────────────────────────────────────────
TUNNEL_TOKEN=""

if [ "$METHOD" == "cloudflare" ]; then
    echo -e "${BOLD}🌐  Cloudflare Tunnel Token${NC}"
    echo -e "    Get one at: ${CYAN}https://one.dash.cloudflare.com → Networks → Tunnels → Create${NC}"
    echo ""
    read -p "    Paste token (or press Enter to skip): " tunnel_token
    if [ -z "$tunnel_token" ]; then
        tunnel_token="YOUR_TUNNEL_TOKEN_HERE"
        echo -e "${YELLOW}    ⚠️  Skipped. Edit .env later and add TUNNEL_TOKEN.${NC}"
    fi
    echo -e "${GREEN}✅  Token saved${NC}"
    echo ""
fi

# ───────────────────────────────────────────────
# 6. Domain (default: localhost)
# ───────────────────────────────────────────────
echo -e "${BOLD}🌐  Domain${NC}"
echo "    URL format: yourdomain.com/CODE"
read -p "    Enter domain (press Enter for localhost): " domain

BASE_URL="http://localhost:$PORT"
if [ -n "$domain" ]; then
    if [[ "$domain" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        BASE_URL="https://$domain"
        echo -e "${GREEN}✅  Domain: $domain${NC}"
    else
        echo -e "${RED}    ❌ Invalid domain. Using localhost.${NC}"
    fi
else
    echo -e "${YELLOW}    ℹ️  Using localhost${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 7. Install Docker (auto-detect)
# ───────────────────────────────────────────────
echo -e "${BOLD}🐳  Docker${NC}"

if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo -e "${GREEN}✅  Docker already installed${NC}"
else
    echo "    Installing Docker..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    echo -e "${GREEN}✅  Docker installed${NC}"
    echo -e "${YELLOW}    ⚠️  Log out and back in if this is your first Docker install.${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 8. Generate configs
# ───────────────────────────────────────────────
echo -e "${BOLD}📦  Generating configs...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# docker-compose.yml
if [ "$METHOD" == "cloudflare" ]; then
    if [ -n "$DB_VOLUME" ]; then
        cat > docker-compose.yml << EOF
version: "3.8"

services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - PORT=3000
      - BASE_URL=${BASE_URL}
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ${DB_VOLUME}:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${tunnel_token}
    networks:
      - cloak-net

volumes:
  ${DB_VOLUME}:

networks:
  cloak-net:
    driver: bridge
EOF
    else
        cat > docker-compose.yml << EOF
version: "3.8"

services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - PORT=3000
      - BASE_URL=${BASE_URL}
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ${DB_PATH}:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${tunnel_token}
    networks:
      - cloak-net

networks:
  cloak-net:
    driver: bridge
EOF
    fi
else
    # Nginx method
    if [ -n "$DB_VOLUME" ]; then
        cat > docker-compose.yml << EOF
version: "3.8"

services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - PORT=3000
      - BASE_URL=${BASE_URL}
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ${DB_VOLUME}:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

volumes:
  ${DB_VOLUME}:

networks:
  cloak-net:
    driver: bridge
EOF
    else
        cat > docker-compose.yml << EOF
version: "3.8"

services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - PORT=3000
      - BASE_URL=${BASE_URL}
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ${DB_PATH}:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

networks:
  cloak-net:
    driver: bridge
EOF
    fi
fi

# .env file
cat > .env << EOF
# Cloak.URL configuration
# Restart with: docker compose up -d

METHOD=${METHOD}
BASE_URL=${BASE_URL}
PORT=${PORT}
DB_PATH=${DB_PATH}
EOF

if [ "$METHOD" == "cloudflare" ]; then
    cat >> .env << EOF
TUNNEL_TOKEN=${tunnel_token}
EOF
fi

# Nginx configs
if [ "$METHOD" == "nginx" ] && [ -n "$domain" ]; then
    NGINX_DIR="$SCRIPT_DIR/nginx"
    mkdir -p "$NGINX_DIR"

    cat > "$NGINX_DIR/$domain.conf" << 'NGINX_EOF'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    location ~ ^/([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)$ {
        proxy_pass http://localhost:PORT_PLACEHOLDER/$1/$2;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ~ ^/([a-zA-Z0-9_-]+)$ {
        proxy_pass http://localhost:PORT_PLACEHOLDER/$1;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://localhost:PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_EOF
    sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" "$NGINX_DIR/$domain.conf"
    sed -i "s/PORT_PLACEHOLDER/$PORT/g" "$NGINX_DIR/$domain.conf"

    cat > "$NGINX_DIR/install-nginx.sh" << 'EOF'
#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then echo "Run as root or with sudo"; exit 1; fi
apt-get update -qq && apt-get install -y -qq nginx
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for conf in "$SCRIPT_DIR"/*.conf; do
    [ -e "$conf" ] || continue
    bn=$(basename "$conf")
    cp "$conf" "/etc/nginx/sites-available/$bn"
    ln -sf "/etc/nginx/sites-available/$bn" "/etc/nginx/sites-enabled/$bn"
done
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
echo "✅ Nginx ready. Run: sudo certbot --nginx  for HTTPS"
EOF
    chmod +x "$NGINX_DIR/install-nginx.sh"
fi

echo -e "${GREEN}✅  Configs generated${NC}"
echo ""

# ───────────────────────────────────────────────
# 9. Build & Start
# ───────────────────────────────────────────────
echo -e "${BOLD}🚀  Starting Cloak.URL...${NC}"

if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}❌ Docker Compose not found.${NC}"
    exit 1
fi

$COMPOSE_CMD down 2>/dev/null || true
$COMPOSE_CMD pull 2>/dev/null || true
$COMPOSE_CMD build --no-cache
$COMPOSE_CMD up -d

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  Cloak.URL is running!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}    URL:${NC}      $BASE_URL"
echo -e "${BOLD}    Method:${NC}    $METHOD"
echo -e "${BOLD}    DB:${NC}       $DB_PATH"
echo ""

if [ "$METHOD" == "cloudflare" ] && [ "$tunnel_token" != "YOUR_TUNNEL_TOKEN_HERE" ]; then
    echo -e "    ${YELLOW}Next:${NC} Add Public Hostname in Cloudflare Dashboard"
    echo -e "         $domain → http://cloak:3000"
elif [ "$METHOD" == "nginx" ]; then
    echo -e "    ${YELLOW}Next:${NC} sudo bash nginx/install-nginx.sh"
fi

echo ""
echo -e "${BOLD}Commands:${NC}"
echo -e "  logs:    ${BOLD}$COMPOSE_CMD logs -f${NC}"
echo -e "  stop:    ${BOLD}$COMPOSE_CMD down${NC}"
echo -e "  restart: ${BOLD}$COMPOSE_CMD restart${NC}"
echo -e "  config:  ${BOLD}nano .env && $COMPOSE_CMD up -d${NC}"
echo ""
echo -e "${BLUE}    Built for privacy. No analytics. No tracking. Just links.${NC}"
echo ""
