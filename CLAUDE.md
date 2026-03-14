# Credebi — Project Instructions

## #1 Design Principle: No Silent Failures

This is a personal finance app. The worst possible outcome is **data silently disappearing** — a transaction that was received but never stored, a webhook that was acknowledged but never processed, a connection that broke but the user was never told.

Every failure must be **loud, visible, and recoverable**:

- Never mark a message as "processed" before the work actually succeeds (2-phase idempotency)
- Never skip a validation check because a config value is missing (fail-closed, not fail-open)
- Never let a broken connection (expired token, failed watch renewal) go unnoticed by the user
- Never allow a partial write (parsed_emails inserted but transactions missing) to become permanent
- If something fails and can't be retried, surface it — to the user, to logs, to an alert. Never swallow it.

**"静かに穴が空く" is the #1 NG.** If you're unsure whether a failure mode is handled, assume it isn't and design the recovery path explicitly.

## #2 Design Principle: Stale Data Must Look Stale

When upstream data sources fail (Gmail watch expires, freee token revoked, pg_cron job crashes), downstream outputs (projections, summaries, budgets) must **visibly degrade**, not silently show outdated numbers as if they're current.

- Every prediction/summary output must carry `data_as_of` (timestamp of the most recent upstream data)
- If `now() - data_as_of > threshold`, the UI must show a staleness warning instead of a clean status
- A "SAFE" verdict from 3-day-old data is worse than an honest "data is stale, we can't tell"
- This applies across all subsystems: email pipeline, income sync, subscription detection, monthly summaries

## #3 Design Principle: Err Toward Safety (安全側に倒す)

When estimation is uncertain, **overestimate expenses and underestimate income**.

- A false "you might run short" warning (空振り) is merely cautious — the user loses nothing
- A false "you're fine" (見逃し) when they're actually short is **catastrophic** — the user overspends
- This is the earthquake early warning principle: false alarms are tolerable, missed alerts are not

Concrete applications:

- **Auto-detected subscriptions**: include in projection immediately (overestimate expense). If wrong, user corrects — but a missed real subscription is a silent hole
- **Income with uncertain timing**: keep in projection only when clearly not yet received. If ambiguous, keep (undercount risk is worse than double-count)
- **Heuristic thresholds**: when a tolerance/confidence check is ambiguous, choose the outcome that adds expense or removes income, not the reverse
- **Card charges**: show accumulating (open period) charges even though the final amount may be lower — overshoot is safe, undershoot is dangerous

**"空振りOK、見逃しNG"** — every estimation decision should ask: "which error direction is safer for the user?"

## Project Structure

- `DESIGN.md` — Main architecture doc (DB schema, API contracts, tier definitions)
- `docs/deep-dive/` — Detailed design docs per subsystem
- `docs/remaining-design-tasks.md` — Design task backlog (DT-001~DT-160)
- `docs/discovery-plan.md` — Product discovery & experiment tracking
- `supabase/functions/` — Edge Functions (Deno)
- `supabase/functions/_shared/api.ts` — Shared error/response types

## Key Conventions

- Error responses use `{ ok, error: { code, message, retryable }, request_id }` envelope
- Auth: OIDC JWT for Pub/Sub webhooks, service_role_key for internal functions
- Encoding: Japanese card issuer emails use ISO-2022-JP with JIS X 0201 half-width katakana edge cases
- DB: Supabase PostgreSQL with RLS (user_id = auth.uid()), service_role bypasses RLS for Edge Functions
- Timezone: All date-boundary logic must use `Asia/Tokyo` explicitly. `new Date().toISOString()` gives UTC — never use it for day/month boundaries
- Idempotency: 2-phase (pending → done) on processed_webhook_messages
- historyId updates must be monotonic (conditional UPDATE, never overwrite with older value)

## Tier Definitions

- Free (tier=0, ¥0+ads)
- Standard (tier=1, ¥300/mo)
- Pro (tier=2, ¥980/mo)
- Owner (tier=3, internal)
