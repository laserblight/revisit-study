-- reVISit schema bootstrap
-- Mounted into /docker-entrypoint-initdb.d/migrations/98-revisit.sql
-- Runs automatically on first Postgres boot (fresh PGDATA only).
-- For existing deployments, run: bash supabase/setup-revisit.sh

-- 1. revisit table
CREATE TABLE IF NOT EXISTS public.revisit (
  "studyId"   VARCHAR                  NOT NULL,
  "docId"     VARCHAR                  NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT now(),
  "data"      JSONB,
  PRIMARY KEY ("studyId", "docId")
);

-- 2. Enable Row Level Security
ALTER TABLE public.revisit ENABLE ROW LEVEL SECURITY;

-- 3. Table RLS policy
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

-- 4. Storage bucket
-- Newer Supabase storage schema no longer includes the `public` column.
INSERT INTO storage.buckets (id, name)
VALUES ('revisit', 'revisit')
ON CONFLICT (id) DO NOTHING;

-- 5. Storage object policy
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
