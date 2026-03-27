-- ============================================================
-- Row Level Security: enable + policies
-- ============================================================

-- Enable RLS on all tables
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE parsed_emails ENABLE ROW LEVEL SECURITY;
ALTER TABLE monthly_summaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE projected_incomes ENABLE ROW LEVEL SECURITY;
ALTER TABLE fixed_cost_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE expected_email_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE expected_email_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE income_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE hourly_rate_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE shift_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limit_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE parse_failures ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_ec_correlations ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_heartbeats ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_suggestion_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggestion_feedback ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Standard pattern: user_id = auth.uid()
-- ============================================================
CREATE POLICY users_select ON users
  FOR SELECT USING (id = auth.uid());

CREATE POLICY users_insert ON users
  FOR INSERT WITH CHECK (id = auth.uid() AND tier = 0);

CREATE POLICY users_update ON users
  FOR UPDATE USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE POLICY users_delete ON users
  FOR DELETE USING (id = auth.uid());

CREATE POLICY "users_own_data" ON email_connections
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON financial_accounts
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON transactions
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON subscriptions
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON parsed_emails
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON monthly_summaries
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON projected_incomes
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON fixed_cost_items
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON expected_email_jobs
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON income_connections
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON shift_records
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON api_keys
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON pending_ec_correlations
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON user_suggestion_stats
  FOR ALL USING (user_id = auth.uid());

CREATE POLICY "users_own_data" ON suggestion_feedback
  FOR ALL USING (user_id = auth.uid());

-- ============================================================
-- Special patterns
-- ============================================================

-- transaction_line_items: RLS via parent transaction's user_id
CREATE POLICY "users_own_data" ON transaction_line_items
  FOR ALL USING (transaction_id IN (SELECT id FROM transactions WHERE user_id = auth.uid()));

-- hourly_rate_periods: via connection_id → income_connections.user_id
CREATE POLICY "users_own_data" ON hourly_rate_periods
  FOR ALL USING (
    connection_id IN (
      SELECT id FROM income_connections WHERE user_id = auth.uid()
    )
  );

-- categories: system-defined (user_id IS NULL) readable by all, user's own CRUD
CREATE POLICY "categories_read" ON categories
  FOR SELECT USING (user_id IS NULL OR user_id = auth.uid());
CREATE POLICY "categories_write" ON categories
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "categories_update" ON categories
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "categories_delete" ON categories
  FOR DELETE USING (user_id = auth.uid());

-- expected_email_rules: system master data, read-only for all authenticated
CREATE POLICY "rules_read" ON expected_email_rules
  FOR SELECT USING (true);

-- parse_failures: users can read their own, service_role inserts
CREATE POLICY "users_own_data" ON parse_failures
  FOR SELECT USING (user_id = auth.uid());

-- system_alerts: users can only read their own (system-wide alerts hidden)
CREATE POLICY "users_read_own_alerts" ON system_alerts
  FOR SELECT USING (user_id = auth.uid());

-- No user-facing policies for: processed_webhook_messages, rate_limit_counters, api_idempotency_keys
-- These are service_role-only tables (RLS enabled but no policies = deny all for non-service_role)
