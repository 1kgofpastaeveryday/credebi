ID: XDOC-R5-001  
Severity: P0 runtime error  
Source A: `docs/deep-dive/02-gmail-integration.md` (webhook must fetch history, parse, write transactions, then update history)  
Source B: `supabase/functions/handle-email-webhook/index.ts`  
Issue: Webhook marks `processed_webhook_messages` as `done` and returns 200 while core processing is still TODO (`processed_count=0`, `parsed_count=0` always). This silently drops real Gmail events.  
Fix: Do not `confirmMessageId()` until email fetch/parse/write + history update succeed; return 5xx (retryable) while processing path is not completed.

ID: XDOC-R5-002  
Severity: P0 runtime error  
Source A: `docs/deep-dive/02-gmail-integration.md` §10c request type `ProactiveInboxCrawlRequest`  
Source B: `supabase/functions/proactive-inbox-crawl/index.ts`  
Issue: Type drift/compile break: declared `ProactiveInboxProactiveInboxCrawlRequest` but code uses `ProactiveInboxCrawlRequest` (undefined).  
Fix: Rename type to `ProactiveInboxCrawlRequest` (or update usages) consistently.

ID: XDOC-R5-003  
Severity: P1 semantic  
Source A: `docs/deep-dive/07-public-api.md` / `docs/deep-dive/05-projection-engine.md` (projection exposes `status: SETUP_REQUIRED|SAFE|WARNING|CRITICAL`, aggregate/account fields)  
Source B: `docs/contracts/projection-response.schema.json` (summary `safety_status: safe|warning`, requires `balance_bars`, no `status`/`account_projections`)  
Issue: Projection API contract is internally inconsistent (docs and schema define different shapes/enums).  
Fix: Choose one canonical response model and align both schema and docs (prefer schema as source of truth, then update examples/engine docs).

ID: XDOC-R5-004  
Severity: P1 semantic  
Source A: `docs/deep-dive/07-public-api.md` §6c (public `ErrorCode` includes `FORBIDDEN`, `NOT_FOUND`, `CONFLICT`, `VALIDATION_ERROR`)  
Source B: `supabase/functions/_shared/api.ts`  
Issue: Shared error union is internal-only; public API codes are missing, so documented responses cannot be type-represented consistently.  
Fix: Split `PublicErrorCode`/`InternalErrorCode` and export union exactly as documented.

ID: XDOC-R5-005  
Severity: P1 semantic  
Source A: `docs/deep-dive/07-public-api.md` error table (`RATE_LIMITED` => 429, retryable=true; authz failures => `FORBIDDEN`)  
Source B: `supabase/functions/proactive-inbox-crawl/index.ts`  
Issue: Tier gate returns `RATE_LIMITED` with HTTP 403 and `retryable=false`, violating enum/status semantics.  
Fix: Return `FORBIDDEN` (403) for tier restriction, reserve `RATE_LIMITED` for 429 throttling.

ID: XDOC-R5-006  
Severity: P1 semantic  
Source A: `docs/deep-dive/05-projection-engine.md` (fixed-cost routing/de-dup logic uses `fixed_costs.account_id`)  
Source B: `supabase/migrations/20260317000002_tables.sql` (`fixed_cost_items` has no `account_id`)  
Issue: Account-scoped projection logic references a column that does not exist in schema, so routing/de-dup design cannot be implemented as written.  
Fix: Add `account_id UUID REFERENCES financial_accounts(id)` to `fixed_cost_items` (or revise projection spec to remove account-scoped fixed-cost routing).

ID: XDOC-R5-007  
Severity: P1 semantic  
Source A: `DESIGN.md` / `docs/deep-dive/02-gmail-integration.md` / `docs/deep-dive/06-income-projection.md` (pg_cron includes proactive crawl + income sync jobs)  
Source B: `supabase/migrations/20260317000007_cron_jobs.sql`  
Issue: Cron drift: no scheduled jobs for `proactive-inbox-crawl`, `sync-income-freee`, or `sync-income-playwright`.  
Fix: Add cron schedules (or fan-out scheduler jobs) for those functions with documented cadence.

ID: XDOC-R5-008  
Severity: P2 cosmetic  
Source A: `docs/deep-dive/03-suggestion-engine.md` (“DESIGN seed の16カテゴリ名のみ使用”)  
Source B: `supabase/migrations/20260317000006_seed.sql` (18 seeded categories)  
Issue: Cross-doc category count drift (16 vs 18) risks stale mapping assumptions in suggestion rules/docs.  
Fix: Update suggestion doc to 18 categories (or explicitly list the allowed subset if intentional).