# ReVISit — DigitalOcean Deployment

Deploys the full self-hosted stack — reVISit app + Supabase — on a single DigitalOcean Droplet (or any plain Ubuntu LTS VPS) using Docker Compose and Caddy for automatic TLS.

This is the recommended self-hosted path. For a managed PaaS alternative see [`deploy/coolify/README.md`](../coolify/README.md).

---

## Files in this directory

| File | Purpose |
|---|---|
| `docker-compose.yml` | App (`study`) + Caddy reverse proxy. Run with `--project-directory .` from the repo root. |
| `../Caddyfile` | Caddy config consumed by `docker-compose.yml` (stays in `deploy/` — shared with local dev) |
| `../.env.prod.example` | Template for `deploy/.env.prod` (domains) |

The `Dockerfile` at the **repo root** is used for the app build. Do not move it.

---

## Prerequisites

- Ubuntu LTS Droplet, **4 GB RAM minimum** (8 GB recommended; see swap note in Troubleshooting)
- Docker + Compose plugin installed (`docker compose` command works)
- DNS control for your domain

---

## Step 1 — Create Droplet and point DNS

1. Create an Ubuntu LTS Droplet.
2. Create two A records pointing at the Droplet's public IP:

| Hostname | Record |
|---|---|
| `study.<your-domain>` | A → Droplet IP |
| `api.<your-domain>` | A → Droplet IP |

3. SSH to the server and install Docker:

```bash
ssh <user>@<droplet-ip>
curl -fsSL https://get.docker.com | sh
```

---

## Step 2 — Clone repo and configure env

```bash
git clone <your-repo-url>
cd <repo-directory>
```

**Configure domains:**

```bash
cp deploy/.env.prod.example deploy/.env.prod
```

Edit `deploy/.env.prod`:

```dotenv
STUDY_DOMAIN=study.<your-domain>
API_DOMAIN=api.<your-domain>
```

**Configure Supabase secrets** in `supabase/.env`:

- Rotate all defaults (`POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `DASHBOARD_PASSWORD`).
- Set the three URL fields to match your domain:

```dotenv
SITE_URL=https://study.<your-domain>
API_EXTERNAL_URL=https://api.<your-domain>
SUPABASE_PUBLIC_URL=https://api.<your-domain>
```

---

## Step 3 — Start services

**Start Supabase** (creates the `revisit_net` Docker network used by the app stack):

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
```

**Bootstrap reVISit schema** (first deploy only — safe to re-run):

```bash
bash supabase/setup-revisit.sh
```

This creates the `revisit` table, RLS policies, storage bucket, and storage policies. No browser or Supabase Studio required.

**Start app + Caddy reverse proxy:**

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod up -d --build
```

> `--project-directory .` is required because the compose file lives in a subdirectory. It keeps all relative paths (build context, Caddyfile volume) anchored to the repo root.

---

## Step 4 — Configure firewall

Allow inbound:
- `22` (SSH) — from your admin IP only
- `80`, `443` — from the internet

Keep all other ports (Postgres, Kong direct, Studio) closed externally.

---

## Step 5 — Smoke test

From your laptop:

```bash
curl -I https://study.<your-domain>/
curl -i https://api.<your-domain>/auth/v1/health
curl -i https://api.<your-domain>/rest/v1/
```

Expected:
- Study: `200` (Caddy may issue a `301` redirect to HTTPS first)
- API without key: `401 No API key found in request` (correct — confirms routing)

---

## Operational commands

All commands run from the **repo root** on the server.

### View container status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Tail logs

```bash
# App and proxy
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod logs -f caddy study

# Supabase services
docker compose -f supabase/docker-compose.yml --env-file supabase/.env \
  logs -f kong auth rest storage db
```

### Rebuild and restart app only

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod up -d --build
```

### Stop all stacks

```bash
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod down
docker compose -f supabase/docker-compose.yml --env-file supabase/.env down
```

---

## Troubleshooting

**`network revisit_net declared as external, but could not be found`**

The app stack was started before Supabase. Supabase creates `revisit_net`; start it first:

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
# wait ~30 s for containers to start, then:
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod up -d --build
```

**Caddy certificate not issued (HTTPS not working)**

- Verify DNS has propagated: `dig +short study.<your-domain>` and `dig +short api.<your-domain>` should return the Droplet IP.
- Ports 80 and 443 must be open inbound.

**Study route returns `403 Forbidden`**

Rebuild the `study` container to pick up the latest nginx fallback config:

```bash
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod build --no-cache study
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod up -d
```

**App shows `STORAGE DISCONNECTED`**

1. Ensure schema was bootstrapped: `bash supabase/setup-revisit.sh`
2. Confirm the API is reachable: `curl -i https://api.<your-domain>/auth/v1/health`
3. Confirm `deploy/.env.prod` uses plain hostnames (no `https://`):
   ```dotenv
   STUDY_DOMAIN=study.<your-domain>
   API_DOMAIN=api.<your-domain>
   ```
4. Confirm the app was built with the correct env — recommended pattern:
   ```bash
   export VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)"
   docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
     --env-file deploy/.env.prod build study
   docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
     --env-file deploy/.env.prod up -d
   ```

**Build fails with `ESOCKETTIMEDOUT`**

Transient. Retry — the `Dockerfile` already includes a yarn retry loop and 600 s timeout.

**Build hangs at `tsc && vite build` for many minutes**

This step can take 10–30 minutes on a 2 GB Droplet. Check memory:

```bash
docker stats --no-stream
free -h
```

If RAM free is under ~100 MB and swap is nearly full, add swap before retrying:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Then retry without `--no-cache`:

```bash
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file deploy/.env.prod build study
```

**Supabase service unhealthy**

```bash
docker logs --tail 200 <container-name>
```

The `analytics` (Logflare) container may stay unhealthy — this is expected and does not affect reVISit.
