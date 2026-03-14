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
 * Internal function auth: verify that the caller provides the service_role key.
 * These functions are called by pg_cron or admin tools, never by end users.
 * The Authorization header must be "Bearer <SUPABASE_SERVICE_ROLE_KEY>".
 */
function isAuthorized(req: Request): boolean {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return false;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return false;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) return false; // fail-closed: no key configured = reject
  return match[1] === serviceKey;
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
