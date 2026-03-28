-- ============================================================
-- ON DELETE CASCADE for all user-data foreign keys
--
-- Enables complete data deletion when a user account is removed.
-- Account deletion = DELETE FROM users WHERE id = $1 triggers
-- cascade across all user data.
--
-- Tables that already have ON DELETE CASCADE (no change needed):
--   api_keys, user_suggestion_stats, suggestion_feedback
--
-- Tables with no FK to users(id):
--   processed_webhook_messages, expected_email_rules,
--   transaction_line_items (FK to transactions, not users),
--   hourly_rate_periods (FK to income_connections, not users),
--   rate_limit_counters, api_idempotency_keys, system_heartbeats
-- ============================================================

-- email_connections
ALTER TABLE email_connections
  DROP CONSTRAINT email_connections_user_id_fkey,
  ADD CONSTRAINT email_connections_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- financial_accounts
ALTER TABLE financial_accounts
  DROP CONSTRAINT financial_accounts_user_id_fkey,
  ADD CONSTRAINT financial_accounts_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- categories
ALTER TABLE categories
  DROP CONSTRAINT categories_user_id_fkey,
  ADD CONSTRAINT categories_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- transactions
ALTER TABLE transactions
  DROP CONSTRAINT transactions_user_id_fkey,
  ADD CONSTRAINT transactions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- parsed_emails
ALTER TABLE parsed_emails
  DROP CONSTRAINT parsed_emails_user_id_fkey,
  ADD CONSTRAINT parsed_emails_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- subscriptions
ALTER TABLE subscriptions
  DROP CONSTRAINT subscriptions_user_id_fkey,
  ADD CONSTRAINT subscriptions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- monthly_summaries
ALTER TABLE monthly_summaries
  DROP CONSTRAINT monthly_summaries_user_id_fkey,
  ADD CONSTRAINT monthly_summaries_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- projected_incomes
ALTER TABLE projected_incomes
  DROP CONSTRAINT projected_incomes_user_id_fkey,
  ADD CONSTRAINT projected_incomes_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- income_connections
ALTER TABLE income_connections
  DROP CONSTRAINT income_connections_user_id_fkey,
  ADD CONSTRAINT income_connections_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- shift_records
ALTER TABLE shift_records
  DROP CONSTRAINT shift_records_user_id_fkey,
  ADD CONSTRAINT shift_records_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- fixed_cost_items
ALTER TABLE fixed_cost_items
  DROP CONSTRAINT fixed_cost_items_user_id_fkey,
  ADD CONSTRAINT fixed_cost_items_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- expected_email_jobs
ALTER TABLE expected_email_jobs
  DROP CONSTRAINT expected_email_jobs_user_id_fkey,
  ADD CONSTRAINT expected_email_jobs_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- system_alerts
ALTER TABLE system_alerts
  DROP CONSTRAINT system_alerts_user_id_fkey,
  ADD CONSTRAINT system_alerts_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- parse_failures
ALTER TABLE parse_failures
  DROP CONSTRAINT parse_failures_user_id_fkey,
  ADD CONSTRAINT parse_failures_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- pending_ec_correlations
ALTER TABLE pending_ec_correlations
  DROP CONSTRAINT pending_ec_correlations_user_id_fkey,
  ADD CONSTRAINT pending_ec_correlations_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- api_idempotency_keys (user_id column exists but may not have named FK)
-- This table uses a composite PK (user_id, key) but no explicit FK to users.
-- Adding CASCADE FK for completeness.
ALTER TABLE api_idempotency_keys
  ADD CONSTRAINT api_idempotency_keys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
