#!/usr/bin/env bash
# setup-revisit.sh — Bootstrap the reVISit Supabase schema, RLS policies, and storage bucket.
#
# Run from the project root after Supabase services are up:
#   bash supabase/setup-revisit.sh
#
# Idempotent: safe to re-run on an already-configured instance.
# Requires: Docker + docker compose, Supabase stack running (no psql client needed locally).

set -euo pipefail

ENV_FILE="supabase/.env"
COMPOSE_FILE="supabase/docker-compose.yml"

# ── Locate the script's repo root (works whether called from any CWD) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Working directory: ${REPO_ROOT}"

# ── Load env ────────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Run from the repo root or ensure supabase/.env exists."
  exit 1
fi

# Extract only the variables we need without sourcing the whole file.
# (sourcing fails on unquoted values with spaces, e.g. STUDIO_DEFAULT_ORGANIZATION=Default Organization)
_get_env() { grep -E "^${1}=" "${ENV_FILE}" | head -1 | cut -d= -f2- || true; }

POSTGRES_USER="$(_get_env POSTGRES_USER)"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="$(_get_env POSTGRES_DB)"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

echo "==> Using POSTGRES_DB=${POSTGRES_DB}, POSTGRES_USER=${POSTGRES_USER}"

# ── Wait for Postgres to accept connections ──────────────────────────────────────
echo "==> Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
  if docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
      exec -T db pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -q 2>/dev/null; then
    echo "    Postgres ready."
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: Postgres did not become ready in 30 attempts. Is the Supabase stack running?"
    echo "       Start it with:"
    echo "         docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d"
    exit 1
  fi
  echo "    Attempt ${i}/30 — waiting 3s..."
  sleep 3
done

# ── Execute setup SQL ────────────────────────────────────────────────────────────
echo "==> Applying reVISit schema, policies, and storage bucket..."

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
  exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<'SQL'

-- ── 1. revisit table ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.revisit (
  "studyId"   VARCHAR                   NOT NULL,
  "docId"     VARCHAR                   NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE  DEFAULT now(),
  "data"      JSONB,
  PRIMARY KEY ("studyId", "docId")
);

-- ── 2. Enable Row Level Security ────────────────────────────────────────────────
ALTER TABLE public.revisit ENABLE ROW LEVEL SECURITY;

-- ── 3. Table RLS policy (idempotent) ────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'revisit'
      AND policyname = 'allow_authenticated_read_write'
  ) THEN
    CREATE POLICY "allow_authenticated_read_write"
      ON public.revisit
      AS PERMISSIVE
      FOR ALL
      TO anon, authenticated, service_role
      USING (true);
  END IF;
END $$;

-- ── 4. Storage bucket ───────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('revisit', 'revisit', false)
ON CONFLICT (id) DO NOTHING;

-- ── 5. Storage object policy (idempotent) ───────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename  = 'objects'
      AND policyname = 'allow_authenticated_read_write'
  ) THEN
    CREATE POLICY "allow_authenticated_read_write"
      ON storage.objects
      AS PERMISSIVE
      FOR ALL
      TO anon, authenticated, service_role
      USING     (bucket_id = 'revisit')
      WITH CHECK (bucket_id = 'revisit');
  END IF;
END $$;

SQL

echo "==> Done. Verifying..."

# ── Quick verification ───────────────────────────────────────────────────────────
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
  exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<'SQL'

\echo '\n── Table:'
SELECT table_schema, table_name
  FROM information_schema.tables
 WHERE table_name = 'revisit' AND table_schema = 'public';

\echo '\n── RLS policies (public.revisit):'
SELECT policyname, cmd, roles
  FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'revisit';

\echo '\n── Storage bucket:'
SELECT id, name, public FROM storage.buckets WHERE id = 'revisit';

\echo '\n── Storage policies (storage.objects):'
SELECT policyname, cmd, roles
  FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects'
   AND policyname = 'allow_authenticated_read_write';

SQL

echo ""
echo "✓ reVISit Supabase setup complete."
echo ""
echo "Next: build and start the app, ensuring the anon key is passed at build time:"
echo ""
echo "  export VITE_SUPABASE_ANON_KEY=\"\$(grep '^ANON_KEY=' supabase/.env | cut -d= -f2-)\""
echo "  docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod build --no-cache study"
echo "  docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d"
