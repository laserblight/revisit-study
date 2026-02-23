# ReVISit — DigitalOcean Deployment

Deploys the full self-hosted stack — reVISit app + Supabase — on a single DigitalOcean Droplet (or any plain Ubuntu LTS VPS) using Docker Compose and Caddy for automatic TLS.

This is the recommended self-hosted path. For a managed PaaS alternative see [`deploy/coolify/README.md`](../coolify/README.md).

---

## Files in this directory

| File | Purpose |
|---|---|
| `setup.sh` | One-command bootstrap — run this after editing `supabase/.env` |
| `docker-compose.yml` | App (`study`) + Caddy reverse proxy (used by `setup.sh` and operational commands) |
| `../Caddyfile` | Caddy config (stays in `deploy/` — shared with local dev) |

**Single config file:** `supabase/.env` (at the repo root) is the only file you edit. It contains both the Supabase secrets and the domain names for the reverse proxy.

The `Dockerfile` at the **repo root** is used for the app build. Do not move it.

---

## Prerequisites

- Ubuntu LTS Droplet, **4 GB RAM minimum** (8 GB recommended; see swap note in Troubleshooting)
- Docker + Compose plugin installed: `curl -fsSL https://get.docker.com | sh`
- DNS control for your domain

---

## Step 1 — Point DNS

Do this first — certificate issuance requires DNS to be live before Caddy starts.

Create two A records pointing at the Droplet's public IP:

| Hostname | Record |
|---|---|
| `study.<your-domain>` | A → Droplet IP |
| `api.<your-domain>` | A → Droplet IP |

Verify propagation from your laptop before proceeding:

```bash
dig +short study.<your-domain>
dig +short api.<your-domain>
```

Both should return the Droplet IP.

---

## Step 2 — Edit `supabase/.env`

Clone the repo on the server and open the **REQUIRED block** at the top of `supabase/.env`:

```bash
git clone <your-repo-url>
cd <repo-directory>
nano supabase/.env
```

Set these 7 values — everything else is handled automatically:

```dotenv
# Domains
STUDY_DOMAIN=study.<your-domain>
API_DOMAIN=api.<your-domain>

# Secrets (rotate all of these)
POSTGRES_PASSWORD=<strong-password>
DASHBOARD_PASSWORD=<strong-password>
JWT_SECRET=<32+-char-random-string>
ANON_KEY=<jwt-derived-from-JWT_SECRET>
SERVICE_ROLE_KEY=<jwt-derived-from-JWT_SECRET>
```

> **JWT keys:** `ANON_KEY` and `SERVICE_ROLE_KEY` must match `JWT_SECRET`. Use the [Supabase JWT generator](https://supabase.com/docs/guides/self-hosting#generate-api-keys) to derive them. For a quick test deployment the committed defaults work as a matched set — just change the domain names and passwords.

The `SITE_URL`, `API_EXTERNAL_URL`, and `SUPABASE_PUBLIC_URL` fields are set automatically by `setup.sh` from your domain values. You do not need to edit them.

---

## Step 3 — Run the setup script

```bash
bash deploy/digitalocean/setup.sh
```

The script:
1. Validates your config (fails fast if defaults are still present)
2. Writes the derived URL fields into `supabase/.env`
3. Starts the Supabase stack
4. Bootstraps the reVISit schema (table, RLS, storage bucket)
5. Builds and starts the app + Caddy reverse proxy
6. Enables UFW (ports 22, 80, 443)

The **first build takes 10–30 min** on a 4 GB Droplet (TypeScript compile). Subsequent builds use Docker layer cache and are much faster.

---

## Step 4 — Smoke test

From your laptop:

```bash
curl -I  https://study.<your-domain>/
curl -si https://api.<your-domain>/auth/v1/health
```

Expected:
- Study: `200` (Caddy may issue a `301` redirect to HTTPS on first request)
- API: `200` with a JSON health response

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
  --env-file supabase/.env logs -f caddy study

# Supabase services
docker compose -f supabase/docker-compose.yml --env-file supabase/.env \
  logs -f kong auth rest storage db
```

### Rebuild and restart app only

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file supabase/.env up -d --build
```

### Stop all stacks

```bash
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file supabase/.env down
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
  --env-file supabase/.env up -d --build
```

**Caddy certificate not issued (HTTPS not working)**

- Verify DNS has propagated: `dig +short study.<your-domain>` and `dig +short api.<your-domain>` should return the Droplet IP.
- Ports 80 and 443 must be open inbound.

**Study route returns `403 Forbidden`**

Rebuild the `study` container to pick up the latest nginx fallback config:

```bash
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file supabase/.env build --no-cache study
docker compose -f deploy/digitalocean/docker-compose.yml --project-directory . \
  --env-file supabase/.env up -d
```

**App shows `STORAGE DISCONNECTED`**

1. Ensure schema was bootstrapped: `bash supabase/setup-revisit.sh`
2. Confirm the API is reachable: `curl -i https://api.<your-domain>/auth/v1/health`
3. Confirm `STUDY_DOMAIN` and `API_DOMAIN` in `supabase/.env` are plain hostnames (no `https://`)
4. Re-run `setup.sh` — it will re-derive the URL fields and rebuild the app:
   ```bash
   bash deploy/digitalocean/setup.sh
   ```

**Build fails with `ESOCKETTIMEDOUT`**

Transient. Retry — the `Dockerfile` already includes a yarn retry loop and 600 s timeout.

**Build hangs at `tsc && vite build` for many minutes**

This step can take 10–30 minutes on a 4 GB Droplet. Check memory:

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

Then retry:

```bash
bash deploy/digitalocean/setup.sh
```

**Supabase service unhealthy**

```bash
docker logs --tail 200 <container-name>
```

The `analytics` (Logflare) container may stay unhealthy — this is expected and does not affect reVISit.
