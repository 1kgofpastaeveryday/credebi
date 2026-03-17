-- ============================================================
-- Stored procedures, triggers, and deferred foreign keys
-- ============================================================

-- ============================================================
-- Deferred FKs (tables defined out of order)
-- ============================================================

-- projected_incomes.connection_id → income_connections.id
ALTER TABLE projected_incomes
  ADD CONSTRAINT fk_projected_incomes_connection
  FOREIGN KEY (connection_id) REFERENCES income_connections(id);

-- system_alerts.income_connection_id → income_connections.id
ALTER TABLE system_alerts
  ADD CONSTRAINT fk_system_alerts_income_connection
  FOREIGN KEY (income_connection_id) REFERENCES income_connections(id) ON DELETE SET NULL;

-- ============================================================
-- financial_accounts constraints
-- ============================================================

-- Bank accounts must NOT have a settlement_account_id
ALTER TABLE financial_accounts
ADD CONSTRAINT chk_settlement_account_only_for_cards
CHECK (
  (type = 'credit_card') OR (settlement_account_id IS NULL)
);

-- Credit card schedule: both or neither of closing_day/billing_day
ALTER TABLE financial_accounts
ADD CONSTRAINT chk_credit_card_schedule_pair_valid
CHECK (
  type <> 'credit_card'
  OR (
    (closing_day IS NULL AND billing_day IS NULL)
    OR (closing_day BETWEEN 1 AND 31 AND billing_day BETWEEN 1 AND 31)
  )
);

-- ============================================================
-- settlement_account_id IDOR prevention (SEC-R4-001)
-- ============================================================
CREATE OR REPLACE FUNCTION check_settlement_account_ownership()
RETURNS TRIGGER AS $$
DECLARE
  target_user_id UUID;
  target_type TEXT;
BEGIN
  IF NEW.settlement_account_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT user_id, type INTO target_user_id, target_type
  FROM financial_accounts WHERE id = NEW.settlement_account_id;

  IF target_user_id IS NULL THEN
    RAISE EXCEPTION 'settlement_account_id references non-existent account';
  END IF;
  IF target_user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'settlement_account_id must reference own account';
  END IF;
  IF target_type <> 'bank' THEN
    RAISE EXCEPTION 'settlement_account_id must reference a bank account, got %', target_type;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_settlement_account_ownership
  BEFORE INSERT OR UPDATE OF settlement_account_id ON financial_accounts
  FOR EACH ROW EXECUTE FUNCTION check_settlement_account_ownership();

-- ============================================================
-- bank_account_id IDOR prevention on projected_incomes (SEC-R4-002)
-- ============================================================
CREATE OR REPLACE FUNCTION check_income_bank_account_ownership()
RETURNS TRIGGER AS $$
DECLARE
  target_user_id UUID;
  target_type TEXT;
BEGIN
  IF NEW.bank_account_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT user_id, type INTO target_user_id, target_type
  FROM financial_accounts WHERE id = NEW.bank_account_id;

  IF target_user_id IS NULL THEN
    RAISE EXCEPTION 'bank_account_id references non-existent account';
  END IF;
  IF target_user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'bank_account_id must reference own account';
  END IF;
  IF target_type <> 'bank' THEN
    RAISE EXCEPTION 'bank_account_id must reference a bank account, got %', target_type;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_income_bank_account_ownership
  BEFORE INSERT OR UPDATE OF bank_account_id ON projected_incomes
  FOR EACH ROW EXECUTE FUNCTION check_income_bank_account_ownership();

-- ============================================================
-- Bank balance update SP (atomic previous_balance shift)
-- ============================================================
CREATE OR REPLACE FUNCTION update_bank_balance(
  p_account_id UUID,
  p_user_id UUID,
  p_new_balance BIGINT,
  p_observed_at TIMESTAMPTZ,
  p_source TEXT
) RETURNS VOID AS $$
BEGIN
  UPDATE financial_accounts
  SET previous_balance             = current_balance,
      previous_balance_observed_at = balance_observed_at,
      current_balance              = p_new_balance,
      balance_observed_at          = p_observed_at,
      balance_updated_at           = now(),
      balance_source               = p_source
  WHERE id = p_account_id
    AND user_id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION update_bank_balance FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_bank_balance TO service_role;

-- ============================================================
-- historyId monotonic update (prevents webhook race conditions)
-- ============================================================
CREATE OR REPLACE FUNCTION update_history_id_monotonic(
  p_connection_id UUID,
  p_new_history_id TEXT
) RETURNS BOOLEAN AS $$
DECLARE
  updated INT;
BEGIN
  UPDATE email_connections
  SET last_history_id = p_new_history_id,
      last_synced_at = now()
  WHERE id = p_connection_id
    AND (last_history_id IS NULL
         OR last_history_id::bigint < p_new_history_id::bigint);
  GET DIAGNOSTICS updated = ROW_COUNT;
  RETURN updated > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION update_history_id_monotonic FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_history_id_monotonic TO service_role;

-- ============================================================
-- Atomic parsed_email + transaction write (DT-029)
-- ============================================================
CREATE OR REPLACE FUNCTION insert_parsed_email_with_transaction(
  p_user_id UUID,
  p_provider_message_id TEXT,
  p_email_subject TEXT,
  p_sender TEXT,
  p_parsed_amount BIGINT,
  p_parsed_merchant TEXT,
  p_parsed_type TEXT,
  p_parsed_card_last4 TEXT,
  p_raw_hash TEXT,
  p_received_at TIMESTAMPTZ,
  p_account_id UUID,
  p_amount BIGINT,
  p_transacted_at TIMESTAMPTZ,
  p_merchant_name TEXT,
  p_category_id UUID DEFAULT NULL,
  p_source TEXT DEFAULT 'email_detect'
) RETURNS TABLE(parsed_email_id UUID, transaction_id UUID) AS $$
DECLARE
  v_tx_id UUID;
  v_pe_id UUID;
BEGIN
  INSERT INTO transactions (user_id, account_id, amount, transacted_at,
                           merchant_name, category_id, source)
  VALUES (p_user_id, p_account_id, p_amount, p_transacted_at,
          p_merchant_name, p_category_id, p_source)
  RETURNING id INTO v_tx_id;

  INSERT INTO parsed_emails (user_id, provider_message_id, email_subject, sender,
                            parsed_amount, parsed_merchant, parsed_type,
                            parsed_card_last4, transaction_id, raw_hash, received_at)
  VALUES (p_user_id, p_provider_message_id, p_email_subject, p_sender,
          p_parsed_amount, p_parsed_merchant, p_parsed_type,
          p_parsed_card_last4, v_tx_id, p_raw_hash, p_received_at)
  RETURNING id INTO v_pe_id;

  RETURN QUERY SELECT v_pe_id, v_tx_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION insert_parsed_email_with_transaction FROM PUBLIC;
GRANT EXECUTE ON FUNCTION insert_parsed_email_with_transaction TO service_role;

-- ============================================================
-- Rate limit increment (Public API)
-- ============================================================
CREATE OR REPLACE FUNCTION increment_rate_limit(p_bucket_key TEXT)
RETURNS INT AS $$
DECLARE current_count INT;
BEGIN
  INSERT INTO rate_limit_counters (bucket_key, count)
  VALUES (p_bucket_key, 1)
  ON CONFLICT (bucket_key) DO UPDATE SET count = rate_limit_counters.count + 1
  RETURNING count INTO current_count;
  RETURN current_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION increment_rate_limit FROM PUBLIC;
GRANT EXECUTE ON FUNCTION increment_rate_limit TO service_role;

-- ============================================================
-- Suggestion stat update (DT-056)
-- ============================================================
CREATE OR REPLACE FUNCTION update_suggestion_stat(
  p_user_id UUID,
  p_signal_type TEXT,
  p_is_hit BOOLEAN
) RETURNS VOID AS $$
BEGIN
  INSERT INTO user_suggestion_stats (user_id, signal_type, hit_count, miss_count, updated_at)
  VALUES (
    p_user_id, p_signal_type,
    CASE WHEN p_is_hit THEN 1 ELSE 0 END,
    CASE WHEN p_is_hit THEN 0 ELSE 1 END,
    now()
  )
  ON CONFLICT (user_id, signal_type) DO UPDATE SET
    hit_count  = user_suggestion_stats.hit_count  + CASE WHEN p_is_hit THEN 1 ELSE 0 END,
    miss_count = user_suggestion_stats.miss_count + CASE WHEN p_is_hit THEN 0 ELSE 1 END,
    updated_at = now();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION update_suggestion_stat FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_suggestion_stat TO service_role;
