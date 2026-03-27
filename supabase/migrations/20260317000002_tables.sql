-- ============================================================
-- Credebi: All tables in dependency order
-- ============================================================

-- ============================================================
-- ユーザー (Supabase Auth連携)
-- ============================================================
CREATE TABLE users (
  id              UUID PRIMARY KEY DEFAULT auth.uid(),
  display_name    TEXT,
  timezone        TEXT DEFAULT 'Asia/Tokyo',
  tier            INT DEFAULT 0 CHECK (tier BETWEEN 0 AND 3),  -- 0:Free, 1:Standard(¥300), 2:Pro(¥980), 3:Owner(内部用)
  -- DT-160: User-configurable push notification level
  notification_level TEXT DEFAULT 'medium'
    CHECK (notification_level IN ('least', 'less', 'medium', 'full')),
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- メール連携
-- ============================================================
CREATE TABLE email_connections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider        TEXT NOT NULL,  -- 'gmail', 'outlook', 'yahoo_jp'
  email_address   TEXT,
  vault_secret_id UUID,
  access_token_expires_at TIMESTAMPTZ,
  last_history_id TEXT,
  last_error      TEXT,
  watch_expiry    TIMESTAMPTZ,
  watch_renewed_at TIMESTAMPTZ,
  last_synced_at  TIMESTAMPTZ,
  last_resync_at  TIMESTAMPTZ,
  bootstrap_completed_at TIMESTAMPTZ,
  consecutive_failure_count INT DEFAULT 0,
  last_failure_at TIMESTAMPTZ,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(provider, email_address)
);

-- ============================================================
-- Webhook冪等性 (Pub/Sub messageId 重複排除)
-- ============================================================
CREATE TABLE processed_webhook_messages (
  message_id    TEXT PRIMARY KEY,
  status        TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'done'
  locked_until  TIMESTAMPTZ,
  processed_at  TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 金融アカウント (銀行口座、クレジットカード)
-- ============================================================
CREATE TABLE financial_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  type            TEXT NOT NULL,  -- 'bank', 'credit_card', 'etc_card'
  issuer          TEXT NOT NULL,
  brand           TEXT,
  name            TEXT NOT NULL,
  last4           TEXT,
  billing_day     INT,
  closing_day     INT,
  schedule_source TEXT,
  schedule_confidence REAL,
  schedule_updated_at TIMESTAMPTZ,
  credit_limit    BIGINT,
  current_balance BIGINT DEFAULT 0,
  balance_updated_at TIMESTAMPTZ,
  balance_source  TEXT,
  balance_observed_at TIMESTAMPTZ,
  previous_balance BIGINT,
  previous_balance_observed_at TIMESTAMPTZ,
  settlement_account_id UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  last_unlinked_notification_at TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ DEFAULT now(),
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- カテゴリ
-- ============================================================
CREATE TABLE categories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id),  -- NULL = システム定義
  name            TEXT NOT NULL,
  icon            TEXT,
  color           TEXT,
  is_fixed_cost   BOOLEAN DEFAULT false,
  sort_order      INT DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, name)
);

-- ============================================================
-- 取引 (全支出・収入)
-- ============================================================
CREATE TABLE transactions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  account_id      UUID REFERENCES financial_accounts(id),
  amount          BIGINT NOT NULL,
  currency        TEXT DEFAULT 'JPY',
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL,
  merchant_name   TEXT,
  description     TEXT,
  location_lat    DOUBLE PRECISION,
  location_lng    DOUBLE PRECISION,
  source          TEXT NOT NULL,
  confidence      REAL,
  status          TEXT DEFAULT 'pending',
  correlation_id  UUID REFERENCES transactions(id),
  is_primary      BOOLEAN DEFAULT true,
  metadata        JSONB DEFAULT '{}',
  transacted_at   TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 取引内訳 (レシートOCR等)
-- ============================================================
CREATE TABLE transaction_line_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  UUID REFERENCES transactions(id) NOT NULL,
  name            TEXT NOT NULL,
  amount          BIGINT NOT NULL,
  quantity        INT DEFAULT 1,
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- メール解析ログ
-- ============================================================
CREATE TABLE parsed_emails (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider_message_id TEXT,
  email_subject   TEXT,
  sender          TEXT,
  parsed_amount   BIGINT,
  parsed_merchant TEXT,
  parsed_type     TEXT,
  parsed_card_last4 TEXT,
  transaction_id  UUID REFERENCES transactions(id),
  raw_hash        TEXT,
  received_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, provider_message_id),
  UNIQUE(user_id, raw_hash)
);

-- ============================================================
-- サブスクリプション (固定費)
-- ============================================================
CREATE TABLE subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  name            TEXT NOT NULL,
  amount          BIGINT NOT NULL,
  billing_cycle   TEXT DEFAULT 'monthly',
  next_billing_at DATE,
  account_id      UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL,
  detected_from   TEXT DEFAULT 'email_keyword',
  subscription_type TEXT DEFAULT 'recurring',
  expected_end_at DATE,
  remaining_count INT,
  is_active       BOOLEAN DEFAULT true,
  last_detected_email_id UUID REFERENCES parsed_emails(id) ON DELETE SET NULL,
  metadata        JSONB DEFAULT '{}',
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 月次サマリ (pg_cronで日次更新)
-- ============================================================
CREATE TABLE monthly_summaries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  year_month      TEXT NOT NULL,
  total_income    BIGINT DEFAULT 0,
  total_expense   BIGINT DEFAULT 0,
  fixed_costs     BIGINT DEFAULT 0,
  variable_costs  BIGINT DEFAULT 0,
  uncategorized   BIGINT DEFAULT 0,
  projected_balance BIGINT DEFAULT 0,
  data_as_of      TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, year_month)
);

-- ============================================================
-- 見込み収入 (予測エンジン入力)
-- ============================================================
CREATE TABLE projected_incomes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  name            TEXT NOT NULL,
  amount          BIGINT NOT NULL,
  gross_amount    BIGINT,
  recurrence      TEXT NOT NULL,
  day_of_month    INT,
  payday_adjustment TEXT DEFAULT 'prev_business_day',
  weekday         INT,
  next_occurs_at  DATE,
  source          TEXT DEFAULT 'manual',
  confidence      REAL DEFAULT 0.5,
  connection_id   UUID,  -- FK added after income_connections
  bank_account_id UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  target_month    TEXT,
  breakdown       JSONB DEFAULT '{}',
  metadata        JSONB DEFAULT '{}',
  data_as_of      TIMESTAMPTZ,
  is_estimated    BOOLEAN DEFAULT false,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 収入ソース連携 (freee HR, ジョブカン等)
-- ============================================================
CREATE TABLE income_connections (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID REFERENCES users(id) NOT NULL,
  provider          TEXT NOT NULL,
  company_id        INT,
  employee_id       INT,
  employer_name     TEXT,
  vault_secret_id   UUID,
  transportation_per_day INT DEFAULT 0,
  payday            INT DEFAULT 25,
  pay_calc_method   TEXT DEFAULT 'hourly',
  session_status    TEXT DEFAULT 'active',
  session_expires_at TIMESTAMPTZ,
  last_synced_at    TIMESTAMPTZ,
  last_error        TEXT,
  is_active         BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 時給期間履歴
-- ============================================================
CREATE TABLE hourly_rate_periods (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id   UUID NOT NULL REFERENCES income_connections(id) ON DELETE CASCADE,
  hourly_rate     INT NOT NULL,
  overtime_multiplier REAL DEFAULT 1.25,
  night_multiplier    REAL DEFAULT 0.25,
  holiday_multiplier  REAL DEFAULT 1.35,
  effective_from  DATE NOT NULL,
  effective_to    DATE,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- シフト・勤怠レコード
-- ============================================================
CREATE TABLE shift_records (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID REFERENCES users(id) NOT NULL,
  connection_id     UUID REFERENCES income_connections(id) NOT NULL,
  date              DATE NOT NULL,
  clock_in          TIME,
  clock_out         TIME,
  break_minutes     INT DEFAULT 0,
  work_hours        REAL NOT NULL,
  overtime_hours    REAL DEFAULT 0,
  shift_type        TEXT NOT NULL,
  source            TEXT NOT NULL,
  raw_data          JSONB DEFAULT '{}',
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, connection_id, date)
);

-- ============================================================
-- 固定費 (サブスク以外: 家賃/通信費など)
-- ============================================================
CREATE TABLE fixed_cost_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  name            TEXT NOT NULL,
  amount          BIGINT NOT NULL,
  billing_cycle   TEXT DEFAULT 'monthly',
  billing_day     INT,
  next_billing_at DATE,
  account_id      UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 期待メール監視 (Tier 2+ の能動クロール用)
-- ============================================================
CREATE TABLE expected_email_rules (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider          TEXT NOT NULL DEFAULT 'gmail',
  issuer            TEXT NOT NULL,
  subject_hint      TEXT NOT NULL,
  sender_hint       TEXT,
  expected_day_from INT NOT NULL,
  expected_day_to   INT NOT NULL,
  is_active         BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE expected_email_jobs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  rule_id         UUID REFERENCES expected_email_rules(id) NOT NULL,
  target_month    TEXT NOT NULL,
  status          TEXT DEFAULT 'pending',
  attempt_count   INT DEFAULT 0,
  next_run_at     TIMESTAMPTZ,
  last_error      TEXT,
  last_checked_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, rule_id, target_month)
);

-- ============================================================
-- APIキー (Public API / MCP認証用)
-- ============================================================
CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
  key_hash      TEXT NOT NULL,
  name          TEXT NOT NULL,
  scopes        TEXT[] NOT NULL,
  last_used_at  TIMESTAMPTZ,
  last_used_ip  INET,
  expires_at    TIMESTAMPTZ,
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT chk_scopes_not_empty CHECK (array_length(scopes, 1) > 0)
);

-- ============================================================
-- レート制限カウンタ (Public API)
-- ============================================================
CREATE TABLE rate_limit_counters (
  bucket_key  TEXT PRIMARY KEY,
  count       INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- API冪等性キーキャッシュ
-- ============================================================
CREATE TABLE api_idempotency_keys (
  key         TEXT NOT NULL,
  user_id     UUID NOT NULL,
  endpoint    TEXT NOT NULL,
  status_code INT NOT NULL,
  response    JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id, key)
);

-- ============================================================
-- パース失敗ログ
-- ============================================================
CREATE TABLE parse_failures (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider_message_id TEXT,
  email_subject   TEXT,
  sender          TEXT,
  failure_reason  TEXT NOT NULL,
  raw_hash        TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- EC注文メール突合の一時保管 (DT-045a)
-- ============================================================
CREATE TABLE pending_ec_correlations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  amount          BIGINT NOT NULL,
  items           JSONB,
  store_name      TEXT,
  suggested_category TEXT,
  order_id        TEXT,
  email_received_at TIMESTAMPTZ NOT NULL,
  matched         BOOLEAN DEFAULT false,
  transaction_id  UUID REFERENCES transactions(id),
  expires_at      TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- システムアラート / Dead Man's Switch (DT-028)
-- ============================================================
CREATE TABLE system_alerts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(id),
  alert_type    TEXT NOT NULL,
  message       TEXT NOT NULL,
  email_connection_id  UUID REFERENCES email_connections(id) ON DELETE SET NULL,
  income_connection_id UUID,  -- FK added after income_connections exists
  resolved_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Suggestion feedback (DT-056)
-- ============================================================
CREATE TABLE user_suggestion_stats (
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  signal_type   TEXT NOT NULL CHECK (signal_type IN ('gps', 'history', 'time', 'amount', 'email_hint')),
  hit_count     INT NOT NULL DEFAULT 0,
  miss_count    INT NOT NULL DEFAULT 0,
  accuracy      REAL GENERATED ALWAYS AS (
    CASE WHEN hit_count + miss_count = 0 THEN NULL
         ELSE hit_count::real / (hit_count + miss_count)
    END
  ) STORED,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, signal_type)
);

CREATE TABLE suggestion_feedback (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  transaction_id   UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  action           TEXT NOT NULL CHECK (action IN ('accepted', 'skipped', 'manual_override')),
  shown_suggestions JSONB NOT NULL,
  accepted_rank     INT,
  accepted_source   TEXT,
  chosen_category_id UUID,
  chosen_merchant    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE system_heartbeats (
  job_name          TEXT PRIMARY KEY,
  last_success_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expected_interval INTERVAL NOT NULL,
  last_status       TEXT NOT NULL DEFAULT 'ok'
    CHECK (last_status IN ('ok', 'error')),
  details           JSONB NOT NULL DEFAULT '{}',
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
