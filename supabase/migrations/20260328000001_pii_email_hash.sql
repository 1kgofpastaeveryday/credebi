-- ============================================================
-- PII Retention: email_address → hash + masked display
--
-- email_address column will be dropped in a future migration
-- after backfill. New code should use email_lookup_hash for
-- lookups and email_display for UI.
-- ============================================================

-- SHA-256 hex digest of lower(trim(email_address))
ALTER TABLE email_connections
  ADD COLUMN email_lookup_hash TEXT;

-- Masked form for UI display (e.g. "s***@gmail.com")
ALTER TABLE email_connections
  ADD COLUMN email_display TEXT;

-- Lookup index: replaces the existing UNIQUE(provider, email_address)
-- after backfill + drop of email_address
CREATE UNIQUE INDEX idx_email_connections_provider_hash
  ON email_connections (provider, email_lookup_hash)
  WHERE email_lookup_hash IS NOT NULL;

COMMENT ON COLUMN email_connections.email_lookup_hash IS
  'SHA-256 hex of normalized (lower+trim) email. Used for dedup lookups. Replaces email_address.';

COMMENT ON COLUMN email_connections.email_display IS
  'Masked email for UI (e.g. s***@gmail.com). No PII recovery possible from this value.';
