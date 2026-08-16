#!/bin/bash
# Cloak.URL One-Click Installer
set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

echo ""
echo -e "${BOLD}🔗  Cloak.URL Installer${NC}"
echo -e "${BLUE}    Private URL shortener — zero tracking, zero logs${NC}"
echo ""

SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# ── Deployment Method ──
echo -e "${BOLD}🚀  Deployment Method${NC}"
echo -e "    ${CYAN}1) Cloudflare Tunnel${NC} — No open ports [Default]"
echo -e "    ${CYAN}2) Nginx${NC}            — Traditional reverse proxy"
echo ""
read -p "    Press Enter for Tunnel, or type 2 for Nginx: " deploy_method

METHOD="cloudflare"
if [ "$deploy_method" == "2" ]; then
    METHOD="nginx"
    echo -e "${GREEN}    ✓ Nginx${NC}"
else
    echo -e "${GREEN}    ✓ Cloudflare Tunnel${NC}"
fi
echo ""

# ── Port ──
echo -e "${BOLD}📡  Port${NC}"
read -p "    Press Enter for 3000, or type a port: " user_port
PORT="${user_port:-3000}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    PORT=3000
fi
echo -e "${GREEN}    ✓ $PORT${NC}"
echo ""

# ── Database Location ──
echo -e "${BOLD}💾  Database Location${NC}"
echo "    1) ./data              [Default — easy backup]"
echo "    2) Docker volume       [Survives container deletion]"
echo "    3) Custom path         [e.g. /var/lib/...]"
echo ""
read -p "    Press Enter for ./data, or type 2/3: " db_choice

DB_HOST_PATH="./data"
DB_VOLUME=""
USE_DOCKER_VOLUME=false

if [ "$db_choice" == "2" ]; then
    DB_HOST_PATH="cloak-url-data"
    DB_VOLUME="cloak-url-data"
    USE_DOCKER_VOLUME=true
    echo -e "${GREEN}    ✓ Docker volume${NC}"
elif [ "$db_choice" == "3" ]; then
    read -p "    Enter directory path (not file path): " custom_db_path
    if [ -n "$custom_db_path" ]; then
        DB_HOST_PATH="$custom_db_path"
        $SUDO mkdir -p "$DB_HOST_PATH" 2>/dev/null || true
        echo -e "${GREEN}    ✓ $DB_HOST_PATH${NC}"
    else
        mkdir -p ./data
        echo -e "${GREEN}    ✓ ./data${NC}"
    fi
else
    mkdir -p ./data
    echo -e "${GREEN}    ✓ ./data${NC}"
fi
echo ""

# ── Cloudflare Token ──
TUNNEL_TOKEN=""
if [ "$METHOD" == "cloudflare" ]; then
    echo -e "${BOLD}🌐  Cloudflare Token${NC}"
    echo -e "    ${DIM}Get one at: one.dash.cloudflare.com → Networks → Tunnels → Create${NC}"
    echo ""
    read -p "    Paste token (or Enter to skip): " tunnel_token
    if [ -z "$tunnel_token" ]; then
        TUNNEL_TOKEN=""
        echo -e "${YELLOW}    ⚠ Skipped — tunnel will not start${NC}"
    else
        TUNNEL_TOKEN="$tunnel_token"
        echo -e "${GREEN}    ✓ Token saved${NC}"
    fi
    echo ""
fi

# ── Domain ──
echo -e "${BOLD}🌐  Domain${NC}"
read -p "    Enter domain (or Enter for localhost): " domain

BASE_URL="http://localhost:$PORT"
if [ -n "$domain" ]; then
    if [[ "$domain" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        BASE_URL="https://$domain"
        echo -e "${GREEN}    ✓ $domain${NC}"
    else
        echo -e "${RED}    ✗ Invalid — using localhost${NC}"
    fi
else
    echo -e "${YELLOW}    ℹ localhost${NC}"
fi
echo ""

# ── Install Docker ──
echo -e "${BOLD}🐳  Docker${NC}"

if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo -e "${GREEN}    ✓ Already installed${NC}"
else
    echo "    Installing..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    echo -e "${GREEN}    ✓ Installed${NC}"
    echo -e "${YELLOW}    ⚠ Log out and back in if this is your first Docker install${NC}"
fi
echo ""

# ── Generate Configs ──
echo -e "${BOLD}📦  Generating configs...${NC}"

WORK_DIR="$(pwd)"

# Generate docker-compose.yml
if [ "$METHOD" == "cloudflare" ] && [ -n "$TUNNEL_TOKEN" ]; then
    # With tunnel
    if [ "$USE_DOCKER_VOLUME" = true ]; then
        cat > docker-compose.yml << EOF
services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:$PORT:3000"
    environment:
      - PORT=3000
      - BASE_URL=$BASE_URL
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - $DB_VOLUME:/app/data
    restart: unless-stopped
    networks:
      - cloak-net
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/stats"]
      interval: 30s
      timeout: 10s
      retries: 3

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=$TUNNEL_TOKEN
    networks:
      - cloak-net
    depends_on:
      cloak:
        condition: service_healthy

volumes:
  $DB_VOLUME:

networks:
  cloak-net:
    driver: bridge
EOF
    else
        cat > docker-compose.yml << EOF
services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:$PORT:3000"
    environment:
      - PORT=3000
      - BASE_URL=$BASE_URL
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - $DB_HOST_PATH:/app/data
    restart: unless-stopped
    networks:
      - cloak-net
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/stats"]
      interval: 30s
      timeout: 10s
      retries: 3

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=$TUNNEL_TOKEN
    networks:
      - cloak-net
    depends_on:
      cloak:
        condition: service_healthy

networks:
  cloak-net:
    driver: bridge
EOF
    fi
else
    # Without tunnel (nginx or no tunnel token)
    if [ "$USE_DOCKER_VOLUME" = true ]; then
        cat > docker-compose.yml << EOF
services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:$PORT:3000"
    environment:
      - PORT=3000
      - BASE_URL=$BASE_URL
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - $DB_VOLUME:/app/data
    restart: unless-stopped
    networks:
      - cloak-net
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/stats"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  $DB_VOLUME:

networks:
  cloak-net:
    driver: bridge
EOF
    else
        cat > docker-compose.yml << EOF
services:
  cloak:
    build: .
    ports:
      - "127.0.0.1:$PORT:3000"
    environment:
      - PORT=3000
      - BASE_URL=$BASE_URL
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - $DB_HOST_PATH:/app/data
    restart: unless-stopped
    networks:
      - cloak-net
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/stats"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  cloak-net:
    driver: bridge
EOF
    fi
fi

# Nginx configs
if [ "$METHOD" == "nginx" ] && [ -n "$domain" ]; then
    NGINX_DIR="$WORK_DIR/nginx"
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
echo "✅ Nginx ready. Run: sudo certbot --nginx for HTTPS"
EOF
    chmod +x "$NGINX_DIR/install-nginx.sh"
fi

echo -e "${GREEN}    ✓ Done${NC}"
echo ""

# ── Build & Start ──
echo -e "${BOLD}🚀  Starting Cloak.URL...${NC}"

if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

cd "$WORK_DIR"

# Stop old containers gracefully
$COMPOSE_CMD down 2>/dev/null || true

# Build and start
$COMPOSE_CMD build --no-cache
$COMPOSE_CMD up -d

# Wait for healthcheck
echo ""
echo -e "${BOLD}⏳  Waiting for service to start...${NC}"
sleep 3

# Check if cloak is running
if docker ps | grep -q "cloak"; then
    echo -e "${GREEN}    ✓ Cloak container is running${NC}"
else
    echo -e "${RED}    ✗ Cloak container failed to start${NC}"
    echo -e "    ${DIM}Run: $COMPOSE_CMD logs cloak${NC}"
fi

# Check if tunnel is running (if applicable)
if [ "$METHOD" == "cloudflare" ] && [ -n "$TUNNEL_TOKEN" ]; then
    if docker ps | grep -q "tunnel"; then
        echo -e "${GREEN}    ✓ Tunnel container is running${NC}"
    else
        echo -e "${YELLOW}    ⚠ Tunnel container is not running${NC}"
        echo -e "    ${DIM}Run: $COMPOSE_CMD logs tunnel${NC}"
    fi
fi

echo ""

# ── FINAL OUTPUT ──
echo -e "${GREEN}┌────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  ✅  Cloak.URL is running              │${NC}"
echo -e "${GREEN}└────────────────────────────────────────┘${NC}"
echo ""

printf "  ${BOLD}%-14s${NC} %s\n" "URL:" "$BASE_URL"
printf "  ${BOLD}%-14s${NC} %s\n" "Method:" "$METHOD"
printf "  ${BOLD}%-14s${NC} %s\n" "Host Port:" "$PORT"
printf "  ${BOLD}%-14s${NC} %s\n" "Container Port:" "3000"
printf "  ${BOLD}%-14s${NC} %s\n" "Host DB:" "$DB_HOST_PATH"
printf "  ${BOLD}%-14s${NC} %s\n" "Container DB:" "/app/data/urls.db"
echo ""

if [ "$METHOD" == "cloudflare" ] && [ -n "$TUNNEL_TOKEN" ] && [ -n "$domain" ]; then
    echo -e "  ${YELLOW}Cloudflare Tunnel Setup:${NC}"
    echo -e "    Dashboard → Networks → Tunnels → Your Tunnel"
    echo -e "    Add hostname: ${BOLD}$domain${NC} → ${BOLD}http://cloak:3000${NC}"
    echo ""
elif [ "$METHOD" == "cloudflare" ] && [ -z "$TUNNEL_TOKEN" ]; then
    echo -e "  ${YELLOW}⚠️  No Cloudflare token set${NC}"
    echo -e "    Your app is running on http://localhost:$PORT only."
    echo -e "    To add a tunnel later, edit docker-compose.yml and restart."
    echo ""
elif [ "$METHOD" == "nginx" ] && [ -n "$domain" ]; then
    echo -e "  ${YELLOW}Next step:${NC}"
    echo -e "    ${BOLD}sudo bash nginx/install-nginx.sh${NC}"
    echo ""
fi

echo -e "  ${BOLD}Commands:${NC}"
echo -e "    ${BOLD}logs${NC}     cd "$WORK_DIR" && $COMPOSE_CMD logs -f"
echo -e "    ${BOLD}stop${NC}     cd "$WORK_DIR" && $COMPOSE_CMD down"
echo -e "    ${BOLD}restart${NC}  cd "$WORK_DIR" && $COMPOSE_CMD restart"
echo -e "    ${BOLD}config${NC}   edit docker-compose.yml && cd "$WORK_DIR" && $COMPOSE_CMD up -d"
echo ""

echo -e "  ${DIM}Built for privacy. No analytics. No tracking. Just links.${NC}"
echo ""
