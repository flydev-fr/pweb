import {
  JsonValue,
  PWEB_ERROR_CODES,
  PWEB_ERROR_STATUS,
  PWebErrorCode,
} from "./types.js";

const DEFAULT_MESSAGE: Readonly<Record<PWebErrorCode, string>> = {
  invalid_request: "Invalid request",
  method_not_found: "Method not found",
  forbidden: "Invocation is not allowed",
  busy: "Runtime is busy",
  cancelled: "Invocation was cancelled",
  service_error: "Service error",
  internal_error: "Internal error",
  runtime_closed: "Runtime is closed",
  protocol_mismatch: "Protocol mismatch",
};

/**
 * Typed PWeb error. `code` is the sole normative discriminator; `status`
 * is informative only — application logic must switch on `code`.
 * `data` carries `service_error`'s structured domain payload (or `busy`
 * retry metadata) exactly as received; it is `null` otherwise.
 */
export class PWebError extends Error {
  readonly code: PWebErrorCode;
  readonly status: number;
  readonly data: JsonValue;

  constructor(code: PWebErrorCode, message?: string, status?: number, data?: JsonValue) {
    super(message !== undefined && message !== "" ? message : DEFAULT_MESSAGE[code]);
    this.name = "PWebError";
    this.code = code;
    this.status = typeof status === "number" ? status : PWEB_ERROR_STATUS[code];
    this.data = data === undefined ? null : data;
  }
}

function isKnownCode(value: unknown): value is PWebErrorCode {
  return (
    typeof value === "string" &&
    (PWEB_ERROR_CODES as readonly string[]).includes(value)
  );
}

/**
 * Map a native rejection reason onto a PWebError.
 *
 * A well-formed canonical envelope (`{code, message, status, data}` with a
 * known v1 code) maps field-for-field; message/status fall back to the
 * frozen defaults when absent or mistyped, `data` passes through as
 * received (absent ⇒ null). Anything else — an `Error` from the page shim,
 * an unknown code string, a non-object — maps to a generic local
 * `internal_error` WITHOUT copying any content from the malformed reason,
 * so nothing unvalidated ever reaches the typed surface. Message text is
 * never parsed to determine `code`.
 */
export function toPWebError(reason: unknown): PWebError {
  if (reason instanceof PWebError) {
    return reason;
  }
  if (typeof reason === "object" && reason !== null && !Array.isArray(reason)) {
    const envelope = reason as { [key: string]: unknown };
    if (isKnownCode(envelope["code"])) {
      const code = envelope["code"];
      const message =
        typeof envelope["message"] === "string" ? envelope["message"] : undefined;
      // status counts as present iff it is an integer (mirrored exactly by
      // the Pas2JS SDK); anything else falls back to the frozen table
      const status =
        typeof envelope["status"] === "number" && Number.isInteger(envelope["status"])
          ? envelope["status"]
          : undefined;
      const data =
        envelope["data"] === undefined ? null : (envelope["data"] as JsonValue);
      return new PWebError(code, message, status, data);
    }
  }
  return new PWebError("internal_error");
}
