import { err, newRequestId, ok, type ApiErr, type ApiOk } from "../_shared/api.ts";

// DT-007: Type name aligned with docs/deep-dive/02-gmail-integration.md §10b
type RenewGmailWatchRequest = {
  dry_run?: boolean;
  limit?: number;
};

export type RenewGmailWatchResponse = ApiOk<{
  scanned: number;
  renewed: number;
  failed: number;
}> | ApiErr;

/**
 * Internal function auth (caller authentication).
 *
 * Caller auth: INTERNAL_SYNC_SECRET — a dedicated secret shared between
 *   pg_cron / admin tools and internal Edge Functions. This proves the
 *   caller is an authorized internal system, NOT an end user.
 *
 * DB auth: The function uses the service_role Supabase client internally
 *   to bypass RLS for batch operations. That is a separate concern from
 *   who is allowed to invoke this function.
 *
 * Separation rationale: service_role_key grants full DB access and should
 *   never appear in HTTP headers over the network. INTERNAL_SYNC_SECRET
 *   is a caller-only credential with no DB privileges.
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

  if (req.method !== "POST") {
    return err(requestId, "INVALID_PAYLOAD", "POST only", false, 405);
  }

  if (!isAuthorized(req)) {
    return err(requestId, "UNAUTHORIZED", "missing/invalid auth", false, 401);
  }

  let body: RenewGmailWatchRequest = {};
  try {
    body = (await req.json()) as RenewGmailWatchRequest;
  } catch {
    // bodyなしでも実行可能
  }

  const dryRun = Boolean(body.dry_run);
  const limit = Math.max(1, Math.min(body.limit ?? 1000, 5000));

  try {
    // TODO:
    // 1. email_connections(provider=gmail,is_active=true) を走査
    // 2. refresh_token で access_token 更新
    // 3. users.watch を再発行
    // 4. watch_expiry / watch_renewed_at 更新
    //
    // Batch strategy (DT-031):
    // - Chunk connections into batches of 50
    // - Process each batch with Promise.allSettled (parallel within batch)
    // - Sequential between batches to avoid Gmail API rate limits
    // - 1000 users = 20 batches × ~3s/batch = ~60s (within 150s timeout)
    // - Failed renewals: log to system_alerts, continue with next batch
    // - Partial success is acceptable: failed watches will be caught by
    //   detect-broken-connections DMS within 12h

    const scanned = dryRun ? 0 : limit;
    return ok(requestId, {
      scanned,
      renewed: 0,
      failed: 0,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "internal error";
    return err(requestId, "INTERNAL_ERROR", msg, true, 500);
  }
});
