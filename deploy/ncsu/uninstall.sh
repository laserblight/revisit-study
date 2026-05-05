#!/usr/bin/env bash
# deploy/ncsu/uninstall.sh
#
# Tears down everything that setup.sh created:
#   1. Stops and removes the study app container
#   2. Stops and removes the Supabase containers
#   3. Restores the original nginx default site
#   4. Removes Docker networks created by the stacks
#
# By default, Docker volumes (Postgres data, Minio storage) are preserved so
# you can re-run setup.sh without losing data. Pass --purge to remove them.
#
# Usage (from repo root):
#   bash deploy/ncsu/uninstall.sh           # keep volumes
#   bash deploy/ncsu/uninstall.sh --purge   # remove volumes too

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

ENV_FILE="supabase/.env"
PURGE=false

for arg in "$@"; do
  case "${arg}" in
    --purge) PURGE=true ;;
    *) echo "Unknown option: ${arg}"; echo "Usage: bash deploy/ncsu/uninstall.sh [--purge]"; exit 1 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------
info() { echo ""; echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
warn() { echo "    ! $*"; }

# ---- stop app stack ---------------------------------------------------------
info "Stopping study app..."
if docker compose -f deploy/ncsu/docker-compose.yml --project-directory . \
     --env-file "${ENV_FILE}" down 2>/dev/null; then
  ok "Study app stopped and removed"
else
  warn "Study app was not running (skipped)"
fi

# ---- stop Supabase stack ----------------------------------------------------
info "Stopping Supabase stack..."
DOWN_ARGS=()
if [[ "${PURGE}" == true ]]; then
  DOWN_ARGS+=("--volumes")
fi
if docker compose -f supabase/docker-compose.yml -f deploy/ncsu/supabase-override.yml \
     --env-file "${ENV_FILE}" down "${DOWN_ARGS[@]}" 2>/dev/null; then
  ok "Supabase stack stopped and removed"
else
  warn "Supabase stack was not running (skipped)"
fi

# ---- remove Postgres data on disk (only with --purge) -----------------------
if [[ "${PURGE}" == true ]]; then
  info "Purging Postgres data on disk..."
  if [[ -d supabase/volumes/db/data ]]; then
    sudo rm -rf supabase/volumes/db/data
    ok "Removed supabase/volumes/db/data"
  else
    warn "No Postgres data directory found (skipped)"
  fi

  if [[ -d supabase/volumes/storage ]]; then
    sudo rm -rf supabase/volumes/storage
    ok "Removed supabase/volumes/storage"
  else
    warn "No storage directory found (skipped)"
  fi
fi

# ---- remove Docker networks -------------------------------------------------
info "Removing Docker networks..."
for net in revisit_net supabase_default; do
  if docker network rm "${net}" 2>/dev/null; then
    ok "Removed network ${net}"
  else
    warn "Network ${net} not found or still in use (skipped)"
  fi
done

# ---- restore nginx ----------------------------------------------------------
info "Restoring nginx default site..."

# Remove the revisit site
if [[ -f /etc/nginx/sites-enabled/revisit ]]; then
  sudo rm -f /etc/nginx/sites-enabled/revisit
  ok "Removed /etc/nginx/sites-enabled/revisit"
else
  warn "revisit site was not enabled (skipped)"
fi

if [[ -f /etc/nginx/sites-available/revisit ]]; then
  sudo rm -f /etc/nginx/sites-available/revisit
  ok "Removed /etc/nginx/sites-available/revisit"
fi

# Restore the default site from backup
if [[ -f /etc/nginx/sites-available/default.bak ]]; then
  sudo cp /etc/nginx/sites-available/default.bak /etc/nginx/sites-available/default
  sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  sudo rm -f /etc/nginx/sites-available/default.bak
  ok "Restored default nginx site from backup"
elif [[ -f /etc/nginx/sites-available/default ]]; then
  sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  ok "Re-enabled existing default nginx site"
else
  warn "No default site backup found — nginx may need manual configuration"
fi

if sudo nginx -t 2>/dev/null; then
  sudo systemctl reload nginx
  ok "nginx reloaded"
else
  warn "nginx config test failed — check /etc/nginx/ manually"
fi

# ---- done -------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  ReVISit uninstalled"
echo "======================================================================"
echo ""
if [[ "${PURGE}" == true ]]; then
  echo "  All containers, volumes, and data have been removed."
  echo "  Run setup.sh again for a clean install."
else
  echo "  Containers removed. Docker volumes and on-disk data preserved."
  echo "  Run setup.sh again to restart, or pass --purge to remove everything:"
  echo "    bash deploy/ncsu/uninstall.sh --purge"
fi
echo ""
