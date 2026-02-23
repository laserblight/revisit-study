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

# ---- wait for storage service -----------------------------------------------
# setup-revisit.sh creates a row in storage.buckets, which only exists after the
# storage container has run its own migrations. Waiting for raw Postgres readiness
# (which setup-revisit.sh already does) is not enough — we must also wait for the
# storage API container itself to reach a healthy state.
info "Waiting for supabase-storage to be healthy (up to 3 min)..."
for i in $(seq 1 36); do
  STATUS="$(docker inspect --format='{{.State.Health.Status}}' supabase-storage 2>/dev/null || echo 'missing')"
  if [[ "${STATUS}" == "healthy" ]]; then
    ok "supabase-storage is healthy"
    break
  fi
  if [[ "${i}" -eq 36 ]]; then
    die "supabase-storage did not become healthy after 3 minutes. Check: docker logs supabase-storage"
  fi
  echo "    waiting... (${STATUS}) [${i}/36]"
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
