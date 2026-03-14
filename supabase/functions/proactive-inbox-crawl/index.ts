import { err, newRequestId, ok, type ApiErr, type ApiOk } from "../_shared/api.ts";

// DT-007: Type name aligned with docs/deep-dive/02-gmail-integration.md §10c
type ProactiveInboxProactiveInboxCrawlRequest = {
  user_id?: string;
  target_month?: string;
  max_users?: number;
  dry_run?: boolean;
};

export type ProactiveInboxCrawlResponse = ApiOk<{
  scanned_jobs: number;
  found_jobs: number;
  missed_jobs: number;
  crawled_jobs: number;
  target_month: string;
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

// TODO: users.tier を取得
async function getUserTier(_userId: string): Promise<number> {
  return 0;
}

Deno.serve(async (req: Request) => {
  const requestId = newRequestId();

  if (req.method !== "POST") {
    return err(requestId, "INVALID_PAYLOAD", "POST only", false, 405);
  }

  if (!isAuthorized(req)) {
    return err(requestId, "UNAUTHORIZED", "missing/invalid auth", false, 401);
  }

  let body: ProactiveInboxCrawlRequest = {};
  try {
    body = (await req.json()) as ProactiveInboxCrawlRequest;
  } catch {
    // bodyなしでも実行可能
  }

  const maxUsers = Math.max(1, Math.min(body.max_users ?? 200, 2000));
  const dryRun = Boolean(body.dry_run);
  // DT-052: Use JST (Asia/Tokyo) for date boundary logic — Japan-only app
  const targetMonth = body.target_month ??
    new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Tokyo" }).slice(0, 7);

  try {
    // TODO:
    // 1. expected_email_jobs(status in pending/crawled, next_run_at <= now) を取得
    // 2. Tier < 2 を除外
    // 3. Gmail query で候補抽出 -> LLM一次判定 -> LLM二次判定
    // 4. found/missed/crawled への遷移 + attempt_count, next_run_at 更新
    // 5. retryable エラー時は指数バックオフ

    if (body.user_id) {
      const tier = await getUserTier(body.user_id);
      if (tier < 2) {
        return err(
          requestId,
          "RATE_LIMITED",
          "tier < 2: proactive crawl is disabled",
          false,
          403,
        );
      }
    }

    return ok(requestId, {
      scanned_jobs: dryRun ? 0 : maxUsers,
      found_jobs: 0,
      missed_jobs: 0,
      crawled_jobs: 0,
      target_month: targetMonth,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "internal error";
    return err(requestId, "INTERNAL_ERROR", msg, true, 500);
  }
});
