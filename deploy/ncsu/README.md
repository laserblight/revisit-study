# ReVISit — NCSU LAS Workspace Deployment

Deploys the full self-hosted stack — reVISit app + Supabase — on an NCSU LAS workspace VM using Docker Compose and the VM's existing nginx as a reverse proxy.

For deployment on a standalone VPS with its own domain and TLS, see [`deploy/digitalocean/README.md`](../digitalocean/README.md).

---

## How this differs from the DigitalOcean deployment

NCSU workspace VMs sit behind an institutional reverse proxy (`proxy.ncsu-las.net`) that terminates TLS and handles SSO authentication. This creates three constraints the DigitalOcean path doesn't have:

1. **Single domain only.** You get `ws-<user>.ncsu-las.net` — you cannot create subdomains like `api.ws-<user>.ncsu-las.net` since NCSU controls DNS. All Supabase API routes (`/auth/v1/`, `/rest/v1/`, `/storage/v1/`, etc.) are path-routed on the same hostname as the study app.

2. **No Caddy / no ACME.** TLS is handled by the NCSU proxy upstream. Caddy's automatic certificate issuance cannot work because the VM never receives direct TLS connections and cannot complete ACME challenges. The VM's own nginx handles reverse-proxy routing instead.

3. **No firewall changes.** The NCSU infrastructure manages firewall rules. Running `ufw` on the VM interferes with the workspace's existing services (VS Code, Jupyter, XFCE desktop, etc.).

| | DigitalOcean | NCSU |
|---|---|---|
| Domains | 2 (study + api) | 1 (study domain only) |
| TLS | Caddy ACME (automatic) | NCSU proxy (managed) |
| Reverse proxy | Caddy container | System nginx |
| API routing | Subdomain-based | Path-based (`/auth/v1/`, `/rest/v1/`, etc.) |
| Firewall | UFW managed by setup.sh | Managed by NCSU (do not touch) |
| Kong port | 8000 | 8100 (avoids workspace nginx conflict) |

---

## Files in this directory

| File | Purpose |
|---|---|
| `setup.sh` | One-command bootstrap — run this after editing `supabase/.env` |
| `uninstall.sh` | Tears down containers, restores nginx, removes networks. Pass `--purge` to also delete data |
| `docker-compose.yml` | App (`study`) container only — no Caddy |
| `supabase-override.yml` | Compose override layered on `supabase/docker-compose.yml` to expose Kong on `127.0.0.1:8100` for the system nginx |
| `nginx-revisit.conf` | nginx site config installed by `setup.sh` to route traffic to the containers |

**Single config file:** `supabase/.env` (at the repo root) is the only file you edit. `API_DOMAIN` is ignored — the setup script derives all URLs from `STUDY_DOMAIN` alone.

The `Dockerfile` at the **repo root** is used for the app build. Do not move it.

---

## Prerequisites

- NCSU LAS workspace VM with Docker + Compose plugin installed
- nginx installed (standard on workspace VMs)
- Your workspace hostname (e.g. `ws-jjlight.ncsu-las.net`)

---

## Step 1 — Edit `supabase/.env`

Open the **REQUIRED block** at the top of `supabase/.env`:

```bash
nano supabase/.env
```

Set these values:

```dotenv
STUDY_DOMAIN=ws-<user>.ncsu-las.net

POSTGRES_PASSWORD=<strong-password>
DASHBOARD_PASSWORD=<strong-password>
JWT_SECRET=<32+-char-random-string>
ANON_KEY=<jwt-derived-from-JWT_SECRET>
SERVICE_ROLE_KEY=<jwt-derived-from-JWT_SECRET>
```

> **Note:** `API_DOMAIN` is present in the file but ignored by this deployment — the NCSU setup script routes everything through `STUDY_DOMAIN`.

> **JWT keys:** `ANON_KEY` and `SERVICE_ROLE_KEY` must match `JWT_SECRET`. Use the [Supabase JWT generator](https://supabase.com/docs/guides/self-hosting#generate-api-keys) to derive them. For a quick test deployment the committed defaults work as a matched set — just change the domain name and passwords.

---

## Step 2 — Run the setup script

```bash
bash deploy/ncsu/setup.sh
```

The script:
1. Validates your config (fails fast if defaults are still present)
2. Writes derived URL fields into `supabase/.env` (single-domain mode)
3. Sets `KONG_HTTP_PORT=8100` (avoids conflict with workspace port 8000)
4. Installs the nginx reverse-proxy config (backs up and replaces the default site on port 80; **does not touch the port 8000 workspace services config**)
5. Starts the Supabase stack
6. Bootstraps the reVISit schema (table, RLS, storage bucket)
7. Builds and starts the app container

The first build takes a few minutes (TypeScript compile). Subsequent builds use Docker layer cache and are much faster.

---

## Step 3 — Smoke test

From a terminal on the VM (or the XFCE desktop browser):

```bash
curl -I http://localhost/
curl -si http://localhost/auth/v1/health \
  -H "apikey: $(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)"
```

Expected:
- Study: `200 OK` with HTML content
- Auth: `200` with a JSON health response containing the GoTrue version

### External access

Accessing `https://ws-<user>.ncsu-las.net/` from outside the VM goes through the NCSU reverse proxy, which currently routes to the workspace Commander page (port 8000), not to port 80 where the app is served. Getting external access may require coordination with the NCSU LAS team to adjust the proxy routing for your workspace.

---

## Operational commands

All commands run from the **repo root** on the VM.

### View container status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Tail logs

```bash
# App
docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
  --env-file supabase/.env logs -f study

# Supabase services
docker compose -f supabase/docker-compose.yml -f deploy/ncsu/supabase-override.yml \
  --env-file supabase/.env logs -f kong auth rest storage db
```

### Deploy study changes (add/edit studies in `public/`)

```bash
git pull
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
  --env-file supabase/.env up -d --build study
```

### Rebuild everything

```bash
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
  --env-file supabase/.env up -d --build
```

### Stop all stacks

```bash
docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
  --env-file supabase/.env down
docker compose -f supabase/docker-compose.yml -f deploy/ncsu/supabase-override.yml \
  --env-file supabase/.env down
```

### Full uninstall

Stops all containers, restores the default nginx site, and removes Docker networks:

```bash
bash deploy/ncsu/uninstall.sh
```

To also delete Docker volumes and on-disk data (Postgres, Minio storage):

```bash
bash deploy/ncsu/uninstall.sh --purge
```

After uninstalling, you can re-run `setup.sh` for a clean install. Without `--purge`, your database and storage data are preserved across reinstalls.

---

## Architecture

```
Browser → NCSU proxy (TLS + SSO) → VM nginx:80 → Docker containers
                                       ├── /auth/v1/*     → Kong:8100 → GoTrue
                                       ├── /rest/v1/*     → Kong:8100 → PostgREST
                                       ├── /storage/v1/*  → Kong:8100 → Storage API
                                       ├── /realtime/v1/* → Kong:8100 → Realtime
                                       ├── /graphql/v1    → Kong:8100 → pg_graphql
                                       └── /*             → study:3001 (reVISit app)
```

The nginx config (`nginx-revisit.conf`) replaces only the default site on port 80. The workspace services config (`/etc/nginx/conf.d/server.conf` on port 8000) is not touched — VS Code, Jupyter, XFCE desktop, and file browser continue to work normally.

---

## Troubleshooting

**`network revisit_net declared as external, but could not be found`**

The app stack was started before Supabase. Supabase creates `revisit_net`; start it first:

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d
# wait ~30 s for containers to start, then:
VITE_SUPABASE_ANON_KEY="$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)" \
  docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
  --env-file supabase/.env up -d --build
```

**Study route returns `502 Bad Gateway`**

The study container isn't running or hasn't started yet. Check:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs supabasetest-study-1
```

**App shows `STORAGE DISCONNECTED`**

1. Ensure schema was bootstrapped: `bash supabase/setup-revisit.sh`
2. Confirm the API is reachable locally: `curl -i http://localhost/auth/v1/health -H "apikey: <your-anon-key>"`
3. Confirm `STUDY_DOMAIN` in `supabase/.env` is a plain hostname (no `https://`)
4. Re-run `setup.sh`:
   ```bash
   bash deploy/ncsu/setup.sh
   ```

**Build fails with permission denied on `supabase/volumes/db/data`**

Ensure `.dockerignore` at the repo root excludes `supabase/volumes`. The setup script's Docker build context is the entire repo; the Postgres data directory is owned by root and must be excluded.

**Build fails with `ESOCKETTIMEDOUT`**

Transient. Retry — the `Dockerfile` already includes a yarn retry loop and 600 s timeout.

**Supabase service unhealthy**

```bash
docker logs --tail 200 <container-name>
```

The `analytics` (Logflare) and `storage` containers may show as unhealthy on memory-constrained VMs — this is often cosmetic and does not affect reVISit functionality.
