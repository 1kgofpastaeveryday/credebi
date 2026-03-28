import { err, newRequestId, ok, type ApiErr, type ApiOk } from "../_shared/api.ts";
import { getAdminClient } from "../_shared/db.ts";

/**
 * update-projection: Daily batch job to recompute monthly_summaries.
 *
 * Called by pg_cron daily at 3:30 JST.
 * Iterates all active users, aggregates their transactions into
 * monthly_summaries, and updates data_as_of.
 *
 * Heartbeat: must call record_system_heartbeat('update-projection')
 * after successful completion.
 */

type UpdateProjectionRequest = {
  batch_size?: number; // default 100
  dry_run?: boolean;
};

export type UpdateProjectionResponse = ApiOk<{
  processed: number;
  failed: number;
  dry_run: boolean;
  batch_size: number;
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

  const body: UpdateProjectionRequest = req.method === "POST"
    ? await req.json().catch(() => ({}))
    : {};
  const batchSize = Math.min(body.batch_size ?? 100, 500);
  const dryRun = body.dry_run ?? false;

  const _supabase = getAdminClient();

  // TODO: Implementation
  // 1. Fetch active users (WHERE deleted_at IS NULL), paginated by batch_size
  // 2. For each user:
  //    a. Query transactions for current month + previous month
  //    b. Aggregate: total_income, total_expense, fixed_costs, variable_costs, uncategorized
  //    c. UPSERT into monthly_summaries with data_as_of = now()
  // 3. Fan-out: Process batches of 100 with Promise.allSettled
  // 4. Record heartbeat on success
  //    await supabase.rpc('record_system_heartbeat', {
  //      p_job_name: 'update-projection',
  //      p_expected_interval: '24 hours',
  //    });

  return ok(requestId, {
    processed: 0,
    failed: 0,
    dry_run: dryRun,
    batch_size: batchSize,
  });
});
