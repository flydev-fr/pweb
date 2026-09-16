/**
 * `@pweb/runtime` — the blob data plane's READ surface (CAP-12B).
 *
 * A TYPE, and a shape check. Nothing else, and both halves of that are
 * deliberate.
 *
 * NO READER. This package holds the CAP-5 bar that no SDK source contains a
 * browser network primitive of any kind, and a helper that loaded a blob
 * would be exactly that. It is also not needed: a blob is an ordinary
 * same-origin resource at `handle.url`, served by the same production
 * `pweb://app` handler that serves the application's own assets, so the page
 * reads it the way it reads anything else it ships - an image element, a
 * media element where the engine supports one, or the browser's own request
 * API, with a `Range` header when it wants a window. The runtime answers a
 * single range with 206 and `Content-Range`, a range it declines
 * (multi-range, or a syntax it does not implement) with the WHOLE body and
 * 200, and an unsatisfiable range with 416 and the real length.
 *
 * NO WRITER. CAP-12A §6.2 ratified a typed-array `PUT` to the blob plane as
 * the JS->native transport and left the SDK that drives it to CAP-12C. A
 * convenience that created blobs would be a surface this package cannot yet
 * keep.
 *
 * THIS FILE NEVER BUILDS A BLOB URL. `handle.url` comes from the runtime,
 * which is the only place in the product that knows both the store's
 * spelling and the URL's. An SDK that concatenated a prefix would be a
 * second answer to the namespace question, and it would be the answer a
 * page could be talked into changing.
 *
 * LIFETIME IS THE RUNTIME'S. A blob dies with the document that owns it —
 * a navigation, a reload, a development generation switch — and with the
 * capability that governs it, and at shutdown. A handle kept across a
 * navigation resolves to nothing, which is a 404 and not something this
 * package can prevent. A foreign principal's token, a released token and a
 * token that never existed all look identical from here, by design.
 */

/** One blob the runtime is holding for this principal — what a
 * `pweb.fetch` envelope carries in `blob` when a response was too large to
 * inline.
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

/** True when `value` has the shape of a blob handle the runtime minted.
 *
 * A SHAPE CHECK and nothing more: it cannot tell a live handle from one
 * whose document has since been replaced, because only the runtime knows
 * that, and it answers by serving or not serving `url`. */
export function isPWebBlobHandle(value: unknown): value is PWebBlobHandle {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const h = value as Partial<PWebBlobHandle>;
  return typeof h.token === "string" &&
    /^[0-9a-f]{32}$/.test(h.token) &&
    typeof h.url === "string" && h.url !== "" &&
    typeof h.size === "number" && Number.isInteger(h.size) && h.size >= 0 &&
    typeof h.type === "string" && h.type !== "";
}
