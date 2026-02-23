#!/usr/bin/env bash
# deploy/digitalocean/setup.sh
#
# One-command bootstrap for a fresh DigitalOcean Droplet (or any Ubuntu VPS).
#
# Prerequisites:
#   - Docker + Compose plugin installed  (curl -fsSL https://get.docker.com | sh)
#   - supabase/.env REQUIRED block filled in (STUDY_DOMAIN, API_DOMAIN, passwords)
#
# Usage (from repo root):
#   bash deploy/digitalocean/setup.sh
#
# What it does:
#   1. Validates supabase/.env (fails fast if defaults are still present)
#   2. Writes derived URL fields (SITE_URL, API_EXTERNAL_URL, etc.) from your domain vars
#   3. Starts the Supabase stack
#   4. Bootstraps the reVISit database schema, RLS policies, and storage bucket
#   5. Builds and starts the reVISit app + Caddy reverse proxy (TLS automatic)
#   6. Enables UFW firewall (allows 22, 80, 443)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

ENV_FILE="supabase/.env"

# ---- helpers ----------------------------------------------------------------
die()  { echo ""; echo "ERROR: $*" >&2; echo ""; exit 1; }
info() { echo ""; echo "==> $*"; }
ok()   { echo "    ✓ $*"; }

# ---- env file ---------------------------------------------------------------
[[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. Run this script from the repo root."

_get() { grep -E "^${1}=" "${ENV_FILE}" | head -1 | cut -d= -f2- || true; }

STUDY_DOMAIN="$(_get STUDY_DOMAIN)"
API_DOMAIN="$(_get API_DOMAIN)"
POSTGRES_PASSWORD="$(_get POSTGRES_PASSWORD)"
DASHBOARD_PASSWORD="$(_get DASHBOARD_PASSWORD)"
ANON_KEY="$(_get ANON_KEY)"

# ---- fail-fast validation ---------------------------------------------------
info "Validating configuration..."

[[ -n "${STUDY_DOMAIN}" ]]    || die "STUDY_DOMAIN is not set in ${ENV_FILE}"
[[ -n "${API_DOMAIN}" ]]      || die "API_DOMAIN is not set in ${ENV_FILE}"
[[ -n "${ANON_KEY}" ]]        || die "ANON_KEY is not set in ${ENV_FILE}"

[[ "${STUDY_DOMAIN}" != *"example.com"* ]] \
  || die "STUDY_DOMAIN is still 'example.com' — edit the REQUIRED block in ${ENV_FILE}"
[[ "${API_DOMAIN}" != *"example.com"* ]] \
  || die "API_DOMAIN is still 'example.com' — edit the REQUIRED block in ${ENV_FILE}"
[[ "${POSTGRES_PASSWORD}" != "this-is-a-crazy-new-password-that-is-fine" ]] \
  || die "POSTGRES_PASSWORD is still the default — edit the REQUIRED block in ${ENV_FILE}"
[[ "${DASHBOARD_PASSWORD}" != "my-dashboard-password-that-is-fine-too" ]] \
  || die "DASHBOARD_PASSWORD is still the default — edit the REQUIRED block in ${ENV_FILE}"

ok "STUDY_DOMAIN=${STUDY_DOMAIN}"
ok "API_DOMAIN=${API_DOMAIN}"

# ---- derive URL fields ------------------------------------------------------
info "Writing derived URL fields into ${ENV_FILE}..."

sed -i "s|^SITE_URL=.*|SITE_URL=https://${STUDY_DOMAIN}|"                       "${ENV_FILE}"
sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://${API_DOMAIN}|"         "${ENV_FILE}"
sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://${API_DOMAIN}|"   "${ENV_FILE}"
sed -i "s|^GITHUB_OAUTH_REDIRECT_URI=.*|GITHUB_OAUTH_REDIRECT_URI=https://${API_DOMAIN}/auth/v1/callback|" "${ENV_FILE}"

ok "SITE_URL=https://${STUDY_DOMAIN}"
ok "API_EXTERNAL_URL=https://${API_DOMAIN}"
ok "SUPABASE_PUBLIC_URL=https://${API_DOMAIN}"

# ---- start Supabase ---------------------------------------------------------
info "Starting Supabase stack..."
docker compose -f supabase/docker-compose.yml --env-file "${ENV_FILE}" up -d
ok "Supabase containers started"

# ---- wait for storage migrations --------------------------------------------
# We need storage.buckets to exist before setup-revisit.sh can insert into it.
# The Docker healthcheck on supabase-storage is unreliable on small VMs (1-2 GB),
# so we poll Postgres directly for the storage schema instead.
info "Waiting for Supabase storage migrations to complete (up to 5 min)..."

POSTGRES_USER="$(grep -E '^POSTGRES_USER=' "${ENV_FILE}" | cut -d= -f2- || echo 'postgres')"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "${ENV_FILE}" | cut -d= -f2- || echo 'postgres')"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

for i in $(seq 1 60); do
  BUCKET_TABLE="$(docker compose -f supabase/docker-compose.yml --env-file "${ENV_FILE}" \
    exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
    "SELECT to_regclass('storage.buckets');" 2>/dev/null || echo '')"
  if [[ "${BUCKET_TABLE}" == "storage.buckets" ]]; then
    ok "storage schema ready (storage.buckets exists)"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    die "storage schema did not appear after 5 minutes. Check: docker logs supabase-storage"
  fi
  echo "    waiting for storage migrations... [${i}/60]"
  sleep 5
done

# ---- bootstrap reVISit schema -----------------------------------------------
info "Bootstrapping reVISit schema (table, RLS, storage bucket)..."
bash supabase/setup-revisit.sh
ok "Schema ready"

# ---- build and start app + Caddy --------------------------------------------
info "Building and starting reVISit app + Caddy..."
info "(First build takes 10–30 min on a 2 GB Droplet — subsequent builds use cache)"

export VITE_SUPABASE_ANON_KEY="${ANON_KEY}"
docker compose \
  -f deploy/digitalocean/docker-compose.yml \
  --project-directory . \
  --env-file "${ENV_FILE}" \
  up -d --build

ok "App and proxy started"

# ---- firewall ---------------------------------------------------------------
info "Configuring UFW firewall..."
ufw allow 22   > /dev/null
ufw allow 80   > /dev/null
ufw allow 443  > /dev/null
ufw --force enable > /dev/null
ok "UFW enabled (22, 80, 443 open)"

# ---- done -------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  ReVISit is live (Caddy obtaining TLS certs — allow ~30 s)"
echo "======================================================================"
echo ""
echo "Smoke tests (run from your laptop):"
echo ""
echo "  curl -I  https://${STUDY_DOMAIN}/"
echo "  curl -si https://${API_DOMAIN}/auth/v1/health"
echo ""
echo "Tail logs:"
echo "  docker compose -f deploy/digitalocean/docker-compose.yml \\"
echo "    --project-directory . --env-file supabase/.env logs -f caddy study"
echo ""
