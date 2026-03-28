ID (UX-R5-201)  
Severity (P0)  
Principle violated (#1)  
Location: `supabase/functions/handle-email-webhook/index.ts:322-341`  
Issue: Webhook main path is still TODO but returns `ok` and marks `message_id` as `done`.  
Impact: Gmail events are acknowledged as processed while no email/transaction parsing occurs. This is a silent data-loss path with no user recovery signal.  
Fix: Gate production with fail-closed behavior until implementation is complete (`500` retryable), or fully implement steps 1-5 before calling `confirmMessageId`.

ID (UX-R5-202)  
Severity (P0)  
Principle violated (#1)  
Location: `supabase/functions/handle-email-webhook/index.ts:226-227, 301-309`  
Issue: If a `pending` row is lock-held by another worker, code returns `"duplicate"` and HTTP `200`.  
Impact: Pub/Sub may treat the message as acknowledged even if the active worker crashes before completion, leaving `pending` forever and dropping the event silently.  
Fix: For lock-held `pending`, return retryable non-2xx (or explicit “in progress, retry”) instead of duplicate-200; only return duplicate-200 for `status='done'`.

ID (UX-R5-203)  
Severity (P1)  
Principle violated (#1)  
Location: `supabase/functions/handle-email-webhook/index.ts:150-153, 282-285`  
Issue: Missing `PUBSUB_AUDIENCE` is mapped to auth failure and returned as `401`.  
Impact: Misconfiguration causes all valid webhooks to be rejected as non-retryable unauthorized traffic; ingestion halts without recovery retries.  
Fix: Treat missing server config as internal error (`500`, retryable), and emit explicit ops alert.

ID (UX-R5-204)  
Severity (P1)  
Principle violated (#2)  
Location: `docs/ui/projection-view-spec.md:39-47, 51-53`  
Issue: Projection first-screen contract requires only safety/risk fields; it omits `data_as_of`, `is_stale`, `stale_sources`.  
Impact: Stale projections can render as normal SAFE/WARNING UI with no explicit freshness degradation indicator.  
Fix: Make freshness fields required in UI contract and render mandatory stale banner/source list on first screen.

ID (UX-R5-205)  
Severity (P1)  
Principle violated (#1)  
Location: `supabase/migrations/20260317000007_cron_jobs.sql:182-232`, `DESIGN.md:2217`  
Issue: Dead Man’s Switch deactivates broken connections and inserts `system_alerts`, but user push notification path is not implemented.  
Impact: Connection can be broken for long periods without loud user-visible notice; users keep trusting stale automation.  
Fix: Invoke `send-push` in the same broken-connection flow (or guaranteed downstream worker), with dedup/rate-limit and deep link to re-auth.

ID (UX-R5-206)  
Severity (P1)  
Principle violated (#3)  
Location: `docs/deep-dive/05-projection-engine.md:223-224`, `docs/deep-dive/04-subscription-detection.md:326-334`  
Issue: JST date logic uses `toLocaleString(...Asia/Tokyo)` then `toISOString().slice(0,10)`, which can shift day boundaries.  
Impact: Income/charge/subscription dates can slip by one day around timezone boundaries, producing unsafe underestimation/overestimation and wrong risk dates.  
Fix: Use explicit JST date formatting for date keys (`toLocaleDateString('en-CA',{timeZone:'Asia/Tokyo'})`) or Temporal/date library with timezone-safe local-date handling.