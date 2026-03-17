-- ============================================================
-- Extensions required for Credebi
-- ============================================================
-- pg_net: HTTP requests from SQL (used by pg_cron to call Edge Functions)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- pg_cron: Scheduled jobs (TTL cleanup, watch renewal, projections)
CREATE EXTENSION IF NOT EXISTS pg_cron;
