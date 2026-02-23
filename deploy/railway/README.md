# ReVISit — Railway Deployment

Railway hosts the reVISit **app container only**. Supabase must already be running somewhere — either on [Supabase.com](https://supabase.com) (managed) or self-hosted (see [`supabase/`](../../supabase/) and [`deploy/DEPLOYMENT_RUNBOOK.md`](../DEPLOYMENT_RUNBOOK.md)).

`railway.json` lives in this directory (`deploy/railway/railway.json`). Railway lets you specify a custom config file path in the service settings, so it does not need to be at the repo root.

---

## Prerequisites

- Railway account and project at [railway.com](https://railway.com)
- This repository connected to Railway (GitHub integration or `railway link`)
- Supabase already running — note your **API URL** and **anon key**

---

## How it works

Railway builds the app using the repo's `Dockerfile`, passing three `VITE_*` values as Docker build args so they are baked into the static JavaScript bundle. At runtime, Railway injects a dynamic `PORT` environment variable; the nginx container reads it via `envsubst` from `deploy/nginx.conf`.

| What | How |
|---|---|
| **Build** | `Dockerfile` (multi-stage: Node 20 build → nginx:alpine serve) |
| **Config file** | `railway.json` at repo root |
| **TLS / routing** | Railway platform (automatic, no config needed) |
| **Supabase** | External — referenced only by build-time env vars |
| **PORT** | Injected by Railway at runtime; nginx reads via envsubst |

---

## Step 1 — Set environment variables

In the Railway dashboard → your service → **Variables**, add:

| Variable | Value |
|---|---|
| `VITE_STORAGE_ENGINE` | `supabase` |
| `VITE_SUPABASE_URL` | Your Supabase API URL (e.g. `https://api.example.com` or your Supabase.com project URL) |
| `VITE_SUPABASE_ANON_KEY` | Anon key from your Supabase deployment |

> **Important:** These values are baked into the JavaScript bundle at build time. Set them **before** your first deploy, or trigger a fresh deploy after changing them.

---

## Step 2 — Deploy

Trigger a deploy from the Railway dashboard:
- Click **Deploy** on your service, or
- Push a commit to the connected branch.

Railway will:
1. Detect `railway.json` and build using the `Dockerfile`.
2. Pass the `VITE_*` values from your Variables tab as Docker build args.
3. Run the nginx container, injecting `PORT` at startup.
4. Perform a healthcheck at `/` (configured in `railway.json`).

---

## Step 3 — Smoke test

```bash
curl -I https://<your-app>.up.railway.app/
```

Expected: `200 OK`.

---

## railway.json reference

`railway.json` is at `deploy/railway/railway.json`. Configure the path in the Railway dashboard under service settings → **Source** → **Config file path**.

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build": {
    "builder": "DOCKERFILE",
    "dockerfilePath": "Dockerfile",
    "buildArgs": {
      "VITE_STORAGE_ENGINE": "${{VITE_STORAGE_ENGINE}}",
      "VITE_SUPABASE_URL": "${{VITE_SUPABASE_URL}}",
      "VITE_SUPABASE_ANON_KEY": "${{VITE_SUPABASE_ANON_KEY}}"
    }
  },
  "deploy": {
    "healthcheckPath": "/",
    "healthcheckTimeout": 300,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 3
  }
}
```

The `${{VAR}}` syntax is Railway's variable interpolation — it reads from the Variables tab at build time.

---

## Troubleshooting

**Build fails with `ESOCKETTIMEDOUT` / network timeout**
Transient. Retry the build — the `Dockerfile` already includes a retry loop and bumps the yarn timeout to 600 s.

**App loads but shows `STORAGE DISCONNECTED`**
- Confirm `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` are set in Variables and match your Supabase instance.
- After changing variables, trigger a new deploy (the bundle must be rebuilt).
- Verify your Supabase API is reachable: `curl -i <VITE_SUPABASE_URL>/auth/v1/health` — expected `200`.

**PORT error / nginx fails to start**
Railway injects `PORT` automatically. If you have manually set a `PORT` variable in the Railway dashboard, remove it and let Railway manage it.

**Healthcheck times out**
The healthcheck allows 300 s for the build. If the build is slow on first deploy (Node install + TypeScript compile), this is normal. Subsequent deploys use Docker layer cache and are faster.
