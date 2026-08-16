#!/bin/bash
# cloak.link Interactive Installer
# Supports both nginx and Cloudflare Tunnel methods

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${BOLD}🔗  Welcome to cloak.link installer${NC}"
echo -e "${BLUE}    Private URL shortener — zero tracking, zero logs${NC}"
echo ""

# ───────────────────────────────────────────────
# 1. Check if running as root
# ───────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
   echo -e "${YELLOW}⚠️  Warning: Running as root. It's recommended to run as a regular user with sudo access.${NC}"
   read -p "Continue anyway? [y/N]: " root_continue
   if [[ ! "$root_continue" =~ ^[Yy]$ ]]; then
       exit 1
   fi
fi

# ───────────────────────────────────────────────
# 2. Choose deployment method
# ───────────────────────────────────────────────
echo -e "${BOLD}🚀  Step 1: Choose your deployment method${NC}"
echo ""
echo -e "    ${CYAN}1) Cloudflare Tunnel${NC} — No open ports, no nginx, works behind CGNAT"
echo -e "    ${CYAN}2) Nginx${NC}            — Traditional reverse proxy, requires port 80/443"
echo ""

while true; do
    read -p "    Enter 1 or 2: " deploy_method
    if [ "$deploy_method" == "1" ] || [ "$deploy_method" == "2" ]; then
        break
    fi
    echo -e "${RED}    ❌ Please enter 1 or 2.${NC}"
done

if [ "$deploy_method" == "1" ]; then
    METHOD="cloudflare"
    echo -e "${GREEN}✅  Cloudflare Tunnel selected${NC}"
else
    METHOD="nginx"
    echo -e "${GREEN}✅  Nginx selected${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 3. Select Port
# ───────────────────────────────────────────────
echo -e "${BOLD}📡  Step 2: Choose your port${NC}"
echo "    Default: 3000"
read -p "    Enter port number (press Enter for 3000): " user_port

PORT="${user_port:-3000}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}❌ Invalid port. Using default 3000.${NC}"
    PORT=3000
fi

# Check if port is already in use (only for nginx method, cloudflare uses localhost)
if [ "$METHOD" == "nginx" ]; then
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
fi

echo -e "${GREEN}✅  Port set to: $PORT${NC}"
echo ""

# ───────────────────────────────────────────────
# 4. Cloudflare Tunnel Token (if method 1)
# ───────────────────────────────────────────────
TUNNEL_TOKEN=""

if [ "$METHOD" == "cloudflare" ]; then
    echo -e "${BOLD}🌐  Step 3: Cloudflare Tunnel Setup${NC}"
    echo ""
    echo -e "    ${CYAN}Before continuing, create a Cloudflare Tunnel:${NC}"
    echo ""
    echo -e "    1. Go to ${BOLD}https://one.dash.cloudflare.com${NC}"
    echo -e "    2. Navigate to ${BOLD}Networks > Tunnels${NC}"
    echo -e "    3. Click ${BOLD}Create a tunnel${NC}"
    echo -e "    4. Name it (e.g., 'cloak-link')"
    echo -e "    5. Choose ${BOLD}Docker${NC} as environment"
    echo -e "    6. Copy the ${BOLD}TUNNEL TOKEN${NC}"
    echo ""

    read -p "    Paste your Cloudflare Tunnel token: " tunnel_token

    if [ -z "$tunnel_token" ]; then
        echo -e "${YELLOW}⚠️  No token provided. You'll need to add it manually later.${NC}"
        tunnel_token="YOUR_TUNNEL_TOKEN_HERE"
    fi

    echo -e "${GREEN}✅  Tunnel token configured${NC}"
    echo ""
fi

# ───────────────────────────────────────────────
# 5. Domain Setup — add 1, then ask "add more?"
# ───────────────────────────────────────────────
echo -e "${BOLD}🌐  Step 4: Custom Domain (Optional)${NC}"
echo "    Enter the domain for your short links."

if [ "$METHOD" == "cloudflare" ]; then
    echo "    This sets BASE_URL for generated short links."
else
    echo "    You'll need to point DNS to this server and configure nginx."
fi

echo "    Press Enter to skip and use localhost."
echo ""

DOMAINS=()
BASE_URL="http://localhost:$PORT"

# First domain
read -p "    Domain 1 (or press Enter to skip): " domain

if [ -z "$domain" ]; then
    echo -e "${YELLOW}    ℹ️  No custom domain. Using localhost.${NC}"
else
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        echo -e "${RED}    ❌ Invalid domain format. Skipping.${NC}"
    else
        DOMAINS+=("$domain")
        BASE_URL="https://$domain"
        echo -e "${GREEN}    ✅ Domain set: $domain${NC}"
    fi
fi

# Ask "add more?" loop (up to 9 more, total 10)
while [ ${#DOMAINS[@]} -lt 10 ]; do
    echo ""
    read -p "    Do you want to add another domain? [y/N]: " add_more

    if [[ ! "$add_more" =~ ^[Yy]$ ]]; then
        break
    fi

    next_num=$((${#DOMAINS[@]} + 1))
    read -p "    Domain $next_num: " domain

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}    Skipped.${NC}"
        continue
    fi

    if [[ ! "$domain" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        echo -e "${RED}    ❌ Invalid domain format. Skipping.${NC}"
        continue
    fi

    DOMAINS+=("$domain")
    echo -e "${GREEN}    ✅ Domain $next_num added: $domain${NC}"
done

if [ ${#DOMAINS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}    Configured domains:${NC}"
    for d in "${DOMAINS[@]}"; do
        echo -e "      • $d"
    done
fi
echo ""

# ───────────────────────────────────────────────
# 6. Install Docker if needed
# ───────────────────────────────────────────────
echo -e "${BOLD}🐳  Step 5: Installing Docker${NC}"

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

    sudo usermod -aG docker "$USER" 2>/dev/null || true

    echo -e "${GREEN}✅  Docker installed${NC}"
    echo -e "${YELLOW}⚠️  You may need to log out and back in for docker group changes.${NC}"
fi
echo ""

# ───────────────────────────────────────────────
# 7. Create docker-compose.yml
# ───────────────────────────────────────────────
echo -e "${BOLD}📦  Step 6: Generating config files${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f docker-compose.yml ]; then
    cp docker-compose.yml "docker-compose.yml.backup.$(date +%s)"
    echo "    Backed up existing docker-compose.yml"
fi

if [ "$METHOD" == "cloudflare" ]; then
    # Cloudflare Tunnel docker-compose
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
      - ./data:/app/data
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
else
    # Nginx docker-compose (no tunnel)
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
      - ./data:/app/data
    restart: unless-stopped
    networks:
      - cloak-net

networks:
  cloak-net:
    driver: bridge
EOF
fi

echo -e "${GREEN}✅  docker-compose.yml created${NC}"

# ───────────────────────────────────────────────
# 8. Generate Nginx configs (if nginx method)
# ───────────────────────────────────────────────
if [ "$METHOD" == "nginx" ] && [ ${#DOMAINS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}🌐  Step 7: Generating Nginx configs${NC}"

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
        sed -i "s/DOMAIN_PLACEHOLDER/$domain/g" "$NGINX_DIR/$domain.conf"
        sed -i "s/PORT_PLACEHOLDER/$PORT/g" "$NGINX_DIR/$domain.conf"
        echo -e "    ${GREEN}✅${NC} nginx/$domain.conf"
    done

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
# 9. Create .env file
# ───────────────────────────────────────────────
echo ""
cat > .env << EOF
# cloak.link configuration
# Edit these values and restart with: docker compose up -d

# Deployment method: cloudflare or nginx
METHOD=${METHOD}

# Your custom domain (used for generated short links)
BASE_URL=${BASE_URL}

# Internal port
CLOAK_PORT=${PORT}
EOF

if [ "$METHOD" == "cloudflare" ]; then
    cat >> .env << EOF

# Cloudflare Tunnel token (required for public access)
TUNNEL_TOKEN=${tunnel_token}
EOF
fi

echo -e "${GREEN}✅  .env file created${NC}"
echo ""

# ───────────────────────────────────────────────
# 10. Build & Start
# ───────────────────────────────────────────────
echo -e "${BOLD}🚀  Step 8: Building & Starting cloak.link${NC}"

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
echo -e "${GREEN}  ✅  cloak.link is running!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}    Method:${NC}        ${METHOD}"
echo -e "${BOLD}    Local URL:${NC}     http://localhost:$PORT"

if [ ${#DOMAINS[@]} -gt 0 ]; then
    echo -e "${BOLD}    Public URL:${NC}   $BASE_URL"
fi

if [ "$METHOD" == "cloudflare" ] && [ ${#DOMAINS[@]} -gt 0 ] && [ "$tunnel_token" != "YOUR_TUNNEL_TOKEN_HERE" ]; then
    echo ""
    echo -e "    ${YELLOW}📋 Next steps in Cloudflare Dashboard:${NC}"
    echo -e "       1. Go to ${BOLD}Networks > Tunnels${NC}"
    echo -e "       2. Select your tunnel"

    if [ ${#DOMAINS[@]} -eq 1 ]; then
        echo -e "       3. Add a ${BOLD}Public Hostname${NC}:"
        echo -e "          - Subdomain: ${BOLD}${DOMAINS[0]}${NC}"
        echo -e "          - Service: ${BOLD}http://cloak:3000${NC}"
    else
        echo -e "       3. Add ${BOLD}Public Hostnames${NC} for each domain:"
        for d in "${DOMAINS[@]}"; do
            echo -e "          - ${BOLD}${d}${NC} → http://cloak:3000"
        done
    fi
    echo -e "       4. Save and wait for 'Healthy' status"
fi

echo ""
echo -e "${BOLD}    Useful commands:${NC}"
echo -e "      View logs:     ${BOLD}$COMPOSE_CMD logs -f${NC}"
echo -e "      Stop:          ${BOLD}$COMPOSE_CMD down${NC}"
echo -e "      Restart:       ${BOLD}$COMPOSE_CMD restart${NC}"
echo -e "      Update:        ${BOLD}git pull && $COMPOSE_CMD up -d --build${NC}"
echo -e "      Edit config:   ${BOLD}nano .env && $COMPOSE_CMD up -d${NC}"
echo ""

if [ "$METHOD" == "cloudflare" ]; then
    echo -e "${CYAN}    🔒 No open ports. No nginx. Cloudflare Tunnel handles everything.${NC}"
else
    echo -e "${CYAN}    🌐 Nginx configs ready in ./nginx/ — run sudo bash nginx/install-nginx.sh${NC}"
fi

echo -e "${BLUE}    Built for privacy. No analytics. No tracking. Just links.${NC}"
echo ""
