#!/usr/bin/env bash
#
# Cloak.URL installer
#
#   bash install.sh                 interactive (5 questions, all have defaults)
#   bash install.sh -y              non-interactive, accepts every default
#   bash install.sh --no-docker     run with plain python3 (app.py is stdlib-only)
#   bash install.sh --help          all options
#
# Design rules that keep this installer from "silently dying":
#   * prompts work without a TTY (pipes, cron, CI, `curl | bash`)
#   * `read` can never return non-zero into `set -e`
#   * no bare `cmd1 && cmd2` statements — a false test would abort the script
#   * Docker problems print an actionable message and offer a no-Docker fallback
#   * bash 3.2 compatible (the version macOS still ships): no associative
#     arrays, no ${var,,}, no mapfile

# Re-exec under bash if someone ran `sh install.sh` (dash/ash lack [[ ]], &>, ...)
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

# SC2059: the only variables embedded in printf format strings below are our own
# ANSI colour constants (no % in them); user data is always passed as arguments.
# shellcheck disable=SC2059

set -euo pipefail

VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours (disabled when stdout is not a terminal) ────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'
    YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'
    DIM=$'\033[2m'; NC=$'\033[0m'
else
    BOLD=''; GREEN=''; BLUE=''; YELLOW=''; RED=''; CYAN=''; DIM=''; NC=''
fi

# ── Defaults (env vars and flags override these) ────────────────────────────
METHOD="${METHOD:-}"                    # cloudflare | nginx | none | "" = ask
PORT="${PORT:-3000}"
DOMAIN="${DOMAIN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
# Cloudflare Zero Trust account tag — NOT a secret. It only makes the dashboard
# links deep-link into your account instead of the account picker.
CF_TAG="${CLOUDFLARE_ACCOUNT_TAG:-}"
TUNNEL_SERVICE="${TUNNEL_SERVICE:-http://cloak:3000}"
TUNNEL_NAME="${TUNNEL_NAME:-cloak-url}"
DB_CHOICE="${DB:-1}"                    # 1|project | 2|volume | 3|<path>
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
MAX_LINKS="${MAX_LINKS:-10000}"
RUN_MODE="docker"                       # docker | local
ASSUME_YES=false
DO_START=true
SKIP_BUILD=false
DRY_RUN=false
VERBOSE=false
UNINSTALL=false
SYSTEMD=false

DOCKER=""            # "docker" or "sudo docker"
COMPOSE=""           # "docker compose" or "docker-compose"
SUDO=""
DB_MOUNT="./data"
LOCAL_DB=""

# ── Output helpers ──────────────────────────────────────────────────────────
info()    { printf '    %s\n' "$*"; }
ok()      { printf "    ${GREEN}✓${NC} %s\n" "$*"; }
warn()    { printf "    ${YELLOW}⚠${NC} %s\n" "$*"; }
err()     { printf "    ${RED}✗${NC} %s\n" "$*" >&2; }
dim()     { printf "    ${DIM}%s${NC}\n" "$*"; }
section() { printf '\n'"${BOLD}%s${NC}\n" "$*"; }

run() {
    if [ "$VERBOSE" = true ] || [ "$DRY_RUN" = true ]; then
        printf "    ${DIM}\$ %s${NC}\n" "$*"
    fi
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi
    "$@"
}

die() {
    printf '\n' >&2
    err "$1"
    if [ -n "${2:-}" ]; then dim "$2"; fi
    printf '\n' >&2
    exit 1
}

on_error() {
    printf '\n' >&2
    err "install.sh stopped at line $1."
    dim "Re-run with --verbose to see every command, or with --no-docker to skip Docker."
    dim "Usual suspects: Docker daemon not running, port ${PORT} taken, or ${SCRIPT_DIR} not writable."
    printf '\n' >&2
    exit 1
}
trap 'on_error $LINENO' ERR

usage() {
    cat << EOF
${BOLD}Cloak.URL installer v${VERSION}${NC}

${BOLD}Usage:${NC}  bash install.sh [options]

${BOLD}Options:${NC}
  --method METHOD     cloudflare (default) | nginx | none
  --port PORT         host port to listen on (default: 3000)
  --domain DOMAIN     public domain, e.g. mybrand.com
  --token TOKEN       Cloudflare tunnel token
  --db WHERE          1/project (./data, default) | 2/volume | /absolute/path
  --bind ADDR         127.0.0.1 (default, private) | 0.0.0.0 (exposed)
  --max-links N       link cap (default: 10000)
  --cf-tag TAG        Cloudflare Zero Trust account tag (not a secret) — makes
                      the dashboard links deep-link into your account
  --tunnel-service U  service the tunnel forwards to (default http://cloak:3000)
  --no-docker         run with python3 directly — no Docker at all
  --systemd           with --no-docker on Linux: also write a systemd unit
  --no-start          write the config but don't start anything
  --skip-build        reuse the existing image instead of rebuilding
  -y, --yes           non-interactive: accept every default
  --dry-run           print what would happen, change nothing
  --verbose           print every command
  --uninstall         stop containers and remove the generated config
  -h, --help          this help

Every option can also be set through an environment variable of the same name
in capitals (METHOD, PORT, DOMAIN, TUNNEL_TOKEN, DB, BIND_ADDR, MAX_LINKS),
which makes the installer fully scriptable:

  PORT=8080 DOMAIN=links.example.com bash install.sh -y

EOF
}

# ── Small utilities ─────────────────────────────────────────────────────────

# prompt "Label" "default" → prints the answer on stdout (label goes to stderr)
# Never blocks and never fails: without a TTY (or with -y) it returns the default.
prompt() {
    local label="$1" default="$2" reply=""
    if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
        printf '%s' "$default"
        return 0
    fi
    printf '%s' "$label" >&2
    read -r reply || reply=""
    reply="$(printf '%s' "$reply" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$reply" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$reply"
    fi
}

is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_port() {
    if is_number "$1"; then
        if [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then return 0; fi
    fi
    return 1
}

valid_domain() {
    printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)+$'
}

port_in_use() {
    local p="$1"
    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | grep -Eq "[:.]${p}[[:space:]]"; then return 0; fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -an 2>/dev/null | grep -Eq "[:.]${p}[[:space:]].*LISTEN"; then return 0; fi
    fi
    return 1
}

# http_get URL [timeout] → 0 on HTTP 2xx. Uses whichever client exists.
http_get() {
    local url="$1" tmo="${2:-5}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m "$tmo" -o /dev/null "$url" 2>/dev/null && return 0
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$url" "$tmo" << 'PY' 2>/dev/null && return 0
import sys, urllib.request
try:
    code = urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2])).getcode()
    sys.exit(0 if 200 <= code < 300 else 1)
except Exception:
    sys.exit(1)
PY
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T "$tmo" -O /dev/null "$url" 2>/dev/null && return 0
        return 1
    fi
    return 1
}

write_env() {
    local target="$1"
    {
        printf '# Generated by install.sh v%s on %s\n' "$VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'COMPOSE_PROJECT_NAME=cloak-url\n'
        printf 'PORT=%s\n' "$PORT"
        printf 'BIND_ADDR=%s\n' "$BIND_ADDR"
        printf 'BASE_URL=%s\n' "$BASE_URL"
        printf 'MAX_LINKS=%s\n' "$MAX_LINKS"
        printf 'DB_MOUNT=%s\n' "$DB_MOUNT"
        printf 'DB_VOLUME_NAME=cloak-url-data\n'
        printf 'COMPOSE_PROFILES=%s\n' "$COMPOSE_PROFILES"
        printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN"
        printf '# Cloudflare "Custom domain" panel: deep links + what the tunnel forwards to.\n'
        printf '# The account tag is not a secret.\n'
        printf 'CLOUDFLARE_ACCOUNT_TAG=%s\n' "$CF_TAG"
        printf 'TUNNEL_SERVICE=%s\n' "$TUNNEL_SERVICE"
        printf 'TUNNEL_NAME=%s\n' "$TUNNEL_NAME"
    } > "$target"
    chmod 600 "$target" 2>/dev/null || true
}

print_summary() {
    printf '\n'
    printf "${GREEN}┌────────────────────────────────────────┐${NC}\n"
    printf "${GREEN}│  ✅  Cloak.URL is installed            │${NC}\n"
    printf "${GREEN}└────────────────────────────────────────┘${NC}\n"
    printf '\n'
    printf "  ${BOLD}%-14s${NC} %s\n" "URL:"      "$BASE_URL"
    printf "  ${BOLD}%-14s${NC} %s\n" "Local:"    "http://localhost:${PORT}"
    if [ "$RUN_MODE" = "docker" ]; then
        printf "  ${BOLD}%-14s${NC} %s\n" "Runtime:" "Docker (${METHOD})"
        printf "  ${BOLD}%-14s${NC} %s\n" "Ports:"   "${BIND_ADDR}:${PORT} → container 3000"
    else
        printf "  ${BOLD}%-14s${NC} %s\n" "Runtime:" "python3 (no Docker)"
        printf "  ${BOLD}%-14s${NC} %s\n" "Listening:" "0.0.0.0:${PORT}"
    fi
    if [ "$DB_MOUNT" = "cloak-data" ]; then
        printf "  ${BOLD}%-14s${NC} %s\n" "Database:" "docker volume cloak-url-data"
    else
        printf "  ${BOLD}%-14s${NC} %s\n" "Database:" "${DB_MOUNT}/urls.db"
    fi
    printf "  ${BOLD}%-14s${NC} %s\n" "Config:" "${SCRIPT_DIR}/.env"
    printf '\n'

    if [ "$METHOD" = "cloudflare" ] && [ -n "$TUNNEL_TOKEN" ]; then
        CF_ZT="https://one.dash.cloudflare.com"
        if [ -n "$CF_TAG" ]; then CF_ZT="${CF_ZT}/${CF_TAG}"; fi
        printf "  ${YELLOW}🌐 Connect %s on Cloudflare:${NC}\n" "${DOMAIN:-yourdomain.com}"
        printf "    ${BOLD}1)%s Tunnel (Docker connector)   ${CYAN}%s/networks/tunnels${NC}\n" "$NC" "$CF_ZT"
        printf "    ${BOLD}2)%s Add a hostname route        ${BOLD}%s${NC} → ${BOLD}%s${NC}\n" "$NC" "${DOMAIN:-yourdomain.com}" "$TUNNEL_SERVICE"
        printf "    ${BOLD}3)%s Check the zone's DNS        ${CYAN}https://dash.cloudflare.com/?to=/:account/:zone/dns${NC}\n" "$NC"
        printf '\n'
        printf "    ${DIM}Or open %s → Custom domain: it prints these links for you and${NC}\n" "$BASE_URL"
        printf "    ${DIM}verifies the tunnel end-to-end (DNS + one HTTPS request to /api/health).${NC}\n"
        printf '\n'
        info "Tunnel logs:  ${COMPOSE} logs -f tunnel"
    elif [ "$METHOD" = "nginx" ] && [ -n "$DOMAIN" ]; then
        printf "  ${YELLOW}Next steps:${NC}\n"
        printf "    ${BOLD}sudo bash nginx/install-nginx.sh${NC}\n"
        printf "    DNS:     A  %s  →  this server's IP\n" "$DOMAIN"
        printf "    HTTPS:   sudo certbot --nginx -d %s\n" "$DOMAIN"
    elif [ -n "$DOMAIN" ]; then
        printf "  ${YELLOW}%s is set, but nothing proxies to it yet.${NC}\n" "$DOMAIN"
        printf "    Point DNS at this machine, then either:\n"
        printf "      ${BOLD}bash install.sh --method nginx --domain %s${NC}\n" "$DOMAIN"
        printf "    or put any reverse proxy/CDN in front of port %s.\n" "$PORT"
    else
        printf "  ${YELLOW}No public hostname configured.${NC}\n"
        printf "    The app answers on http://localhost:%s only.\n" "$PORT"
        printf "    Re-run ${BOLD}bash install.sh${NC} with a token or domain to expose it.\n"
    fi

    printf '\n'
    printf "  ${BOLD}Commands:${NC}\n"
    if [ "$RUN_MODE" = "docker" ] && [ -n "$COMPOSE" ]; then
        printf "    ${BOLD}logs${NC}     cd %s && %s logs -f\n" "$SCRIPT_DIR" "$COMPOSE"
        printf "    ${BOLD}stop${NC}     cd %s && %s down\n" "$SCRIPT_DIR" "$COMPOSE"
        printf "    ${BOLD}restart${NC}  cd %s && %s up -d\n" "$SCRIPT_DIR" "$COMPOSE"
        printf "    ${BOLD}config${NC}   edit .env, then %s up -d\n" "$COMPOSE"
        printf "    ${BOLD}remove${NC}   bash install.sh --uninstall\n"
    else
        printf "    ${BOLD}logs${NC}     tail -f %s/cloak-url.log\n" "$SCRIPT_DIR"
        printf "    ${BOLD}stop${NC}     kill \$(cat %s/.cloak-url.pid)\n" "$SCRIPT_DIR"
        printf "    ${BOLD}remove${NC}   bash install.sh --uninstall\n"
    fi
    printf '\n'
    printf "  ${DIM}Built for privacy. No analytics. No tracking. Just links.${NC}\n\n"
}

verify_local() {
    local url="http://127.0.0.1:${PORT}/api/health" i
    info "Waiting for ${url}"
    i=0
    while [ "$i" -lt 15 ]; do
        if http_get "$url" 3; then
            ok "Cloak.URL is answering on port ${PORT}"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    err "No response after 15s. Last log lines:"
    tail -n 20 "${SCRIPT_DIR}/cloak-url.log" 2>/dev/null | sed 's/^/      /' || true
    return 1
}

verify_docker() {
    local url="http://127.0.0.1:${PORT}/api/health" i
    if [ -z "$COMPOSE" ]; then
        warn "No compose command available — skipping verification."
        return 1
    fi
    info "Waiting for ${url}"
    i=0
    while [ "$i" -lt 45 ]; do
        if http_get "$url" 3; then
            ok "Cloak.URL is answering on port ${PORT}"
            if [ -n "$TUNNEL_TOKEN" ]; then
                if $COMPOSE ps 2>/dev/null | grep -q tunnel; then
                    ok "Tunnel container is running"
                else
                    warn "Tunnel container not running yet — check: ${COMPOSE} logs tunnel"
                fi
            fi
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    err "No healthy response after 45s."
    printf '\n'
    info "Container status:"
    $COMPOSE ps 2>/dev/null | sed 's/^/      /' || true
    printf '\n'
    info "Last 40 log lines:"
    $COMPOSE logs --tail=40 2>/dev/null | sed 's/^/      /' || true
    printf '\n'
    dim "Is port ${PORT} free? Is ${DB_MOUNT} writable by the container?"
    dim "Try: ${COMPOSE} down && ${COMPOSE} up -d"
    return 1
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --method)     METHOD="${2:-}"; shift 2 ;;
        --port)       PORT="${2:-}"; shift 2 ;;
        --domain)     DOMAIN="${2:-}"; shift 2 ;;
        --token)      TUNNEL_TOKEN="${2:-}"; shift 2 ;;
        --db)         DB_CHOICE="${2:-}"; shift 2 ;;
        --bind)       BIND_ADDR="${2:-}"; shift 2 ;;
        --max-links)  MAX_LINKS="${2:-}"; shift 2 ;;
        --cf-tag)     CF_TAG="${2:-}"; shift 2 ;;
        --tunnel-service) TUNNEL_SERVICE="${2:-}"; shift 2 ;;
        --no-docker)  RUN_MODE="local"; shift ;;
        --systemd)    SYSTEMD=true; shift ;;
        --no-start)   DO_START=false; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        -y|--yes)     ASSUME_YES=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --verbose)    VERBOSE=true; shift ;;
        --uninstall)  UNINSTALL=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Unknown option: $1"; printf '\n' >&2; usage >&2; exit 2 ;;
    esac
done

case "$METHOD" in
    ""|cloudflare|nginx|none) ;;
    *) warn "Unknown --method '${METHOD}' — you will be asked instead"; METHOD="" ;;
esac
if ! valid_port "$PORT"; then
    warn "Invalid port '$PORT' — using 3000"
    PORT=3000
fi
case "$BIND_ADDR" in
    127.0.0.1|0.0.0.0|localhost) ;;
    *) warn "Invalid --bind '$BIND_ADDR' — using 127.0.0.1"; BIND_ADDR="127.0.0.1" ;;
esac
if [ "$BIND_ADDR" = "localhost" ]; then BIND_ADDR="127.0.0.1"; fi
if ! is_number "$MAX_LINKS"; then
    warn "Invalid --max-links '$MAX_LINKS' — using 10000"
    MAX_LINKS=10000
fi

# ── Platform detection ──────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
    Darwin)               PLATFORM="macos" ;;
    Linux)                PLATFORM="linux" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)                    PLATFORM="unknown" ;;
esac

DISTRO="unknown"
DISTRO_LIKE=""
FAMILY="unknown"        # debian | rhel | arch | alpine | suse | unknown
PM=""
if [ "$PLATFORM" = "linux" ] && [ -r /etc/os-release ]; then
    # Read os-release inside a subshell: it defines NAME/VERSION/ID/..., and
    # sourcing it here would clobber our own VERSION (Debian sets
    # VERSION="12 (bookworm)") and other variables.
    DISTRO="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
    DISTRO_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    for candidate in apt-get dnf yum zypper pacman apk; do
        if command -v "$candidate" >/dev/null 2>&1; then
            PM="$candidate"
            break
        fi
    done
fi

# ID alone misses derivatives (Linux Mint, Pop!_OS, Manjaro, Rocky...), so
# classify on ID + ID_LIKE. This decides how Docker gets installed.
case " ${DISTRO} ${DISTRO_LIKE} " in
    *alpine*)                       FAMILY="alpine" ;;
    *arch*|*manjaro*)               FAMILY="arch" ;;
    *debian*|*ubuntu*)              FAMILY="debian" ;;
    *fedora*|*rhel*|*centos*)       FAMILY="rhel" ;;
    *suse*)                         FAMILY="suse" ;;
esac

IN_WSL=false
if [ "$PLATFORM" = "linux" ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    IN_WSL=true
fi

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

printf '\n'
printf "${BOLD}🔗  Cloak.URL Installer v%s${NC}\n" "$VERSION"
printf "${BLUE}    Private URL shortener — zero tracking, zero logs${NC}\n"
printf "${DIM}    %s · %s · %s${NC}\n" "$OS" "$DISTRO" "$SCRIPT_DIR"
if [ "$DRY_RUN" = true ]; then
    printf "${YELLOW}    DRY RUN — nothing will be changed${NC}\n"
fi
if [ ! -t 0 ]; then
    printf "${DIM}    Non-interactive stdin detected — defaults will be used (or pass flags).${NC}\n"
fi

# ── Uninstall ───────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
    section "🗑  Uninstall"
    if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            run docker compose down --remove-orphans || true
        elif command -v docker-compose >/dev/null 2>&1; then
            run docker-compose down --remove-orphans || true
        fi
    fi
    if [ -f "${SCRIPT_DIR}/.cloak-url.pid" ]; then
        kill "$(cat "${SCRIPT_DIR}/.cloak-url.pid")" 2>/dev/null || true
        run rm -f "${SCRIPT_DIR}/.cloak-url.pid"
    fi
    OLD_DB="./data"
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        OLD_DB="$(grep -E '^DB_MOUNT=' "${SCRIPT_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [ -n "$OLD_DB" ] || OLD_DB="./data"
    fi
    run rm -f "${SCRIPT_DIR}/.env"
    ok "Stopped; .env removed."
    warn "Your links were NOT deleted."
    if [ "$OLD_DB" = "cloak-data" ]; then
        dim "Full wipe: docker volume rm cloak-url-data"
    else
        dim "Full wipe: rm -rf ${SCRIPT_DIR}/${OLD_DB#./}"
    fi
    exit 0
fi

# ── Sanity checks ───────────────────────────────────────────────────────────
for required in app.py index.html docker-compose.yml; do
    if [ ! -f "${SCRIPT_DIR}/${required}" ]; then
        die "${required} not found in ${SCRIPT_DIR}" \
            "Your download looks incomplete — re-download the ZIP or re-clone the repo."
    fi
done
if [ ! -w "$SCRIPT_DIR" ]; then
    die "${SCRIPT_DIR} is not writable by $(id -un)." \
        "Move the project somewhere you own (e.g. ~/cloak-url) and re-run."
fi

# ── Q1: runtime ─────────────────────────────────────────────────────────────
section "🚀  How should Cloak.URL run?"
if [ "$RUN_MODE" = "local" ]; then
    METHOD="none"
    ok "No Docker — python3 app.py (--no-docker)"
elif [ -n "$METHOD" ]; then
    # --method / $METHOD was given explicitly: flags beat prompts.
    ok "Method: ${METHOD} (from flag/env)"
else
    printf '    %s1)%s Docker + Cloudflare Tunnel   no open ports       %s[default]%s\n' "$CYAN" "$NC" "$DIM" "$NC"
    printf '    %s2)%s Docker + Nginx               traditional reverse proxy\n' "$CYAN" "$NC"
    printf '    %s3)%s Docker only                  localhost / LAN, no proxy\n' "$CYAN" "$NC"
    printf '    %s4)%s No Docker                    plain python3, stdlib only\n' "$CYAN" "$NC"
    printf '\n'
    ANSWER="$(prompt "    Choice [1]: " "1")"
    case "$ANSWER" in
        2) METHOD="nginx";      ok "Docker + Nginx" ;;
        3) METHOD="none";       ok "Docker only" ;;
        4) METHOD="none"; RUN_MODE="local"; ok "No Docker — python3 app.py" ;;
        *) METHOD="cloudflare"; ok "Docker + Cloudflare Tunnel" ;;
    esac
fi

# ── Q2: port ────────────────────────────────────────────────────────────────
section "📡  Port"
ANSWER="$(prompt "    Press Enter for ${PORT}, or type a port: " "$PORT")"
if valid_port "$ANSWER"; then
    PORT="$ANSWER"
else
    warn "'${ANSWER}' is not a valid port — using ${PORT}"
fi
if port_in_use "$PORT"; then
    warn "Something is already listening on port ${PORT}."
    dim "Re-run with --port <other> if the start fails."
fi
ok "Port ${PORT}"

# ── Q3: database location ───────────────────────────────────────────────────
section "💾  Database location"
printf '    %s1)%s ./data           %s[default — easy to back up]%s\n' "$CYAN" "$NC" "$DIM" "$NC"
printf '    %s2)%s Docker volume    %ssurvives container deletion%s\n' "$CYAN" "$NC" "$DIM" "$NC"
printf '    %s3)%s Custom path      %se.g. /var/lib/cloak-url%s\n' "$CYAN" "$NC" "$DIM" "$NC"
printf '\n'
ANSWER="$(prompt "    Choice [${DB_CHOICE}]: " "$DB_CHOICE")"
case "$ANSWER" in
    2|volume)
        DB_MOUNT="cloak-data"
        ok "Docker volume: cloak-url-data"
        ;;
    1|project|"")
        DB_MOUNT="./data"
        ;;
    3)
        ANSWER="$(prompt "    Directory path: " "")"
        if [ -n "$ANSWER" ]; then DB_MOUNT="$ANSWER"; else DB_MOUNT="./data"; fi
        ;;
    *)
        DB_MOUNT="$ANSWER"
        ;;
esac

# Normalise DB_MOUNT and work out the absolute path used in --no-docker mode.
if [ "$DB_MOUNT" = "cloak-data" ]; then
    if [ "$RUN_MODE" = "local" ]; then
        warn "Docker volumes need Docker — falling back to ./data"
        DB_MOUNT="./data"
    fi
fi
if [ "$DB_MOUNT" != "cloak-data" ]; then
    case "$DB_MOUNT" in
        /*) LOCAL_DB="${DB_MOUNT}/urls.db" ;;          # absolute path
        ./*) LOCAL_DB="${SCRIPT_DIR}/${DB_MOUNT#./}/urls.db" ;;
        *)
            DB_MOUNT="./${DB_MOUNT}"
            LOCAL_DB="${SCRIPT_DIR}/${DB_MOUNT#./}/urls.db"
            ;;
    esac
    ok "${DB_MOUNT}/urls.db"
fi

# ── Q4: Cloudflare token ────────────────────────────────────────────────────
if [ "$METHOD" = "cloudflare" ] && [ "$RUN_MODE" = "docker" ]; then
    section "🌐  Cloudflare Tunnel token"
    dim "one.dash.cloudflare.com → Networks → Tunnels → Create → Docker → copy the token"
    if [ -n "$TUNNEL_TOKEN" ]; then
        ok "Token supplied via --token/env"
    else
        ANSWER="$(prompt "    Paste token (Enter to skip): " "")"
        TUNNEL_TOKEN="$ANSWER"
        if [ -n "$TUNNEL_TOKEN" ]; then
            ok "Token saved"
        else
            warn "Skipped — the app will run on localhost only"
            METHOD="none"
        fi
    fi
    dim "Optional: Zero Trust account tag — the string in"
    dim "https://one.dash.cloudflare.com/<tag>/networks/tunnels. Not a secret;"
    dim "it just makes Cloak.URL deep-link into your account."
    if [ -n "$CF_TAG" ]; then
        ok "Account tag supplied via --cf-tag/env"
    else
        ANSWER="$(prompt "    Account tag (Enter to skip): " "")"
        CF_TAG="$ANSWER"
        if [ -n "$CF_TAG" ]; then ok "Deep links will use tag ${CF_TAG}"; else info "Skipped — links land on the account picker"; fi
    fi
fi
if [ "$RUN_MODE" = "local" ]; then
    TUNNEL_TOKEN=""
    METHOD="none"
fi

# ── Q5: domain ──────────────────────────────────────────────────────────────
section "🌐  Domain"
ANSWER="$(prompt "    Public domain (Enter for localhost): " "$DOMAIN")"
DOMAIN="$ANSWER"
if [ -n "$DOMAIN" ]; then
    if valid_domain "$DOMAIN"; then
        BASE_URL="https://${DOMAIN}"
        ok "$DOMAIN"
    else
        warn "'${DOMAIN}' doesn't look like a domain — using localhost"
        DOMAIN=""
        BASE_URL="http://localhost:${PORT}"
    fi
else
    BASE_URL="http://localhost:${PORT}"
    info "localhost"
fi

COMPOSE_PROFILES=""
if [ "$METHOD" = "cloudflare" ] && [ -n "$TUNNEL_TOKEN" ]; then
    COMPOSE_PROFILES="tunnel"
fi

# ── No-Docker path ──────────────────────────────────────────────────────────
if [ "$RUN_MODE" = "local" ]; then
    section "🐍  Python runtime"
    PYTHON=""
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
                PYTHON="$candidate"
                break
            fi
        fi
    done
    if [ -z "$PYTHON" ]; then
        die "Python 3.8+ is required but was not found." \
            "Install it from https://www.python.org/downloads/ and re-run."
    fi
    ok "$($PYTHON -V 2>&1)"

    if [ "$DRY_RUN" = true ]; then
        info "Would write ${SCRIPT_DIR}/.env (PORT=${PORT}, DB_MOUNT=${DB_MOUNT}, BASE_URL=${BASE_URL})"
    else
        if [ -f "${SCRIPT_DIR}/.env" ]; then
            cp "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.bak" 2>/dev/null || true
        fi
        write_env "${SCRIPT_DIR}/.env"
        ok ".env written (chmod 600)"
    fi

    if [ ! -d "$(dirname "$LOCAL_DB")" ]; then
        run mkdir -p "$(dirname "$LOCAL_DB")" || die "Cannot create $(dirname "$LOCAL_DB")"
    fi

    if [ "$SYSTEMD" = true ] && [ "$PLATFORM" = "linux" ]; then
        cat > "${SCRIPT_DIR}/cloak-url.service" << EOF
[Unit]
Description=Cloak.URL private URL shortener
After=network.target

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
Environment=PORT=${PORT}
Environment=DB_PATH=${LOCAL_DB}
Environment=BASE_URL=${BASE_URL}
Environment=MAX_LINKS=${MAX_LINKS}
ExecStart=$(command -v "$PYTHON") ${SCRIPT_DIR}/app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        ok "cloak-url.service written"
        info "Enable it with:"
        printf "      ${BOLD}sudo cp cloak-url.service /etc/systemd/system/${NC}\n"
        printf "      ${BOLD}sudo systemctl daemon-reload && sudo systemctl enable --now cloak-url${NC}\n"
    fi

    if [ "$DO_START" = true ]; then
        section "🚀  Starting Cloak.URL (no Docker)"
        if [ "$DRY_RUN" = false ]; then
            PORT="$PORT" \
            DB_PATH="$LOCAL_DB" \
            BASE_URL="$BASE_URL" \
            MAX_LINKS="$MAX_LINKS" \
                nohup "$PYTHON" "${SCRIPT_DIR}/app.py" > "${SCRIPT_DIR}/cloak-url.log" 2>&1 &
            LOCAL_PID=$!
            printf '%s\n' "$LOCAL_PID" > "${SCRIPT_DIR}/.cloak-url.pid"
            sleep 1
            if ! kill -0 "$LOCAL_PID" 2>/dev/null; then
                err "The app exited immediately. Log:"
                tail -n 20 "${SCRIPT_DIR}/cloak-url.log" 2>/dev/null | sed 's/^/      /' || true
                exit 1
            fi
            ok "Started with pid ${LOCAL_PID}"
        fi
        printf '\n'
        verify_local || true
    fi

    if [ "$DRY_RUN" = true ]; then
        section "🧪  Dry run complete"
        info "Nothing was started or written."
    else
        print_summary
    fi
    exit 0
fi

# ── Docker path ─────────────────────────────────────────────────────────────
section "🐳  Docker"

detect_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    if docker info >/dev/null 2>&1; then
        DOCKER="docker"
    elif [ -n "$SUDO" ] && $SUDO -n docker info >/dev/null 2>&1; then
        DOCKER="$SUDO docker"
        warn "Docker needs root here — using sudo for docker commands."
    elif [ -n "$SUDO" ] && [ -t 0 ] && $SUDO docker info >/dev/null 2>&1; then
        DOCKER="$SUDO docker"
        warn "Docker needs root here — using sudo for docker commands."
    else
        return 1
    fi

    if $DOCKER compose version >/dev/null 2>&1; then
        COMPOSE="$DOCKER compose"
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    elif command -v docker-compose >/dev/null 2>&1 && [ -n "$SUDO" ] && $SUDO docker-compose version >/dev/null 2>&1; then
        COMPOSE="$SUDO docker-compose"
    else
        COMPOSE=""
    fi
    return 0
}

install_docker_linux() {
    if [ "$IN_WSL" = true ]; then
        warn "WSL detected. Install Docker Desktop for Windows, then enable:"
        dim "Settings → General → Use the WSL 2 based engine"
        dim "Settings → Resources → WSL Integration → enable your distro"
        return 1
    fi
    if [ -z "$PM" ]; then
        warn "No supported package manager found (${DISTRO})."
        dim "Install Docker manually: https://docs.docker.com/engine/install/"
        return 1
    fi
    info "Installing Docker for ${DISTRO} (${FAMILY} family, ${PM})..."
    case "$FAMILY" in
        arch)
            if [ -n "$SUDO" ]; then
                run $SUDO pacman -Sy --noconfirm docker docker-compose || return 1
            else
                run pacman -Sy --noconfirm docker docker-compose || return 1
            fi
            ;;
        alpine)
            run $SUDO apk add --no-cache docker docker-cli-compose || return 1
            run $SUDO rc-update add docker boot 2>/dev/null || true
            run $SUDO service docker start 2>/dev/null || true
            ;;
        suse)
            run $SUDO zypper --non-interactive install -y docker docker-compose || return 1
            ;;
        debian|rhel)
            # Docker's own installer covers Debian/Ubuntu/Fedora/CentOS/RHEL and
            # installs the compose plugin too — far more reliable than hand-rolling
            # apt/dnf repos (which is what used to break this script).
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
                    if [ -n "$SUDO" ]; then
                        run $SUDO sh /tmp/get-docker.sh || return 1
                    else
                        run sh /tmp/get-docker.sh || return 1
                    fi
                else
                    warn "Could not download get.docker.com (no internet?)"
                    dim "Manual install: https://docs.docker.com/engine/install/${DISTRO}/"
                    return 1
                fi
            else
                warn "curl is missing — cannot auto-install Docker."
                dim "Manual install: https://docs.docker.com/engine/install/${DISTRO}/"
                return 1
            fi
            ;;
        *)
            warn "Unrecognised distribution '${DISTRO}'."
            dim "Try your package manager: ${PM} install docker"
            dim "Or follow: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        run $SUDO systemctl enable --now docker 2>/dev/null || true
    fi
    if [ -n "$SUDO" ] && [ -n "${USER:-}" ]; then
        # Lets you run docker without sudo after your next login.
        run $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    fi
    return 0
}

install_docker_macos() {
    warn "Docker is not running on this Mac."
    if command -v brew >/dev/null 2>&1; then
        info "Install it with Homebrew (pick one):"
        printf "      ${BOLD}brew install --cask docker${NC}                        # Docker Desktop\n"
        printf "      ${BOLD}brew install colima docker docker-compose${NC} && colima start   # no GUI\n"
        if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
            ANSWER="$(prompt "    Run 'brew install --cask docker' now? [y/N]: " "n")"
            case "$ANSWER" in
                y|Y|yes|YES)
                    run brew install --cask docker || warn "brew install failed"
                    open -a Docker 2>/dev/null || true
                    info "Waiting for Docker Desktop to finish starting..."
                    ;;
                *) info "Skipped." ;;
            esac
        fi
    else
        info "Download Docker Desktop, install it, then start it:"
        dim "https://www.docker.com/products/docker-desktop/"
    fi
    warn "Docker Desktop must be RUNNING (whale icon in the menu bar) to continue."
    return 1
}

if detect_docker; then
    ok "Docker: $($DOCKER --version 2>/dev/null | head -1)"
    if [ -n "$COMPOSE" ]; then
        ok "Compose: $($COMPOSE version 2>/dev/null | head -1)"
        if [ "$COMPOSE" = "docker-compose" ] || [ "$COMPOSE" = "$SUDO docker-compose" ]; then
            warn "Legacy docker-compose v1 detected. v2 is recommended:"
            dim "https://docs.docker.com/compose/install/"
            LEGACY_VER="$($COMPOSE version --short 2>/dev/null | head -1 || true)"
            LEGACY_MINOR="$(printf '%s' "$LEGACY_VER" | sed -e 's/^v//' -e 's/^[0-9]*\.\([0-9]*\).*/\1/')"
            if is_number "$LEGACY_MINOR" && [ "$LEGACY_MINOR" -lt 28 ]; then
                warn "docker-compose ${LEGACY_VER} is too old for this compose file."
                dim "'profiles' needs docker-compose >= 1.28. Upgrade, or use --no-docker."
            fi
        fi
    else
        warn "Docker is present but the Compose plugin is missing — trying to add it..."
        case "$PM" in
            apt-get) run $SUDO apt-get install -y docker-compose-plugin 2>/dev/null || true ;;
            dnf|yum) run $SUDO "$PM" install -y docker-compose-plugin 2>/dev/null || true ;;
            zypper)  run $SUDO zypper install -y docker-compose 2>/dev/null || true ;;
            pacman)  run $SUDO pacman -S --noconfirm docker-compose 2>/dev/null || true ;;
            apk)     run $SUDO apk add --no-cache docker-cli-compose 2>/dev/null || true ;;
            *)       true ;;
        esac
        detect_docker || true
    fi
else
    warn "Docker is not usable right now."
    DO_INSTALL="n"
    if [ "$PLATFORM" = "linux" ]; then
        if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
            DO_INSTALL="$(prompt "    Install Docker now? [Y/n]: " "y")"
        fi
        case "$DO_INSTALL" in
            n|N|no|NO) info "Not installing Docker." ;;
            *) install_docker_linux || true ;;
        esac
        if detect_docker; then
            if [ -n "$COMPOSE" ]; then
                ok "Docker is ready."
                warn "If Docker was just installed, log out and back in so your user"
                dim "joins the docker group — then sudo is no longer needed."
            fi
        fi
    elif [ "$PLATFORM" = "macos" ]; then
        install_docker_macos || true
        detect_docker || true
    elif [ "$PLATFORM" = "windows" ]; then
        warn "Git Bash on Windows detected."
        dim "Install Docker Desktop with the WSL 2 backend, start it, then re-run."
        dim "https://docs.docker.com/desktop/install/windows-install/"
    fi
fi

if [ "$DRY_RUN" = true ] && { [ -z "$DOCKER" ] || [ -z "$COMPOSE" ]; }; then
    warn "Docker is not available, but this is a dry run — continuing to show the plan."
fi

if [ "$DRY_RUN" = false ] && { [ -z "$DOCKER" ] || [ -z "$COMPOSE" ]; }; then
    printf '\n'
    warn "Docker isn't available, so the container can't be built."
    info "Two ways forward:"
    printf "      ${BOLD}1)%s Run without Docker — app.py is pure Python stdlib:\n" "$NC"
    printf "         ${CYAN}bash install.sh --no-docker --port %s${NC}\n" "$PORT"
    printf "      ${BOLD}2)%s Install Docker, then re-run this installer:\n" "$NC"
    printf "         ${DIM}https://docs.docker.com/get-docker/${NC}\n"
    if [ "$PLATFORM" = "macos" ]; then
        printf "         ${DIM}macOS: start Docker Desktop, wait for the whale, re-run.${NC}\n"
    fi
    if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
        ANSWER="$(prompt $'\n'"    Fall back to --no-docker right now? [Y/n]: " "y")"
        case "$ANSWER" in
            n|N|no|NO)
                die "Docker is required for this mode." "Re-run with --no-docker to use plain Python."
                ;;
            *)
                info "Switching to --no-docker..."
                FALLBACK_ARGS=(--no-docker --port "$PORT" --db "$DB_MOUNT" --max-links "$MAX_LINKS")
                if [ -n "$DOMAIN" ]; then FALLBACK_ARGS+=(--domain "$DOMAIN"); fi
                if [ "$ASSUME_YES" = true ]; then FALLBACK_ARGS+=(-y); fi
                printf '\n'
                exec bash "$0" "${FALLBACK_ARGS[@]}"
                ;;
        esac
    else
        die "Docker is required for this mode." "Re-run with --no-docker to use plain Python instead."
    fi
fi

# For display only: a dry run never executes compose, but it should still show
# the command it *would* run when Docker is missing on this machine.
if [ "$DRY_RUN" = true ] && [ -z "$COMPOSE" ]; then
    COMPOSE="docker compose"
fi

# ── Write .env ──────────────────────────────────────────────────────────────
section "📦  Writing configuration"
if [ "$DRY_RUN" = true ]; then
    info "Would write ${SCRIPT_DIR}/.env with:"
    printf '      COMPOSE_PROJECT_NAME=cloak-url\n'
    printf '      PORT=%s\n      BIND_ADDR=%s\n      BASE_URL=%s\n' "$PORT" "$BIND_ADDR" "$BASE_URL"
    printf '      MAX_LINKS=%s\n      DB_MOUNT=%s\n' "$MAX_LINKS" "$DB_MOUNT"
    printf '      COMPOSE_PROFILES=%s\n      TUNNEL_TOKEN=%s\n' "$COMPOSE_PROFILES" \
        "$([ -n "$TUNNEL_TOKEN" ] && printf '***set***' || printf '(empty)')"
    printf '      CLOUDFLARE_ACCOUNT_TAG=%s\n' "${CF_TAG:-(empty)}"
    printf '      TUNNEL_SERVICE=%s\n      TUNNEL_NAME=%s\n' "$TUNNEL_SERVICE" "$TUNNEL_NAME"
else
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        cp "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.bak" 2>/dev/null || true
        dim "Previous .env backed up to .env.bak"
    fi
    write_env "${SCRIPT_DIR}/.env"
    ok ".env written (chmod 600 — it can hold your tunnel token)"
    ok "docker-compose.yml untouched (it reads .env)"
    if [ "$VERBOSE" = true ]; then
        sed -e 's/^TUNNEL_TOKEN=.*/TUNNEL_TOKEN=***hidden***/' "${SCRIPT_DIR}/.env" | sed 's/^/      /'
    fi
fi

# Make sure a relative bind-mount target exists before Docker tries to use it.
if [ "$DB_MOUNT" != "cloak-data" ]; then
    case "$DB_MOUNT" in
        /*) DB_TARGET="$DB_MOUNT" ;;
        *)  DB_TARGET="${SCRIPT_DIR}/${DB_MOUNT#./}" ;;
    esac
    if [ ! -d "$DB_TARGET" ] && [ "$DRY_RUN" = false ]; then
        if ! mkdir -p "$DB_TARGET" 2>/dev/null; then
            if [ -n "$SUDO" ]; then
                run $SUDO mkdir -p "$DB_TARGET" || true
                run $SUDO chown "$(id -u):$(id -g)" "$DB_TARGET" 2>/dev/null || true
            fi
        fi
        if [ -d "$DB_TARGET" ]; then
            ok "Created ${DB_TARGET}"
        else
            warn "Could not create ${DB_TARGET} — Docker will try, as root."
        fi
    fi
fi

# ── Nginx config ────────────────────────────────────────────────────────────
if [ "$METHOD" = "nginx" ] && [ -n "$DOMAIN" ]; then
    section "🧭  Nginx"
    NGINX_DIR="${SCRIPT_DIR}/nginx"
    if [ "$DRY_RUN" = true ]; then
        info "Would write ${NGINX_DIR}/${DOMAIN}.conf and ${NGINX_DIR}/install-nginx.sh"
    else
    mkdir -p "$NGINX_DIR"
    cat > "${NGINX_DIR}/${DOMAIN}.conf" << EOF
# Generated by install.sh — reverse proxy for ${DOMAIN} → 127.0.0.1:${PORT}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
    ok "nginx/${DOMAIN}.conf"

    cat > "${NGINX_DIR}/install-nginx.sh" << 'NGINXSH'
#!/usr/bin/env bash
# Installs nginx and enables the generated site config(s). Run with sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root:  sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITE=""

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq nginx
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx
elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx
elif command -v zypper >/dev/null 2>&1; then
    zypper install -y nginx
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm nginx
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nginx
else
    echo "No supported package manager found — install nginx manually." >&2
    exit 1
fi

if [ -d /etc/nginx/sites-available ]; then
    # Debian / Ubuntu layout
    for conf in "$SCRIPT_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        bn="$(basename "$conf")"
        cp "$conf" "/etc/nginx/sites-available/$bn"
        ln -sf "/etc/nginx/sites-available/$bn" "/etc/nginx/sites-enabled/$bn"
        SITE="${SITE:+$SITE }${bn%.conf}"
    done
    rm -f /etc/nginx/sites-enabled/default
else
    # RHEL / Fedora / Arch / Alpine layout
    mkdir -p /etc/nginx/conf.d
    for conf in "$SCRIPT_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        bn="$(basename "$conf")"
        cp "$conf" "/etc/nginx/conf.d/$bn"
        SITE="${SITE:+$SITE }${bn%.conf}"
    done
fi

nginx -t
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
else
    service nginx restart >/dev/null 2>&1 || nginx -s reload
fi

echo "✅ Nginx is now serving: ${SITE:-your config}"
echo "   Add HTTPS with:  sudo certbot --nginx -d ${SITE:-yourdomain.com}"
NGINXSH
    chmod +x "${NGINX_DIR}/install-nginx.sh"
    ok "nginx/install-nginx.sh"
    info "After the app is up:  ${BOLD}sudo bash nginx/install-nginx.sh${NC}"
    fi
fi

# ── Build & start ───────────────────────────────────────────────────────────
if [ "$DO_START" = true ]; then
    section "🚀  Building and starting"
    if [ "$DRY_RUN" = false ]; then
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [ "$SKIP_BUILD" = false ]; then
        if [ "$DRY_RUN" = true ]; then
            info "Would build the image: ${COMPOSE:-docker compose} build"
        else
            info "Building the image (first run takes ~30s)..."
        fi
        if ! run $COMPOSE build; then
            printf '\n' >&2
            err "The Docker build failed."
            dim "Usually: no internet access to pull python:3.11-slim, or Docker needs sudo."
            dim "Re-run with --verbose, or --skip-build to reuse an existing image."
            exit 1
        fi
        ok "Image built"
    fi
    if ! run $COMPOSE up -d; then
        printf '\n' >&2
        err "'${COMPOSE} up -d' failed."
        $COMPOSE logs --tail=40 2>/dev/null | sed 's/^/      /' || true
        exit 1
    fi
    if [ "$DRY_RUN" = true ]; then
        ok "Would start: ${COMPOSE:-docker compose} up -d"
    else
        ok "Containers started"
        printf '\n'
        verify_docker || true
    fi
else
    section "📝  Configuration written (--no-start)"
    info "Start it later with:  cd ${SCRIPT_DIR} && ${COMPOSE:-docker compose} up -d --build"
fi

if [ "$DRY_RUN" = true ]; then
    section "🧪  Dry run complete"
    info "Nothing was built, started, or written."
else
    print_summary
fi
