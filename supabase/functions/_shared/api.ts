export type PublicErrorCode =
  | "UNAUTHORIZED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "CONFLICT"
  | "VALIDATION_ERROR"
  | "RATE_LIMITED"
  | "INTERNAL_ERROR";

export type InternalErrorCode =
  | "UNAUTHORIZED"
  | "INVALID_PAYLOAD"
  | "TOKEN_REFRESH_FAILED"
  | "GMAIL_HISTORY_API_FAILED"
  | "HISTORY_ID_EXPIRED"
  | "RATE_LIMITED"
  | "INTERNAL_ERROR";

export type ErrorCode = PublicErrorCode | InternalErrorCode;

export type ApiOk<T> = {
  ok: true;
  data: T;
  request_id: string;
};

export type ApiErr = {
  ok: false;
  error: {
    code: ErrorCode;
    message: string;
    retryable: boolean;
  };
  request_id: string;
};

export function newRequestId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}

export function ok<T>(requestId: string, data: T, status = 200): Response {
  const body: ApiOk<T> = { ok: true, data, request_id: requestId };
  return jsonResponse(body, status);
}

export function err(
  requestId: string,
  code: ErrorCode,
  message: string,
  retryable: boolean,
  status = 400,
): Response {
  const body: ApiErr = {
    ok: false,
    error: { code, message, retryable },
    request_id: requestId,
  };
  return jsonResponse(body, status);
}
