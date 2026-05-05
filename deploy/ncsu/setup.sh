#!/usr/bin/env bash
# deploy/ncsu/setup.sh
#
# One-command bootstrap for an NCSU LAS workspace VM.
#
# Key differences from deploy/digitalocean/setup.sh:
#   - Single domain: no API_DOMAIN — all Supabase API routes are path-routed
#     through nginx on the same hostname as the study app.
#   - No Caddy: TLS is terminated by the NCSU reverse proxy upstream.
#   - No UFW: the NCSU infrastructure manages firewall rules.
#   - Kong on port 8100: avoids conflict with the workspace nginx on port 8000.
#   - Installs an nginx site config to reverse-proxy to the Docker containers.
#
# Prerequisites:
#   - Docker + Compose plugin installed
#   - supabase/.env REQUIRED block filled in (STUDY_DOMAIN, passwords)
#   - nginx installed (standard on NCSU workspace VMs)
#
# Usage (from repo root):
#   bash deploy/ncsu/setup.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

ENV_FILE="supabase/.env"

# Layer the NCSU override on every Supabase compose call so Kong is exposed
# on the host loopback for the system nginx to reach.
SUPABASE_COMPOSE=(-f supabase/docker-compose.yml -f deploy/ncsu/supabase-override.yml)

# ---- helpers ----------------------------------------------------------------
die()  { echo ""; echo "ERROR: $*" >&2; echo ""; exit 1; }
info() { echo ""; echo "==> $*"; }
ok()   { echo "    ✓ $*"; }

# ---- env file ---------------------------------------------------------------
[[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. Run this script from the repo root."

_get() { grep -E "^${1}=" "${ENV_FILE}" | head -1 | cut -d= -f2- || true; }

STUDY_DOMAIN="$(_get STUDY_DOMAIN)"
POSTGRES_PASSWORD="$(_get POSTGRES_PASSWORD)"
DASHBOARD_PASSWORD="$(_get DASHBOARD_PASSWORD)"
ANON_KEY="$(_get ANON_KEY)"

# ---- fail-fast validation ---------------------------------------------------
info "Validating configuration..."

[[ -n "${STUDY_DOMAIN}" ]]    || die "STUDY_DOMAIN is not set in ${ENV_FILE}"
[[ -n "${ANON_KEY}" ]]        || die "ANON_KEY is not set in ${ENV_FILE}"

[[ "${STUDY_DOMAIN}" != *"example.com"* ]] \
  || die "STUDY_DOMAIN is still 'example.com' — edit the REQUIRED block in ${ENV_FILE}"
[[ "${POSTGRES_PASSWORD}" != "this-is-a-crazy-new-password-that-is-fine" ]] \
  || die "POSTGRES_PASSWORD is still the default — edit the REQUIRED block in ${ENV_FILE}"
[[ "${DASHBOARD_PASSWORD}" != "my-dashboard-password-that-is-fine-too" ]] \
  || die "DASHBOARD_PASSWORD is still the default — edit the REQUIRED block in ${ENV_FILE}"

ok "STUDY_DOMAIN=${STUDY_DOMAIN}"

# ---- derive URL fields (single-domain) --------------------------------------
info "Writing derived URL fields into ${ENV_FILE} (single-domain mode)..."

# On NCSU VMs there is no separate API subdomain — everything is path-routed
# through nginx on the same hostname. Point all URLs at STUDY_DOMAIN.
sed -i "s|^SITE_URL=.*|SITE_URL=https://${STUDY_DOMAIN}|"                                                    "${ENV_FILE}"
sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://${STUDY_DOMAIN}|"                                    "${ENV_FILE}"
sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://${STUDY_DOMAIN}|"                              "${ENV_FILE}"
sed -i "s|^GITHUB_OAUTH_REDIRECT_URI=.*|GITHUB_OAUTH_REDIRECT_URI=https://${STUDY_DOMAIN}/auth/v1/callback|" "${ENV_FILE}"

# Kong must not conflict with the NCSU workspace nginx on port 8000.
sed -i "s|^KONG_HTTP_PORT=.*|KONG_HTTP_PORT=8100|" "${ENV_FILE}"

ok "SITE_URL=https://${STUDY_DOMAIN}"
ok "API_EXTERNAL_URL=https://${STUDY_DOMAIN}"
ok "SUPABASE_PUBLIC_URL=https://${STUDY_DOMAIN}"
ok "KONG_HTTP_PORT=8100"

# ---- install nginx config ---------------------------------------------------
info "Installing nginx reverse-proxy config..."

NGINX_CONF="deploy/ncsu/nginx-revisit.conf"
[[ -f "${NGINX_CONF}" ]] || die "${NGINX_CONF} not found"

sudo cp "${NGINX_CONF}" /etc/nginx/sites-available/revisit

# Back up the default site if it hasn't been backed up yet
if [[ -f /etc/nginx/sites-enabled/default ]] && [[ ! -f /etc/nginx/sites-available/default.bak ]]; then
  sudo cp /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default.bak
  ok "Backed up default nginx site to /etc/nginx/sites-available/default.bak"
fi

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/revisit /etc/nginx/sites-enabled/revisit
sudo nginx -t || die "nginx config test failed — check ${NGINX_CONF}"
sudo systemctl reload nginx
ok "nginx reloaded with reVISit proxy config"

# ---- start Supabase ---------------------------------------------------------
info "Starting Supabase stack..."
# `|| true` prevents set -e from aborting if a container's healthcheck hasn't
# passed within Docker Compose's timeout. Our storage.buckets polling loop
# below provides the actual readiness gate.
docker compose "${SUPABASE_COMPOSE[@]}" --env-file "${ENV_FILE}" up -d || true
ok "Supabase containers started (polling for readiness...)"

# ---- wait for storage migrations --------------------------------------------
# We need storage.buckets to exist before setup-revisit.sh can insert into it.
# The Docker healthcheck on supabase-storage is unreliable on memory-constrained VMs,
# so we poll Postgres directly for the storage schema instead.
info "Waiting for Supabase storage migrations to complete (up to 8 min)..."

POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "${ENV_FILE}" | cut -d= -f2- || echo 'postgres')"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

for i in $(seq 1 96); do
  BUCKET_TABLE="$(docker compose "${SUPABASE_COMPOSE[@]}" --env-file "${ENV_FILE}" \
    exec -T db psql -U supabase_admin -d "${POSTGRES_DB}" -tAc \
    "SELECT to_regclass('storage.buckets');" 2>/dev/null || echo '')"
  if [[ "${BUCKET_TABLE}" == "storage.buckets" ]]; then
    ok "storage schema ready (storage.buckets exists)"
    break
  fi
  if [[ "${i}" -eq 96 ]]; then
    die "storage schema did not appear after 8 minutes. Check: docker logs supabase-db && docker logs supabase-storage"
  fi
  echo "    waiting for storage migrations... [${i}/96]"
  sleep 5
done

# ---- bootstrap reVISit schema -----------------------------------------------
# Retry up to 3 times — the psql heredoc may fail silently on first attempt
# if the storage service's internal state isn't fully consistent yet.
info "Bootstrapping reVISit schema (table, RLS, storage bucket)..."
for attempt in 1 2 3; do
  bash supabase/setup-revisit.sh && break
  echo "    setup-revisit.sh attempt ${attempt} failed, retrying in 10s..."
  sleep 10
done

# Verify the bucket row was actually inserted
BUCKET_ROW="$(docker compose "${SUPABASE_COMPOSE[@]}" --env-file "${ENV_FILE}" \
  exec -T db psql -U supabase_admin -d "${POSTGRES_DB}" -tAc \
  "SELECT id FROM storage.buckets WHERE id = 'revisit';" 2>/dev/null || echo '')"
if [[ "${BUCKET_ROW}" != "revisit" ]]; then
  die "storage bucket 'revisit' was not created. Check: docker logs supabase-db"
fi
ok "Schema ready (bucket confirmed in Postgres)"

# ---- build and start app ----------------------------------------------------
info "Building and starting reVISit app..."
info "(First build takes a few minutes — subsequent builds use cache)"

export VITE_SUPABASE_ANON_KEY="${ANON_KEY}"
docker compose \
  -f deploy/ncsu/docker-compose.yml \
  --project-directory . \
  --env-file "${ENV_FILE}" \
  up -d --build

ok "App started"

# ---- done -------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  ReVISit is running on the NCSU workspace"
echo "======================================================================"
echo ""
echo "Local smoke tests (from the XFCE desktop browser or curl on the VM):"
echo ""
echo "  curl -I  http://localhost/"
echo "  curl -si http://localhost/auth/v1/health -H 'apikey: ${ANON_KEY}'"
echo ""
echo "External access:"
echo "  https://${STUDY_DOMAIN}/"
echo "  (goes through NCSU proxy — may require workspace port routing;"
echo "   see deploy/ncsu/README.md for details)"
echo ""
echo "Tail logs:"
echo "  docker compose -f deploy/ncsu/docker-compose.yml \\"
echo "    --project-directory . --env-file supabase/.env logs -f study"
echo ""
