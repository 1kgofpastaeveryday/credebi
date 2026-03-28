# 07. Public API & MCP Server

> アプリ向けAPIを外部ツール（MCP含む）にも開放する設計。
> iOSアプリもMCPサーバーも同じAPIを叩く。

---

## 1. 設計原則

1. **ユーザーインテント単位** — テーブルCRUDではなく、ユーザーがやりたいことベースでエンドポイントを切る
2. **アプリと同一契約** — iOSアプリが叩くAPIとMCPツールは同じEdge Function。MCPは薄いラッパー
3. **RLSで自然にスコープ** — APIキー → user_id マッピング後、テナント分離を保証
4. **Design Principle遵守** — 全レスポンスに `data_as_of` / `is_stale` を含む。staleデータはstaleと表示
5. **fail-closed** — 不明なデータ状態は「stale」として扱う。データなし = 安全ではなく「判定不能」

---

## 2. 認証: APIキー

### 2a. スキーマ

```sql
CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
  key_hash      TEXT NOT NULL,           -- SHA-256(raw_key)。平文は保存しない
  name          TEXT NOT NULL,           -- 'Claude Code', 'My Script' 等
  scopes        TEXT[] NOT NULL,         -- 必須。'read', 'write' の組み合わせ。空配列禁止
  last_used_at  TIMESTAMPTZ,
  last_used_ip  INET,                   -- フォレンジクス用
  expires_at    TIMESTAMPTZ,            -- NULL = 無期限
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now(),
  -- 空スコープを禁止
  CONSTRAINT chk_scopes_not_empty CHECK (array_length(scopes, 1) > 0)
);

ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_data" ON api_keys
  FOR ALL USING (user_id = auth.uid());

CREATE INDEX idx_api_keys_hash ON api_keys(key_hash) WHERE is_active = true;
```

### 2b. スコープモデル

| スコープ | 許可される操作 |
|---------|-------------|
| `read` | 全 GET エンドポイント |
| `write` | POST, PATCH, DELETE エンドポイント (read を含む) |

- キー発行時にスコープ指定必須。デフォルトは `['read']`（最小権限）
- MCP設定ファイル（`~/.claude/mcp.json`）に平文保存されることを前提に、`read` only がセーフデフォルト
- `write` スコープのキーは発行時に明示的なユーザー確認を要求

### 2c. キー形式

```
crd_live_<base62_32chars>
```

- Prefix `crd_live_` で誤送信・ログ検出を容易にする
- 生成時に1度だけ平文を返す。以後はhashのみDB保持
- SHA-256ハッシュで照合（keyspaceは~190bit。ハッシュの目的はpre-image resistance、timing-safetyではない）

### 2d. 認証ミドルウェア

```typescript
// supabase/functions/_shared/api-key-auth.ts

import { createClient } from "@supabase/supabase-js";

interface AuthResult {
  user_id: string;
  tier: number;
  scopes: string[];
  auth_method: "api_key" | "jwt";  // audit trail用
  api_key_id?: string;             // どのキー経由か記録
}

export async function authenticateApiKey(
  req: Request,
): Promise<AuthResult | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer crd_live_")) return null;

  const rawKey = authHeader.slice(7); // "Bearer " を除去
  const keyHash = await sha256(rawKey);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: apiKey } = await supabase
    .from("api_keys")
    .select("id, user_id, scopes, is_active, expires_at")
    .eq("key_hash", keyHash)
    .eq("is_active", true)
    .single();

  if (!apiKey) return null;
  if (apiKey.expires_at && new Date(apiKey.expires_at) < new Date()) return null;

  // last_used_at を更新（失敗時はログ出力、swallowしない）
  const clientIp = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
  supabase
    .from("api_keys")
    .update({ last_used_at: "now()", last_used_ip: clientIp })
    .eq("id", apiKey.id)
    .then(({ error }) => {
      if (error) console.error("Failed to update api_key last_used_at:", error.message);
    });

  // ユーザーのtier取得 — fail-closed: usersが見つからなければ認証拒否
  const { data: user } = await supabase
    .from("users")
    .select("tier")
    .eq("id", apiKey.user_id)
    .single();

  if (!user) return null; // fail-closed: users行なし → 認証拒否

  return {
    user_id: apiKey.user_id,
    tier: user.tier,
    scopes: apiKey.scopes,
    auth_method: "api_key",
    api_key_id: apiKey.id,
  };
}

async function sha256(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
```

### 2e. 認証フロー統合

Edge Function は2つの認証パスをサポート:

```
リクエスト
  │
  ├── Authorization: Bearer <supabase_jwt>  → 既存のauth.uid()フロー (iOSアプリ)
  │                                            scopes: ['read', 'write'] (全権限)
  │
  └── Authorization: Bearer crd_live_xxx    → APIキー認証 → user_id + scopesをセット
```

統合ヘルパー:

```typescript
// supabase/functions/_shared/auth.ts

export async function resolveUser(req: Request): Promise<AuthResult> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) throw new ApiError("UNAUTHORIZED", "Missing Authorization header");

  // API key path
  if (authHeader.startsWith("Bearer crd_live_")) {
    const result = await authenticateApiKey(req);
    if (!result) throw new ApiError("UNAUTHORIZED", "Invalid or expired API key");
    return result;
  }

  // Supabase JWT path (existing)
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) throw new ApiError("UNAUTHORIZED", "Invalid JWT");

  const { data: profile } = await supabase
    .from("users")
    .select("tier")
    .eq("id", user.id)
    .single();

  // fail-closed: users行なし → 認証拒否
  if (!profile) throw new ApiError("UNAUTHORIZED", "User profile not found");

  return {
    user_id: user.id,
    tier: profile.tier,
    scopes: ["read", "write"], // JWTは全権限
    auth_method: "jwt",
  };
}

// スコープチェックヘルパー
export function requireScope(auth: AuthResult, scope: string): void {
  if (!auth.scopes.includes(scope)) {
    throw new ApiError("FORBIDDEN", `API key lacks required scope: ${scope}`);
  }
}
```

### 2f. レート制限

| Tier | リクエスト/分 | リクエスト/日 |
|------|-------------|-------------|
| Free (0) | 30 | 1,000 |
| Standard (1) | 60 | 5,000 |
| Pro (2) | 120 | 20,000 |
| Owner (3) | 600 | 無制限 |

**実装: DB側カウンタ**（Edge Functionはステートレスなのでインメモリは不可）

```sql
CREATE TABLE rate_limit_counters (
  bucket_key  TEXT NOT NULL,        -- '{api_key_id}:{minute_bucket}' or '{user_id}:{minute_bucket}'
  count       INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (bucket_key)
);

-- TTL: 5分超を定期削除 (pg_cron)
CREATE INDEX idx_rate_limit_ttl ON rate_limit_counters(created_at);
```

```typescript
async function checkRateLimit(auth: AuthResult, supabase: SupabaseClient): Promise<void> {
  const minuteBucket = new Date().toISOString().slice(0, 16); // "2026-03-11T22:05"
  const bucketKey = `${auth.api_key_id ?? auth.user_id}:${minuteBucket}`;

  const { data, error } = await supabase.rpc("increment_rate_limit", {
    p_bucket_key: bucketKey,
  });

  if (error) {
    // fail-closed: DB failure = deny request (Design Principle #1: No Silent Failures)
    // Rationale: a broken rate limiter could allow abuse that overwhelms the system.
    // Log for ops visibility; the client gets a retryable 500, not a silent pass-through.
    console.error("Rate limit check failed:", error.message);
    throw new ApiError("INTERNAL_ERROR", "Rate limit check unavailable", true);
  }

  const limit = TIER_LIMITS[auth.tier]?.per_minute ?? 30;
  if (data > limit) {
    throw new ApiError("RATE_LIMITED", `Rate limit exceeded: ${limit} req/min`);
  }
}
```

```sql
CREATE OR REPLACE FUNCTION increment_rate_limit(p_bucket_key TEXT)
RETURNS INT AS $$
DECLARE
  current_count INT;
BEGIN
  INSERT INTO rate_limit_counters (bucket_key, count)
  VALUES (p_bucket_key, 1)
  ON CONFLICT (bucket_key) DO UPDATE SET count = rate_limit_counters.count + 1
  RETURNING count INTO current_count;
  RETURN current_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- REVOKE EXECUTE ON FUNCTION increment_rate_limit FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION increment_rate_limit TO service_role;
```

---

## 3. APIキー認証とRLSの連携 — 候補B確定 (SEC-R4-004)

> **ステータス: 確定 — 候補B (RLS経由) を採用**

### 確定方針: Supabase auth.admin でユーザースコープJWTを発行し、RLSを通す

```typescript
async function createRlsClient(userId: string): Promise<SupabaseClient> {
  const adminClient = createClient(url, serviceRoleKey)

  // Supabase GoTrue admin API: ユーザーとして短寿命トークンを発行
  // Edge Function 内で auth.admin.generateLink() を使い、
  // そのトークンで新しいクライアントを作成する
  // → RLS が auth.uid() = userId を自動適用
  // → .eq('user_id', ...) の書き忘れが構造的に不可能

  // 実装詳細は Supabase docs を参照 (実装フェーズで検証)
  // フォールバック: Edge Function 内で supabase.auth.admin.getUserById() +
  //   createClient with { global: { headers: { Authorization: `Bearer ${userJwt}` } } }

  return userScopedClient
}
```

### 却下理由

**候補A (service_role + 明示的 `.eq('user_id', ...)`)** を却下:
- `.eq()` 1箇所の書き忘れ = 全ユーザーのデータ漏洩。テナント漏洩が「静かに穴が空く」典型例
- Edge Function が増えるほどリスクが線形に増加
- Design Principle #1 違反: fail-open (書き忘れ = 全データ公開) ではなく fail-closed (RLS = 書き忘れてもブロック) であるべき

**候補C (カスタムJWT署名)** も却下: JWT secret 漏洩時に全ユーザー偽装可能

### 実装メモ

- Phase A (read-only) / Phase B (write) の区別は不要。最初から RLS 経由で統一
- 短寿命JWT (5分) をリクエストごとに発行。ログに漏れても再利用困難
- DESIGN.md の記述 (§6c) と整合

---

## 4. 冪等性とミューテーション安全性

### 4a. Idempotency-Key ヘッダー

全 POST エンドポイントで `Idempotency-Key` ヘッダーを**必須**とする。

```sql
CREATE TABLE api_idempotency_keys (
  key         TEXT NOT NULL,
  user_id     UUID NOT NULL,
  endpoint    TEXT NOT NULL,
  status_code INT NOT NULL,
  response    JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id, key)
);
-- TTL: 24h超を日次削除 (pg_cron)
```

フロー:
1. クライアントが `Idempotency-Key: <uuid>` を送信
2. サーバーが `(user_id, key)` で既存レスポンスを検索
3. あり → キャッシュ済みレスポンスを返す（再実行しない）
4. なし → 処理実行 → レスポンスを `api_idempotency_keys` に保存 → 返す

```typescript
async function withIdempotency(
  req: Request,
  auth: AuthResult,
  endpoint: string,
  handler: () => Promise<Response>,
): Promise<Response> {
  const idempotencyKey = req.headers.get("Idempotency-Key");
  if (!idempotencyKey) {
    throw new ApiError("INVALID_PAYLOAD", "Idempotency-Key header is required for POST requests");
  }

  // Check for existing response
  const { data: existing } = await supabase
    .from("api_idempotency_keys")
    .select("status_code, response")
    .eq("user_id", auth.user_id)
    .eq("key", idempotencyKey)
    .single();

  if (existing) {
    return jsonResponse(existing.response, existing.status_code);
  }

  // Execute handler and cache response
  const response = await handler();
  const body = await response.clone().json();

  await supabase.from("api_idempotency_keys").insert({
    key: idempotencyKey,
    user_id: auth.user_id,
    endpoint,
    status_code: response.status,
    response: body,
  });

  return response;
}
```

### 4b. 楽観的排他制御 (PATCH)

PATCH リクエストは `If-Match` ヘッダーで `updated_at` を渡す:

```
PATCH /v1/transactions/:id
If-Match: "2026-03-11T12:00:00+09:00"

{ "category_id": "uuid" }
```

サーバー側:
```typescript
const { data, error } = await supabase
  .from("transactions")
  .update({ category_id: input.category_id, updated_at: "now()" })
  .eq("id", id)
  .eq("user_id", auth.user_id)
  .eq("updated_at", ifMatch)  // 楽観的ロック
  .select()
  .single();

if (!data) {
  throw new ApiError("CONFLICT", "Transaction was modified by another client. Refetch and retry.");
}
```

> **注**: `transactions.updated_at` は DESIGN.md のスキーマに定義済み (XDOC-R4-012)。

### 4c. DELETE 制約の明示的エンフォースメント

```typescript
// DELETE /v1/transactions/:id
async function deleteTransaction(id: string, auth: AuthResult) {
  requireScope(auth, "write");

  const { data: tx } = await supabase
    .from("transactions")
    .select("source")
    .eq("id", id)
    .eq("user_id", auth.user_id)
    .single();

  if (!tx) throw new ApiError("NOT_FOUND", "Transaction not found");

  if (tx.source !== "manual") {
    throw new ApiError("FORBIDDEN", "Only manually added transactions can be deleted");
  }

  await supabase.from("transactions").delete().eq("id", id);
}
```

### 4d. PATCH リクエストボディ契約

各リソースのPATCHで変更可能なフィールドを明示:

**`PATCH /v1/transactions/:id`**

| フィールド | 変更可 | 条件 |
|-----------|--------|------|
| `merchant_name` | Yes | |
| `category_id` | Yes | |
| `description` | Yes | |
| `account_id` | Yes | source=manual のみ |
| `amount` | Yes | source=manual のみ |
| `transacted_at` | Yes | source=manual のみ |
| `source` | No | immutable |
| `status` | No | 内部遷移のみ |
| `confidence` | No | システム管理 |

email_detect で自動取得された取引: merchant_name, category_id, description のみ変更可。
manual 取引: 上記 + amount, account_id, transacted_at も変更可。

immutable フィールドがPATCHに含まれている場合は `VALIDATION_ERROR` を返す。

### 4e. Mutation Audit Trail

全 write 操作のレスポンスに `mutated_by` を含める:

```json
{
  "ok": true,
  "data": {
    "id": "uuid",
    "...": "...",
    "mutated_by": {
      "method": "api_key",
      "api_key_id": "uuid",
      "api_key_name": "Claude Code"
    }
  }
}
```

将来的に `audit_log` テーブルで操作履歴を記録可能にするが、v1では不要。
レスポンスに含めることで、呼び出し元が「誰が変更したか」を把握できる。

---

## 5. API エンドポイント一覧

Base URL: `https://<project>.supabase.co/functions/v1/api`

全エンドポイントは単一の `api` Edge Functionにルーティングし、パスベースで分岐。
レスポンスは `ApiOk<T>` / `ApiErr` エンベロープを使用。

> **NOTE**: パフォーマンス問題が出た場合、projection計算等の重いエンドポイントを
> 別Edge Functionに分離する。初期は単一関数で開始し、CPU制限に当たったら分割する。

### 5a. 共通レスポンスフィールド

**全 GET レスポンス**に以下の鮮度フィールドを含める（Design Principle #2）:

```typescript
interface FreshnessMetadata {
  data_as_of: string;     // 最も古い上流データのタイムスタンプ (TIMESTAMPTZ)
  is_stale: boolean;      // now() - data_as_of > threshold
  stale_sources?: string[]; // staleなソース一覧 (is_stale=true時のみ)
}
```

**data_as_of の算出ルール**:
```typescript
function computeFreshness(emailConns: EmailConnection[], incomeConns: IncomeConnection[], summary: MonthlySummary | null): FreshnessMetadata {
  const timestamps: number[] = [];

  for (const ec of emailConns) {
    if (ec.last_synced_at) timestamps.push(new Date(ec.last_synced_at).getTime());
  }
  for (const ic of incomeConns) {
    if (ic.last_synced_at) timestamps.push(new Date(ic.last_synced_at).getTime());
  }

  // fail-closed: summaryなし = epoch (常にstale)
  timestamps.push(summary?.updated_at ? new Date(summary.updated_at).getTime() : 0);

  // 接続がゼロの場合もepoch (常にstale)
  if (timestamps.length === 0) timestamps.push(0);

  const dataAsOf = new Date(Math.min(...timestamps));

  // XDOC-R4-004 / XDOC-R4-006: Per-source thresholds, NOT a single global value.
  // Must match 05-projection-engine.md and DMS cron thresholds:
  //   - email_connections: 48h (aligned with DMS and projection engine)
  //   - income_connections: 48h
  //   - bank_balance: 30 days (per-account, computed in projection engine)
  // For non-projection endpoints, use email/income staleness as the main signal.
  // For GET /v1/projection, delegate to the engine's own is_stale/stale_sources.
  const EMAIL_STALE_MS = 48 * 3600_000   // 48h
  const INCOME_STALE_MS = 48 * 3600_000  // 48h

  const staleSources: string[] = []
  for (const ec of emailConns) {
    const age = ec.last_synced_at ? Date.now() - new Date(ec.last_synced_at).getTime() : Infinity
    if (age > EMAIL_STALE_MS) staleSources.push(`email:${ec.id}`)
  }
  for (const ic of incomeConns) {
    const age = ic.last_synced_at ? Date.now() - new Date(ic.last_synced_at).getTime() : Infinity
    if (age > INCOME_STALE_MS) staleSources.push(`income:${ic.id}`)
  }

  return {
    data_as_of: dataAsOf.toISOString(),
    is_stale: staleSources.length > 0,
    stale_sources: staleSources.length > 0 ? staleSources : undefined,
  };
}
```

> **重要**: `monthly_summaries` 行が存在しない場合、`data_as_of = epoch (1970-01-01)` として
> `is_stale = true` を返す。「データなし = SAFE」ではなく「データなし = 判定不能」。

### 5b. 予測・サマリ (コア体験)

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/projection` | read | 残高予測を取得 (projection-response.schema.json 準拠) |
| GET | `/v1/summary/:year_month` | read | 月次サマリ取得 (`2026-03` 形式) |
| GET | `/v1/summary/current` | read | 当月サマリ (JST基準) |
| ~~GET~~ | ~~`/v1/daily-budget`~~ | — | PROJ-R4-006: 削除。予測残高は `/v1/projection` の `summary` に統合 |

#### `GET /v1/projection`

Query params:
- `horizon_days` (optional, default=60, max=120)

Response: `projection-response.schema.json` 準拠 + エンベロープ

```json
{
  "ok": true,
  "data": {
    "generated_at": "2026-03-11T22:00:00+09:00",
    "data_as_of": "2026-03-11T21:30:00+09:00",
    "is_stale": false,
    "stale_sources": [],
    "timezone": "Asia/Tokyo",
    "horizon_days": 60,
    "currency": "JPY",
    "status": "SAFE",
    "aggregate_balance": 152000,
    "aggregate_timeline": ["..."],
    "aggregate_balance_bars": ["..."],
    "account_projections": [
      {
        "account_id": "uuid",
        "account_name": "三井住友銀行",
        "current_balance": 120000,
        "timeline": ["..."],
        "balance_bars": ["..."],
        "danger_zones": [],
        "is_safe": true
      }
    ],
    "charge_coverages": ["..."],
    "danger_zones": [],
    "summary": {
      "projected_end_balance": 52000,
      "first_deficit_date": null,
      "first_deficit_shortfall": null,
      "funded_charges": 3,
      "unfunded_charges": 0
    }
  },
  "request_id": "uuid"
}
```

#### ~~`GET /v1/daily-budget`~~ — 削除 (PROJ-R4-006)

日割り予算は非現実的なため削除。代わりに `GET /v1/projection` の response に
`summary.min_projected_balance` と `summary.pre_payday_balance` を含める。
「給料日前日の予測残高」としてUIに事実を表示する。

#### `GET /v1/summary/:year_month`

Response:
```json
{
  "ok": true,
  "data": {
    "year_month": "2026-03",
    "total_income": 145000,
    "total_expense": -87200,
    "fixed_costs": -45000,
    "variable_costs": -38200,
    "uncategorized": -4000,
    "projected_balance": 57800,
    "data_as_of": "2026-03-11T21:30:00+09:00",
    "is_stale": false
  },
  "request_id": "uuid"
}
```

### 5c. 取引

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/transactions` | read | 取引一覧 (フィルタ・ページネーション) |
| GET | `/v1/transactions/:id` | read | 取引詳細 (line_items含む) |
| POST | `/v1/transactions` | write | 手動取引追加 (Idempotency-Key必須) |
| PATCH | `/v1/transactions/:id` | write | 取引更新 (If-Match必須) |
| DELETE | `/v1/transactions/:id` | write | 取引削除 (source=manualのみ) |

#### `GET /v1/transactions`

Query params:
- `from` / `to` (ISO date, JST解釈)
- `category_id` (UUID)
- `account_id` (UUID)
- `status` (`pending` | `confirmed` | `categorized`)
- `source` (`email_detect` | `manual` | etc.)
- `q` (merchant_name / description の部分一致)
- `limit` (default=50, max=200)
- `offset` (default=0)
- `order` (`asc` | `desc`, default=`desc`)

Response:
```json
{
  "ok": true,
  "data": {
    "items": [
      {
        "id": "uuid",
        "amount": -1200,
        "merchant_name": "セブンイレブン 新宿店",
        "category": { "id": "uuid", "name": "コンビニ", "icon": "building.2", "color": "#FFA07A" },
        "account": { "id": "uuid", "name": "三井住友NL", "last4": "1234" },
        "status": "categorized",
        "source": "email_detect",
        "transacted_at": "2026-03-11T12:30:00+09:00",
        "updated_at": "2026-03-11T12:30:00+09:00",
        "line_items": null
      }
    ],
    "total": 142,
    "has_more": true,
    "data_as_of": "2026-03-11T21:30:00+09:00",
    "is_stale": false
  },
  "request_id": "uuid"
}
```

#### `POST /v1/transactions`

Headers: `Idempotency-Key: <uuid>` (必須)

```json
{
  "amount": -980,
  "merchant_name": "松屋 池袋店",
  "category_id": "uuid",
  "account_id": "uuid",
  "transacted_at": "2026-03-11T12:00:00+09:00",
  "description": "ランチ"
}
```

### 5d. カテゴリ

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/categories` | read | カテゴリ一覧 (システム + カスタム) |
| POST | `/v1/categories` | write | カスタムカテゴリ作成 (Idempotency-Key必須) |
| PATCH | `/v1/categories/:id` | write | カスタムカテゴリ更新 (If-Match必須) |
| DELETE | `/v1/categories/:id` | write | カスタムカテゴリ削除 (システムカテゴリは不可) |

### 5e. 金融アカウント

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/accounts` | read | 金融アカウント一覧 |
| POST | `/v1/accounts` | write | アカウント追加 (Idempotency-Key必須) |
| PATCH | `/v1/accounts/:id` | write | アカウント更新 (If-Match必須) |
| DELETE | `/v1/accounts/:id` | write | アカウント削除 |

PATCH `/v1/accounts/:id` request body (XDOC-R4-008):

| Field | Type | Condition | Description |
|-------|------|-----------|-------------|
| `name` | string | any type | 表示名 |
| `current_balance` | integer | type=bank | 手動残高更新 (update_bank_balance SP経由) |
| `settlement_account_id` | UUID | type=credit_card | 引き落とし口座 (own bank account only, SEC-R4-001 trigger enforced) |
| `closing_day` | integer (1-31) | type=credit_card | 締め日 |
| `billing_day` | integer (1-31) | type=credit_card | 引き落とし日 |
| `credit_limit` | integer | type=credit_card | 利用限度額 |

Validation:
- `settlement_account_id` must reference the same user's bank account (trigger rejects otherwise)
- `closing_day` and `billing_day` must be set together (CHECK constraint)
- `current_balance` for bank accounts goes through `update_bank_balance` SP (shifts previous_balance)

### 5f. サブスクリプション

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/subscriptions` | read | サブスク一覧 |
| POST | `/v1/subscriptions` | write | 手動サブスク追加 (Idempotency-Key必須) |
| PATCH | `/v1/subscriptions/:id` | write | サブスク更新 (If-Match必須) |
| DELETE | `/v1/subscriptions/:id` | write | サブスク削除 |

Query params for GET:
- `is_active` (boolean, optional)
- `limit` (default=50, max=200)
- `offset` (default=0)

### 5g. 固定費

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/fixed-costs` | read | 固定費一覧 |
| POST | `/v1/fixed-costs` | write | 固定費追加 (Idempotency-Key必須) |
| PATCH | `/v1/fixed-costs/:id` | write | 固定費更新 (If-Match必須) |
| DELETE | `/v1/fixed-costs/:id` | write | 固定費削除 |

Query params for GET:
- `is_active` (boolean, optional)
- `limit` (default=50, max=200)
- `offset` (default=0)

### 5h. 収入

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/income/projections` | read | 見込み収入一覧 |
| GET | `/v1/income/shifts` | read | シフト実績一覧 |
| POST | `/v1/income/projections` | write | 手動収入見込み追加 (Idempotency-Key必須) |
| PATCH | `/v1/income/projections/:id` | write | 収入見込み更新 (If-Match必須) |

Query params for GET `/v1/income/shifts`:
- `from` / `to` (ISO date, 必須。最大範囲=6ヶ月)
- `connection_id` (UUID, optional)
- `limit` (default=50, max=200)
- `offset` (default=0)

### 5i. 接続ステータス・ヘルス

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/connections` | read | 全接続ステータス (email + income 統合) |
| GET | `/v1/health` | read | システムヘルス (staleness, alerts) |
| GET | `/v1/alerts` | read | アラート一覧 |

#### `GET /v1/connections`

Response:
```json
{
  "ok": true,
  "data": {
    "email": [
      {
        "id": "uuid",
        "provider": "gmail",
        "email_address": "user@gmail.com",
        "is_active": true,
        "last_synced_at": "2026-03-11T21:00:00+09:00",
        "watch_expiry": "2026-03-18T11:00:00+09:00",
        "consecutive_failure_count": 0,
        "bootstrap_completed_at": "2026-03-01T10:00:00+09:00"
      }
    ],
    "income": [
      {
        "id": "uuid",
        "provider": "freee",
        "employer_name": "ファミリーマート 新宿店",
        "is_active": true,
        "session_status": "active",
        "last_synced_at": "2026-03-11T20:00:00+09:00",
        "payday": 25
      }
    ]
  },
  "request_id": "uuid"
}
```

#### `GET /v1/health`

Response:
```json
{
  "ok": true,
  "data": {
    "overall_status": "healthy",
    "data_as_of": "2026-03-11T20:00:00+09:00",
    "is_stale": false,
    "stale_sources": [],
    "sources": {
      "gmail:vpass": { "last_synced_at": "2026-03-11T21:00:00+09:00", "is_stale": false },
      "freee": { "last_synced_at": "2026-03-11T20:00:00+09:00", "is_stale": false }
    },
    "unresolved_alerts": 0,
    "parse_failures_24h": 0
  },
  "request_id": "uuid"
}
```

#### `GET /v1/alerts`

Query params:
- `resolved` (boolean, optional. default=false: 未解決のみ)
- `limit` (default=50, max=200)
- `offset` (default=0)

### 5j. APIキー管理

| Method | Path | Scope | 説明 |
|--------|------|-------|------|
| GET | `/v1/api-keys` | read | 自分のAPIキー一覧 (hash化済み、平文は返さない) |
| POST | `/v1/api-keys` | — | 新規APIキー発行 (**JWT認証のみ。APIキーでは不可**) |
| POST | `/v1/api-keys/:id/rotate` | — | キーローテーション (**JWT認証のみ**) |
| DELETE | `/v1/api-keys/:id` | — | APIキー失効 (**JWT認証のみ**) |

> APIキー管理は **Supabase JWT認証のみ** (APIキーでAPIキーは操作不可)。
> iOSアプリ内の設定画面から操作する想定。

#### `POST /v1/api-keys`

Request:
```json
{
  "name": "Claude Code",
  "scopes": ["read"],
  "expires_at": null
}
```

Response (**このレスポンスのみ平文を返す**):
```json
{
  "ok": true,
  "data": {
    "id": "uuid",
    "name": "Claude Code",
    "scopes": ["read"],
    "raw_key": "crd_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "created_at": "2026-03-11T22:00:00+09:00",
    "expires_at": null
  },
  "request_id": "uuid"
}
```

#### `POST /v1/api-keys/:id/rotate`

原子的に: (1) 新しいキーを生成 (2) 平文を返す (3) 旧キーを無効化。
単一DBトランザクションで実行。

Response:
```json
{
  "ok": true,
  "data": {
    "id": "uuid (新しいapi_key行のID)",
    "name": "Claude Code",
    "scopes": ["read"],
    "raw_key": "crd_live_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy",
    "rotated_from": "uuid (旧api_key行のID)",
    "created_at": "2026-03-11T23:00:00+09:00"
  },
  "request_id": "uuid"
}
```

---

## 6. エラーコード

公開APIとinternal webhook handlerでエラーコードを分離する。

### 6a. 公開APIエラーコード

| Code | HTTP Status | retryable | 説明 |
|------|------------|-----------|------|
| `UNAUTHORIZED` | 401 | false | 認証失敗（無効なJWT/APIキー） |
| `FORBIDDEN` | 403 | false | スコープ不足、システムリソースへの操作禁止 |
| `NOT_FOUND` | 404 | false | リソースが存在しない |
| `CONFLICT` | 409 | false | 楽観的ロック失敗、重複名 |
| `VALIDATION_ERROR` | 422 | false | リクエストボディの検証失敗 |
| `RATE_LIMITED` | 429 | true | レート制限超過 |
| `INTERNAL_ERROR` | 500 | true | サーバー内部エラー |

### 6b. Internal エラーコード (webhook handler専用、API非公開)

| Code | 説明 |
|------|------|
| `TOKEN_REFRESH_FAILED` | OAuthトークンリフレッシュ失敗 |
| `GMAIL_HISTORY_API_FAILED` | Gmail History API呼び出し失敗 |
| `HISTORY_ID_EXPIRED` | historyId失効 |
| `INVALID_PAYLOAD` | webhookペイロード不正 |

### 6c. _shared/api.ts への反映

```typescript
// 公開API用
export type PublicErrorCode =
  | "UNAUTHORIZED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "CONFLICT"
  | "VALIDATION_ERROR"
  | "RATE_LIMITED"
  | "INTERNAL_ERROR";

// Internal webhook handler用 (既存)
export type InternalErrorCode =
  | "UNAUTHORIZED"
  | "INVALID_PAYLOAD"
  | "TOKEN_REFRESH_FAILED"
  | "GMAIL_HISTORY_API_FAILED"
  | "HISTORY_ID_EXPIRED"
  | "RATE_LIMITED"
  | "INTERNAL_ERROR";

export type ErrorCode = PublicErrorCode | InternalErrorCode;
```

---

## 7. MCP Server 定義

### 7a. 構成

MCP Serverは上記APIの薄いラッパー。各APIエンドポイントに対応するMCPツールを定義する。

配置: `mcp-server/` ディレクトリ (npm パッケージとして公開可能)

```
mcp-server/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts          -- MCP Server エントリポイント
│   ├── client.ts         -- Credebi API クライアント
│   └── tools/
│       ├── projection.ts
│       ├── transactions.ts
│       ├── categories.ts
│       ├── accounts.ts
│       ├── subscriptions.ts
│       ├── income.ts
│       └── health.ts
```

### 7b. MCP ツール一覧

#### コア体験

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `get_projection` | GET /v1/projection | 今後N日間の残高予測・引き落としカバー率・safety status。「次の引き落とし大丈夫？」「いつ残高マイナスになる？」に使う |
| ~~`get_daily_budget`~~ | — | PROJ-R4-006: 削除。`get_projection` の summary に統合 |
| `get_monthly_summary` | GET /v1/summary/:ym | 指定月のサマリ（収入合計、支出合計、カテゴリ別内訳）。「今月の支出は？」「先月と比べて？」に使う |

#### 取引

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_transactions` | GET /v1/transactions | 取引一覧。引数: from, to, category_id, q, limit |
| `get_transaction` | GET /v1/transactions/:id | 取引詳細 (内訳含む) |
| `add_transaction` | POST /v1/transactions | 手動取引追加。write scope必須 |
| `update_transaction` | PATCH /v1/transactions/:id | 取引のカテゴリや店舗名を修正。write scope必須 |
| `delete_transaction` | DELETE /v1/transactions/:id | 手動追加した取引の削除。write scope必須 |

#### カテゴリ

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_categories` | GET /v1/categories | カテゴリ一覧 (システム定義 + ユーザー作成) |
| `create_category` | POST /v1/categories | カスタムカテゴリ作成。write scope必須 |

#### 金融アカウント

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_accounts` | GET /v1/accounts | 金融アカウント一覧 (銀行口座、クレカ) |
| `create_account` | POST /v1/accounts | アカウント追加。write scope必須 |
| `update_account` | PATCH /v1/accounts/:id | アカウント情報更新。write scope必須 |

#### サブスクリプション

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_subscriptions` | GET /v1/subscriptions | サブスク一覧 (active/inactive) |
| `add_subscription` | POST /v1/subscriptions | 手動サブスク追加。write scope必須 |
| `update_subscription` | PATCH /v1/subscriptions/:id | サブスク更新 (金額変更、解約等)。write scope必須 |

#### 固定費

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_fixed_costs` | GET /v1/fixed-costs | 固定費一覧 |
| `add_fixed_cost` | POST /v1/fixed-costs | 固定費追加。write scope必須 |
| `update_fixed_cost` | PATCH /v1/fixed-costs/:id | 固定費更新。write scope必須 |

#### 収入

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `list_income_projections` | GET /v1/income/projections | 見込み収入一覧 |
| `list_shifts` | GET /v1/income/shifts | シフト実績一覧 (from/to必須) |
| `add_income_projection` | POST /v1/income/projections | 手動収入見込み追加。write scope必須 |

#### ヘルス・運用

| Tool Name | API Endpoint | 説明 |
|-----------|-------------|------|
| `get_connections` | GET /v1/connections | メール・収入ソースの接続ステータス |
| `get_health` | GET /v1/health | システム全体のヘルス (staleness, エラー率) |
| `list_alerts` | GET /v1/alerts | 未解決のシステムアラート |

### 7c. MCP ツール定義例

```typescript
// mcp-server/src/tools/projection.ts
import { z } from "zod";

export const getProjectionTool = {
  name: "get_projection",
  description:
    "Get the cash flow projection for the next N days. Shows daily balance forecast, " +
    "card charge coverage (will the bank balance cover each card billing?), and overall " +
    "safety status (SETUP_REQUIRED/SAFE/WARNING/CRITICAL). Use when the user asks about upcoming charges, " +
    "whether they can afford something, or when a deficit might occur. " +
    "The response includes summary.pre_payday_balance for a quick 'how much is left?' answer.",
  inputSchema: z.object({
    horizon_days: z
      .number()
      .int()
      .min(1)
      .max(120)
      .default(60)
      .describe("Forecast horizon in days (default: 60)"),
  }),
  handler: async (input: { horizon_days: number }, client: CredebiClient) => {
    return client.get("/v1/projection", { horizon_days: input.horizon_days });
  },
};

// PROJ-R4-006: get_daily_budget removed.
// Pre-payday balance is now part of get_projection response (summary.pre_payday_balance).
```

### 7d. Claude Code 接続設定

ユーザーの `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "credebi": {
      "command": "npx",
      "args": ["@credebi/mcp-server@1"],
      "env": {
        "CREDEBI_API_KEY": "crd_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

> NOTE: `@1` でメジャーバージョン固定。MCP toolスキーマの破壊的変更時は `@2` にバンプ。

---

## 8. APIに含めないもの

以下はAPIキー経由では操作不可。iOSアプリ + Supabase JWT 専用:

| 操作 | 理由 |
|------|------|
| OAuth接続 (Gmail/freee) の開始・切断 | ブラウザリダイレクトが必要。APIキーでは不可 |
| Vaultシークレットの読み書き | service_role専用。ユーザー向けに開放しない |
| push通知の登録・解除 | デバイストークンが必要 |
| 課金プラン変更 | App Store IAP経由 |
| メール再処理・リプレイ | 内部運用操作 (Owner限定) |
| APIキー管理 (発行/失効/ローテ) | JWT認証のみ。APIキーでAPIキーは操作不可 |

---

## 9. フェーズ戦略

### Phase A: Read-only API

- GET エンドポイントのみ公開
- スコープ: `read` のみ
- auth bridge: 候補A (service_role + 明示的user_idフィルタ)
- 前提条件: レート制限DB実装、全GETレスポンスにdata_as_of、fail-closed freshness

### Phase B: Bounded writes

- POST/PATCH/DELETE を追加
- スコープ: `read` + `write`
- Idempotency-Key必須、If-Match楽観的ロック、DELETE source制約
- auth bridge: 候補Bの検証完了後に移行 (or 候補AのscopedQueryラッパーで継続)
- transactions テーブルに `updated_at` 追加

### Phase C: Full capabilities + third-party

- バージョニング戦略確定 (`/v1/` 安定性保証、破壊的変更は `/v2/` + 90日並行)
- audit_log テーブル追加
- 細粒度スコープ (`read:transactions`, `write:categories` 等)
- Edge Function分割 (CPU制限対策)
- Web fallback でのAPIキー発行UI

---

## 10. 設計タスクとの関連

| DT | 関連 |
|----|------|
| DT-021 | 外部API公開時の認可設計 → **本ドキュメントで解決** |
| DT-046 | 内部関数authの専用シークレット化 → APIキーは別系統。内部関数は引き続きservice_role |
| DT-085 | RLSバイパスの構造的リスク → §3で2候補を提示。Phase A は候補Aで開始、Phase B前に再評価 |

### DT-021 解決方針

DT-021 は「外部API公開時の認可設計」を求めていた。本設計で以下を確定:

- **認証**: `crd_live_` prefix付きAPIキー + SHA-256ハッシュ照合
- **認可**: スコープモデル (`read` / `write`) + user_idフィルタ
- **レート制限**: DB側カウンタ、Tier別 (30~600 req/min)
- **冪等性**: `Idempotency-Key` ヘッダー必須 (POST)
- **排他制御**: `If-Match` + `updated_at` (PATCH)
- **鮮度**: 全GETレスポンスに `data_as_of` / `is_stale`
- **auth bridge**: 2候補提示、実装時に検証して確定 (§3)

**ステータス: DT-021 → 設計完了 ✅ (auth bridge方式のみ未確定)**

---

## 11. スキーマ変更まとめ

本設計で必要なスキーマ変更:

```sql
-- 1. api_keys テーブル (§2a) — 既にDESIGN.mdに追加済み。scopes制約を更新
-- 2. transactions.updated_at — already in DESIGN.md CREATE TABLE (XDOC-R4-012: removed duplicate ALTER)
CREATE INDEX idx_transactions_updated ON transactions(updated_at);

-- 3. レート制限カウンタ (§2f)
CREATE TABLE rate_limit_counters (
  bucket_key  TEXT PRIMARY KEY,
  count       INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_rate_limit_ttl ON rate_limit_counters(created_at);

-- 4. 冪等性キーキャッシュ (§4a)
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

-- 5. レート制限RPC (§2f)
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

-- REVOKE EXECUTE ON FUNCTION increment_rate_limit FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION increment_rate_limit TO service_role;

-- 6. pg_cron: TTL cleanup
-- rate_limit_counters: 5分超を毎分削除
-- api_idempotency_keys: 24h超を日次削除
```
