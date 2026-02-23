# ReVISit — Deployment Overview

This directory contains deployment configurations and guides for all supported hosting targets.

```
deploy/
  README.md                        ← this file: local dev + directory guide
  digitalocean/                    ← DigitalOcean Droplet (or any plain Linux VPS)
    README.md
    setup.sh                       ← one-command bootstrap (run this)
    docker-compose.yml
  railway/                         ← Railway (app-only, external Supabase)
    README.md
    railway.json
  render/                          ← Render (app-only, external Supabase)
    README.md
    render.yaml
  coolify/                         ← Coolify (full self-hosted PaaS)
    README.md
  Caddyfile                        ← Caddy config for production (DigitalOcean)
  Caddyfile.local                  ← Caddy config for local full-Docker (Option B)
  .env.local.example               ← Domain env template for local full-Docker
  nginx.conf                       ← nginx template baked into the Docker image (all targets)
```

**Files at the repo root used in deployments:**
- `Dockerfile` — multi-stage build used by every Docker-based target; stays at root for build context
- `docker-compose.local.yml` — full local Docker stack (Option B below); stays at root for convenience

---

## Local development

### Option A: Native frontend + Docker Supabase

Use this for faster frontend iteration. The app runs natively; Supabase runs in Docker.

1. Start Supabase with host-exposed ports:

```bash
docker compose -f supabase/docker-compose.yml -f supabase/docker-compose.local.yml --env-file supabase/.env up -d
```

2. **Bootstrap reVISit schema (first time only — safe to re-run):**

```bash
bash supabase/setup-revisit.sh
```

3. In root `.env`, set:

```dotenv
VITE_STORAGE_ENGINE="supabase"
VITE_SUPABASE_URL="http://localhost:8000"
VITE_SUPABASE_ANON_KEY="<ANON_KEY from supabase/.env>"
```

4. Start frontend:

```bash
yarn install
yarn serve
```

5. Open http://localhost:8080

### Option B: Full local Docker (app + proxy + Supabase)

Use this for production parity. Everything runs in Docker; Caddy proxies both.

1. Start Supabase stack:

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
```

2. Start app + local Caddy proxy:

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f docker-compose.local.yml --env-file deploy/.env.local.example up -d --build
```

3. Open:
   - App: http://localhost:8080
   - API (through proxy): http://api.localhost:8080

If `api.localhost` does not resolve, add to `/etc/hosts`:

```
127.0.0.1 api.localhost
```

### Local smoke tests

```bash
curl -i http://localhost:8080/
curl -i --resolve api.localhost:8080:127.0.0.1 http://api.localhost:8080/auth/v1/health
curl -i --resolve api.localhost:8080:127.0.0.1 http://api.localhost:8080/rest/v1/
```

Expected: app → `200`; API without key → `401 No API key found in request` (correct — confirms routing).

### Stop local stacks

```bash
docker compose -f docker-compose.local.yml --env-file deploy/.env.local.example down
docker compose -f supabase/docker-compose.yml --env-file supabase/.env down
```

