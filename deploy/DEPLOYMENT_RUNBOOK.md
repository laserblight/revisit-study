# ReVISit Docker Deployment Runbook

This guide covers:
- Local testing (native + full Docker)
- Production-style deployment on a DigitalOcean Droplet
- Smoke tests and troubleshooting

## 1) Prerequisites

- Docker + Docker Compose plugin installed (`docker compose` command works)
- DNS control for your domain (for production)
- This repository checked out on your machine/server

Command copy note:
- Paste commands as plain text in your shell.
- Do not include rendered markdown/link text like `[docker-compose.prod.yml](...)` in terminal commands.

---

## 2) Local testing

### Option A: Native frontend + Docker Supabase

Use this for faster frontend iteration.

1. Create shared Docker network (once):

```bash
docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net
```

2. Start Supabase with local-exposed ports:

```bash
docker compose -f supabase/docker-compose.yml -f supabase/docker-compose.local.yml --env-file supabase/.env up -d
```

3. **Bootstrap reVISit schema (first time only — safe to re-run):**

```bash
bash supabase/setup-revisit.sh
```

4. In root `.env`, set:

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

5. Open:
- App: http://localhost:8080

### Option B: Full local Docker (app + proxy + supabase)

Use this for production parity.

1. Create shared network (once):

```bash
docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net
```

2. Start Supabase stack:

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
```

3. Start app + local Caddy proxy:

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" docker compose -f docker-compose.local.yml --env-file deploy/.env.local.example up -d --build
```

4. Open:
- App: http://localhost:8080
- API host (through proxy): http://api.localhost:8080

If `api.localhost` does not resolve, add this to hosts file:

```text
127.0.0.1 api.localhost
```

---

## 3) Local smoke tests

### Basic route checks

```bash
curl -i http://localhost:8080/
curl -i --resolve api.localhost:8080:127.0.0.1 http://api.localhost:8080/auth/v1/health
curl -i --resolve api.localhost:8080:127.0.0.1 http://api.localhost:8080/rest/v1/
```

Expected results:
- App route: `200`
- API routes without key: `401` with message `No API key found in request` (this is expected and confirms routing)

### Authenticated API check (optional)

```bash
ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)"
curl -i --resolve api.localhost:8080:127.0.0.1 \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}" \
  http://api.localhost:8080/auth/v1/settings
```

---

## 4) Deploy to DigitalOcean (Droplet)

## 4.1 Create and prepare server

1. Create Ubuntu LTS Droplet.
2. Point DNS records:
   - `study.<your-domain>` -> Droplet public IP
   - `api.<your-domain>` -> Droplet public IP
3. SSH to server:

```bash
ssh <user>@<server-ip>
```

4. Install Docker + Compose plugin.

## 4.2 Clone repo and configure env

```bash
git clone <your-repo-url>
cd supabasetest
```

1. Configure app/proxy domains:

```bash
cp deploy/.env.prod.example deploy/.env.prod
```

Edit `deploy/.env.prod`:

```dotenv
STUDY_DOMAIN=study.<your-domain>
API_DOMAIN=api.<your-domain>
```

2. Edit `supabase/.env` for production:
- Rotate all defaults/secrets (`POSTGRES_PASSWORD`, `JWT_SECRET`, keys, dashboard password).
- Set:

```dotenv
SITE_URL=https://study.<your-domain>
API_EXTERNAL_URL=https://api.<your-domain>
SUPABASE_PUBLIC_URL=https://api.<your-domain>
```

## 4.3 Start services

1. Create shared network:

```bash
docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net
```

2. Start Supabase:

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
```

3. **Bootstrap reVISit schema (first deploy only — safe to re-run):**

   This creates the `revisit` table, RLS policies, storage bucket, and storage policies
   that reVISit requires. No browser or Supabase dashboard required.

```bash
bash supabase/setup-revisit.sh
```

4. Start app + Caddy reverse proxy:

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d --build
```

## 4.4 Configure firewall

Allow inbound:
- `22` (SSH) from your admin IP(s)
- `80`, `443` from internet

Keep internal/admin ports private.

## 4.5 Production smoke tests

From your laptop:

```bash
curl -I https://study.<your-domain>/
curl -i https://api.<your-domain>/auth/v1/health
curl -i https://api.<your-domain>/rest/v1/
```

Expected:
- Study: `200` (or `301/308` then `200`)
- API without key: `401` (expected)

---

## 5) Deploy to Railway (app only)

Railway hosts the reVISit app container. Supabase must be running elsewhere (self-hosted or Supabase.com).

### 5.1 Prerequisites

- Railway account and project created at [railway.com](https://railway.com)
- Supabase already running (self-hosted or managed) — note your API URL and anon key.
- `railway.json` in the repo root (already committed) — configures Dockerfile build and healthcheck.

### 5.2 Set environment variables in Railway

In the Railway dashboard → your service → Variables, add:

| Variable | Value |
|---|---|
| `VITE_STORAGE_ENGINE` | `supabase` |
| `VITE_SUPABASE_URL` | `https://api.<your-domain>` (or Supabase.com project URL) |
| `VITE_SUPABASE_ANON_KEY` | anon key from your Supabase deployment |

> **Important:** These values are baked into the JavaScript bundle at build time. Set them *before* your first deploy, or redeploy after changing them.

### 5.3 Deploy

Trigger a deploy from the Railway dashboard (push to connected branch or click **Deploy**).

Railway injects a dynamic `PORT` at runtime; the nginx container reads it via envsubst so no additional configuration is needed.

### 5.4 Smoke test

```bash
curl -I https://<your-app>.up.railway.app/
```

Expected: `200`.

---

## 6) Deploy to Coolify (full self-hosted: app + Supabase)

Coolify is a self-hosted PaaS that runs on any VPS and manages Docker Compose stacks with automatic Traefik routing and TLS. This is the recommended path for full self-hosted deployments.

### 6.1 Prerequisites

- VPS with Ubuntu LTS, **4 GB RAM minimum** (8 GB recommended for build headroom).
- DNS control for your domain.
- Coolify installed:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

  Wait 1–2 minutes, then open `http://<droplet-ip>:8000` to complete the Coolify setup wizard.

### 6.2 DNS (do this first — propagation takes time)

Create two A records pointing at your Coolify droplet's public IP:

| Hostname | Record |
|---|---|
| `api.<your-domain>` | A → Coolify IP |
| `study.<your-domain>` | A → Coolify IP |

### 6.3 Deploy Supabase

1. In Coolify: **New Resource → Docker Compose → Git repository**.
2. Connect your repo, branch `main`.
3. Set:
   - **Compose file path**: `supabase/docker-compose.yml`
   - **Override / merge file**: `supabase/docker-compose.coolify.yml`
4. Paste all variables from `supabase/.env`, updating these three:

```dotenv
SITE_URL=https://study.<your-domain>
API_EXTERNAL_URL=https://api.<your-domain>
SUPABASE_PUBLIC_URL=https://api.<your-domain>
```

5. Assign the domain `api.<your-domain>` to the **kong** service (port `8000`).
6. Deploy and wait for all containers to reach healthy status (~2–3 minutes).

> **What the override file does**: `supabase/docker-compose.coolify.yml` removes the `revisit_net` external network requirement that the DigitalOcean setup needs. Coolify handles networking internally, so the cross-stack shared network is not required.

### 6.4 Bootstrap reVISit schema

After Supabase is healthy, open a terminal to the Coolify droplet and run:

```bash
cd <repo-directory>
bash supabase/setup-revisit.sh
```

Or run the SQL manually in the Supabase Studio SQL editor using the contents of `supabase/volumes/db/revisit.sql`.

Verify (expected output: `(1 row)` for each check):

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env \
  exec -T db psql -U postgres -c "SELECT count(*) FROM public.revisit;"
```

### 6.5 Deploy reVISit app

1. In Coolify: **New Resource → Dockerfile → Git repository**.
2. Connect same repo, branch `main`, Base Directory `/`.
3. Set build arguments:

| Build arg | Value |
|---|---|
| `VITE_STORAGE_ENGINE` | `supabase` |
| `VITE_SUPABASE_URL` | `https://api.<your-domain>` |
| `VITE_SUPABASE_ANON_KEY` | `ANON_KEY` value from `supabase/.env` |

4. Port: `80`.
5. Assign domain `study.<your-domain>`.
6. Deploy.

### 6.6 Smoke test

```bash
curl -I https://study.<your-domain>/
curl -i https://api.<your-domain>/auth/v1/health
```

Open `https://study.<your-domain>` in a browser and confirm no **STORAGE DISCONNECTED** badge.

---

## 7) Operational commands

### View status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Tail logs

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod logs -f caddy study
docker compose -f supabase/docker-compose.yml --env-file supabase/.env logs -f kong auth rest storage db
```

### Restart app/proxy only

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d --build
```

### Stop local stacks

```bash
docker compose -f docker-compose.local.yml --env-file deploy/.env.local.example down
docker compose -f supabase/docker-compose.yml --env-file supabase/.env down
```

---

## 8) Troubleshooting

- Error: `network revisit_net declared as external, but could not be found`
  - Create the shared network explicitly, then retry compose:

```bash
docker network inspect revisit_net >/dev/null 2>&1 || docker network create --driver bridge revisit_net
docker network ls | grep revisit_net
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
```

  - If it still fails, ensure you are using the same Docker daemon/context for both commands:

```bash
docker context show
docker info --format '{{.Name}}'
```

- `api.localhost` not resolving locally:
  - Add `127.0.0.1 api.localhost` to hosts file.
- API returns `401 No API key found in request`:
  - Routing is working; add `apikey` and `Authorization` headers for authenticated checks.
- Caddy certificate delay on new domain:
  - Verify DNS A records have propagated and ports `80/443` are reachable publicly.
- Study route returns `403 Forbidden` from nginx for paths like `/demo-screen-recording/`:
  - Rebuild and restart the `study` app container so the latest nginx fallback config is included:

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build --no-cache study
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d
```

  - Confirm the new image/container is active:

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod ps
docker logs --tail 50 $(docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod ps -q study)
```

  - Then retest:

```bash
curl -I https://study.<your-domain>/demo-screen-recording/
```
- A Supabase service is unhealthy:
  - Inspect logs for that container:

```bash
docker logs --tail 200 <container-name>
```

- App image build fails with `ESOCKETTIMEDOUT` / `There appears to be trouble with your network connection`:
  - This is usually transient network/registry timeout on the server.
  - First verify your Droplet has the latest Dockerfile updates:

```bash
grep -n "registry.npmjs.org" Dockerfile
grep -n "network-timeout 600000" Dockerfile
```

  - If those commands return no lines, update your server copy of the repo before rebuilding.
  - Retry build once (often succeeds on second run):

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build --no-cache study
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d
```

  - Confirm outbound connectivity from the Droplet:

```bash
curl -I https://registry.npmjs.org
curl -I https://registry.yarnpkg.com
```

- App image build appears to hang at `tsc && vite build` (`[build 6/6]`):
  - This is often the slowest step and can take `10-30` minutes on small VMs.
  - Check whether it is still making progress:

```bash
docker stats --no-stream
free -h
```

  - Hard threshold for action:
    - If RAM free is under ~`100Mi` **and** swap is nearly/full (`Swap free ~0`), the build is usually thrashing.
    - In that state, stop the build and temporarily resize to `4GB` (or add more swap), then rebuild.

  - If memory is tight, add swap (recommended on 2 GB Droplets):

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

  - Then rerun build without `--no-cache` for faster retries:

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build study
```

- Study loads but shows `STORAGE DISCONNECTED` / `Failed to connect to the storage engine`:
  - **First, ensure the reVISit schema has been bootstrapped** (table, RLS, storage bucket):

```bash
bash supabase/setup-revisit.sh
```

  - Verify API domain is reachable publicly:

```bash
curl -i https://api.<your-domain>/auth/v1/health
curl -i https://api.<your-domain>/rest/v1/
```

  - Expected without API key: `401` (this confirms routing works).

  - Verify `deploy/.env.prod` uses plain hostnames (no `https://`):

```dotenv
STUDY_DOMAIN=study.<your-domain>
API_DOMAIN=api.<your-domain>
```

  - Confirm app bundle was built with the correct API domain:

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod exec study sh -lc "grep -R 'api\\.' -n /usr/share/nginx/html/assets | head"
```

  - If it shows wrong domain (for example `api.example.com`), rebuild app with correct env:

```bash
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build --no-cache study
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d
```

  - Verify app uses the same anon key as Supabase:

```bash
grep '^ANON_KEY=' supabase/.env
echo "${#VITE_SUPABASE_ANON_KEY}"
```

  - Recommended deploy pattern to avoid mismatch:

```bash
export VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)"
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build study
docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d
```
