# ReVISit — Coolify Deployment

Coolify is a self-hosted PaaS that runs on any Linux VPS. It manages Docker Compose stacks and Dockerfile-based apps with automatic Traefik routing and TLS. This guide deploys a **full self-hosted stack**: reVISit app + Supabase, all on one VPS managed by Coolify.

If you only need to deploy the app and use an external Supabase, see [`deploy/railway/README.md`](../railway/README.md) or [`deploy/render/README.md`](../render/README.md) instead.

---

## How it works

| Component | How Coolify manages it |
|---|---|
| **Supabase** | Docker Compose resource (pointed at `supabase/docker-compose.yml`) |
| **reVISit app** | Dockerfile resource (builds from repo root `Dockerfile`) |
| **TLS / routing** | Traefik (built into Coolify — automatic ACME certificates) |
| **PORT** | nginx listens on `80` inside the container; Traefik handles HTTPS externally |

---

## Prerequisites

- VPS with **Ubuntu LTS**, **4 GB RAM minimum** (8 GB recommended — the TypeScript build is memory-heavy on first deploy).
- DNS control for your domain.
- This repository accessible to Coolify (public GitHub URL or connected GitHub account).

---

## Step 1 — Install Coolify

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Wait 1–2 minutes, then open `http://<your-vps-ip>:8000` and complete the Coolify setup wizard. Create your admin account.

---

## Step 2 — DNS (do this first — propagation takes time)

Create two A records pointing at your VPS's public IP:

| Hostname | Record |
|---|---|
| `api.<your-domain>` | A → VPS IP |
| `study.<your-domain>` | A → VPS IP |

Coolify's Traefik will obtain TLS certificates for both once DNS has propagated.

---

## Step 3 — Deploy Supabase

1. In Coolify: **New Resource → Docker Compose → Git repository**.
2. Connect your repository, select branch `main`.
3. Set **Compose file path**: `supabase/docker-compose.yml`.
4. Paste all variables from `supabase/.env` into Coolify's environment editor. **Update these three** to match your domain:

```dotenv
SITE_URL=https://study.<your-domain>
API_EXTERNAL_URL=https://api.<your-domain>
SUPABASE_PUBLIC_URL=https://api.<your-domain>
```

5. In the service networking settings, assign the domain `api.<your-domain>` to the **kong** service on port `8000`.
6. Rotate all default secrets before deploying to production:

| Variable | Action |
|---|---|
| `POSTGRES_PASSWORD` | Generate a strong random password |
| `JWT_SECRET` | Generate ≥32-character random string |
| `ANON_KEY` | Re-derive from new `JWT_SECRET` (see Supabase docs) |
| `SERVICE_ROLE_KEY` | Re-derive from new `JWT_SECRET` |
| `DASHBOARD_PASSWORD` | Set a strong password |

7. Deploy. Wait for all containers to reach healthy status (~2–3 minutes). The `analytics` (Logflare) service may stay unhealthy — this is expected and does not affect reVISit.

---

## Step 4 — Bootstrap reVISit schema

After Supabase is healthy, SSH to the VPS and run:

```bash
cd <path-to-repo>
bash supabase/setup-revisit.sh
```

This idempotently creates the `revisit` table, RLS policies, storage bucket, and storage policies. It is safe to re-run.

Alternatively, paste the contents of `supabase/volumes/db/revisit.sql` into the Supabase Studio SQL editor (available in Coolify via the Studio service).

Verify (each query should return `(1 row)`):

```bash
docker compose -f supabase/docker-compose.yml --env-file supabase/.env \
  exec -T db psql -U postgres -c "SELECT count(*) FROM public.revisit;"
```

---

## Step 5 — Deploy reVISit app

1. In Coolify: **New Resource → Dockerfile → Git repository**.
2. Connect the same repository, branch `main`, Base Directory `/`.
3. Set build arguments:

| Build arg | Value |
|---|---|
| `VITE_STORAGE_ENGINE` | `supabase` |
| `VITE_SUPABASE_URL` | `https://api.<your-domain>` |
| `VITE_SUPABASE_ANON_KEY` | `ANON_KEY` value from `supabase/.env` |

4. Set port to `80`.
5. Assign domain `study.<your-domain>`.
6. Deploy.

> **Note:** The first build can take 10–30 minutes on a 2 GB VPS due to the TypeScript compile step. Add swap if needed (see Troubleshooting below).

---

## Step 6 — Smoke test

```bash
curl -I https://study.<your-domain>/
curl -i https://api.<your-domain>/auth/v1/health
```

Expected:
- Study: `200 OK`
- API without key: `401` with `No API key found in request` (confirms routing works)

Open `https://study.<your-domain>` in a browser and confirm there is no **STORAGE DISCONNECTED** badge in the header.

---

## Operational commands

These are run from the VPS (SSH in first):

### View container status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Tail logs

```bash
# Supabase services
docker compose -f supabase/docker-compose.yml --env-file supabase/.env logs -f kong auth rest storage db

# reVISit app (Coolify manages the container name; check `docker ps` output)
docker logs -f <revisit-container-name>
```

### Rebuild app after config change

```bash
# In Coolify dashboard: click Redeploy on the reVISit app resource.
# Or trigger via git push to the connected branch.
```

---

## Troubleshooting

**Build hangs at `tsc && vite build` for many minutes**
This step can take 10–30 minutes on a 2 GB VPS. Check memory:

```bash
docker stats --no-stream
free -h
```

If RAM free is under ~100 MB and swap is full, add swap:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Then redeploy from the Coolify dashboard.

**App shows `STORAGE DISCONNECTED`**
- Confirm `supabase/setup-revisit.sh` has been run (creates the table and storage bucket).
- Confirm the `VITE_SUPABASE_URL` build arg matches the URL Kong is reachable at.
- Verify the API is reachable: `curl -i https://api.<your-domain>/auth/v1/health`.
- Confirm the `VITE_SUPABASE_ANON_KEY` build arg matches the `ANON_KEY` in `supabase/.env`.

**Traefik certificate not issued**
- Verify DNS A records have propagated: `dig +short api.<your-domain>` and `dig +short study.<your-domain>` should return your VPS IP.
- Ports 80 and 443 must be open inbound on the VPS firewall.

**`analytics` (Logflare) container is unhealthy**
Expected — reVISit does not use Logflare. The `depends_on` conditions in `supabase/docker-compose.yml` are set to `service_started` (not `service_healthy`) for this service, so the rest of the stack is unaffected.

**Build fails with `ESOCKETTIMEDOUT`**
Transient network/registry timeout on the VPS. The `Dockerfile` includes a retry loop. Retrigger the deploy from the Coolify dashboard.
