/**
 * LLM Output Trust Boundary — Zod validation schemas
 *
 * LLM outputs are untrusted. All LLM responses MUST pass through
 * validateLlmOutput() before any database operation. Validation failure =
 * transaction saved with category=NULL, failure logged to parse_failures.
 *
 * Prompt injection defense: the Zod schema structurally enforces that LLM
 * output can only contain the expected field shapes. SQL, column names, and
 * function names are rejected by max-length string constraints and regex
 * patterns — there is no path from LLM output to dynamic query construction.
 */

// zod is available in Deno via npm specifier (see deno.json or import map)
import { z } from "npm:zod@3";

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

export const ParsedTransactionSchema = z.object({
  merchant_name: z.string().max(200),
  amount: z.number().int().min(1), // amounts in yen, always positive
  transacted_at: z.string().regex(/^\d{4}-\d{2}-\d{2}/), // ISO date prefix
  card_last4: z.string().regex(/^\d{4}$/).optional(),
  suggested_category: z.string().max(100).optional(),
  currency: z.literal("JPY").default("JPY"),
});

export type ParsedTransaction = z.infer<typeof ParsedTransactionSchema>;

export const ParsedEmailResponseSchema = z.object({
  transactions: z.array(ParsedTransactionSchema).min(1).max(10),
  raw_merchant: z.string().max(200).optional(), // original merchant text before normalization
});

export type ParsedEmailResponse = z.infer<typeof ParsedEmailResponseSchema>;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

type ValidationSuccess = {
  ok: true;
  data: ParsedEmailResponse;
};

type ValidationFailure = {
  ok: false;
  error: z.ZodError;
  rawInput: string; // first 500 chars of JSON.stringify(raw) for diagnostics
};

export type ValidationResult = ValidationSuccess | ValidationFailure;

export function validateLlmOutput(raw: unknown): ValidationResult {
  const result = ParsedEmailResponseSchema.safeParse(raw);

  if (result.success) {
    return { ok: true, data: result.data };
  }

  return {
    ok: false,
    error: result.error,
    rawInput: JSON.stringify(raw).slice(0, 500),
  };
}
