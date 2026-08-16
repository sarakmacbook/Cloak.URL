# 🔐 Shorten — Private URL Shortener

A minimal, self-hosted URL shortener built for privacy. Zero tracking, zero logs, zero analytics.

## Privacy Guarantees

| What | Status |
|------|--------|
| IP logging | ❌ None |
| User-Agent logging | ❌ None |
| Referer logging | ❌ None |
| Click analytics | ❌ None |
| Third-party scripts | ❌ None |
| Cookies | ❌ None |
| External APIs | ❌ None |

## Features

- **Password protection** — Lock links behind a password
- **Auto-expiration** — Links self-destruct after a set time
- **Custom domains** — Brand your short links
- **Custom codes** — Choose memorable slugs
- **Rate limiting** — Max links cap (default 10,000)
- **No tracking** — No clicks, no IPs, no logs

## Quick Start

```bash
docker-compose up -d
# Open http://localhost:3000
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server port |
| `BASE_URL` | `http://localhost:3000` | Main domain |
| `DB_PATH` | `data/urls.db` | SQLite path |
| `MAX_LINKS` | `10000` | Max total links |

## Custom Domain Setup

```nginx
server {
    listen 80;
    server_name go.mybrand.com;
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
    }
}
```

## API

```bash
# Create a private, expiring link
curl -X POST http://localhost:3000/api/shorten \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com",
    "domain": "go.mybrand.com",
    "custom_code": "secret",
    "password": "mypass",
    "expires": "24"
  }'
```
