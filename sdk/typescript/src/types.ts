/**
 * PWeb protocol v1 wire types (CAP-5).
 *
 * These mirror the frozen native contract in `src/rpc/pweb.rpc.intf.pas`
 * and `wire-semantics.md`. Nothing here is negotiable SDK design: the wire
 * owns these shapes, the SDK only names them for TypeScript consumers.
 */

/** Any JSON value. A successful invocation may resolve to ANY of these —
 * including `null`, which is a valid success distinct from any error. */
export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

/** Named arguments of an invocation: a JSON object, or null (protocol v1
 * has no positional-array form). Keys are part of the public wire
 * contract and pass through byte-exact — the SDK never renames, folds
 * case, or reorders semantically. */
export type InvokeArgs = { [key: string]: JsonValue } | null;

/** The nine frozen protocol v1 error codes. `code` is the only normative
 * discriminator; `status` is informative. Deliberately no `unauthorized`. */
export const PWEB_ERROR_CODES = [
  "invalid_request",
  "method_not_found",
  "forbidden",
  "busy",
  "cancelled",
  "service_error",
  "internal_error",
  "runtime_closed",
  "protocol_mismatch",
] as const;

export type PWebErrorCode = (typeof PWEB_ERROR_CODES)[number];

/** Informative `status` per code, frozen with protocol v1. Used only to
 * fill a missing/malformed `status` member; never for discrimination. */
export const PWEB_ERROR_STATUS: Readonly<Record<PWebErrorCode, number>> = {
  invalid_request: 400,
  method_not_found: 404,
  forbidden: 403,
  busy: 429,
  cancelled: 499,
  service_error: 422,
  internal_error: 500,
  runtime_closed: 503,
  protocol_mismatch: 426,
};

/** `pweb.handshake` response. `capabilities` is ADVISORY UI metadata
 * only: authorization stays native-side and is evaluated per invocation.
 * The SDK never enforces, caches-then-trusts, or grants from it. */
export interface PWebRuntimeInfo {
  readonly protocol: number;
  readonly runtime: string;
  readonly capabilities?: readonly string[];
}

/** The native invocation primitive installed by the PWeb runtime
 * (CAP-2 binding): resolves with any JSON value, rejects with the
 * canonical error envelope object. */
export type PWebNativePrimitive = (
  method: string,
  args: InvokeArgs,
) => Promise<JsonValue>;
