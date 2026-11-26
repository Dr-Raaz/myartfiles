BEGIN;

-- ============================================================================
-- My Art Studio — Recovery-Safe ImageKit Cleanup Queue & Atomic Deletion RPCs
-- (Final Approved Artifact: 003_asset_cleanup_queue_final.sql)
-- Target: Supabase PostgreSQL (execute AFTER 001_init_schema_and_rls.sql)
-- Works on both a clean project and an upgrade where original 003 was installed.
-- Notes:
--   * Never assumes storage_path is an ImageKit file ID.
--   * Preserves active leases completely without modification and returns
--     claimed = false with the existing open cleanup_job_id via fallback SELECT.
--   * Bounds exponential backoff in DOUBLE PRECISION before INTEGER cast.
--   * Recovers expired processing leases and resets attempts on exhausted jobs.
--   * Supports manual admin requeue for failed, exhausted, and expired leases.
--   * All RPCs are service_role-only; backend MUST verify admin JWT first.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.asset_cleanup_queue (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  artwork_id       TEXT NOT NULL,
  imagekit_file_id TEXT NOT NULL,
  image_url        TEXT,
  status           TEXT NOT NULL DEFAULT 'pending',
  attempts         INTEGER NOT NULL DEFAULT 0,
  max_attempts     INTEGER NOT NULL DEFAULT 10,
  total_attempts   INTEGER NOT NULL DEFAULT 0,
  requeue_count    INTEGER NOT NULL DEFAULT 0,
  last_error       TEXT,
  next_retry_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_at        TIMESTAMPTZ,
  lease_expires_at TIMESTAMPTZ,
  locked_by        TEXT,
  exhausted_at     TIMESTAMPTZ,
  requeued_at      TIMESTAMPTZ,
  requeued_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  processed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT asset_cleanup_queue_artwork_id_nonempty_chk
    CHECK (char_length(btrim(artwork_id)) > 0),
  CONSTRAINT asset_cleanup_queue_file_id_nonempty_chk
    CHECK (char_length(btrim(imagekit_file_id)) > 0),
  CONSTRAINT asset_cleanup_queue_status_chk
    CHECK (status IN ('pending', 'processing', 'failed', 'succeeded', 'exhausted')),
  CONSTRAINT asset_cleanup_queue_attempts_chk
    CHECK (attempts >= 0 AND max_attempts BETWEEN 1 AND 50 AND total_attempts >= 0 AND requeue_count >= 0)
);

-- Prevent duplicate active/failed/exhausted cleanup jobs for the same ImageKit file ID
CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_cleanup_open_file_unique
  ON public.asset_cleanup_queue (imagekit_file_id)
  WHERE status IN ('pending', 'processing', 'failed', 'exhausted');

CREATE INDEX IF NOT EXISTS idx_asset_cleanup_claimable
  ON public.asset_cleanup_queue (next_retry_at, id)
  WHERE status IN ('pending', 'failed');

CREATE INDEX IF NOT EXISTS idx_asset_cleanup_processing_lease
  ON public.asset_cleanup_queue (lease_expires_at, id)
  WHERE status = 'processing';

CREATE INDEX IF NOT EXISTS idx_asset_cleanup_exhausted
  ON public.asset_cleanup_queue (exhausted_at DESC, id)
  WHERE status = 'exhausted';

DROP TRIGGER IF EXISTS trg_asset_cleanup_set_updated_at ON public.asset_cleanup_queue;
CREATE TRIGGER trg_asset_cleanup_set_updated_at
  BEFORE UPDATE ON public.asset_cleanup_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Strict browser lockdown: server-only access via SUPABASE_SECRET_KEY (service_role)
REVOKE ALL ON TABLE public.asset_cleanup_queue FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.asset_cleanup_queue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.asset_cleanup_queue_id_seq TO service_role;

ALTER TABLE public.asset_cleanup_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_cleanup_queue FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS asset_cleanup_deny_all_browser ON public.asset_cleanup_queue;
CREATE POLICY asset_cleanup_deny_all_browser
  ON public.asset_cleanup_queue
  FOR ALL
  TO anon, authenticated
  USING (false)
  WITH CHECK (false);

-- ----------------------------------------------------------------------------
-- 1. Atomic Artwork Deletion + Cleanup Enqueue (single DB transaction)
--    Optionally claims the newly queued job immediately with a processing lease
--    if p_claim_worker_id IS NOT NULL so the caller can invoke ImageKit right away.
--    Returns claimed = true ONLY when this invocation inserted or updated and
--    acquired the lease; preserves active leases untouched and returns
--    claimed = false with the existing open cleanup_job_id.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.delete_artwork_and_enqueue_cleanup(TEXT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION public.delete_artwork_and_enqueue_cleanup(
  p_artwork_id      TEXT,
  p_claim_worker_id TEXT DEFAULT NULL,
  p_lease_seconds   INTEGER DEFAULT 120
)
RETURNS TABLE (
  deleted              BOOLEAN,
  cleanup_job_id       BIGINT,
  claimed              BOOLEAN,
  imagekit_file_id     TEXT,
  legacy_storage_path  TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_artwork             public.artworks%ROWTYPE;
  v_imagekit_file_id    TEXT;
  v_legacy_storage_path TEXT;
  v_job_id              BIGINT;
  v_claim_now           BOOLEAN := NULLIF(btrim(COALESCE(p_claim_worker_id, '')), '') IS NOT NULL;
  v_claimed             BOOLEAN := false;
  v_lease_secs          INTEGER := GREATEST(30, LEAST(COALESCE(p_lease_seconds, 120), 900));
BEGIN
  -- Lock target artwork row so concurrent deletes cannot race
  SELECT *
  INTO v_artwork
  FROM public.artworks
  WHERE id = p_artwork_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::BIGINT, false, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Resolve ImageKit fileId strictly matching existing app semantics:
  -- 1) Prefer explicit imagekit_file_id column.
  -- 2) Only treat storage_path as an ImageKit fileId if image_url points to ik.imagekit.io
  --    AND storage_path is NOT a Firebase Storage path (e.g. 'artworks/...') and contains no '/'.
  v_imagekit_file_id := NULLIF(btrim(v_artwork.imagekit_file_id), '');

  IF v_imagekit_file_id IS NULL
     AND v_artwork.image_url ILIKE '%ik.imagekit.io%'
     AND NULLIF(btrim(v_artwork.storage_path), '') IS NOT NULL
     AND btrim(v_artwork.storage_path) NOT LIKE 'artworks/%'
     AND btrim(v_artwork.storage_path) NOT LIKE '/artworks/%'
     AND position('/' IN btrim(v_artwork.storage_path)) = 0 THEN
    v_imagekit_file_id := btrim(v_artwork.storage_path);
  END IF;

  -- Preserve legacy Firebase Storage path (if any) in return payload without queuing ImageKit
  IF v_imagekit_file_id IS NULL
     AND NULLIF(btrim(v_artwork.storage_path), '') IS NOT NULL THEN
    v_legacy_storage_path := btrim(v_artwork.storage_path);
  END IF;

  -- Delete the database record inside this transaction
  DELETE FROM public.artworks
  WHERE id = p_artwork_id;

  -- Enqueue ImageKit deletion only when an actual ImageKit fileId exists
  IF v_imagekit_file_id IS NOT NULL THEN
    INSERT INTO public.asset_cleanup_queue (
      artwork_id,
      imagekit_file_id,
      image_url,
      status,
      attempts,
      total_attempts,
      next_retry_at,
      locked_at,
      lease_expires_at,
      locked_by
    )
    VALUES (
      v_artwork.id,
      v_imagekit_file_id,
      v_artwork.image_url,
      CASE WHEN v_claim_now THEN 'processing' ELSE 'pending' END,
      CASE WHEN v_claim_now THEN 1 ELSE 0 END,
      CASE WHEN v_claim_now THEN 1 ELSE 0 END,
      now(),
      CASE WHEN v_claim_now THEN now() ELSE NULL END,
      CASE WHEN v_claim_now THEN now() + make_interval(secs => v_lease_secs) ELSE NULL END,
      CASE WHEN v_claim_now THEN btrim(p_claim_worker_id) ELSE NULL END
    )
    ON CONFLICT (imagekit_file_id)
      WHERE status IN ('pending', 'processing', 'failed', 'exhausted')
    DO UPDATE SET
      artwork_id       = EXCLUDED.artwork_id,
      image_url        = EXCLUDED.image_url,
      status           = CASE WHEN v_claim_now THEN 'processing' ELSE 'pending' END,
      attempts         = CASE
                           WHEN asset_cleanup_queue.status = 'exhausted'
                                OR asset_cleanup_queue.attempts >= asset_cleanup_queue.max_attempts
                             THEN CASE WHEN v_claim_now THEN 1 ELSE 0 END
                           WHEN v_claim_now
                             THEN LEAST(asset_cleanup_queue.attempts + 1, asset_cleanup_queue.max_attempts)
                           ELSE asset_cleanup_queue.attempts
                         END,
      total_attempts   = CASE
                           WHEN v_claim_now THEN asset_cleanup_queue.total_attempts + 1
                           ELSE asset_cleanup_queue.total_attempts
                         END,
      exhausted_at     = NULL,
      next_retry_at    = now(),
      locked_at        = CASE WHEN v_claim_now THEN now() ELSE NULL END,
      lease_expires_at = CASE WHEN v_claim_now THEN now() + make_interval(secs => v_lease_secs) ELSE NULL END,
      locked_by        = CASE WHEN v_claim_now THEN btrim(p_claim_worker_id) ELSE NULL END
    WHERE NOT (
      asset_cleanup_queue.status = 'processing'
      AND asset_cleanup_queue.lease_expires_at IS NOT NULL
      AND asset_cleanup_queue.lease_expires_at > now()
    )
    RETURNING id INTO v_job_id;

    IF v_job_id IS NOT NULL THEN
      v_claimed := v_claim_now;
    ELSE
      v_claimed := false;
      SELECT q.id
      INTO v_job_id
      FROM public.asset_cleanup_queue q
      WHERE q.imagekit_file_id = v_imagekit_file_id
        AND q.status IN ('pending', 'processing', 'failed', 'exhausted')
      LIMIT 1;
    END IF;
  END IF;

  RETURN QUERY SELECT true, v_job_id, v_claimed, v_imagekit_file_id, v_legacy_storage_path;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. Claim Pending / Failed / Expired-Lease Jobs (with SKIP LOCKED)
--    Also sweeps expired 'processing' leases that already reached max_attempts
--    into 'exhausted' so abandoned jobs never remain stuck in 'processing'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_asset_cleanup_jobs(
  p_worker_id     TEXT,
  p_limit         INTEGER DEFAULT 10,
  p_lease_seconds INTEGER DEFAULT 120
)
RETURNS SETOF public.asset_cleanup_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_worker_id  TEXT := NULLIF(btrim(p_worker_id), '');
  v_limit      INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 10), 100));
  v_lease_secs INTEGER := GREATEST(30, LEAST(COALESCE(p_lease_seconds, 120), 900));
BEGIN
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'p_worker_id is required to claim cleanup jobs.';
  END IF;

  -- Sweep any expired 'processing' jobs that already used all attempts -> exhausted
  UPDATE public.asset_cleanup_queue
  SET status           = 'exhausted',
      exhausted_at     = COALESCE(exhausted_at, now()),
      last_error       = COALESCE(last_error, 'Processing lease expired after reaching maximum retry attempts.'),
      locked_at        = NULL,
      lease_expires_at = NULL,
      locked_by        = NULL
  WHERE status = 'processing'
    AND lease_expires_at IS NOT NULL
    AND lease_expires_at <= now()
    AND attempts >= max_attempts;

  -- Claim eligible pending, failed, or abandoned-processing jobs
  RETURN QUERY
  WITH candidate AS (
    SELECT q.id
    FROM public.asset_cleanup_queue q
    WHERE (
      (
        q.status IN ('pending', 'failed')
        AND q.next_retry_at <= now()
        AND q.attempts < q.max_attempts
      )
      OR (
        q.status = 'processing'
        AND q.lease_expires_at IS NOT NULL
        AND q.lease_expires_at <= now()
        AND q.attempts < q.max_attempts
      )
    )
    ORDER BY q.next_retry_at ASC, q.id ASC
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.asset_cleanup_queue q
  SET status           = 'processing',
      attempts         = q.attempts + 1,
      total_attempts   = q.total_attempts + 1,
      locked_at        = now(),
      lease_expires_at = now() + make_interval(secs => v_lease_secs),
      locked_by        = v_worker_id
  FROM candidate c
  WHERE q.id = c.id
  RETURNING q.*;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. Mark Cleanup Job Succeeded (lease-checked)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_asset_cleanup_succeeded(
  p_job_id    BIGINT,
  p_worker_id TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_updated INTEGER;
BEGIN
  UPDATE public.asset_cleanup_queue
  SET status           = 'succeeded',
      processed_at     = now(),
      last_error       = NULL,
      locked_at        = NULL,
      lease_expires_at = NULL,
      locked_by        = NULL,
      exhausted_at     = NULL
  WHERE id = p_job_id
    AND status = 'processing'
    AND locked_by = btrim(p_worker_id);

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Record Cleanup Failure with Exponential Backoff or Exhausted Transition
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_asset_cleanup_failure(
  p_job_id    BIGINT,
  p_worker_id TEXT,
  p_error     TEXT
)
RETURNS TABLE (
  updated    BOOLEAN,
  new_status TEXT,
  attempts   INTEGER,
  next_retry TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row        public.asset_cleanup_queue%ROWTYPE;
  v_backoff    INTERVAL;
  v_new_status TEXT;
  v_next_retry TIMESTAMPTZ;
BEGIN
  SELECT *
  INTO v_row
  FROM public.asset_cleanup_queue
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND OR v_row.status <> 'processing' OR v_row.locked_by IS DISTINCT FROM btrim(p_worker_id) THEN
    RETURN QUERY SELECT false, NULL::TEXT, NULL::INTEGER, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  IF v_row.attempts >= v_row.max_attempts THEN
    v_new_status := 'exhausted';
    v_next_retry := v_row.next_retry_at;

    UPDATE public.asset_cleanup_queue
    SET status           = 'exhausted',
        exhausted_at     = now(),
        last_error       = left(COALESCE(p_error, 'Unknown ImageKit deletion error'), 2000),
        locked_at        = NULL,
        lease_expires_at = NULL,
        locked_by        = NULL
    WHERE id = p_job_id;
  ELSE
    -- Exponential backoff: 60s, 120s, 240s, ... capped safely at 6 hours (21600s)
    v_backoff := make_interval(
      secs => LEAST(
        21600::DOUBLE PRECISION,
        60.0 * power(2, LEAST(10, GREATEST(0, v_row.attempts - 1)))
      )::INTEGER
    );
    v_new_status := 'failed';
    v_next_retry := now() + v_backoff;

    UPDATE public.asset_cleanup_queue
    SET status           = 'failed',
        next_retry_at    = v_next_retry,
        last_error       = left(COALESCE(p_error, 'Unknown ImageKit deletion error'), 2000),
        locked_at        = NULL,
        lease_expires_at = NULL,
        locked_by        = NULL
    WHERE id = p_job_id;
  END IF;

  RETURN QUERY SELECT true, v_new_status, v_row.attempts, v_next_retry;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. Administrator Manual Retry RPC for Exhausted / Failed / Expired Jobs
--    Called by Express ONLY after verifying caller's Supabase admin JWT.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.requeue_asset_cleanup_job(
  p_job_id        BIGINT,
  p_admin_user_id UUID
)
RETURNS SETOF public.asset_cleanup_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_is_valid_admin BOOLEAN;
BEGIN
  -- Defense-in-depth check that p_admin_user_id is an active, confirmed admin
  SELECT EXISTS (
    SELECT 1
    FROM public.admin_users a
    JOIN auth.users u ON u.id = a.user_id
    WHERE a.user_id = p_admin_user_id
      AND a.is_active = true
      AND a.role IN ('admin', 'super_admin')
      AND u.deleted_at IS NULL
      AND u.email_confirmed_at IS NOT NULL
      AND (u.banned_until IS NULL OR u.banned_until <= now())
      AND lower(btrim(COALESCE(u.email, ''))) = lower(btrim(a.email))
  ) INTO v_is_valid_admin;

  IF NOT v_is_valid_admin THEN
    RAISE EXCEPTION 'Unauthorized: p_admin_user_id is not an active administrator.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  UPDATE public.asset_cleanup_queue
  SET status           = 'pending',
      attempts         = 0,
      requeue_count    = requeue_count + 1,
      requeued_at      = now(),
      requeued_by      = p_admin_user_id,
      exhausted_at     = NULL,
      next_retry_at    = now(),
      locked_at        = NULL,
      lease_expires_at = NULL,
      locked_by        = NULL
  WHERE id = p_job_id
    AND (
      status IN ('failed', 'exhausted')
      OR (
        status = 'processing'
        AND lease_expires_at IS NOT NULL
        AND lease_expires_at <= now()
      )
    )
  RETURNING *;
END;
$$;

-- Lock down all cleanup RPCs exclusively to service_role
REVOKE ALL ON FUNCTION public.delete_artwork_and_enqueue_cleanup(TEXT, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_artwork_and_enqueue_cleanup(TEXT, TEXT, INTEGER) TO service_role;

REVOKE ALL ON FUNCTION public.claim_asset_cleanup_jobs(TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_asset_cleanup_jobs(TEXT, INTEGER, INTEGER) TO service_role;

REVOKE ALL ON FUNCTION public.mark_asset_cleanup_succeeded(BIGINT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_asset_cleanup_succeeded(BIGINT, TEXT) TO service_role;

REVOKE ALL ON FUNCTION public.record_asset_cleanup_failure(BIGINT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_asset_cleanup_failure(BIGINT, TEXT, TEXT) TO service_role;

REVOKE ALL ON FUNCTION public.requeue_asset_cleanup_job(BIGINT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_asset_cleanup_job(BIGINT, UUID) TO service_role;

COMMIT;
```
