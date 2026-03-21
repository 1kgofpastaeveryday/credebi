# Credebi.com - Architecture Design Document

> 「短期的に、おれはどうなるのか」をよく調べなくてもわかるアプリ

ガキンチョ用マネーフォワード。メール・勤怠API・スクレイプで支出と収入を自動取得し、
「次の給料日まで安全にいくら使えるか」を常に可視化する短期キャッシュフロー予測ツール。

---

## 0. プロダクト戦略

### ビジョン

「お金の不安を、見える化で消す」
- クレカの「見えない負債」とバイト収入の「読めない給料」を同時に可視化
- 「記録・管理」ではなく**「判断支援」**。使った後に振り返るツールではなく、使う前に教えてくれるツール
- 誠実さ: 数字の確度を常に開示 (概算 / 見込み / 確定の3段階)
- 軽さ: 金額の羅列ではなく「あと自由に使える ¥XX,XXX」+ SAFE / WARNING
- 自動化: 手入力を極限まで減らす

### コスト構造上の優位性

マネーフォワード等の既存PFMは銀行API (アカウントアグリゲーション) に年間数千万円を投じている。
Credebi はメールパース + 公開API (freee HR等) + Playwright スクレイプで同等の情報を取得し、
**銀行API接続コストをゼロにする**。範囲は狭いが、ターゲットセグメントには十分。

### ターゲット (最優先セグメント)

クレカ持ち始めの大学生・専門学生 (アルバイト収入で生活)
- JTBD: 「クレカを使い始めたけど、今月いくら使ったか分からなくて怖い。引き落とし日に残高足りるか不安」
- 月収8-15万、固定費少ない、ITリテラシー高い、お金のリテラシーは低い

### North Star Metric

**SAFE状態を維持できた引き落とし日の割合**
= (口座残高不足にならなかった引き落とし回数) / (全引き落とし回数)

### トレードオフ (やらないこと)

| やらない | 理由 |
|---------|------|
| 銀行API連携 | コストが高すぎる。メール起点で代替可能 |
| 投資・資産管理 | スコープ外。短期キャッシュフロー予測に特化 |
| 美しいグラフ・詳細分析 | Gen-Z向けに認知負荷を下げる |
| iOS 25以前 / Android | 1人開発でマルチプラットフォームは無理 |
| レシートOCR・手入力を主動線にする | 自動化が核心。これらは補助機能 |
| Freeで広告を大量に入れる | 小さめの広告でサーバー費カバー。体験を壊さない |
| 機能制限で課金を強制する | 核心体験は全員に開放。有料はLLM + 自動化の幅 |
| 非アクティブユーザーからの課金 | 使ってないなら自動解約。誠実に運営 |

### 検証すべき仮説

| # | 仮説 | 検証方法 | 状態 |
|---|------|---------|------|
| H1 | 大学生はクレカの引き落とし残高不足に本当に困っている | 友人5人にインタビュー | 未着手 |
| H2 | メールパースで主要カード利用通知の80%以上をカバーできる | Phase 2 実装 | 未着手 |
| H3 | freee勤怠 + 時給で給与見込みの誤差 ±10%以内 | 2月実データで検証可能 | **検証可能** |
| H4 | 「あと自由に使える ¥XX,XXX」(自由残額) が日常的に見られるUXになる | プロトタイプでユーザーテスト | 未着手 |
| H5 | Free → Standard (¥300) への転換率 5%以上 | Phase 5 で計測 | 将来 |

> 詳細な戦略分析は別途 Strategy Canvas として保持 (vision/segments/growth/defensibility)

---

### タイムゾーン規約 (DT-052)

日本限定アプリのため、全ての日付境界ロジック (日次予算計算、月初リセット、引き落とし日判定、`target_month` 算出) は **`Asia/Tokyo` (JST, UTC+9)** を明示的に使用すること。

```typescript
// ✅ Good: explicit JST
new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Tokyo" })
Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", ... })

// ❌ Bad: implicit UTC
new Date().toISOString().slice(0, 10)  // UTC midnight ≠ JST midnight
new Date().getMonth()                   // UTC-based
```

DB側: `TIMESTAMPTZ` を使用 (PostgreSQLはUTC保存)。アプリ/Edge Function側で表示・判定時にJST変換。

### データ鮮度アーキテクチャ (DT-033)

**原則**: 予測・サマリの出力には必ず `data_as_of` を含め、上流データの鮮度をユーザーに開示する。

```
上流データソース         data_as_of の決定方法                    閾値
──────────────────────  ────────────────────────────────────  ──────
Gmail (email_connections) email_connections.last_synced_at       48h (XDOC-R4-004: aligned with DMS + engine)
freee (income_connections) income_connections.last_synced_at     48h (XDOC-R4-004: aligned with DMS)
Playwright (同上)          income_connections.last_synced_at     48h (スクレイプは遅延許容)
Bank balance              financial_accounts.balance_observed_at 30d (per-account, see 05-projection-engine.md)
pg_cron (monthly_summaries) monthly_summaries.updated_at        24h
```

**Projection API の data_as_of 算出**:
```typescript
// 全上流ソースの最古のタイムスタンプを採用 (most conservative)
const dataAsOf = Math.min(
  emailConnection.last_synced_at,
  incomeConnection?.last_synced_at ?? Infinity,
  monthlySummary.updated_at,
)
const isStale = Date.now() - dataAsOf > STALENESS_THRESHOLD_MS
```

**UI劣化表示**:
- `is_stale = false`: 通常表示 (SAFE / WARNING / DANGER)
- `is_stale = true`: オレンジ帯「データが古い可能性があります (最終更新: X時間前)」
- `stale_sources` に具体的なソース名を含めてトラブルシュート可能にする
- 壊れた接続 (`is_active = false`) がある場合: 赤帯「Gmail連携が切れています」

**DB反映**:
- `monthly_summaries.data_as_of` — pg_cronジョブ更新時に算出
- `projected_incomes.data_as_of` — sync-income-freee/playwright 更新時に算出
- Projection API応答: `data_as_of`, `is_stale`, `stale_sources` を含む (schema定義済み)

### 安全側バイアス原則 (Design Principle #3)

推定が不確実なとき、**支出は多めに、収入は少なめに**見積もる。

```text
空振り (false positive) → 「足りないかも」と警告 → 実際は足りた → 問題なし
見逃し (false negative) → 「大丈夫」と表示   → 実際は不足   → 最悪の体験

適用例:
- 自動検知サブスク → 即 projection に含める (支出多め = 安全側)
- income の同日判定が曖昧 → income を残す (二重計上 = 安全方向)
- カード accumulating charge → オープン期間でも表示 (最終額は下がるかもしれないが、多めが安全)
- heuristic の閾値が曖昧 → 支出を増やす / 収入を減らす方向に倒す

「空振りOK、見逃しNG」— 緊急地震速報と同じ。
```

## 1. 技術スタック

| レイヤー | 技術 | 理由 |
|---------|------|------|
| iOS App | SwiftUI (iOS 26+) | 最新API活用を優先。後方互換は段階的に追加 |
| バックエンド | Supabase (BaaS) | Auth/DB/Realtime/Edge Functions/Vault 一体型 |
| DB | PostgreSQL (Supabase内蔵) | RLS, JSONB, pg_cron, pgsodium |
| メール連携 | Gmail API (OAuth2) | まずGmailのみ。Tier1以上で他プロバイダ追加 |
| LLM (分類/パース) | **Gemini 2.5 Flash-Lite** (主) | 後述のコスト比較参照 |
| LLM (Tier1) | Claude Sonnet 4.5 | カスタム分類・編集等の高度タスク |
| LLM (Tier2) | GPT-5.2 Thinking | 最上位プラン用 |
| Push通知 | APNs (Apple Push Notification) | SwiftUIネイティブ |
| 位置情報 | CoreLocation + 逆ジオコーディング | 決済場所サジェスト |

---

## 2. LLMコスト比較と選定

### 価格表 (per 1M tokens)

| モデル | Input | Output | 備考 |
|--------|-------|--------|------|
| Claude Haiku 4.5 | $1.00 | $5.00 | 高精度だがコスト高 |
| Gemini 2.5 Flash | $0.30 | $2.50 | バランス型 |
| **Gemini 2.5 Flash-Lite** | **$0.10** | **$0.40** | **最安。分類タスクに最適** |
| GPT-4o-mini | $0.15 | $0.60 | 安価だがGemini Liteより高い |

### 推定月間コスト (1000ユーザー, 1人平均30回/日のメール分類)

```
1日あたり: 1000 × 30 = 30,000リクエスト
1リクエスト: ~500 input tokens + ~100 output tokens

Gemini 2.5 Flash-Lite:
  Input:  30,000 × 500 / 1M × $0.10 × 30日 = $0.45/月
  Output: 30,000 × 100 / 1M × $0.40 × 30日 = $0.36/月
  合計: ~$0.81/月 ← 極めて安い

Claude Haiku 4.5 (比較):
  合計: ~$5.10/月 ← 6倍以上高い
```

### 結論

- **フリーミアム / Tier1**: Gemini 2.5 Flash-Lite (コスト優先)
- **Tier1 (カスタム分類等)**: Claude Sonnet 4.5 (精度優先)
- **Tier2**: GPT-5.2 Thinking (最高性能)
- **フォールバック**: 精度が低い場合のリトライはGemini 2.5 Flashにステップアップ

---

## 3. データモデル

```sql
-- ============================================================
-- ユーザー (Supabase Auth連携)
-- ============================================================
CREATE TABLE users (
  id              UUID PRIMARY KEY DEFAULT auth.uid(),
  display_name    TEXT,
  timezone        TEXT DEFAULT 'Asia/Tokyo',
  tier            INT DEFAULT 3,  -- 0:Free, 1:Standard(¥300), 2:Pro(¥980), 3:Owner(内部用)
  -- DT-160: User-configurable push notification level
  notification_level TEXT DEFAULT 'medium'
    CHECK (notification_level IN ('least', 'less', 'medium', 'full')),
  -- least:  CRITICAL/broken_connection only
  -- less:   WARNING+ and subscription detection (cap 2/day)
  -- medium: + balance reminder, card utilization (cap 3/day) [default]
  -- full:   all notifications, no daily cap
  -- Quiet hours: iOS側制御 (Focus/おやすみモード)。サーバーキュー不要 (DT-176)。
  -- CRITICAL/broken_connection: APNs interruption-level = 'time-sensitive' で集中モード貫通 (critical は Apple 特別entitlement必要)。
  -- Bypass: CRITICAL within 7d + broken_connection → always deliver regardless of level
  -- Bootstrap: setup notifications exempt from cap at all levels
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- メール連携
-- ============================================================
CREATE TABLE email_connections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider        TEXT NOT NULL,  -- 'gmail', 'outlook', 'yahoo_jp'
  email_address   TEXT,           -- Pub/Sub通知のemailAddressと照合
  -- access_token / refresh_token は Supabase Vault に格納
  vault_secret_id UUID,          -- vault.secrets への参照
  access_token_expires_at TIMESTAMPTZ,  -- DT-051: Vault内access_tokenの有効期限
  last_history_id TEXT,          -- Gmail History API差分取得用
  last_error      TEXT,          -- DT-028: terminal error (e.g. 'token_revoked')
  watch_expiry    TIMESTAMPTZ,   -- Gmail watch() の有効期限
  watch_renewed_at TIMESTAMPTZ,
  last_synced_at  TIMESTAMPTZ,
  last_resync_at  TIMESTAMPTZ,           -- DT-003: HISTORY_ID_EXPIRED recovery timestamp
  bootstrap_completed_at TIMESTAMPTZ,    -- DT-049: initial inbox scan completion
  consecutive_failure_count INT DEFAULT 0,  -- DT-008: error tracking
  last_failure_at TIMESTAMPTZ,              -- DT-008: last failure timestamp
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(provider, email_address)
);

-- ============================================================
-- Webhook冪等性 (Pub/Sub messageId 重複排除)
-- ============================================================
CREATE TABLE processed_webhook_messages (
  message_id    TEXT PRIMARY KEY,
  status        TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'done'
  locked_until  TIMESTAMPTZ,                     -- DT-034: concurrent retry lock
  processed_at  TIMESTAMPTZ DEFAULT now()
);
-- TTL: pg_cronで7日超を日次削除 (DT-036 ✅ 定義済み)
-- RLS不要 (service_roleからのみアクセス)
-- NOTE: status='pending' のまま残った行はリトライ対象。
--   'done' になった行のみが重複排除として機能する。
--   クラッシュ時に処理が静かに消えることを防ぐ2フェーズ設計。
-- DT-034: Concurrent retry prevention
--   When claiming a 'pending' row for retry, set locked_until = now() + INTERVAL '5 minutes'.
--   Other workers skip rows where locked_until > now().
--   If the worker crashes, the lock expires and the next retry can reclaim.

-- ============================================================
-- 金融アカウント (銀行口座、クレジットカード)
-- ============================================================
CREATE TABLE financial_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  type            TEXT NOT NULL,  -- 'bank', 'credit_card', 'etc_card'
  issuer          TEXT NOT NULL,  -- 'smbc', 'life', 'saison', 'jal'
  brand           TEXT,           -- 'visa', 'mastercard', 'amex', 'jcb'
  name            TEXT NOT NULL,  -- 表示名: '三井住友NL', 'ライフカード学生'
  last4           TEXT,           -- 下4桁
  billing_day     INT,            -- 引き落とし日 (自動抽出 or 手入力)
  closing_day     INT,            -- 締め日 (自動抽出 or 手入力)
  schedule_source TEXT,           -- 'billing_email', 'issuer_default', 'manual'
  schedule_confidence REAL,       -- 0.0-1.0
  schedule_updated_at TIMESTAMPTZ,
  credit_limit    BIGINT,         -- ショッピング枠 (円)
  current_balance BIGINT DEFAULT 0,  -- 銀行:残高, カード:今月利用額
  balance_updated_at TIMESTAMPTZ,   -- DT-107: 残高の最終更新日時 (NULL = 未入力)
  balance_source  TEXT,             -- 'manual' | 'ocr_screenshot' | 'api' (Phase 2+)
  balance_observed_at TIMESTAMPTZ,  -- When was the balance actually observed? (may differ from updated_at)
  -- balance_observed_at sources:
  --   ocr_screenshot: EXIF timestamp if present + trustworthy, else upload time
  --   manual: user confirmation time (= balance_updated_at)
  --   api: API response timestamp
  -- DT-107 income double-count rule uses balance_observed_at (not balance_updated_at)
  -- because the question is "when was this balance true?" not "when did the user enter it?"
  -- DT-157: Previous balance snapshot for same-day income reconciliation heuristic.
  -- On each balance update, current values are shifted here before overwrite.
  -- Used by Layer B (amount-based reconciliation) when balance_observed_at
  -- shares the same JST date as a projected_income.
  previous_balance BIGINT,
  previous_balance_observed_at TIMESTAMPTZ,
  -- DT-159: Account-scoped cashflow model
  -- For credit_card: which bank account does the card bill settle from?
  -- Must reference a financial_accounts row with type='bank'.
  -- NULL = not yet configured → aggregate-only mode (DT-177: not SETUP_REQUIRED).
  -- iOS app shows settlement confirmation prompt with all banks + "銀行口座を追加".
  -- Only valid for type='credit_card'. Bank accounts must have this NULL.
  settlement_account_id UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  last_unlinked_notification_at TIMESTAMPTZ,  -- DT-006: notification frequency cap
  updated_at      TIMESTAMPTZ DEFAULT now(),
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- XDOC-R4-011 / OPS-R4-002: Stored procedure for balance updates.
-- Atomically shifts current_balance → previous_balance before overwriting.
-- Without this, previous_balance is always NULL and Layer B income reconciliation is dead.
-- Both OCR and manual balance update paths MUST use this SP (never raw .update()).
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
    AND user_id = p_user_id;  -- RLS double-check
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION update_bank_balance FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_bank_balance TO service_role;

-- DT-159: settlement_account_id constraints
-- 1. Bank accounts must NOT have a settlement_account_id (self-referential nonsense)
-- 2. Credit cards may have NULL (not yet configured) or a valid bank account
ALTER TABLE financial_accounts
ADD CONSTRAINT chk_settlement_account_only_for_cards
CHECK (
  (type = 'credit_card') OR (settlement_account_id IS NULL)
);

-- SEC-R4-001: settlement_account_id must reference the SAME user's bank account.
-- Without this trigger, a user could point their credit card at another user's bank account (IDOR).
-- Also enforces that the referenced row has type='bank' (XDOC-R4-005).
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

-- credit_card の日程は「未設定」も許容。
-- ただし片方だけ設定される不整合は防止する。
ALTER TABLE financial_accounts
ADD CONSTRAINT chk_credit_card_schedule_pair_valid
CHECK (
  type <> 'credit_card'
  OR (
    (closing_day IS NULL AND billing_day IS NULL)
    OR (closing_day BETWEEN 1 AND 31 AND billing_day BETWEEN 1 AND 31)
  )
);

-- DT-005: Schedule source priority and issuer defaults
-- Priority: billing_email (3) > issuer_default (2) > manual (1)
-- Higher priority source always overwrites lower. Same priority updates only on value change.
-- See docs/deep-dive/05-projection-engine.md for upsertAccountSchedule() implementation.

-- DT-107: Bank balance freshness policy
-- Phase 1 (MVP): 手動入力 + payday翌日Push nudge
-- Phase 2 (法人化後): Moneytree LINK API で自動取得
-- Phase 3 (将来): 電子決済等代行業登録 → 銀行APIダイレクト接続
--
-- Staleness 判定:
--   1. balance_updated_at IS NULL → SETUP_REQUIRED (予測画面ブロック)
--   2. payday が設定済み → balance_updated_at < 直近の payday → stale
--   3. payday 未設定 → balance_updated_at < now() - 30 days → stale
--   4. stale 時は projection API の is_stale = true, stale_sources に 'bank_balance' 追加
--
-- Bank balance は projection の truth anchor。stale な balance で SAFE を出すのは
-- Design Principle #1 違反。stale 時は WARNING 寄りに判定を倒す (fail-closed)。

-- DT-005: Issuer default schedule table
-- Used during onboarding to pre-fill closing_day/billing_day
-- { smbc: {closing:15, billing:10}, jcb: {closing:15, billing:10},
--   saison: {closing:10, billing:4} }
-- ライフカード: closing=5, billing varies → must come from email or manual

-- DT-006: Unlinked card notification rules
-- Cards with closing_day IS NULL are excluded from projection (silent hole → amber banner)
-- Push notification: max 1/card/7days, stop after 3 (use last_unlinked_notification_at)
-- UI: persistent amber banner "予測に含まれていません" until schedule is set

-- DT-008: Consecutive failure tracking rules (on email_connections)
-- On success: consecutive_failure_count = 0
-- On retryable failure: consecutive_failure_count++, last_failure_at = now()
-- At count 3: create system_alerts entry
-- At count 5: is_active = false, Push notification to user

-- ============================================================
-- カテゴリ
-- ============================================================
CREATE TABLE categories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id),  -- NULL = システム定義
  name            TEXT NOT NULL,       -- '食費', '交通費', 'サブスク'
  icon            TEXT,                -- SF Symbol名
  color           TEXT,                -- HEX
  is_fixed_cost   BOOLEAN DEFAULT false,
  sort_order      INT DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT now(),
  -- DT-062: Prevent duplicate names within same scope (system or per-user)
  UNIQUE(user_id, name)
);

-- DT-059: System category seed data (user_id = NULL)
-- These are referenced by TIME_PROFILES, AMOUNT_PROFILES, and LLM classification
INSERT INTO categories (user_id, name, icon, color, is_fixed_cost, sort_order) VALUES
  (NULL, '食費',       'fork.knife',           '#FF6B6B', false, 1),
  (NULL, 'コンビニ',    'building.2',           '#FFA07A', false, 2),
  (NULL, 'カフェ',      'cup.and.saucer',       '#D2B48C', false, 3),
  (NULL, '交通費',      'tram',                 '#4ECDC4', false, 4),
  (NULL, '日用品',      'cart',                 '#95E1D3', false, 5),
  (NULL, '衣服',       'tshirt',               '#DDA0DD', false, 6),
  (NULL, '娯楽',       'gamecontroller',       '#87CEEB', false, 7),
  (NULL, '医療',       'cross.case',           '#FF69B4', false, 8),
  (NULL, '通信費',      'wifi',                 '#778899', true,  9),
  (NULL, 'サブスク',    'repeat',               '#9370DB', true,  10),
  (NULL, '家賃',       'house',                '#CD853F', true,  11),
  (NULL, '光熱費',      'bolt',                 '#FFD700', true,  12),
  (NULL, '保険',       'shield',               '#2E8B57', true,  13),
  (NULL, '教育',       'book',                 '#6495ED', false, 14),
  (NULL, '美容',       'scissors',             '#FF69B4', false, 15),
  -- DT-119: 資金移動系カテゴリ追加 (支出として計算。口座残高が減る事実は同じ)
  (NULL, '貯蓄・投資',  'banknote',             '#4CAF50', false, 16),
  (NULL, '振込・送金',  'arrow.right.arrow.left', '#607D8B', false, 17),
  (NULL, 'その他',      'ellipsis.circle',      '#A9A9A9', false, 99)
ON CONFLICT (user_id, name) DO NOTHING;

-- ============================================================
-- 取引 (全支出・収入)
-- ============================================================
CREATE TABLE transactions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  account_id      UUID REFERENCES financial_accounts(id),
  amount          BIGINT NOT NULL,     -- 正:収入, 負:支出 (円単位)
  currency        TEXT DEFAULT 'JPY',
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL, -- DT-058
  merchant_name   TEXT,                -- 店舗名
  description     TEXT,
  location_lat    DOUBLE PRECISION,    -- GPS (任意)
  location_lng    DOUBLE PRECISION,
  source          TEXT NOT NULL,       -- 'email_detect', 'merchant_notification', 'manual', 'statement_sync', 'etc_api'
  confidence      REAL,                -- LLM分類の信頼度 (0.0-1.0)
  status          TEXT DEFAULT 'pending',  -- 'pending' → 'confirmed' → 'categorized'
  correlation_id  UUID REFERENCES transactions(id),  -- 二重通知の突合リンク
  is_primary      BOOLEAN DEFAULT true,              -- falseはUI非表示候補
  metadata        JSONB DEFAULT '{}',
  transacted_at   TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()  -- Public API楽観的排他制御用
);

-- ============================================================
-- 取引内訳 (レシートOCR等)
-- ============================================================
CREATE TABLE transaction_line_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  UUID REFERENCES transactions(id) NOT NULL,
  name            TEXT NOT NULL,            -- 'シャンプー', 'お菓子'
  amount          BIGINT NOT NULL,          -- 個別金額 (円, 正値)
  quantity        INT DEFAULT 1,
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL, -- DT-058
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_line_items_transaction ON transaction_line_items(transaction_id);
ALTER TABLE transaction_line_items ENABLE ROW LEVEL SECURITY;
-- DT-045d: RLS via parent transaction's user_id
CREATE POLICY "users_own_data" ON transaction_line_items
  FOR ALL USING (transaction_id IN (SELECT id FROM transactions WHERE user_id = auth.uid()));

-- ============================================================
-- サブスクリプション (固定費)
-- ============================================================
CREATE TABLE subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  name            TEXT NOT NULL,
  amount          BIGINT NOT NULL,
  billing_cycle   TEXT DEFAULT 'monthly',  -- 'monthly', 'yearly', 'weekly'
  next_billing_at DATE,
  account_id      UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,  -- DT-073: consistent with DT-058 pattern
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL,          -- DT-074: link to expense category for projection integration
  detected_from   TEXT DEFAULT 'email_keyword',  -- DT-075: 'email_keyword', 'pattern', 'known_db', 'manual' (aligned with 04-subscription-detection.md)
  -- DT-110: 分割払い対応
  subscription_type TEXT DEFAULT 'recurring',  -- 'recurring' (通常サブスク) | 'installment' (分割払い)
  expected_end_at DATE,               -- installment のみ: 最終支払予定日
  remaining_count INT,                -- installment のみ: 残り回数 (UI表示用)
  -- installment の終了処理:
  --   next_billing_at > expected_end_at になったら自動で is_active = false
  --   ※ 通常サブスクの「解約確認Push」(04-subscription-detection.md §6) は
  --     subscription_type = 'installment' には発火させない (予定通りの終了なので)
  is_active       BOOLEAN DEFAULT true,
  -- SEC-R4-004: Source traceability — which email triggered the last detection/amount change?
  -- UI displays this so users can see WHY a subscription exists or why the amount changed.
  -- If the source email looks bogus, the user can edit/delete the subscription themselves.
  -- This replaces complex trust-hierarchy logic with user-visible transparency.
  last_detected_email_id UUID REFERENCES parsed_emails(id) ON DELETE SET NULL,
  metadata        JSONB DEFAULT '{}',  -- DT-121: previous_amount etc.
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()  -- DT-076: needed for staleness detection and audit
);

-- ============================================================
-- メール解析ログ (生データは保存しない)
-- ============================================================
CREATE TABLE parsed_emails (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider_message_id TEXT,   -- Gmail message.id など
  email_subject   TEXT,
  sender          TEXT,
  parsed_amount   BIGINT,
  parsed_merchant TEXT,
  parsed_type     TEXT,     -- 'card_use', 'deposit', 'withdrawal', 'subscription', 'statement'
  parsed_card_last4 TEXT,   -- メールから検出したカード下4桁 (アカウント紐付け用)
  transaction_id  UUID REFERENCES transactions(id),
  raw_hash        TEXT,          -- SHA-256 of email body (重複防止)
  received_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, provider_message_id),
  UNIQUE(user_id, raw_hash)
);

-- ============================================================
-- 月次サマリ (pg_cronで日次更新)
-- ============================================================
CREATE TABLE monthly_summaries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  year_month      TEXT NOT NULL,        -- '2026-02'
  total_income    BIGINT DEFAULT 0,
  total_expense   BIGINT DEFAULT 0,
  fixed_costs     BIGINT DEFAULT 0,
  variable_costs  BIGINT DEFAULT 0,
  uncategorized   BIGINT DEFAULT 0,    -- DT-057: category_id IS NULL の支出額
  projected_balance BIGINT DEFAULT 0,   -- 引き落とし後の見込み残高
  data_as_of      TIMESTAMPTZ,         -- DT-033: most recent upstream data timestamp
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, year_month)
);
-- DT-057: Uncategorized transaction handling rules:
--   1. total_expense ALWAYS includes uncategorized (category_id IS NULL) transactions
--   2. variable_costs = total_expense - fixed_costs - uncategorized
--   3. UI: Show "未分類 ¥X" badge when uncategorized > 0, link to categorization flow
--   4. Projection engine treats uncategorized same as variable_costs (included in burn rate)
--   5. If uncategorized > 20% of total_expense, show warning "分類されていない取引があります"

-- ============================================================
-- 見込み収入 (予測エンジン入力)
-- ============================================================
CREATE TABLE projected_incomes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  name            TEXT NOT NULL,            -- '給料', '副業'
  amount          BIGINT NOT NULL,
  gross_amount    BIGINT,                   -- 額面 (shift_calc時に使用)
  recurrence      TEXT NOT NULL,            -- 'monthly', 'weekly', 'one_time'
  day_of_month    INT,                      -- monthly用 (1-31); 0 = 末日
  payday_adjustment TEXT DEFAULT 'prev_business_day',
    -- DT-120: 給料日が土日祝の場合の調整方法
    -- 'prev_business_day': 直前の営業日に前倒し (日本のデファクト)
    -- 'next_business_day': 翌営業日に後倒し
    -- 'exact': 調整なし (ATMやネット振込など日付通り)
  weekday         INT,                      -- weekly用 (0-6)
  next_occurs_at  DATE,
  source          TEXT DEFAULT 'manual',    -- 'manual','email_detect','pattern_estimate','shift_calc','payroll_statement'
  confidence      REAL DEFAULT 0.5,         -- 0.0-1.0
  connection_id   UUID,  -- FK added after income_connections is created (see below)
  -- DT-159: Which bank account does this income land in?
  -- Used for per-account income exclusion (balance_observed_at check is account-scoped).
  -- NULL = unknown → income kept in projection (conservative) but stale_sources += 'income_account_unknown'
  bank_account_id UUID REFERENCES financial_accounts(id) ON DELETE SET NULL,
  -- SEC-R4-002: Ownership check via trigger (see trg_check_income_bank_account_ownership below)
  target_month    TEXT,                     -- '2026-03' (shift_calc は月別レコード)
  breakdown       JSONB DEFAULT '{}',       -- { worked_hours, hourly_rate, deductions, ... }
  metadata        JSONB DEFAULT '{}',
  data_as_of      TIMESTAMPTZ,         -- DT-033: freee/playwright last successful sync time
  is_estimated    BOOLEAN DEFAULT false,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- SEC-R4-002: bank_account_id must reference the SAME user's bank account.
-- Without this trigger, user A could route income to user B's bank account (IDOR).
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
-- 収入ソース連携 (freee HR, ジョブカン等)
-- ============================================================
CREATE TABLE income_connections (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID REFERENCES users(id) NOT NULL,
  provider          TEXT NOT NULL,         -- 'freee', 'jobcan', 'king_of_time', 'manual'
  company_id        INT,                   -- freee company_id
  employee_id       INT,                   -- freee employee_id
  employer_name     TEXT,                  -- 'ファミリーマート 新宿店'
  vault_secret_id   UUID,                  -- OAuth tokens or session cookies (Vault)
  transportation_per_day INT DEFAULT 0,    -- 通勤手当 (日額, 出社日のみ支給)
  payday            INT DEFAULT 25,
  pay_calc_method   TEXT DEFAULT 'hourly', -- 'hourly', 'monthly_fixed', 'daily'
  session_status    TEXT DEFAULT 'active', -- 'active', 'expired', 'error'
  session_expires_at TIMESTAMPTZ,
  last_synced_at    TIMESTAMPTZ,
  last_error        TEXT,
  is_active         BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- FK: projected_incomes.connection_id → income_connections.id
-- (income_connections は projected_incomes の後に定義されるため ALTER TABLE で追加)
ALTER TABLE projected_incomes
  ADD CONSTRAINT fk_projected_incomes_connection
  FOREIGN KEY (connection_id) REFERENCES income_connections(id);

-- XDOC-R4-003 / OPS-R4-001: system_alerts.income_connection_id FK was promised in comment
-- but never materialized. Without this, deleted income_connections leave dangling UUIDs
-- in system_alerts, breaking dedup logic in the Dead Man's Switch.
ALTER TABLE system_alerts
  ADD CONSTRAINT fk_system_alerts_income_connection
  FOREIGN KEY (income_connection_id) REFERENCES income_connections(id) ON DELETE SET NULL;

-- ============================================================
-- 時給期間履歴 (有効期間付きレート管理)
-- ============================================================
CREATE TABLE hourly_rate_periods (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id   UUID NOT NULL REFERENCES income_connections(id) ON DELETE CASCADE,
  hourly_rate     INT NOT NULL,              -- 時給 (円)
  overtime_multiplier REAL DEFAULT 1.25,     -- 時間外労働割増率
  night_multiplier    REAL DEFAULT 0.25,     -- 深夜労働加算率
  holiday_multiplier  REAL DEFAULT 1.35,     -- 法定休日割増率
  effective_from  DATE NOT NULL,             -- 適用開始日
  effective_to    DATE,                      -- 適用終了日 (NULL = 現在有効)
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
  shift_type        TEXT NOT NULL,         -- 'actual', 'scheduled', 'absent', 'paid_leave'
  source            TEXT NOT NULL,         -- 'freee_api', 'playwright_scrape', 'manual'
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
  name            TEXT NOT NULL,            -- '家賃', '電気代'
  amount          BIGINT NOT NULL,
  billing_cycle   TEXT DEFAULT 'monthly',   -- 'monthly', 'yearly'
  billing_day     INT,                      -- 毎月の引落日
  next_billing_at DATE,
  category_id     UUID REFERENCES categories(id) ON DELETE SET NULL, -- DT-058
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
  issuer            TEXT NOT NULL,          -- 'life', 'smbc' など
  subject_hint      TEXT NOT NULL,          -- 例: 'ご請求金額のご案内'
  sender_hint       TEXT,
  expected_day_from INT NOT NULL,           -- 例: 10
  expected_day_to   INT NOT NULL,           -- 例: 16
  is_active         BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE expected_email_jobs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  rule_id         UUID REFERENCES expected_email_rules(id) NOT NULL,
  target_month    TEXT NOT NULL,          -- '2026-02'
  status          TEXT DEFAULT 'pending', -- 'pending'|'found'|'missed'|'crawled'
  attempt_count   INT DEFAULT 0,
  next_run_at     TIMESTAMPTZ,
  last_error      TEXT,
  last_checked_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, rule_id, target_month)
);

-- ============================================================
-- 実運用向けインデックス
-- ============================================================
CREATE INDEX idx_transactions_user_transacted_at ON transactions(user_id, transacted_at DESC);
CREATE INDEX idx_transactions_user_status ON transactions(user_id, status);
CREATE INDEX idx_transactions_user_source ON transactions(user_id, source);
CREATE INDEX idx_transactions_user_amount_time ON transactions(user_id, amount, transacted_at DESC);
-- DT-128: GPS proximity query (suggestion engine §4a bounding-box filter)
CREATE INDEX idx_transactions_location ON transactions(user_id, location_lat, location_lng)
  WHERE location_lat IS NOT NULL;
CREATE INDEX idx_parsed_emails_user_received_at ON parsed_emails(user_id, received_at DESC);
CREATE INDEX idx_email_connections_user_provider ON email_connections(user_id, provider);
CREATE INDEX idx_projected_incomes_user_active ON projected_incomes(user_id, is_active);
CREATE INDEX idx_fixed_cost_items_user_active ON fixed_cost_items(user_id, is_active);
CREATE INDEX idx_expected_email_rules_active ON expected_email_rules(provider, issuer, is_active);
CREATE INDEX idx_expected_email_jobs_user_month ON expected_email_jobs(user_id, target_month, status);
CREATE INDEX idx_expected_email_jobs_next_run ON expected_email_jobs(status, next_run_at);
CREATE INDEX idx_income_connections_user_active ON income_connections(user_id, is_active);
-- DT-045e: Missing indexes for FK lookups and correlation queries
CREATE INDEX idx_parsed_emails_transaction ON parsed_emails(transaction_id) WHERE transaction_id IS NOT NULL;
CREATE INDEX idx_transactions_correlation ON transactions(correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_pending_ec_user_amount ON pending_ec_correlations(user_id, amount, matched) WHERE matched = false;
CREATE INDEX idx_hourly_rate_periods_connection ON hourly_rate_periods(connection_id, effective_from);
CREATE INDEX idx_shift_records_user_date ON shift_records(user_id, date DESC);
CREATE INDEX idx_shift_records_connection_month ON shift_records(connection_id, date);

-- ============================================================
-- RLS (全テーブル共通パターン)
-- ============================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
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

-- 全テーブルに適用するポリシー (user_idベース)
-- authenticated ユーザーは自分のデータのみ CRUD 可能
-- service_role は RLS をバイパスする (Edge Function内部処理用)

-- 標準パターン: user_id = auth.uid()
CREATE POLICY "users_own_data" ON users
  FOR ALL USING (id = auth.uid());

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

-- hourly_rate_periods: connection_id経由でuser_idを辿る
CREATE POLICY "users_own_data" ON hourly_rate_periods
  FOR ALL USING (
    connection_id IN (
      SELECT id FROM income_connections WHERE user_id = auth.uid()
    )
  );

-- categories: システム定義 (user_id IS NULL) は全員読める、自分のカスタム定義はCRUD可
CREATE POLICY "categories_read" ON categories
  FOR SELECT USING (user_id IS NULL OR user_id = auth.uid());
CREATE POLICY "categories_write" ON categories
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "categories_update" ON categories
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "categories_delete" ON categories
  FOR DELETE USING (user_id = auth.uid());

-- expected_email_rules: システムマスタ (管理者のみ書き込み、全員読み取り可)
CREATE POLICY "rules_read" ON expected_email_rules
  FOR SELECT USING (true);
-- INSERT/UPDATE/DELETE は service_role 経由のみ (RLS bypass)

-- ============================================================
-- APIキー (Public API / MCP認証用) — DT-021
-- ============================================================
CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
  key_hash      TEXT NOT NULL,           -- SHA-256(raw_key)。平文は保存しない
  name          TEXT NOT NULL,           -- 'Claude Code', 'My Script' 等
  scopes        TEXT[] NOT NULL,         -- 'read', 'write' の組み合わせ。空禁止
  last_used_at  TIMESTAMPTZ,
  last_used_ip  INET,                   -- フォレンジクス用
  expires_at    TIMESTAMPTZ,            -- NULL = 無期限
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT chk_scopes_not_empty CHECK (array_length(scopes, 1) > 0)
);

ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON api_keys
  FOR ALL USING (user_id = auth.uid());
CREATE INDEX idx_api_keys_hash ON api_keys(key_hash) WHERE is_active = true;

-- ============================================================
-- レート制限カウンタ (Public API) — 07-public-api.md §2f
-- ============================================================
CREATE TABLE rate_limit_counters (
  bucket_key  TEXT PRIMARY KEY,        -- '{api_key_id}:{minute_bucket}'
  count       INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_rate_limit_ttl ON rate_limit_counters(created_at);
-- SEC-R3-007: RLS enabled, no user-facing policies.
-- Only service_role (Edge Functions) accesses this table.
-- Without RLS, anon/authenticated roles could read/write rate limit counters.
ALTER TABLE rate_limit_counters ENABLE ROW LEVEL SECURITY;

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

-- EXECUTE grant: service_role only (Edge Functions)
-- REVOKE EXECUTE ON FUNCTION increment_rate_limit FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION increment_rate_limit TO service_role;

-- ============================================================
-- API冪等性キーキャッシュ — 07-public-api.md §4a
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
CREATE INDEX idx_idempotency_ttl ON api_idempotency_keys(created_at);
-- SEC-R3-008: RLS enabled, no user-facing policies.
-- Only service_role (Edge Functions) accesses this table.
ALTER TABLE api_idempotency_keys ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- パース失敗ログ (デバッグ・監査用)
-- ============================================================
CREATE TABLE parse_failures (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  provider_message_id TEXT,
  email_subject   TEXT,
  sender          TEXT,
  failure_reason  TEXT NOT NULL,  -- 'no_parser_matched', 'parse_error', 'decode_error'
  raw_hash        TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);
-- RLS: service_role からのみ INSERT、ユーザーは自分のデータを READ 可
ALTER TABLE parse_failures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON parse_failures
  FOR SELECT USING (user_id = auth.uid());
CREATE INDEX idx_parse_failures_user ON parse_failures(user_id, created_at DESC);

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
ALTER TABLE pending_ec_correlations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON pending_ec_correlations
  FOR ALL USING (user_id = auth.uid());
-- TTL: pg_cronで30日超を日次削除 (DT-036 ✅ 定義済み)

-- ============================================================
-- DT-028: システムアラート / Dead Man's Switch
-- ============================================================
CREATE TABLE system_alerts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(id),  -- NULL = system-wide alert
  alert_type    TEXT NOT NULL,  -- 'stale_pending_webhook', 'broken_connection', 'stale_sync'
  message       TEXT NOT NULL,
  email_connection_id  UUID REFERENCES email_connections(id) ON DELETE SET NULL,
  income_connection_id UUID,  -- FK: see ALTER TABLE below income_connections (XDOC-R4-003)
  -- Dedup: broken_connection alerts use email_connection_id or income_connection_id (polymorphic)
  resolved_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now()
);
-- RLS enabled: system_alerts contains per-user alerts (broken_connection etc.)
-- service_role writes; users can only read their own alerts.
-- Public API exposes user-scoped alerts, so RLS is required.
ALTER TABLE system_alerts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_read_own_alerts" ON system_alerts
  FOR SELECT USING (user_id = auth.uid());
-- SEC-R3-003: Removed "OR user_id IS NULL". System-wide alerts (user_id IS NULL)
-- should NOT be exposed to end users — they may contain ops-internal details
-- (e.g., "pg_cron job X failed", infra connection strings). System-wide alerts
-- are for ops dashboards (service_role queries) only.
-- INSERT/UPDATE/DELETE: service_role only (no user-facing policy).

CREATE INDEX idx_system_alerts_unresolved ON system_alerts(alert_type, created_at)
  WHERE resolved_at IS NULL;

-- ============================================================
-- historyId 条件付き更新 (単調増加保証)
-- ============================================================
-- 並行webhookで古いhistoryIdが後から来ても巻き戻らない
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

-- EXECUTE grant: service_role only
-- REVOKE EXECUTE ON FUNCTION update_history_id_monotonic FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION update_history_id_monotonic TO service_role;

-- ============================================================
-- DT-029: Atomic parsed_email + transaction write
-- ============================================================
-- parsed_emails と transactions を単一トランザクションで作成。
-- 片方だけ成功する部分書き込みを防止する。
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
  -- transaction fields
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
  -- Create transaction first
  INSERT INTO transactions (user_id, account_id, amount, transacted_at,
                           merchant_name, category_id, source)
  VALUES (p_user_id, p_account_id, p_amount, p_transacted_at,
          p_merchant_name, p_category_id, p_source)
  RETURNING id INTO v_tx_id;

  -- Create parsed_email linked to the transaction
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

-- EXECUTE grant: service_role only (Edge Functions)
-- REVOKE EXECUTE ON FUNCTION insert_parsed_email_with_transaction FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION insert_parsed_email_with_transaction TO service_role;

-- ============================================================
-- DT-056: Suggestion feedback tables
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
ALTER TABLE user_suggestion_stats ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON user_suggestion_stats
  FOR ALL USING (user_id = auth.uid());

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
ALTER TABLE suggestion_feedback ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON suggestion_feedback
  FOR ALL USING (user_id = auth.uid());
CREATE INDEX idx_suggestion_feedback_user ON suggestion_feedback(user_id, created_at DESC);

-- DT-056: Atomic suggestion stat update
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

-- REVOKE EXECUTE ON FUNCTION update_suggestion_stat FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION update_suggestion_stat TO service_role;
```

---

## 4. 初期スコープ: カード会社メールパーサー

### 対応カード (Phase 0) — 実メール検証済

| カード | 発行元 | 通知メール送信元 | メール件名パターン | 備考 |
|--------|--------|-----------------|-------------------|------|
| 三井住友NL (Visa) | SMBC | `statement@vpass.ne.jp` | `ご利用のお知らせ【三井住友カード】` | ISO-2022-JP |
| 三井住友Olive Flex Pay | SMBC | 同上 | 同上 | クレジットモード利用時 |
| ライフカード (学生) | Life | `lifeweb-entry@lifecard.co.jp` | `カードご利用のお知らせ` | ISO-2022-JP |
| JALカード navi | JCB | `mail@qa.jcb.co.jp` | `JCBカード／ショッピングご利用のお知らせ` | UTF-8, JCB共通送信元 |
| JCBカード W | JCB | `mail@qa.jcb.co.jp` | 同上 | 本文の「カード名称」で区別 |
| セゾンゴールドAMEX | Credit Saison | **メール通知なし** | — | アプリPush通知のみ。手動入力対応 |

> 詳細は [docs/deep-dive/01-email-parser.md](docs/deep-dive/01-email-parser.md) 参照

### 三井住友カード メール通知フォーマット (実メール確認済)

```
件名: ご利用のお知らせ【三井住友カード】
送信元: statement@vpass.ne.jp  ← ⚠️ 旧想定の mail@contact.vpass.ne.jp ではない

本文に含まれる情報 (ISO-2022-JPデコード後):
- ★利用日：YYYY/MM/DD HH:MM
- ★利用先：店舗名
- ★利用取引：買物 / タッチ決済 等
- ★利用金額：X,XXX円
- ご利用カード：三井住友カードVISA（NL）

注意:
- 継続的な利用 (公共料金等) は通知されない
- ETC / PiTaPa等の電子マネーは通知されない → ETC別対応の理由
- Oliveクレジットモードも同じフォーマット
```

### パーサー戦略 (2段構成)

```
メール受信
    │
    ▼
[Stage 1] ルールベースパーサー (正規表現)
    │  ← 既知のカード会社フォーマットに対応
    │  ← コスト: $0 / 遅延: <10ms
    │
    ├─ パース成功 → transaction作成 → Push通知
    │
    └─ パース失敗
         │
         ▼
    [Stage 2] LLMパーサー (Gemini 2.5 Flash-Lite)
         │  ← 未知フォーマットの解析
         │  ← コスト: ~$0.00005/回
         │
         └─ transaction作成 → Push通知
```

---

## 5. コアフロー

### 5a. メール検知 → 即時通知フロー

```
Gmail API (Push via Pub/Sub webhook)
    │
    ▼  ほぼリアルタイム (数秒)
┌──────────────────────────────────────┐
│ Edge Function: handle-email-webhook   │
│                                       │
│ 1. Gmail API で新着メール取得          │
│ 2. 送信元でカード会社フィルタ           │
│ 3. ルールベース or LLMでパース         │
│ 4. parsed_emails に記録               │
│ 5. transactions に仮登録 (pending)    │
│ 6. APNs Push通知送信                  │
│    「¥1,280 の決済を検知しました」      │
└──────────────────────────────────────┘
```

### 5b. ユーザー分類フロー (Push通知タップ後)

```
┌─────────────────────────────────────────┐
│ iOS App: QuickCategorizeView            │
│                                         │
│ ┌─────────────────────────────────┐     │
│ │ ¥1,280 の決済                    │     │
│ │ 2026/02/18 12:34               │     │
│ │ カード: 三井住友NL (*1234)       │     │
│ └─────────────────────────────────┘     │
│                                         │
│ サジェスト (GPS + 履歴 + 時間帯):       │
│ ┌──────────┐ ┌──────────┐              │
│ │🍱 食費    │ │☕ カフェ  │              │
│ │セブン新宿 │ │スタバ新宿│              │
│ └──────────┘ └──────────┘              │
│ ┌──────────┐ ┌──────────┐              │
│ │📝 手入力  │ │⏭ スキップ│              │
│ └──────────┘ └──────────┘              │
│                                         │
│ → 選択: status='confirmed'             │
│ → スキップ: status='pending'            │
│   → 後日カード明細反映時にLLMで自動分類  │
│                                         │
│ ┌─────────────────────────────────┐     │
│ │ メモ (任意):                     │     │
│ │ [友達の誕生日プレゼント       ]   │     │
│ └─────────────────────────────────┘     │
│                                         │
│ → メモ入力時: LLMでカテゴリ自動推定      │
│   「プレゼント」→ 交際費をサジェスト      │
│ → transactions.description に保存       │
│ → メモなしでもOK (強制しない)            │
└─────────────────────────────────────────┘
```

```text
メモ機能の設計方針:
- 主動線はあくまで自動検知 → サジェスト選択。メモは補助
- メモ欄は折りたたみ or 小さいテキストフィールド (目立たせない)
- メモが入力された場合、LLM (Gemini Flash-Lite) でカテゴリを再推定
  → サジェストの精度改善にも使える (学習データとして)
- 格納先: transactions.description (既存カラム、スキーマ変更不要)
- メモの内容は LLM 送信時に redactPII を適用
```

### 5b-2. レシートOCR → 内訳記録フロー

```
QuickCategorizeView 内の補助機能。
カード利用の「中身が何だったか」を記録したいときに使う。

┌─────────────────────────────────────────┐
│ 📷 レシート撮影                          │
│                                         │
│ [カメラ or フォトライブラリから選択]       │
│         │                               │
│         ▼                               │
│ OCR + LLM (Gemini Flash-Lite)           │
│ → 商品名・金額・数量を構造化抽出          │
│                                         │
│ ┌─────────────────────────────────┐     │
│ │ シャンプー           ¥698       │     │
│ │ お菓子               ¥324       │     │
│ │ 電池                 ¥548       │     │
│ │ タオル              ¥1,710      │     │
│ │──────────────────────────────── │     │
│ │ レシート合計         ¥3,280      │     │
│ │ カード利用額         ¥3,280  ✅  │     │
│ └─────────────────────────────────┘     │
│                                         │
│ 金額一致: ✅ → 内訳を保存               │
│ 金額不一致: ⚠ 差額 ¥XX を表示           │
│   → 修正 or そのまま保存 を選択          │
│                                         │
│ 各行にカテゴリ自動割当:                   │
│   シャンプー → 日用品                    │
│   お菓子 → 食費                         │
│   電池 → 日用品                         │
│   タオル → 日用品                       │
└─────────────────────────────────────────┘

格納先: transaction_line_items テーブル
金額検証: SUM(line_items.amount) vs transactions.amount
LLMコスト: ~$0.0001/レシート (画像入力 + 構造化出力)
レシート画像: パース後は保存しない (プライバシー保護)
```

### 5c. サブスク自動検知フロー

```
メール解析時に以下を検知:
  - 件名/本文に「月額」「自動更新」「サブスクリプション」
  - 同一送信元から毎月同額の決済
  - LLMが "subscription" と分類

検知時:
  1. subscriptions テーブルに仮登録
  2. Push通知: "Netflix (¥1,490/月) をサブスクとして登録しました"
  3. ユーザーが確認 or 修正

毎月の処理:
  - next_billing_at の3日前にリマインド通知
  - 引き落とし後に実際の金額と突合
```

### 5d. 引き落とし予測エンジン

```
┌─────────────────────────────────────────────────┐
│ ダッシュボード: 資金推移 (履歴30日 + 予測60日)         │
│                                                   │
│ +600k ┤                                           │
│ +400k ┤     ███ ███     ▒▒▒ ▒▒▒                   │
│ +200k ┤ ███ ████ ███ ▒▒▒ ▒▒▒▒ ▒▒▒▒                │
│    0 ─┼────────────────────────────────           │
│ -100k ┤                           ▒▒▒▒            │
│        実績(青)            予測(縞)                │
│                       ▲3/10 三井住友NL -¥45,230    │
│                       ▲3/27 ライフカード -¥12,800   │
│                                                   │
│ 0円割れ予測: 3/27 ライフカード引き落とし後 -¥7,200    │
│ カード別判定: セゾン OK / 三井住友 OK / ライフ 不足   │
└─────────────────────────────────────────────────┘
```

- 引き落とし日はカードごとに `financial_accounts.billing_day` で個別管理
- 同日イベントは安全側判定として「出金優先」で残高シミュレーション
- `running_balance < 0` に初めて落ちたイベントを「不足トリガー」として表示

---

## 6. セキュリティ設計

### 6a. 認証・認可

| レイヤー | 手段 |
|---------|------|
| 認証 | Supabase Auth (Apple Sign In + Email/Pass) |
| 行レベル制御 | PostgreSQL RLS — `user_id = auth.uid()` を全ユーザーデータテーブルに適用 |
| API保護 | Edge Functions + JWT検証 + Rate Limiting |
| 機密データ | Supabase Vault (pgsodium) でトークン暗号化 |

### 6b. データ分類と保護

```
┌─────────────────────────────────────────────────┐
│               保存するもの                        │
│                                                   │
│ [平文]                                            │
│ - 取引金額, 日時, カテゴリ                          │
│ - 店舗名, サブスク名                               │
│ - 月次サマリ                                      │
│                                                   │
│ [Vault暗号化]                                     │
│ - Gmail OAuth tokens                              │
│ - カード下4桁 (表示時に復号)                        │
│ - LLM送信用の一時マスクルール設定                    │
│                                                   │
│               保存しないもの                       │
│                                                   │
│ - メール本文の原文保存 (パース後即破棄、ハッシュのみ保持) │
│ - カード番号全桁                                   │
│ - 銀行口座番号全桁                                 │
│ - パスワード / PIN                                 │
└─────────────────────────────────────────────────┘
```

### 6c. API公開リスク管理

```
iOSアプリ        → Supabase Client SDK (anon key + RLS)
外部ツール/MCP   → Public API (APIキー → RLS付きクエリ)
                     │
                     ├── 一般クエリ: RLSで自動フィルタ (user_id = auth.uid())
                     │
                     └── 機密操作: Edge Function経由のみ
                          - OAuthトークンの読み書き
                          - メール取得・解析
                          - LLM API呼び出し
                          - APNs送信

原則:
- anon key はクライアントに露出するが、RLSにより自分のデータのみアクセス可
- service_role key は Edge Function 内のみ。クライアントには絶対に渡さない
- APIキー認証: `crd_live_` prefix + SHA-256ハッシュ照合 → user_id解決 → RLS付きクエリ
  - APIキーでもservice_roleを直接使わず、カスタムJWT経由でRLSを通す (テナント分離保証)
  - Tier別レート制限 (Free:30/min, Standard:60, Pro:120, Owner:600)
- 詳細: `docs/deep-dive/07-public-api.md`
```

---

## 7. 料金プラン

### 設計原則: 原価透明 × 誠実運営

```text
1. 核心体験 (予測 60日 / SAFE・WARNING / 自由残額) は全員に制限なく提供
2. 有料プランは原価を開示し「なぜこの値段か」を説明する
3. 広告は全Tierで入れない (金銭不安を扱うアプリのトーンに合わない)
4. 使ってないのに課金しない → 非アクティブ30日で自動ダウングレード
```

### Tier構成

| | Free (Tier 0) | Standard (Tier 1) | Pro (Tier 2) | Owner (Tier 3) |
|--|---|---|---|---|
| 月額 | ¥0 | **¥300** | ¥980 | - (自分用) |
| ポジション | ルールベースで試す | **ほぼ全員がここ** | パワーユーザー | 全機能解放 |
| 広告 | **あり (小)** | なし | なし | なし |
| **LLM機能** | **なし** | **○ (Flash-Lite)** | **○ (Sonnet 4.5)** | **全モデル** |
| 予測期間 | 60日 | 60日 | 90日 | 90日 |
| メール検知 (Gmail) | ○ (ルールベースのみ) | ○ (+ LLMフォールバック) | ○ | ○ |
| 自由残額 / SAFE・WARNING | ○ | ○ | ○ | ○ |
| カテゴリ自動分類 (LLM) | - | ○ | ○ | ○ |
| レシートOCR (LLM) | - | ○ | ○ | ○ |
| freee HR連携 | - | ○ | ○ | ○ |
| カスタムカテゴリ | - | ○ | ○ | ○ |
| iOSウィジェット (フル) | - | ○ | ○ | ○ |
| メール連携 (Outlook/Yahoo) | - | ○ | ○ | ○ |
| Playwright汎用スクレイプ | - | - | ○ | ○ |
| 複数バイト先対応 | - | 1件 | 3件 | 無制限 |
| 能動クロール (LLM) | - | - | ○ | ○ |
| ETC連携 | - | - | ○ | ○ |
| 非アクティブ自動解約 | - | ○ | ○ | - |

**デフォルト: Tier 3 (Owner)** — 自分専用ツールとして全機能解放

```text
Free / Standard の境界線: LLM機能の有無

Free (¥0 + 広告):
  - メール検知はルールベースパーサーのみ (既知フォーマットは100%抽出)
  - 未知フォーマットのメールはスキップ (LLMフォールバックなし)
  - カテゴリは手動選択 or サジェスト (GPS+履歴ベース、LLMなし)
  - レシートOCR 不可
  - 広告収入でサーバー維持費をカバー

Standard (¥300):
  - LLM (Gemini Flash-Lite) 解放
  - 未知メールもLLMでパース → カバレッジ向上
  - カテゴリ自動分類 (LLM)
  - レシートOCR (LLM)
  - 広告なし
  - 「¥300 = AI機能 + 広告除去 + サーバー維持費」

この境界線が機能する理由:
  1. LLMは実際にコストがかかる → 有料化の説明が誠実にできる
  2. Free でもルールベースで主要カード (三井住友/JCB/ライフ) の利用通知をほぼリアルタイムで検知
     → 核心体験は制限されない
  3. LLM が加わると「未知のメールも拾える」「分類が自動になる」「レシートが読める」
     → 体感の便利さが明確に上がる
```

### ¥300の原価内訳 (透明性のためユーザーに開示)

```text
¥300/月の使いみち:
  AI (LLM) 利用料:  ~¥2-5   (Gemini Flash-Lite, 1日30回の分類・解析)
  サーバー維持費:   ~¥20-30  (Supabase DB・API・リアルタイム通信)
  Apple手数料 (30%): ¥90     (App Store決済手数料)
  開発継続費:       ~¥175    (個人開発者がアプリを維持・改善する資金)
```

#### 図解: アプリ内 / App Store 説明用

```text
┌─────────────────────────────────────────────────┐
│            ¥300/月 の使いみち                     │
│                                                  │
│  ┌──────────────────────────────────────┐       │
│  │██████████████████████████████████░░░░│       │
│  └──────────────────────────────────────┘       │
│   ▲開発・改善 ¥175     ▲Apple税 ¥90  ▲運営 ¥35 │
│      (58%)              (30%)       (12%)       │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │ 🔧 開発・改善 (58%)                        │ │
│  │    1人の開発者がアプリを改善し続ける費用     │ │
│  │                                            │ │
│  │ 🍎 App Store 手数料 (30%)                  │ │
│  │    Appleへの決済手数料。これは削れません     │ │
│  │                                            │ │
│  │ 🤖 AI + サーバー (12%)                     │ │
│  │    メール解析AI・カテゴリ自動分類・           │ │
│  │    リアルタイム通信の維持費                  │ │
│  └────────────────────────────────────────────┘ │
│                                                  │
│  「サブスクで儲けたいわけじゃないです。           │
│    アプリを動かし続けるのにこれだけかかります」    │
└─────────────────────────────────────────────────┘
```

#### 図解: Free vs Standard の違い

```text
┌─────────────────────────────────────────────────┐
│         Free              Standard ¥300/月       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 📧 メール検知  │    │ 📧 メール検知      │       │
│  │ (対応3社のみ)  │    │ (全メール対応)      │       │
│  │ ルールベース   │    │ ルール + AI解析     │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 📊 予測 60日  │    │ 📊 予測 60日       │       │
│  │ 自由残額 │    │ 自由残額      │       │
│  │ SAFE/WARNING  │    │ SAFE/WARNING       │       │
│  │     ○ 同じ    │    │     ○ 同じ         │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 🏷 カテゴリ   │    │ 🏷 カテゴリ        │       │
│  │ 手動で選択    │    │ AIが自動分類 🤖     │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 🧾 レシート   │    │ 🧾 レシート        │       │
│  │    ×          │    │ AIで読み取り 🤖     │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 💼 バイト連携  │    │ 💼 バイト連携       │       │
│  │    ×          │    │ freee自動連携 ○     │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ┌──────────────┐    ┌──────────────────┐       │
│  │ 📢 広告あり   │    │ 📢 広告なし        │       │
│  │ (小さめ)      │    │                    │       │
│  └──────────────┘    └──────────────────┘       │
│                                                  │
│  ── 大事なこと ──────────────────────────────── │
│  │ 予測・アラート・「自由残額」は          │ │
│  │ Free でも Standard でも同じです。             │ │
│  │ Standard は AI の力で「もっと楽に」なります   │ │
│  └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

#### 図解: 非アクティブポリシー

```text
┌─────────────────────────────────────────────────┐
│       使ってないのにお金は取りません              │
│                                                  │
│  Standard / Pro:                                 │
│  ┌──┬──┬──┬──┬──┐                               │
│  │  │  │  │  │  │  ← 30日間アプリを開かない      │
│  └──┴──┴──┴──┴──┘                               │
│   14日  21日  28日  30日                          │
│   📱    📱    📱‼   🔄                            │
│  お知らせ 警告 最終  Freeに                        │
│                    自動移行                       │
│                                                  │
│  → データはずっと残ります                         │
│  → いつでもワンタップで戻れます                    │
│                                                  │
│  Free:                                           │
│  ┌──┬──┬──┬──┬──┐                               │
│  │  │  │  │  │  │  ← 30日間アプリを開かない      │
│  └──┴──┴──┴──┴──┘                               │
│   14日        28日  30日                          │
│   📱          📱‼   ⏸                            │
│  お知らせ    最終  監視を                          │
│                    一時停止                       │
│                                                  │
│  → 月に1回アプリを開くだけで監視は続きます         │
│  → 停止中のメールも再開時にまとめて取得します      │
└─────────────────────────────────────────────────┘
```

### 非アクティブポリシー

全Tierに適用。理由がTierごとに異なる。

```text
アクティブの定義 (いずれか1つを満たせばOK):
  - アプリを開いた
  - Push通知をタップした
  - ウィジェットが表示更新された

  ※ バックグラウンドのメール検知だけではアクティブ判定しない。
    ユーザーが実際にCredebiを見ている証拠が必要。
```

#### Standard / Pro: 非アクティブ自動ダウングレード

```text
理由: 使ってないのにお金を取り続けない

非アクティブ判定: 30日間アクティブ条件を1度も満たさなかった場合

段階的な通知:
  1. 14日目: Push通知
     「2週間ほどご利用がないようです。大丈夫ですか？」
     → アプリを開くだけでリセット

  2. 21日目: Push通知
     「3週間ご利用がありません。
      あと9日で自動的にFreeプランに戻します」

  3. 28日目: Push通知 (最終警告)
     「あと2日でFreeプランに移行します。
      アプリを1回開くだけで継続できます」
     → アプリ内にも解約予告バナー表示

  4. 30日目: 自動ダウングレード
     → Freeプランに移行、次回課金停止
     → Push通知「Freeプランに移行しました。再開はいつでもワンタップで」
     → データは全て保持 (削除しない)

  5. 再開時: アプリ内でワンタップで再課金
```

#### Free: 非アクティブ時のメール監視停止

```text
理由: Freeユーザーでも裏では以下のコストが常時発生している
  - Gmail watch (Pub/Sub) → webhook受信 → Edge Function実行
  - メールパース → DB書き込み
  - 日次バックフィル (History API)
  - Supabase Realtime 接続枠
  放置ユーザーが増えると広告収入ゼロのままコストだけ膨らむ

非アクティブ判定: 30日間アクティブ条件を1度も満たさなかった場合

段階的な通知:
  1. 14日目: Push通知
     「2週間ほどアプリが開かれていません。
      メールの監視を続けるにはサーバー費用がかかるため、
      このまま利用がない場合は監視を一時停止します」

  2. 28日目: Push通知 (最終警告)
     「あと2日でメール監視を一時停止します。
      月に1回アプリを開くだけで監視は続きます」

  3. 30日目: メール監視停止
     → Gmail watch() の更新を停止 (有効期限切れで自然停止)
     → pg_cron のバックフィル対象から除外
     → Push通知「メール監視を一時停止しました。
        アプリを開けばすぐに再開します」
     → データは全て保持

  4. 再開時: アプリを開く → Gmail watch() 再登録 → 監視再開
     → 停止中に届いたメールもバックフィルで遡って取得

ユーザー向け説明:
  「Credebi は無料でもメールを監視してカード利用を検知しています。
   この処理にはサーバー費用がかかるため、月に1回はアプリを開いてください。
   30日間ご利用がない場合、サーバー負荷を抑えるために監視を一時停止します。
   アプリを開くだけですぐ再開でき、停止中のメールも遡って取得します」
```

#### コスト試算 (非アクティブFreeユーザーの影響)

```text
アクティブFreeユーザー 1人あたりの月間コスト:
  Gmail webhook受信 + Edge Function: ~¥5-10
  DB書き込み + Realtime: ~¥3-5
  バックフィル (日次): ~¥2-3
  合計: ~¥10-18/人/月

広告収入 (アクティブの場合): ~¥30-80/人/月
  → アクティブなら黒字 or ほぼトントン

非アクティブ (広告表示なし): 収入 ¥0、コスト ~¥10-18/人/月
  → 純粋な赤字。1000人放置で月¥10,000-18,000の損失
  → 監視停止でコストをほぼゼロに削減

監視停止後のコスト: ~¥0.5/人/月 (データ保持のDB容量のみ)
```

```text
プライシングページに明記:
  「使ってないのにお金を取り続けることはしません (Standard/Pro)。
   無料プランでも、メール監視の維持にはコストがかかっています。
   月に1回アプリを開くだけで監視は続きます。
   30日間ご利用がない場合、サーバー負荷を抑えるために一時停止します。
   データはずっと残ります。いつでもすぐに再開できます」
```

### Free tier の広告ポリシー

```text
広告を入れる理由 (ユーザーに開示):
  「Freeプランは無料ですが、サーバーやメール検知の維持にコストがかかります。
   小さな広告を表示させてもらうことで、無料でも使い続けられるようにしています。
   広告が気になる方は Standard (¥300/月) で広告なしになります」

広告の配置ルール:
  ○ 許可: 取引一覧の下部、設定画面、月次レポート画面
  × 禁止: SAFE/WARNING ステータス表示の周辺
  × 禁止: 自由残額ヒーローカードの周辺
  × 禁止: Push通知の中
  × 禁止: QuickCategorizeView (分類操作中)
  × 禁止: 予測グラフ・危険ゾーン表示

原則: 核心体験 (予測・アラート・分類) には広告を入れない。
      ユーザーが「お金の判断」をしている瞬間を汚さない。
```

---

## 8. ETC対応 (将来: Tier 2+)

```
課題: ETC利用は決済が遅延する (数日〜数週間)
     → カード利用通知メールにも含まれない

解決策:
  1. ETC利用照会サービスAPI (https://www.etc-meisai.jp/)
     - スクレイピング or API経由で利用履歴取得
     - 走行区間, 料金, 日時が取得可能

  2. 別カテゴリ「ETC/高速道路」として管理
     - カードの利用とは独立して支出検知
     - 後日カード明細に反映された際に突合

  3. フロー:
     ETC利用 → (数日後) ETC明細に反映
                         │
                         ▼
              Edge Function: etc-sync (日次バッチ)
                         │
                         ▼
              transaction作成 (source='etc_api')
                         │
                         ▼
              Push通知 + カード利用との突合待ち
```

---

## 9. iOS App 構成 (SwiftUI)

```
Credebi/
├── CredebiApp.swift              -- エントリポイント
├── Models/
│   ├── Transaction.swift
│   ├── FinancialAccount.swift
│   ├── Subscription.swift
│   ├── Category.swift
│   └── MonthlySummary.swift
├── Views/
│   ├── Dashboard/
│   │   ├── DashboardView.swift       -- メイン画面: 残高 + 今月の支出
│   │   ├── BalanceCardView.swift     -- 残高カード
│   │   └── ProjectionView.swift      -- 引き落とし予測
│   ├── Transactions/
│   │   ├── TransactionListView.swift -- 取引一覧
│   │   ├── TransactionDetailView.swift
│   │   └── QuickCategorizeView.swift -- Push通知からの即時分類
│   ├── Subscriptions/
│   │   ├── SubscriptionListView.swift
│   │   └── SubscriptionDetailView.swift
│   ├── Accounts/
│   │   ├── AccountListView.swift     -- カード・銀行一覧
│   │   └── AccountDetailView.swift
│   ├── Analytics/
│   │   ├── MonthlyReportView.swift
│   │   └── CategoryBreakdownView.swift
│   └── Settings/
│       ├── SettingsView.swift
│       ├── EmailConnectionView.swift -- Gmail連携設定
│       └── NotificationSettingsView.swift
├── Services/
│   ├── SupabaseClient.swift          -- Supabase SDK初期化
│   ├── AuthService.swift
│   ├── TransactionService.swift
│   ├── NotificationService.swift     -- APNs + ローカル通知
│   ├── LocationService.swift         -- CoreLocation
│   └── SuggestionEngine.swift        -- GPS + 履歴ベースのサジェスト
├── Utilities/
│   ├── Extensions/
│   └── Constants.swift
└── Resources/
    └── Assets.xcassets
```

---

## 10. 開発フェーズ

### Phase 0: Foundation
- [ ] Supabase プロジェクト作成 + DB migration
- [ ] iOS プロジェクトセットアップ (SwiftUI, iOS 26+)
- [ ] Supabase Auth (Apple Sign In)
- [ ] 基本モデル + CRUD

### Phase 1: Core Transaction Flow
- [ ] 手動取引入力UI
- [ ] カード・銀行アカウント登録UI
- [ ] カード登録時の日程自動取得 (請求メール優先 / UI確認なしで即反映 / 未取得時のみ手入力)
- [ ] ダッシュボード (残高表示 + 今月支出)
- [ ] カテゴリ管理

### Phase 2: Email Detection
- [ ] Gmail OAuth連携フロー
- [ ] Gmail Push (Pub/Sub) → Edge Function webhook
- [ ] 三井住友カード メールパーサー (ルールベース)
- [ ] ライフカード利用通知 + 請求案内 / JCB(JAL含む) / スターバックス通知 パーサー
- [ ] LLMフォールバックパーサー (Gemini Flash-Lite)
- [ ] parsed_emails → transactions 自動生成

### Phase 2.5: Income Projection (シフト → 給与見込み)
- [ ] income_connections + hourly_rate_periods + shift_records テーブル作成
- [ ] projected_incomes カラム拡張
- [ ] freee OAuth フロー + oauth-freee-callback Edge Function
  - ⚠ /users/me から company_id を取得し income_connections に保存必須 (E3で判明)
- [ ] sync-income-freee Edge Function (日次同期、日次レコードベース)
- [x] ~~basic_pay_rule self_only 権限検証~~ → DT-022 ✅ アクセス不可確認済み、時給は手入力
- [ ] 給与見込み算出ロジック (3層: 勤務給/手当/控除) + 予測エンジン統合
- [ ] iOS: 収入ソース設定画面 + 時給期間入力 (effective_from/to)

### Phase 3: Real-time UX
- [ ] APNs Push通知設定
- [ ] QuickCategorizeView (通知タップ→即時分類)
- [ ] CoreLocation連携 + 逆ジオコーディング
- [ ] サジェストエンジン (GPS + 履歴 + 時間帯)

### Phase 4: Subscriptions & Projections
- [ ] サブスク自動検知ロジック
- [ ] サブスク管理UI
- [ ] 引き落とし予測エンジン
- [ ] 残高アラート通知
- [ ] Playwright + LLM 汎用勤怠スクレイプ基盤
- [ ] ジョブカン対応 (最初の Playwright ターゲット)
- [ ] 給与明細突合ロジック (payroll_statements)
- [ ] iOS: 収入内訳表示 (予測ビュー内)

### Phase 5: Polish & Monetization
- [ ] 月次レポート / カテゴリ別分析
- [ ] 広告統合 (Free tier)
- [ ] In-App Purchase (Tier 1/2/3)
- [ ] Tier 2+ 期待メール未着時の能動クロール
- [ ] ETC連携 (Tier 2+)

---

## 11. Supabase Edge Functions 一覧

| Function | トリガー | 機能 |
|----------|---------|------|
| `handle-email-webhook` | Gmail Pub/Sub webhook | メール受信→パース→transaction作成→Push |
| `renew-gmail-watch` | pg_cron (日次) | Gmail watch() の期限更新 |
| `classify-transaction` | transaction INSERT/UPDATE | LLMでカテゴリ分類 |
| `detect-subscription` | transaction INSERT | サブスクパターン検知 |
| `update-projection` | transaction INSERT/UPDATE | 月次サマリ・予測更新 |
| `send-push` | 内部呼び出し | APNs経由でPush通知送信 |
| `correlate-transactions` | transaction INSERT | マーチャント/EC通知とカード通知の突合 |
| `parse-ec-email` | メール受信 (Tier 2+) | EC注文メールをLLMで解析→商品名抽出 |
| `proactive-inbox-crawl` | pg_cron (Tier 2+) | 期待メール未着時に受信箱をLLM探索 |
| `sync-statements` | pg_cron (Tier依存) | カード明細APIの取得・突合 |
| `sync-etc` | pg_cron (日次) | ETC利用照会からの取得 |
| `sync-income-freee` | pg_cron (日次) | freee HR API → shift_records → projected_incomes |
| `sync-income-playwright` | pg_cron (日次) | Playwright scrape → shift_records → projected_incomes |
| `oauth-freee-callback` | HTTP (OAuth redirect) | freee OAuth code → token exchange → Vault保存 |
| `api` | HTTP (APIキー/JWT) | Public API ルーター (全エンドポイント統合) |
| `issue-api-key` | HTTP (JWT only) | APIキー発行 (iOSアプリ内から) |
| `update-balance-ocr` | HTTP (JWT, multipart) | スクショOCR→銀行残高更新 (EXIF日時判定) |
| `nudge-balance-update` | pg_cron (日次) | payday翌日に残高更新Push通知 |

### デプロイ前提条件チェックリスト (DT-124)

pg_cron ジョブが正しく動作するために、以下のDB設定が必要:

```sql
-- 1. pg_net 拡張の有効化 (Supabase Dashboard > Database > Extensions で有効化)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 2. pg_cron 拡張の有効化
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 3. DB parameters の設定 (Supabase Dashboard > Settings > Database または SQL)
ALTER DATABASE postgres SET app.supabase_url = 'https://<project-ref>.supabase.co';
ALTER DATABASE postgres SET app.service_role_key = '<service-role-key>';
-- ⚠️ service_role_key はDB parameterに平文保存されるため、
--    Supabase Vault 経由で読む方が望ましいが、pg_cron SQL内では
--    current_setting() しか使えないため、この方法が現実的。

-- 4. 起動検証クエリ (migration 適用後に実行)
DO $$
BEGIN
  -- pg_net が有効か
  PERFORM 1 FROM pg_extension WHERE extname = 'pg_net';
  IF NOT FOUND THEN RAISE EXCEPTION 'pg_net extension is not enabled'; END IF;

  -- pg_cron が有効か
  PERFORM 1 FROM pg_extension WHERE extname = 'pg_cron';
  IF NOT FOUND THEN RAISE EXCEPTION 'pg_cron extension is not enabled'; END IF;

  -- app.supabase_url が設定されているか
  IF current_setting('app.supabase_url', true) IS NULL THEN
    RAISE EXCEPTION 'app.supabase_url is not set';
  END IF;

  -- app.service_role_key が設定されているか
  IF current_setting('app.service_role_key', true) IS NULL THEN
    RAISE EXCEPTION 'app.service_role_key is not set';
  END IF;

  RAISE NOTICE 'All deployment prerequisites verified.';
END $$;
```

### pg_cron ジョブ定義 (DT-036)

```text
DT-117: バッチ Edge Function の設計方針

Supabase Edge Functions は 150秒 hard timeout。全ユーザーを1回の invocation で
逐次処理するとユーザー数に比例してタイムアウトする。

対策パターン (全バッチジョブ共通):
1. pg_cron → "scheduler" Edge Function を呼ぶ
2. scheduler は対象ユーザーの id リストを取得 (SELECT id FROM ... WHERE ...)
3. scheduler は各ユーザーに対して個別の Edge Function invocation を net.http_post で kick
   (fan-out: 1ユーザー = 1 invocation)
4. 各 invocation は 1ユーザー分だけ処理 → タイムアウトのリスクなし

適用対象:
- renew-gmail-watch: 全 email_connections を fan-out
- update-projection: 全 users を fan-out
- sync-income-freee: 全 income_connections (provider='freee') を fan-out
- sync-income-playwright: 全 income_connections (provider!='freee') を fan-out
- proactive-inbox-crawl: 全 expected_email_jobs を fan-out

注意: fan-out は Supabase Edge Functions の同時実行数制限 (Pro: 100) に注意。
chunk size 20-30 で Promise.allSettled() + 間隔を空けて実行。
```

```sql
-- TTL cleanup: processed_webhook_messages (7日超の完了行を削除)
SELECT cron.schedule(
  'cleanup-processed-webhook-messages',
  '0 3 * * *',  -- 毎日 03:00 UTC (12:00 JST)
  $$DELETE FROM processed_webhook_messages
    WHERE status = 'done' AND processed_at < now() - INTERVAL '7 days'$$
);

-- TTL cleanup: pending_ec_correlations (30日超の未突合行を削除)
SELECT cron.schedule(
  'cleanup-pending-ec-correlations',
  '0 3 * * *',
  $$DELETE FROM pending_ec_correlations
    WHERE created_at < now() - INTERVAL '30 days'$$
);

-- Stale pending row alert: pending状態が24時間以上のメッセージを検知
-- → DT-034 と連携。lock_until でreclaim可能になるまで、ここで監視
-- Dedup: only insert alerts for message_ids not already in unresolved alerts.
SELECT cron.schedule(
  'alert-stale-pending-messages',
  '0 */6 * * *',  -- 6時間ごと
  $$INSERT INTO system_alerts (alert_type, message, created_at)
    SELECT 'stale_pending_webhook',
           format('message_id=%s pending since %s', message_id, processed_at),
           now()
    FROM processed_webhook_messages pwm
    WHERE pwm.status = 'pending'
      AND pwm.processed_at < now() - INTERVAL '24 hours'
      AND NOT EXISTS (
        SELECT 1 FROM system_alerts sa
        WHERE sa.alert_type = 'stale_pending_webhook'
          AND sa.resolved_at IS NULL
          AND sa.message LIKE format('message_id=%s%%', pwm.message_id)
      )$$
);

-- Gmail watch renewal (日次)
SELECT cron.schedule(
  'renew-gmail-watches',
  '0 2 * * *',  -- 毎日 02:00 UTC (11:00 JST)
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/renew-gmail-watch',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key')),
    body := '{}'::jsonb
  )$$
);

-- Monthly summaries update (日次)
SELECT cron.schedule(
  'update-monthly-summaries',
  '30 3 * * *',  -- 毎日 03:30 UTC (12:30 JST)
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/update-projection',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key')),
    body := '{}'::jsonb
  )$$
);

-- DT-114: Advance next_occurs_at for recurring projected_incomes
-- IDEMPOTENT + CALENDAR-SAFE: Uses generate_series to find the first future date.
-- This avoids the CEIL(epoch/30days) bug that causes permanent end-of-month drift
-- (e.g., Jan 31 → Feb 28 → Mar 28 forever) and month-skip on 31-day months.
-- TIMEZONE: Uses JST (Asia/Tokyo) for date boundary.
SELECT cron.schedule(
  'advance-projected-income-dates',
  '0 4 * * *',  -- 毎日 04:00 UTC (13:00 JST)
  $$
  -- Monthly: advance to the first future occurrence using calendar-month arithmetic
  UPDATE projected_incomes pi
  SET next_occurs_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT pi2.id, (
      SELECT d::date FROM generate_series(
        pi2.next_occurs_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 months', INTERVAL '1 month'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM projected_incomes pi2
    WHERE pi2.is_active = true
      AND pi2.recurrence = 'monthly'
      AND pi2.next_occurs_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE pi.id = adv.id AND adv.new_date IS NOT NULL;

  -- Weekly: 7-day arithmetic is exact, no drift risk. Keep simple CEIL.
  UPDATE projected_incomes
  SET next_occurs_at = next_occurs_at
        + (INTERVAL '7 days' * CEIL(
            ((NOW() AT TIME ZONE 'Asia/Tokyo')::date - next_occurs_at)::numeric / 7
          )),
      updated_at = now()
  WHERE is_active = true
    AND recurrence = 'weekly'
    AND next_occurs_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date;
  $$
);

-- Advance subscriptions.next_billing_at for active subscriptions.
-- CALENDAR-SAFE: Uses generate_series (same pattern as projected_incomes).
-- Also handles installment termination (DT-110 §6b).
SELECT cron.schedule(
  'advance-subscription-billing-dates',
  '10 4 * * *',  -- 毎日 04:10 UTC (13:10 JST), after income advancement
  $$
  -- Step 1: Monthly subscriptions (calendar-safe, no 30-day drift)
  UPDATE subscriptions s
  SET next_billing_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT s2.id, (
      SELECT d::date FROM generate_series(
        s2.next_billing_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 months', INTERVAL '1 month'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM subscriptions s2
    WHERE s2.is_active = true
      AND s2.billing_cycle = 'monthly'
      AND s2.next_billing_at IS NOT NULL
      AND s2.next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE s.id = adv.id AND adv.new_date IS NOT NULL;

  -- Step 1b: Weekly subscriptions (7-day arithmetic is exact)
  UPDATE subscriptions
  SET next_billing_at = next_billing_at
        + (INTERVAL '7 days' * CEIL(
            ((NOW() AT TIME ZONE 'Asia/Tokyo')::date - next_billing_at)::numeric / 7
          )),
      updated_at = now()
  WHERE is_active = true
    AND billing_cycle = 'weekly'
    AND next_billing_at IS NOT NULL
    AND next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date;

  -- Step 2: Yearly subscriptions (calendar-safe)
  UPDATE subscriptions s
  SET next_billing_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT s2.id, (
      SELECT d::date FROM generate_series(
        s2.next_billing_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 years', INTERVAL '1 year'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM subscriptions s2
    WHERE s2.is_active = true
      AND s2.billing_cycle = 'yearly'
      AND s2.next_billing_at IS NOT NULL
      AND s2.next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE s.id = adv.id AND adv.new_date IS NOT NULL;

  -- Step 3: Deactivate completed installments (DT-110 §6b)
  UPDATE subscriptions
  SET is_active = false,
      updated_at = now()
  WHERE is_active = true
    AND subscription_type = 'installment'
    AND (
      (remaining_count IS NOT NULL AND remaining_count <= 0)
      OR (expected_end_at IS NOT NULL AND next_billing_at > expected_end_at)
    );
  $$
);

-- DT-107: Bank balance update nudge (payday翌日にPush通知)
-- 毎日実行。payday翌日 (JST) かつ balance_updated_at が payday より前のユーザーに通知。
SELECT cron.schedule(
  'nudge-balance-update',
  '0 0 * * *',  -- 毎日 00:00 UTC (09:00 JST)
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/nudge-balance-update',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key')),
    body := '{}'::jsonb
  )$$
);

-- nudge-balance-update Edge Function の概要:
-- 1. projected_incomes から各ユーザーの payday (day_of_month) を取得
-- 2. 昨日が payday だったユーザーを抽出 (JST)
-- 3. そのユーザーの financial_accounts (type='bank') で
--    balance_updated_at IS NULL OR balance_updated_at < 昨日 のものを検索
-- 4. 該当ユーザーに Push通知:
--    title: '銀行残高を更新してください'
--    body: '給料日を過ぎました。最新の残高を入力すると予測の精度が上がります'
--    deepLink: 'credebi://accounts/update-balance'
-- 5. payday 未設定のユーザーには30日ごとに nudge (balance_updated_at + 30d < now())

-- DT-028: Dead Man's Switch — 壊れた接続の検知+ユーザー通知
-- Covers BOTH email_connections AND income_connections.
-- last_synced_at が48時間以上前 or watch_expiry を過ぎた接続を検知 (SEC-R3-010)
SELECT cron.schedule(
  'detect-broken-connections',
  '0 */12 * * *',  -- 12時間ごと
  $$
  -- Part 1: Email connections (stale sync OR expired watch)
  WITH broken_email AS (
    UPDATE email_connections
    SET is_active = false,
        last_error = COALESCE(last_error, 'stale_sync_48h')
    WHERE is_active = true
      AND (
        last_synced_at < now() - INTERVAL '48 hours'
        OR watch_expiry < now()  -- SEC-R3-010: expired watch = no future webhooks
      )
    RETURNING id, user_id, last_synced_at
  )
  INSERT INTO system_alerts (user_id, alert_type, message, email_connection_id)
  SELECT user_id, 'broken_connection',
         format('email_connection %s inactive: last_synced_at=%s', id, last_synced_at),
         id
  FROM broken_email
  WHERE id NOT IN (
    SELECT email_connection_id FROM system_alerts
    WHERE alert_type = 'broken_connection'
      AND resolved_at IS NULL
      AND email_connection_id IS NOT NULL
  );

  -- Part 2: Income connections (stale sync)
  WITH broken_income AS (
    UPDATE income_connections
    SET is_active = false,
        last_error = COALESCE(last_error, 'stale_sync_48h')
    WHERE is_active = true
      AND last_synced_at < now() - INTERVAL '48 hours'
    RETURNING id, user_id, last_synced_at
  )
  INSERT INTO system_alerts (user_id, alert_type, message, income_connection_id)
  SELECT user_id, 'broken_connection',
         format('income_connection %s inactive: last_synced_at=%s', id, last_synced_at),
         id
  FROM broken_income
  WHERE id NOT IN (
    SELECT income_connection_id FROM system_alerts
    WHERE alert_type = 'broken_connection'
      AND resolved_at IS NULL
      AND income_connection_id IS NOT NULL
  );

  -- TODO: Trigger Push notification to affected users via send-push Edge Function
  $$
);

-- ============================================================
-- TTL Cleanup: api_idempotency_keys (24時間超を日次削除)
-- ============================================================
SELECT cron.schedule(
  'cleanup-api-idempotency-keys',
  '0 4 * * *',  -- 毎日 04:00 UTC
  $$DELETE FROM api_idempotency_keys WHERE created_at < now() - INTERVAL '24 hours'$$
);

-- ============================================================
-- TTL Cleanup: rate_limit_counters (10分超を定期削除)
-- ============================================================
SELECT cron.schedule(
  'cleanup-rate-limit-counters',
  '*/10 * * * *',  -- 10分ごと
  $$DELETE FROM rate_limit_counters WHERE created_at < now() - INTERVAL '10 minutes'$$
);
```

---

## Sources

- [残り設計タスク一覧](docs/remaining-design-tasks.md)
- [三井住友カード 利用通知サービス](https://www.smbc-card.com/mem/service/sec/selfcontrol/usage_notice.jsp)
- [三井住友カード 通知サンプル](https://www.smbc-card.com/mem/service/sec/selfcontrol/pop/usage_notice_sample.jsp)
- [Gemini API Pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [LLM Pricing Comparison](https://intuitionlabs.ai/articles/llm-api-pricing-comparison-2025)
- [AI API Pricing Comparison 2026](https://intuitionlabs.ai/articles/ai-api-pricing-comparison-grok-gemini-openai-claude)
- [freee HR API Reference](https://developer.freee.co.jp/reference/hr)
- [freee HR API Detailed Reference](https://developer.freee.co.jp/reference/hr/reference)
