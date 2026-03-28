import { err, newRequestId, ok, type ApiErr, type ApiOk } from "../_shared/api.ts";
import { getAdminClient } from "../_shared/db.ts";
import { addDaysJST, todayJST } from "../_shared/date-jst.ts";

/**
 * nudge-balance-update: Daily job to prompt users to update their bank balance.
 *
 * Called by pg_cron daily at midnight JST.
 * Finds users whose projected income landed yesterday but whose
 * bank balance hasn't been updated since, and sends a Push notification
 * nudging them to refresh their balance.
 *
 * Heartbeat: must call record_system_heartbeat('nudge-balance-update')
 * after successful completion.
 */

type NudgeRequest = {
  dry_run?: boolean;
};

export type NudgeBalanceUpdateResponse = ApiOk<{
  nudged: number;
  skipped: number;
  dry_run: boolean;
}> | ApiErr;

/**
 * Internal function auth (caller authentication).
 *
 * Caller auth: INTERNAL_SYNC_SECRET — a dedicated secret shared between
 *   pg_cron / admin tools and internal Edge Functions.
 */
function isAuthorized(req: Request): boolean {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return false;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return false;
  const syncSecret = Deno.env.get("INTERNAL_SYNC_SECRET");
  if (!syncSecret) return false; // fail-closed: no secret configured = reject
  return match[1] === syncSecret;
}

Deno.serve(async (req: Request) => {
  const requestId = newRequestId();

  if (!isAuthorized(req)) {
    return err(requestId, "UNAUTHORIZED", "Missing or invalid auth header", false, 401);
  }

  const body: NudgeRequest = req.method === "POST"
    ? await req.json().catch(() => ({}))
    : {};
  const dryRun = body.dry_run ?? false;

  const _supabase = getAdminClient();
  const _yesterday = addDaysJST(todayJST(), -1);

  // TODO: Implementation
  // 1. Query projected_incomes WHERE day_of_month = yesterday's day
  //    AND is_active = true
  // 2. For each, check financial_accounts.balance_updated_at < yesterday
  // 3. If stale, send Push notification:
  //    title: "残高を更新してください"
  //    body: "昨日の収入が反映されていない可能性があります"
  // 4. Respect notification_level (less以上で配信)
  // 5. Record heartbeat on success
  //    await supabase.rpc('record_system_heartbeat', {
  //      p_job_name: 'nudge-balance-update',
  //      p_expected_interval: '24 hours',
  //    });

  return ok(requestId, {
    nudged: 0,
    skipped: 0,
    dry_run: dryRun,
  });
});
