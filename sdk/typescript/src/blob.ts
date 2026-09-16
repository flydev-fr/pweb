/**
 * `@pweb/runtime` — the blob data plane's READ surface (CAP-12B).
 *
 * A type and one reader, and deliberately nothing else. There is no
 * `create`, no `put` and no upload here: CAP-12A §6.2 ratified
 * `fetch(PUT pweb://…)` with a typed-array body as the JS→native transport
 * and left the SDK that drives it to CAP-12C. A convenience that wrote
 * blobs would be a surface this package cannot yet keep.
 *
 * THIS FILE NEVER BUILDS A BLOB URL. `handle.url` comes from the runtime,
 * which is the only place in the product that knows both the store's
 * spelling and the URL's. An SDK that concatenated a prefix would be a
 * second answer to the namespace question, and it would be the answer a
 * page could be talked into changing.
 *
 * WHAT A BLOB IS, from here: bytes the runtime holds for THIS principal,
 * addressed by a 128-bit token, readable at `handle.url` through the same
 * production `pweb://app` handler that serves the application's assets —
 * so `fetch`, `<img src>` and (where the engine supports it) a media
 * element all work on it without this package transporting a byte. It is
 * not a `Blob`: it never enters the page's memory unless the page asks for
 * it, and asking for a window of it is one `Range` header.
 *
 * LIFETIME IS THE RUNTIME'S. A blob dies with the document that owns it —
 * a navigation, a reload, a development generation switch — and with the
 * capability that governs it, and at shutdown. A handle kept across a
 * navigation resolves to nothing, which is a 404 and not an error this
 * package can prevent.
 */
import { PWebError } from "./errors.js";

/** The blob capability surface is READ-ONLY in v1: no method name here,
 * because reading a blob is not an `invoke` at all — it is an ordinary
 * same-origin `fetch` of a URL the runtime handed out. */

/** One blob the runtime is holding for this principal.
 *
 * - `token` is 32 lowercase hexadecimal characters — exactly 128 bits.
 *   It is an identifier, never an authorization: the runtime checks the
 *   owner too, and a token belonging to another principal is answered
 *   exactly as an unknown one is.
 * - `url` is where the bytes are, built by the runtime. Use it; do not
 *   derive it.
 * - `size` is the whole length in bytes.
 * - `type` is the Content-Type the blob was sealed with, served verbatim.
 *   It never comes from a path extension. */
export interface PWebBlobHandle {
  readonly token: string;
  readonly url: string;
  readonly size: number;
  readonly type: string;
}

/** Options for {@link readBlob}. */
export interface PWebBlobReadOptions {
  /** Read only `[offset, offset + length)`. Both are byte counts and both
   * are optional; giving `offset` alone reads to the end.
   *
   * The runtime answers a single range with `206` and a `Content-Range`,
   * and answers a range it declines — a multi-range, or a syntax it does
   * not implement — with the WHOLE body and `200`. So a caller that asked
   * for a window must check what it got rather than assume, which is what
   * this function does on its behalf. */
  readonly offset?: number;
  readonly length?: number;
}

/** True when `value` has the shape of a blob handle the runtime minted. */
export function isPWebBlobHandle(value: unknown): value is PWebBlobHandle {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const h = value as Partial<PWebBlobHandle>;
  return typeof h.token === "string" &&
    /^[0-9a-f]{32}$/.test(h.token) &&
    typeof h.url === "string" && h.url !== "" &&
    typeof h.size === "number" &&
    typeof h.type === "string";
}

/**
 * Read a blob, whole or by window.
 *
 * Resolves with the bytes. Rejects with {@link PWebError}:
 * `invalid_request` for a handle this package cannot recognise or a window
 * that is not a pair of non-negative integers, and `service_error` when the
 * runtime did not serve the resource — which is what a released token, a
 * token belonging to another principal and a token that never existed all
 * look like from here, deliberately and identically.
 *
 * WHEN A WINDOW IS ASKED FOR AND THE WHOLE BODY ARRIVES, this function
 * slices it rather than pretending: the runtime is allowed to decline a
 * range, so a caller asking for the last megabyte of an eight-megabyte
 * blob must end up with that megabyte either way. What it will never do is
 * return FEWER bytes than the window it was asked for without saying so —
 * a short read past the end of the blob is the caller's arithmetic, and
 * the length that comes back is the truth about it.
 */
export async function readBlob(
  handle: PWebBlobHandle | string,
  options: PWebBlobReadOptions = {},
): Promise<ArrayBuffer> {
  const url = typeof handle === "string" ? handle : handle?.url;
  if (typeof url !== "string" || url === "") {
    throw new PWebError(
      "invalid_request",
      "A blob handle, or the URL from one, is required",
    );
  }
  const { offset, length } = options;
  for (const [name, v] of [["offset", offset], ["length", length]] as const) {
    if (v === undefined) {
      continue;
    }
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
      throw new PWebError(
        "invalid_request",
        `${name} must be a non-negative integer`,
      );
    }
  }
  const init: RequestInit = {};
  let wantOffset = 0;
  let ranged = false;
  if (offset !== undefined || length !== undefined) {
    wantOffset = offset ?? 0;
    // the grammar the runtime implements, and nothing wider: a single
    // range or a suffix range. A caller wanting two windows asks twice.
    const last = length === undefined ? "" : String(wantOffset + length - 1);
    init.headers = { Range: `bytes=${wantOffset}-${last}` };
    ranged = true;
  }
  let response: Response;
  try {
    response = await fetch(url, init);
  } catch (cause) {
    throw new PWebError(
      "service_error",
      "the blob could not be read",
      undefined,
      { reason: String((cause as Error)?.message ?? cause) },
    );
  }
  if (!response.ok) {
    throw new PWebError(
      "service_error",
      `the blob could not be read (status ${response.status})`,
      undefined,
      { status: response.status },
    );
  }
  const bytes = await response.arrayBuffer();
  if (!ranged || response.status === 206) {
    return bytes;
  }
  // 200 to a ranged request: the runtime declined the range and sent the
  // whole resource, which is a documented answer rather than a failure.
  const end = length === undefined ? bytes.byteLength : wantOffset + length;
  return bytes.slice(Math.min(wantOffset, bytes.byteLength),
    Math.min(end, bytes.byteLength));
}
