import { err, newRequestId, ok, type ApiErr, type ApiOk } from "../_shared/api.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type PubSubPushBody = {
  message?: {
    data?: string;
    messageId?: string;
    publishTime?: string;
  };
  subscription?: string;
};

type DecodedMessage = {
  emailAddress: string;
  historyId: string;
};

export type HandleEmailWebhookResponse = ApiOk<{
  processed_count: number;
  parsed_count: number;
  skipped_count: number;
  updated_history_id: string;
  skipped?: string;
}> | ApiErr;

// ---------------------------------------------------------------------------
// DT-001: OIDC JWT Verification (Pub/Sub push authentication)
// ---------------------------------------------------------------------------

// Google JWKS endpoint for signature verification
const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const VALID_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
const CLOCK_SKEW_SECONDS = 30;

// In-memory JWKS cache (per Edge Function invocation)
let jwksCache: { keys: JsonWebKey[]; fetchedAt: number } | null = null;
const JWKS_CACHE_TTL_MS = 6 * 60 * 60 * 1000; // 6 hours

interface JwtHeader {
  alg: string;
  kid: string;
  typ?: string;
}

interface JwtPayload {
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
  email?: string;
  email_verified?: boolean;
  sub?: string;
}

function base64UrlDecode(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJwtParts(token: string): { header: JwtHeader; payload: JwtPayload; signedInput: string; signature: Uint8Array } | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[0]))) as JwtHeader;
    const payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[1]))) as JwtPayload;
    const signature = base64UrlDecode(parts[2]);
    return { header, payload, signedInput: `${parts[0]}.${parts[1]}`, signature };
  } catch {
    return null;
  }
}

async function fetchGoogleJwks(): Promise<JsonWebKey[]> {
  if (jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_CACHE_TTL_MS) {
    return jwksCache.keys;
  }
  const res = await fetch(GOOGLE_JWKS_URL);
  if (!res.ok) throw new Error(`Failed to fetch JWKS: ${res.status}`);
  const body = await res.json() as { keys: JsonWebKey[] };
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function verifyJwtSignature(
  signedInput: string,
  signature: Uint8Array,
  kid: string,
): Promise<boolean> {
  const jwks = await fetchGoogleJwks();
  const jwk = jwks.find((k) => k.kid === kid);
  if (!jwk) return false;

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );

  return crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    signature,
    new TextEncoder().encode(signedInput),
  );
}

async function verifyPubSubOidc(req: Request): Promise<{ ok: true } | { ok: false; reason: string }> {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) {
    return { ok: false, reason: "missing authorization header" };
  }

  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return { ok: false, reason: "invalid bearer token format" };
  }

  const token = match[1];
  const decoded = decodeJwtParts(token);
  if (!decoded) {
    return { ok: false, reason: "malformed JWT" };
  }

  // Verify signature
  try {
    const valid = await verifyJwtSignature(decoded.signedInput, decoded.signature, decoded.header.kid);
    if (!valid) {
      return { ok: false, reason: "JWT signature verification failed" };
    }
  } catch {
    return { ok: false, reason: "JWT signature verification error" };
  }

  // Verify issuer
  if (!decoded.payload.iss || !VALID_ISSUERS.includes(decoded.payload.iss)) {
    return { ok: false, reason: "invalid issuer" };
  }

  // Verify audience (fail-closed: reject if env var is not configured)
  const expectedAudience = Deno.env.get("PUBSUB_AUDIENCE");
  if (!expectedAudience) {
    return { ok: false, reason: "PUBSUB_AUDIENCE not configured" };
  }
  if (decoded.payload.aud !== expectedAudience) {
    return { ok: false, reason: "invalid audience" };
  }

  // Verify expiration (fail-closed: reject if exp claim is missing)
  const now = Math.floor(Date.now() / 1000);
  if (!decoded.payload.exp) {
    return { ok: false, reason: "missing exp claim" };
  }
  if (decoded.payload.exp + CLOCK_SKEW_SECONDS < now) {
    return { ok: false, reason: "token expired" };
  }

  // Verify email_verified
  if (decoded.payload.email_verified !== true) {
    return { ok: false, reason: "email not verified" };
  }

  return { ok: true };
}

// ---------------------------------------------------------------------------
// DT-002: Idempotency (messageId deduplication)
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function getSupabaseAdmin() {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return createClient(url, key);
}

/**
 * Two-phase idempotency: claim → work → confirm.
 *
 * Phase 1 (claimMessageId): INSERT with status='pending'.
 *   - New message: returns 'new' → proceed with processing.
 *   - Existing 'pending': returns 'retry' → previous attempt crashed, re-process.
 *   - Existing 'done': returns 'duplicate' → skip entirely.
 *
 * Phase 2 (confirmMessageId): UPDATE status='done' after all DB writes succeed.
 *   If the function crashes between phase 1 and 2, status stays 'pending'
 *   and the next Pub/Sub retry will re-process safely.
 */
type ClaimResult = "new" | "retry" | "duplicate";

async function claimMessageId(messageId: string): Promise<ClaimResult> {
  const supabase = getSupabaseAdmin();

  // Try INSERT first
  const { error: insertError } = await supabase
    .from("processed_webhook_messages")
    .insert({
      message_id: messageId,
      status: "pending",
      locked_until: new Date(Date.now() + 5 * 60 * 1000).toISOString(), // 5 min lock
    });

  if (!insertError) return "new";

  // unique_violation → row already exists, check its status
  if (insertError.code === "23505") {
    const { data } = await supabase
      .from("processed_webhook_messages")
      .select("status, locked_until")
      .eq("message_id", messageId)
      .single();

    if (data?.status === "done") return "duplicate";

    // DT-034: Concurrent retry prevention — skip if another worker holds the lock
    if (data?.locked_until && new Date(data.locked_until) > new Date()) {
      return "duplicate"; // Another worker is actively processing; treat as handled
    }

    // Lock expired or null — reclaim with atomic UPDATE
    const { count } = await supabase
      .from("processed_webhook_messages")
      .update({
        locked_until: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
      })
      .eq("message_id", messageId)
      .eq("status", "pending")
      .lt("locked_until", new Date().toISOString());

    if (count === 0) return "duplicate"; // Another worker beat us to the reclaim
    return "retry";
  }

  // Other DB errors — treat as new to avoid silent drops
  console.error("claimMessageId error:", insertError);
  return "new";
}

async function confirmMessageId(messageId: string): Promise<void> {
  const supabase = getSupabaseAdmin();
  await supabase
    .from("processed_webhook_messages")
    .update({ status: "done", processed_at: new Date().toISOString() })
    .eq("message_id", messageId);
}

// ---------------------------------------------------------------------------
// Message decoding
// ---------------------------------------------------------------------------

function decodeMessageData(data: string): DecodedMessage | null {
  try {
    const raw = atob(data);
    return JSON.parse(raw) as DecodedMessage;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  const requestId = newRequestId();

  if (req.method !== "POST") {
    return err(requestId, "INVALID_PAYLOAD", "POST only", false, 405);
  }

  // DT-001: OIDC verification
  const authResult = await verifyPubSubOidc(req);
  if (!authResult.ok) {
    return err(requestId, "UNAUTHORIZED", authResult.reason, false, 401);
  }

  let payload: PubSubPushBody;
  try {
    payload = (await req.json()) as PubSubPushBody;
  } catch {
    return err(requestId, "INVALID_PAYLOAD", "invalid JSON body", false, 400);
  }

  const encodedData = payload.message?.data;
  const messageId = payload.message?.messageId;
  if (!encodedData || !messageId) {
    return err(requestId, "INVALID_PAYLOAD", "missing message.data/messageId", false, 400);
  }

  // DT-002: Two-phase idempotency check
  const claimResult = await claimMessageId(messageId);
  if (claimResult === "duplicate") {
    return ok(requestId, {
      processed_count: 0,
      parsed_count: 0,
      skipped_count: 0,
      updated_history_id: "",
      skipped: "duplicate",
    });
  }
  // claimResult === "new" or "retry" → proceed with processing

  const decoded = decodeMessageData(encodedData);
  if (!decoded?.emailAddress || !decoded?.historyId) {
    // DT-035: Terminal error — malformed payload will never succeed on retry.
    // Mark as 'done' to prevent Pub/Sub infinite retry storm.
    await confirmMessageId(messageId);
    return err(requestId, "INVALID_PAYLOAD", "message.data decode failed", false, 400);
  }

  try {
    // TODO:
    // 1. emailAddress から email_connections を特定
    // 2. last_history_id -> history.list 差分取得
    // 3. parser/LLM で処理
    // 4. DT-029: parsed_emails + transactions を atomic に作成:
    //    await supabase.rpc('insert_parsed_email_with_transaction', { ... })
    //    (stored procedure で単一トランザクション保証)
    // 5. DT-048: last_history_id を条件付き更新 (単調増加保証):
    //    await supabase.rpc('update_history_id_monotonic', {
    //      p_connection_id: conn.id, p_new_history_id: decoded.historyId })

    // Phase 2: Mark messageId as done only after all writes succeed
    await confirmMessageId(messageId);

    return ok(requestId, {
      processed_count: 0,
      parsed_count: 0,
      skipped_count: 0,
      updated_history_id: decoded.historyId,
    });
  } catch (e) {
    // On failure, status stays 'pending' → Pub/Sub retry will re-process
    const msg = e instanceof Error ? e.message : "internal error";
    return err(requestId, "INTERNAL_ERROR", msg, true, 500);
  }
});
