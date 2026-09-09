/**
 * `@pweb/runtime` — the native outbound network door (CAP-15B).
 *
 * ONE function over `invoke("pweb.fetch", …)`, and deliberately nothing
 * else. This file contains no URL construction, no default origin, no
 * retry, no redirect handling, no header defaulting, no cookie jar and no
 * timeout policy: every one of those is a NATIVE decision, taken by
 * `src/rpc/pweb.rpc.fetch.pas` under the `network.fetch` capability and a
 * per-application origin allowlist compiled into the host. An SDK that
 * helpfully supplied one of them would be a second answer to a question the
 * runtime has already answered — and a second answer that `app.pwb` could
 * replace, which is exactly what the native allowlist exists to prevent.
 *
 * WHAT THE PAGE CANNOT DO FROM HERE, and why it is not a limitation of this
 * file: `PWEB_NATIVE_CSP` keeps `connect-src 'self'`, so the engine itself
 * reaches no remote server. The application's reach is exactly the origin
 * set its `pweb.json` declared, and nothing in the frontend — not a field,
 * not an option, not an environment variable — can name an origin or relax
 * a policy. See `docs/cli-contract.md` §5.
 */
import { invoke } from "./invoke.js";
import { PWebError } from "./errors.js";
import type { JsonValue } from "./types.js";

/** The runtime-owned method name, spelled once. Applications call
 * {@link httpFetch}; this constant exists so a caller that wants to check a
 * handshake capability list does not have to spell it again. */
export const PWEB_METHOD_FETCH = "pweb.fetch";

/** The capability that authorizes it. ADVISORY here, exactly as the
 * handshake's capability list is: authorization is native and per
 * invocation, and this SDK never enforces, caches-then-trusts, or grants
 * from a name. */
export const PWEB_CAP_NETWORK_FETCH = "network.fetch";

/** The six methods the native door accepts, compared CASE-SENSITIVELY on
 * the native side: `patch` is not `PATCH` and is refused. */
export type PWebFetchMethod =
  | "GET"
  | "POST"
  | "PUT"
  | "PATCH"
  | "DELETE"
  | "HEAD";

/** One outbound request.
 *
 * - `url` must be absolute and its ORIGIN — scheme, host and port, compared
 *   as parsed components — must equal one the application declared. A prefix
 *   is not a match, a port difference is not a match, and a URL carrying
 *   userinfo, a fragment, a control byte or a non-ASCII byte is refused
 *   before it is parsed.
 * - `method` defaults to `GET` when absent.
 * - `headers` is an ALLOWLIST on the native side: `accept`,
 *   `accept-language`, `authorization`, `content-type`, `if-match`,
 *   `if-none-match`, `if-modified-since`, plus any `x-`-prefixed
 *   application header. Anything else is `invalid_request`, and so is a
 *   repeated name or a value carrying CR, LF or NUL.
 * - `body` is at most 1 MiB, and a body on `GET` or `HEAD` is refused.
 * - `timeoutMs` is a WALL-CLOCK total-request deadline: 10 s by default,
 *   30 s at most, and a larger value is refused rather than clamped. It is
 *   observed DURING the transfer, so a slow response is cancelled rather
 *   than waited out. */
export interface PWebFetchRequest {
  readonly url: string;
  readonly method?: PWebFetchMethod;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string;
  readonly timeoutMs?: number;
}

/** One response.
 *
 * - `headers` is an allowlist too — `content-type`, `content-length`,
 *   `etag`, `last-modified`, `retry-after`, `location` and `x-`-prefixed —
 *   and **`set-cookie` is never present**, so nothing here can reconstruct
 *   a jar the runtime refused to keep. `location` IS present, because a 3xx
 *   is returned rather than followed.
 * - exactly one of `bodyText` and `bodyBase64` is non-null: text when the
 *   body is valid UTF-8, base64 otherwise.
 * - `truncated` is `false` in every envelope this contract defines. It is
 *   reserved for a future streaming form and NEVER means "some of the body
 *   is here": a response too large to inline is a typed `service_error`
 *   with category `response_too_large_to_inline`, not a success with a null
 *   body. */
export interface PWebFetchResponse {
  readonly status: number;
  readonly ms: number;
  readonly bytes: number;
  readonly truncated: boolean;
  readonly headers: Readonly<Record<string, string>>;
  readonly bodyText: string | null;
  readonly bodyBase64: string | null;
}

/**
 * Perform ONE bounded outbound request through the native door.
 *
 * Rejects with {@link PWebError}: `forbidden` when the application does not
 * hold `network.fetch` (with zero network activity — the policy runs before
 * the door is reached), `invalid_request` for anything the request contract
 * refuses, `cancelled` when the deadline expires, and `service_error` with
 * a category in `data` for a transport failure or a response over a bound.
 */
export async function httpFetch(
  request: PWebFetchRequest,
): Promise<PWebFetchResponse> {
  if (request === null || typeof request !== "object") {
    throw new PWebError("invalid_request", "A fetch request object is required");
  }
  // the args object is built key by key, and an ABSENT option is absent
  // rather than null: the native door refuses an argument of the wrong
  // type, and sending `method: undefined` would be sending one
  const args: Record<string, JsonValue> = { url: request.url as JsonValue };
  if (request.method !== undefined) {
    args.method = request.method;
  }
  if (request.headers !== undefined) {
    args.headers = request.headers as unknown as JsonValue;
  }
  if (request.body !== undefined) {
    args.body = request.body;
  }
  if (request.timeoutMs !== undefined) {
    args.timeoutMs = request.timeoutMs;
  }
  const value = await invoke(PWEB_METHOD_FETCH, args);
  return value as unknown as PWebFetchResponse;
}
