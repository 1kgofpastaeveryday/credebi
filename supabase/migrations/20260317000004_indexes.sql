-- ============================================================
-- All indexes
-- ============================================================

-- transactions
CREATE INDEX idx_transactions_user_transacted_at ON transactions(user_id, transacted_at DESC);
CREATE INDEX idx_transactions_user_status ON transactions(user_id, status);
CREATE INDEX idx_transactions_user_source ON transactions(user_id, source);
CREATE INDEX idx_transactions_user_amount_time ON transactions(user_id, amount, transacted_at DESC);
CREATE INDEX idx_transactions_location ON transactions(user_id, location_lat, location_lng)
  WHERE location_lat IS NOT NULL;

-- transaction_line_items
CREATE INDEX idx_line_items_transaction ON transaction_line_items(transaction_id);

-- parsed_emails
CREATE INDEX idx_parsed_emails_user_received_at ON parsed_emails(user_id, received_at DESC);
CREATE INDEX idx_parsed_emails_transaction ON parsed_emails(transaction_id) WHERE transaction_id IS NOT NULL;

-- email_connections
CREATE INDEX idx_email_connections_user_provider ON email_connections(user_id, provider);

-- projected_incomes
CREATE INDEX idx_projected_incomes_user_active ON projected_incomes(user_id, is_active);

-- fixed_cost_items
CREATE INDEX idx_fixed_cost_items_user_active ON fixed_cost_items(user_id, is_active);

-- expected_email_rules / jobs
CREATE INDEX idx_expected_email_rules_active ON expected_email_rules(provider, issuer, is_active);
CREATE INDEX idx_expected_email_jobs_user_month ON expected_email_jobs(user_id, target_month, status);
CREATE INDEX idx_expected_email_jobs_next_run ON expected_email_jobs(status, next_run_at);

-- income_connections
CREATE INDEX idx_income_connections_user_active ON income_connections(user_id, is_active);

-- correlation queries
CREATE INDEX idx_transactions_correlation ON transactions(correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_pending_ec_user_amount ON pending_ec_correlations(user_id, amount, matched) WHERE matched = false;

-- hourly_rate_periods / shift_records
CREATE INDEX idx_hourly_rate_periods_connection ON hourly_rate_periods(connection_id, effective_from);
CREATE INDEX idx_shift_records_user_date ON shift_records(user_id, date DESC);
CREATE INDEX idx_shift_records_connection_month ON shift_records(connection_id, date);

-- api_keys
CREATE INDEX idx_api_keys_hash ON api_keys(key_hash) WHERE is_active = true;

-- rate_limit / idempotency TTL
CREATE INDEX idx_rate_limit_ttl ON rate_limit_counters(created_at);
CREATE INDEX idx_idempotency_ttl ON api_idempotency_keys(created_at);

-- parse_failures
CREATE INDEX idx_parse_failures_user ON parse_failures(user_id, created_at DESC);

-- system_alerts
CREATE INDEX idx_system_alerts_unresolved ON system_alerts(alert_type, created_at)
  WHERE resolved_at IS NULL;

-- suggestion_feedback
CREATE INDEX idx_suggestion_feedback_user ON suggestion_feedback(user_id, created_at DESC);
