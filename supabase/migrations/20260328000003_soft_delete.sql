-- ============================================================
-- Soft-delete support for user accounts
--
-- Supports the account deletion flow documented in DESIGN.md §6d:
--   1. User initiates deletion → deleted_at = now()
--   2. 30-day grace period (user can cancel by logging in)
--   3. pg_cron hard-purges expired soft-deleted users
--   4. ON DELETE CASCADE propagates to all child tables
-- ============================================================

ALTER TABLE users
  ADD COLUMN deleted_at TIMESTAMPTZ;

-- RLS: hide soft-deleted users from normal queries
-- (service_role can still see them for the purge job)
CREATE POLICY users_hide_deleted ON users
  FOR SELECT USING (deleted_at IS NULL OR id = auth.uid());

-- pg_cron job: hard-purge users past 30-day grace period
-- CASCADE delete handles all child tables; Vault cleanup must be
-- done by a pre-delete Edge Function (see DESIGN.md §6d step 6).
SELECT cron.schedule(
  'purge-deleted-users',
  '0 4 * * *',  -- daily at 04:00 UTC
  $$DELETE FROM users WHERE deleted_at < now() - interval '30 days'$$
);
