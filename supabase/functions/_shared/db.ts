import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Tenant-safe database access layer.
 *
 * All user-data queries MUST use scopedQuery() to prevent cross-tenant data
 * leakage. Direct .from() on user tables is prohibited.
 *
 * Architecture:
 *   - getAdminClient() creates a service_role Supabase client that bypasses RLS.
 *     This is necessary for batch operations in internal Edge Functions (e.g.,
 *     renew-gmail-watch iterating over all users' email connections).
 *   - scopedQuery() wraps the client's .from() with a mandatory user_id filter.
 *     This is a defense-in-depth layer — it does NOT replace RLS, but ensures
 *     that code-level bugs in Edge Functions cannot accidentally query across
 *     tenants. The service_role client still has full DB access if this wrapper
 *     is bypassed, so treat it as a convention enforced by code review, not a
 *     hard security boundary.
 */

let _adminClient: SupabaseClient | null = null;

/**
 * Returns a Supabase client authenticated with the service_role key.
 * The client bypasses RLS — use scopedQuery() for all user-data access.
 *
 * Throws if SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not configured
 * (fail-closed).
 */
export function getAdminClient(): SupabaseClient {
  if (_adminClient) return _adminClient;

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!url) throw new Error("SUPABASE_URL is not set — cannot create admin client");
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY is not set — cannot create admin client");

  _adminClient = createClient(url, key, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  return _adminClient;
}

/**
 * Tenant-scoped query helper. Returns an object with select/update/delete
 * methods that automatically apply user_id filtering.
 *
 * Supabase's PostgREST builder requires .eq() AFTER the operation method,
 * so we wrap each operation to inject the user_id filter.
 *
 * Usage:
 *   // SELECT
 *   const { data } = await scopedQuery(client, 'email_connections', userId)
 *     .select('*')
 *     .eq('is_active', true);
 *
 *   // UPDATE
 *   const { error } = await scopedQuery(client, 'transactions', userId)
 *     .update({ category_id: newCat })
 *     .eq('id', txnId);
 *
 *   // DELETE
 *   const { error } = await scopedQuery(client, 'shift_records', userId)
 *     .delete()
 *     .lt('created_at', cutoff);
 */
export function scopedQuery(
  client: SupabaseClient,
  tableName: string,
  userId: string,
) {
  if (!userId) {
    throw new Error(`scopedQuery: userId is required for table "${tableName}"`);
  }
  const base = client.from(tableName);
  return {
    select: (columns = "*") => base.select(columns).eq("user_id", userId),
    update: (values: Record<string, unknown>, opts?: { count?: "exact" }) =>
      base.update(values, opts).eq("user_id", userId),
    delete: () => base.delete().eq("user_id", userId),
  };
}
