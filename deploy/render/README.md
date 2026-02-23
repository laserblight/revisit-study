# ReVISit — Render Deployment

Render hosts the reVISit **app container only**. Supabase must already be running somewhere — either on [Supabase.com](https://supabase.com) (managed) or self-hosted (see [`supabase/`](../../supabase/) and [`deploy/DEPLOYMENT_RUNBOOK.md`](../DEPLOYMENT_RUNBOOK.md)).

`render.yaml` lives in this directory (`deploy/render/render.yaml`) to keep the repo root clean.

Render Blueprint **auto-detection** scans the repo root for `render.yaml`. If you want to use Blueprint deployment, copy the file to the root:

```bash
cp deploy/render/render.yaml render.yaml
```

For **manual service creation** from the Render dashboard (the simpler path), the file does not need to be at root — just follow the steps below and use `render.yaml` as a reference.

---

## Prerequisites

- Render account at [render.com](https://render.com)
- This repository connected to Render (GitHub integration)
- Supabase already running — note your **API URL** and **anon key**

---

## How it works

Render builds the app using the repo's `Dockerfile`. The three `VITE_*` values are passed as environment variables and baked into the static JavaScript bundle at build time. At runtime, Render injects a dynamic `PORT`; the nginx container reads it via `envsubst` from `deploy/nginx.conf`.

| What | How |
|---|---|
| **Build** | `Dockerfile` (multi-stage: Node 20 build → nginx:alpine serve) |
| **Config file** | `render.yaml` at repo root (Render Blueprint) |
| **TLS / routing** | Render platform (automatic, no config needed) |
| **Supabase** | External — referenced only by build-time env vars |
| **PORT** | Injected by Render at runtime; nginx reads via envsubst |

---

## Step 1 — Deploy via Blueprint

1. In your Render dashboard click **New → Blueprint**.
2. Connect your GitHub repository.
3. Render detects `render.yaml` and shows the `revisit` web service.
4. Click **Apply** to create the service.
5. Render will prompt you for the `sync: false` variables (see next step).

Alternatively, create a **New → Web Service** manually, set runtime to **Docker**, and point it at the same repo.

---

## Step 2 — Set environment variables

In the Render dashboard → your service → **Environment**, set:

| Variable | Value |
|---|---|
| `VITE_STORAGE_ENGINE` | `supabase` |
| `VITE_SUPABASE_URL` | Your Supabase API URL (e.g. `https://api.example.com` or your Supabase.com project URL) |
| `VITE_SUPABASE_ANON_KEY` | Anon key from your Supabase deployment |

> **Important:** These values are baked into the JavaScript bundle at build time. Set them **before** your first deploy, or trigger a manual deploy after changing them.

---

## Step 3 — Deploy

Render automatically deploys when variables are saved (if auto-deploy is enabled) or when you push to the connected branch. You can also click **Manual Deploy → Deploy latest commit** from the dashboard.

Render will:
1. Build using the `Dockerfile`, passing the `VITE_*` env vars as build args.
2. Run the nginx container, injecting `PORT` at startup.
3. Perform a healthcheck at `/` (configured in `render.yaml`).

---

## Step 4 — Smoke test

```bash
curl -I https://<your-app>.onrender.com/
```

Expected: `200 OK`.

---

## render.yaml reference

`render.yaml` is at `deploy/render/render.yaml`. For Blueprint deployment copy it to the repo root; for manual setup it serves as a reference only.

```yaml
services:
  - name: revisit
    type: web
    runtime: docker
    dockerfilePath: ./Dockerfile
    port: 80
    healthCheckPath: /
    envVars:
      - key: VITE_STORAGE_ENGINE
        value: supabase
      - key: VITE_SUPABASE_URL
        sync: false        # set in Render dashboard — not stored in this file
      - key: VITE_SUPABASE_ANON_KEY
        sync: false        # set in Render dashboard — not stored in this file
```

`sync: false` means Render will prompt for the value in the UI and never commit it to the repo.

---

## Troubleshooting

**Build fails with network timeout**
Transient. Retry from the Render dashboard. The `Dockerfile` already includes a yarn retry loop and a 600 s network timeout.

**App loads but shows `STORAGE DISCONNECTED`**
- Confirm `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` are set correctly in the Environment tab.
- After changing environment variables, trigger a new deploy (the bundle must be rebuilt).
- Verify your Supabase API is reachable: `curl -i <VITE_SUPABASE_URL>/auth/v1/health` — expected `200`.

**PORT error / nginx fails to start**
Render injects `PORT` automatically. Do not set a `PORT` variable manually in the Environment tab.

**Healthcheck fails**
The first deploy may be slow (full Node install + TypeScript compile). Render allows up to the configured timeout. If it consistently fails, check the build logs for TypeScript or memory errors.

**Free tier sleeps after inactivity**
Render free-tier web services spin down after 15 minutes of inactivity and take ~30 s to wake on next request. Use a paid instance type to avoid this for study deployments.
