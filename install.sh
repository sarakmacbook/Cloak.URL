#!/bin/bash
# cloak.link Interactive Installer
# Supports custom port + up to 10 optional domains

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo ""
echo -e "${BOLD}🔗  Welcome to cloak.link installer${NC}"
echo -e "${BLUE}    Private URL shortener — zero tracking, zero logs${NC}"
echo ""

# ───────────────────────────────────────────────
# 1. Check if running as root (warn but don't exit)
# ───────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
   echo -e "${YELLOW}⚠️  Warning: Running as root. It's recommended to run as a regular user with sudo access.${NC}"
   read -p "Continue anyway? [y/N]: " root_continue
   if [[ ! "$root_continue" =~ ^[Yy]$ ]]; then
       exit 1
   fi
fi

# ───────────────────────────────────────────────
# 2. Select Port
# ───────────────────────────────────────────────
echo -e "${BOLD}📡  Step 1: Choose your port${NC}"
echo "    Default: 3000"
read -p "    Enter port number (press Enter for 3000): " user_port

PORT="${user_port:-3000}"

# Validate port is a number between 1-65535
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}❌ Invalid port. Using default 3000.${NC}"
    PORT=3000
fi

# Check if port is already in use
if command -v ss &> /dev/null && ss -tlnp | grep -q ":$PORT "; then
    echo -e "${YELLOW}⚠️  Port $PORT is already in use.${NC}"
    read -p "    Continue anyway? [y/N]: " port_continue
    if [[ ! "$port_continue" =~ ^[Yy]$ ]]; then
        exit 1
    fi
elif command -v netstat &> /dev/null && netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
    echo -e "${YELLOW}⚠️  Port $PORT is already in use.${NC}"
    read -p "    Continue anyway? [y/N]: " port_continue
    if [[ ! "$port_continue" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}✅  Port set to: $PORT${NC}"
echo ""

# ───────────────────────────────────────────────
# 3. Domain Setup (Optional)
# ───────────────────────────────────────────────
echo -e "${BOLD}🌐  Step 2: Custom Domains (Optional)${NC}"
echo "    You can add up to 10 custom domains."
echo "    Press Enter to skip and use localhost only."
echo ""

DOMAINS=()
BASE_URL="http://localhost:$PORT"
NGINX_CONFIGS=()

for i in $(seq 1 10); do
    read -p "    Domain $i (or press Enter to finish): " domain

    if [ -z "$domain" ]; then
        break
    fi

    # Basic domain validation
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        echo -e "${RED}    ❌ Invalid domain format. Skipping.${NC}"
        continue
    fi

    DOMAINS+=("$domain")

    if [ "$i" -eq 1 ]; then
        BASE_URL="https://$domain"
        echo -e "${GREEN}    ✅ Primary domain set: $domain${NC}"
    else
        echo -e "${GREEN}    ✅ Additional domain: $domain${NC}"
    fi
done

if [ ${#DOMAINS[@]} -eq 0 ]; then
    echo -e "${YELLOW}    ℹ️  No custom domains configured. Using localhost.${NC}"
else
    echo ""
    echo -e "${BOLD}    Configured domains:${NC}"
    for d in "${DOMAINS[@]}"; do
        echo -e "      • $d"
    done
fi
echo ""

# ───────────────────────────────────────────────
# 4. Install Docker & Docker Compose if needed
# ───────────────────────────────────────────────
echo -e "${BOLD}🐳  Step 3: Installing Docker${NC}"

if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    echo -e "${GREEN}✅  Docker & Docker Compose already installed${NC}"
else
    echo "    Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    sudo usermod -aG docker "$USER" 2>/dev/null || true

    echo -e "${GREEN}✅  Docker installed${NC}"
    echo -e "${YELLOW}⚠️  You may need to log out and back in for docker group changes to take effect.${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 5. Create docker-compose.yml
# ───────────────────────────────────────────────
echo -e "${BOLD}📦  Step 4: Generating config files${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Backup existing docker-compose.yml if present
if [ -f docker-compose.yml ]; then
    cp docker-compose.yml "docker-compose.yml.backup.$(date +%s)"
    echo "    Backed up existing docker-compose.yml"
fi

cat > docker-compose.yml << EOF
version: "3.8"

services:
  cloak:
    build: .
    ports:
      - "${PORT}:3000"
    environment:
      - PORT=3000
      - BASE_URL=${BASE_URL}
      - DB_PATH=/app/data/urls.db
      - MAX_LINKS=10000
    volumes:
      - ./data:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

networks:
  cloak-net:
    driver: bridge
EOF

echo -e "${GREEN}✅  docker-compose.yml created${NC}"

# ───────────────────────────────────────────────
# 6. Generate Nginx configs if domains were set
# ───────────────────────────────────────────────
if [ ${#DOMAINS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}🌐  Step 5: Generating Nginx configs${NC}"

    NGINX_DIR="$SCRIPT_DIR/nginx"
    mkdir -p "$NGINX_DIR"

    for domain in "${DOMAINS[@]}"; do
        cat > "$NGINX_DIR/$domain.conf" << 'NGINX_EOF'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

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
        # Replace placeholders
        sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" "$NGINX_DIR/$domain.conf"
        sed -i "s/PORT_PLACEHOLDER/$PORT/g" "$NGINX_DIR/$domain.conf"
        echo -e "    ${GREEN}✅${NC} nginx/$domain.conf"
    done

    # Create install script for nginx
    cat > "$NGINX_DIR/install-nginx.sh" << 'EOF'
#!/bin/bash
# Run this after pointing your DNS to this server

set -e

if [ "$EUID" -ne 0 ]; then
   echo "Please run as root or with sudo"
   exit 1
fi

echo "Installing Nginx..."
apt-get update -qq
apt-get install -y -qq nginx

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for conf in "$SCRIPT_DIR"/*.conf; do
    [ -e "$conf" ] || continue
    basename_conf=$(basename "$conf")
    cp "$conf" "/etc/nginx/sites-available/$basename_conf"
    ln -sf "/etc/nginx/sites-available/$basename_conf" "/etc/nginx/sites-enabled/$basename_conf"
    echo "Enabled: $basename_conf"
done

# Remove default site if it exists
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx

echo ""
echo "✅ Nginx configured!"
echo ""
echo "To enable HTTPS with Let's Encrypt, run:"
echo "  sudo apt install certbot python3-certbot-nginx -y"
echo "  sudo certbot --nginx"
EOF
    chmod +x "$NGINX_DIR/install-nginx.sh"

    echo ""
    echo -e "    ${YELLOW}📋 Next steps for domains:${NC}"
    echo -e "       1. Point DNS A records to this server's IP"
    echo -e "       2. Run: ${BOLD}sudo bash nginx/install-nginx.sh${NC}"
    echo -e "       3. (Optional) Enable HTTPS: ${BOLD}sudo certbot --nginx${NC}"
fi

# ───────────────────────────────────────────────
# 7. Build & Start
# ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}🚀  Step 6: Building & Starting cloak.link${NC}"

# Try to use docker compose (plugin) or fall back to docker-compose
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}❌ Docker Compose not found. Please install it first.${NC}"
    exit 1
fi

$COMPOSE_CMD down 2>/dev/null || true
$COMPOSE_CMD build --no-cache
$COMPOSE_CMD up -d

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  cloak.link is running!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}    Local URL:${NC}     http://localhost:$PORT"

if [ ${#DOMAINS[@]} -gt 0 ]; then
    echo -e "${BOLD}    Public URL:${NC}    $BASE_URL"
    echo ""
    echo -e "    ${YELLOW}Don't forget to point DNS to this server!${NC}"
fi

echo ""
echo -e "${BOLD}    Useful commands:${NC}"
echo -e "      View logs:     ${BOLD}$COMPOSE_CMD logs -f${NC}"
echo -e "      Stop:          ${BOLD}$COMPOSE_CMD down${NC}"
echo -e "      Restart:       ${BOLD}$COMPOSE_CMD restart${NC}"
echo -e "      Update:        ${BOLD}git pull && $COMPOSE_CMD up -d --build${NC}"
echo ""
echo -e "${BLUE}    Built for privacy. No analytics. No tracking. Just links.${NC}"
echo ""
