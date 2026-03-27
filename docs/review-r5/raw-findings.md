# Round 5 Review Raw Findings (source: Claude Opus 5-agent parallel review)

## P0 — Must fix before implementation

### SEC-R5-001: users.tier DEFAULT 3 (Owner)
- Location: supabase/migrations/20260317000002_tables.sql line 12
- Issue: `tier INT DEFAULT 3` gives every new signup Owner access (unlimited rate limits, all features)
- Fix: Change to `DEFAULT 0` (Free). Add CHECK constraint `tier BETWEEN 0 AND 3`

### SEC-R5-002: users RLS FOR ALL allows self-tier-escalation
- Location: supabase/migrations/20260317000005_rls.sql line 34-35
- Issue: `FOR ALL USING (id = auth.uid())` allows user to UPDATE their own tier column
- Fix: Split into SELECT/UPDATE policies. Add BEFORE UPDATE trigger preventing tier changes except by service_role

### SEC-R5-003: transactions.account_id IDOR — no ownership trigger
- Location: supabase/migrations/20260317000002_tables.sql line 103
- Issue: No trigger validating that transactions.account_id belongs to the same user_id. User can associate transactions with another user's financial account
- Fix: Add IDOR trigger like check_settlement_account_ownership. Also for subscriptions.account_id

### PROJ-R5-001: Variable costs completely missing from projection
- Location: docs/deep-dive/05-projection-engine.md
- Issue: estimated_variable appears in formulas but no function/table/column computes or stores it. buildTimeline has no variable cost parameter. The largest expense category (food, transport) is zero in projections
- Fix: Define estimateVariableCosts() using monthly_summaries avg(variable_costs + uncategorized). Add to buildTimeline

### PROJ-R5-003: fixed_cost_items missing account_id — no per-account routing, double-counted in aggregate
- Location: supabase/migrations/20260317000002_tables.sql line 287
- Issue: fixed_cost_items has no account_id. All items have fc.account_id=undefined, fall into BOTH directDebitFixedCosts AND unroutedFixedCosts → double-counted in aggregate timeline
- Fix: Add account_id column to fixed_cost_items. Fix filter logic so items without account_id appear in only one array

### XDOC-R5-002: projection-response.schema.json status enum mismatch
- Location: docs/contracts/projection-response.schema.json
- Issue: Schema has safety_status enum ["safe","warning"] (2 values lowercase). Engine produces SETUP_REQUIRED/SAFE/WARNING/CRITICAL (4 values uppercase)
- Fix: Update schema to 4-value uppercase enum. Add status to top-level required

### XDOC-R5-003: projection-response.schema.json missing major fields
- Location: docs/contracts/projection-response.schema.json
- Issue: Schema missing account_projections, aggregate_balance, aggregate_timeline, aggregate_balance_bars, danger_zones, status, stale_sources
- Fix: Expand schema to match Projection interface in 05-projection-engine.md

### OPS-R5-002: Dead Man's Switch has no monitor-the-monitor
- Location: supabase/migrations/20260317000007_cron_jobs.sql line 186
- Issue: If pg_cron stops executing, all broken connections go undetected. Nothing monitors the DMS itself
- Fix: External health check (Edge Function or third-party uptime monitor) verifying DMS ran within 24h

### OPS-R5-003: pg_net HTTP calls are fire-and-forget — cron failures invisible
- Location: supabase/migrations/20260317000007_cron_jobs.sql lines 46-62
- Issue: net.http_post is async, pg_cron always shows "succeeded". Edge Function 500s are invisible
- Fix: Heartbeat pattern — each Edge Function writes success marker, DMS checks freshness

## P1 — Fix during implementation (28 items)

### Security
- SEC-R5-004: subscriptions.account_id IDOR trigger missing
- SEC-R5-005: OIDC JWT missing iat/nbf validation
- SEC-R5-006: JWT email claim not verified against Pub/Sub service account
- SEC-R5-007: service_role_key exposed in pg_cron SQL / pg_net logs
- SEC-R5-009: claimMessageId treats DB errors as "new" (fail-open)
- SEC-R5-014: LLM output parsed without schema validation (JSON.parse only)
- SEC-R5-016: email_connections.email_address stored plaintext (PII)

### Projection
- PROJ-R5-002: todayStr JST conversion fragile (toISOString round-trip)
- PROJ-R5-004: One unconfigured card blocks entire projection (SETUP_REQUIRED too aggressive)
- PROJ-R5-005: minBar.balance uses nonexistent field → min_projected_balance always wrong
- PROJ-R5-006: amount >= 30000 threshold excludes low-income students from payday detection
- PROJ-R5-007: computeNextBilling anchored to detection time, not transaction date
- PROJ-R5-008: Card period boundary uses UTC midnight not JST midnight
- PROJ-R5-009: schema.json vs engine status enum mismatch (also P0 XDOC-R5-002)
- PROJ-R5-011: fixed_cost_items double-counted in aggregate (directDebit + unrouted)

### UX/Safety
- UX-R5-002: Bootstrap sub detection uses oldest transaction amount (price increase missed)
- UX-R5-003: Unconfigured card spending excluded from projection entirely (zero estimate)
- UX-R5-004: UI spec has no data_as_of/is_stale/stale_sources (Design Principle #2 violation)
- UX-R5-007: Pub/Sub fallback polling cron job missing (described in design, not in cron SQL)
- UX-R5-008: Bootstrap-stuck connections not caught by DMS (last_synced_at IS NULL)
- UX-R5-015: fixed_cost_items.next_billing_at has no advance cron job → fixed costs vanish after billing day

### Cross-doc
- XDOC-R5-007: _shared/api.ts ErrorCode missing FORBIDDEN/CONFLICT/NOT_FOUND
- XDOC-R5-008: ProactiveInboxProactiveInboxCrawlRequest type name duplicated
- XDOC-R5-015: Cron calls update-projection/nudge-balance-update Edge Functions that don't exist
- XDOC-R5-016: computeNextBilling() uses UTC .toISOString() — timezone convention violation

### Ops
- OPS-R5-004: claimMessageId .update() missing count:'exact' → always returns "retry"
- OPS-R5-008: OAuth token refresh race between webhook handler and renew-gmail-watch

## P2 — Future (15 items)
SEC-R5-008, SEC-R5-010, SEC-R5-012, SEC-R5-015, UX-R5-011, UX-R5-012, UX-R5-014, PROJ-R5-012, PROJ-R5-013, PROJ-R5-014, OPS-R5-005, OPS-R5-006, OPS-R5-012, OPS-R5-013, OPS-R5-016
