ID: SEC-R5-001  
Severity: P1  
Location: `supabase/migrations/20260317000002_tables.sql` (`transactions.account_id`/`category_id` at lines 103/106, `subscriptions.account_id`/`category_id`/`last_detected_email_id` at 166/167/173, `fixed_cost_items.category_id` at 295, `pending_ec_correlations.transaction_id` at 396, `suggestion_feedback.transaction_id` at 435) + `supabase/migrations/20260317000003_functions_triggers.sql` (only ownership triggers for `settlement_account_id` and `projected_incomes.bank_account_id`)  
Issue: Cross-tenant foreign-key ownership is not enforced for many user-scoped references. RLS checks row ownership on the child table but does not guarantee referenced FK rows belong to the same user.  
Impact: IDOR/data-integrity gap: a user who obtains another tenant’s UUID can link their rows to foreign tenant resources, causing data contamination and possible operational DoS (e.g., preventing deletes due to FK references).  
Fix: Enforce same-user FK ownership structurally. Preferred: composite FKs `(user_id, fk_id)` referencing `(user_id, id)` with supporting unique indexes; alternatively add BEFORE INSERT/UPDATE triggers for each FK field to validate referenced row `user_id = NEW.user_id` (or system category rules where applicable).

---

ID: SEC-R5-002  
Severity: P1  
Location: `supabase/migrations/20260317000002_tables.sql` (`projected_incomes.connection_id` line 213, `shift_records.connection_id` line 269) + `supabase/migrations/20260317000003_functions_triggers.sql` (no ownership trigger for these) + `supabase/migrations/20260317000005_rls.sql` (`projected_incomes`/`shift_records` policies only on `user_id`)  
Issue: `income_connections` references are not ownership-validated. Users can create/update rows with their own `user_id` but another user’s `connection_id`.  
Impact: Cross-tenant linkage in payroll/income pipeline; potential corruption of projections and incorrect joins in service-role jobs.  
Fix: Add ownership triggers (same pattern as existing `check_income_bank_account_ownership`) or composite FK `(user_id, connection_id)` to `(user_id, id)` on `income_connections`.

---

ID: SEC-R5-003  
Severity: P1  
Location: `supabase/functions/handle-email-webhook/index.ts` (`verifyPubSubOidc`, especially lines 167-170) + `docs/deep-dive/02-gmail-integration.md` (§9c claims)  
Issue: Pub/Sub OIDC verification does not bind token identity to an expected caller principal (service account/subscription). It validates issuer/audience/exp/email_verified only.  
Impact: Any Google-signed ID token with matching `aud` can potentially pass, allowing forged webhook payload injection (history advancement, fake processing attempts, noisy retries).  
Fix: Validate caller identity claims (`email` and/or `sub`/`azp`) against configured expected service account(s), and optionally verify `subscription` field against allowlist.

---

ID: SEC-R5-004  
Severity: P1  
Location: `supabase/functions/handle-email-webhook/index.ts` (`claimMessageId`, lines 244-246)  
Issue: Dedup claim path is fail-open on DB error (`return "new"`).  
Impact: When idempotency storage is degraded, webhook processing continues without a valid lock/claim, enabling duplicate processing and replay amplification (financial double-write risk once TODO path is implemented).  
Fix: Fail closed: if claim cannot be established, return 5xx retryable and do not process; emit alert/log for ops.

---

ID: SEC-R5-005  
Severity: P2  
Location: `supabase/functions/renew-gmail-watch/index.ts` (`isAuthorized` lines 15-28), `supabase/functions/proactive-inbox-crawl/index.ts` (`isAuthorized` lines 19-32), `docs/deep-dive/07-public-api.md` (DT-046 note at lines 1157-1158)  
Issue: Internal endpoints authenticate by directly accepting `Bearer <SUPABASE_SERVICE_ROLE_KEY>`.  
Impact: Service-role blast radius remains maximal: any key disclosure grants both DB super-privilege and invocation of all internal admin functions.  
Fix: Use dedicated per-function internal secrets (or signed internal JWT with strict `aud`), separate from DB service role key; rotate independently and compare in constant time.