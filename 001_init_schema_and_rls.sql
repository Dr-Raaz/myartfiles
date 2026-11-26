BEGIN;

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  icon TEXT NOT NULL DEFAULT '🎨',
  sort_order INTEGER NOT NULL DEFAULT 1,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT categories_name_nonempty CHECK (char_length(btrim(name)) > 0)
);

CREATE TABLE IF NOT EXISTS public.artworks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  category_id TEXT NOT NULL REFERENCES public.categories(id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  image_url TEXT NOT NULL,
  storage_path TEXT,
  imagekit_file_id TEXT,
  difficulty TEXT NOT NULL DEFAULT 'easy'
    CHECK (difficulty IN ('easy', 'medium', 'hard')),
  is_published BOOLEAN NOT NULL DEFAULT true,
  image_width INTEGER NOT NULL DEFAULT 800 CHECK (image_width > 0),
  image_height INTEGER NOT NULL DEFAULT 800 CHECK (image_height > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT artworks_title_nonempty CHECK (char_length(btrim(title)) > 0),
  CONSTRAINT artworks_image_url_nonempty CHECK (char_length(btrim(image_url)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_artworks_category_id
  ON public.artworks(category_id);

CREATE INDEX IF NOT EXISTS idx_artworks_published_created
  ON public.artworks(is_published, created_at DESC);

CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'admin'
    CHECK (role IN ('admin', 'super_admin')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT admin_users_email_nonempty CHECK (char_length(btrim(email)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_users_email_lower
  ON public.admin_users (lower(email));

DROP TRIGGER IF EXISTS trg_categories_set_updated_at ON public.categories;
CREATE TRIGGER trg_categories_set_updated_at
BEFORE UPDATE ON public.categories
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_artworks_set_updated_at ON public.artworks;
CREATE TRIGGER trg_artworks_set_updated_at
BEFORE UPDATE ON public.artworks
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_admin_users_set_updated_at ON public.admin_users;
CREATE TRIGGER trg_admin_users_set_updated_at
BEFORE UPDATE ON public.admin_users
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.admin_users a
    JOIN auth.users u ON u.id = a.user_id
    WHERE a.user_id = auth.uid()
      AND a.is_active = true
      AND a.role IN ('admin', 'super_admin')
      AND u.deleted_at IS NULL
      AND u.email_confirmed_at IS NOT NULL
      AND (u.banned_until IS NULL OR u.banned_until <= now())
      AND lower(btrim(u.email)) = lower(btrim(a.email))
  );
$$;

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories FORCE ROW LEVEL SECURITY;
ALTER TABLE public.artworks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artworks FORCE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS categories_public_read ON public.categories;
CREATE POLICY categories_public_read
ON public.categories FOR SELECT
TO anon, authenticated
USING (is_active = true OR public.is_admin());

DROP POLICY IF EXISTS categories_admin_insert ON public.categories;
CREATE POLICY categories_admin_insert
ON public.categories FOR INSERT
TO authenticated
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS categories_admin_update ON public.categories;
CREATE POLICY categories_admin_update
ON public.categories FOR UPDATE
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS categories_admin_delete ON public.categories;
CREATE POLICY categories_admin_delete
ON public.categories FOR DELETE
TO authenticated
USING (public.is_admin());

DROP POLICY IF EXISTS artworks_public_read ON public.artworks;
CREATE POLICY artworks_public_read
ON public.artworks FOR SELECT
TO anon, authenticated
USING (is_published = true OR public.is_admin());

DROP POLICY IF EXISTS artworks_admin_insert ON public.artworks;
CREATE POLICY artworks_admin_insert
ON public.artworks FOR INSERT
TO authenticated
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS artworks_admin_update ON public.artworks;
CREATE POLICY artworks_admin_update
ON public.artworks FOR UPDATE
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS artworks_admin_delete ON public.artworks;
CREATE POLICY artworks_admin_delete
ON public.artworks FOR DELETE
TO authenticated
USING (public.is_admin());

DROP POLICY IF EXISTS admin_users_deny_browser ON public.admin_users;
CREATE POLICY admin_users_deny_browser
ON public.admin_users
FOR ALL
TO anon, authenticated
USING (false)
WITH CHECK (false);

REVOKE ALL ON public.admin_users FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.admin_users TO service_role;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT ON public.categories, public.artworks TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.categories, public.artworks TO authenticated;
GRANT ALL ON public.categories, public.artworks TO service_role;

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin() TO anon, authenticated, service_role;

COMMIT;
