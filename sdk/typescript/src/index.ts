/**
 * @pweb/runtime — the PWeb TypeScript frontend SDK (CAP-5).
 *
 * A thin, dependency-free adapter over the native invocation primitive
 * installed by the PWeb runtime (CAP-2 binding). One wire, one binding,
 * one scheduler, one capability path: this SDK's responsibility ends at
 * the primitive. It contains no HTTP client, no fallback transport, and
 * no capability logic.
 *
 * `httpFetch` (CAP-15B) is not an exception to that: it is one `invoke` of
 * the runtime-owned `pweb.fetch`, and every policy it appears to carry -
 * the origin allowlist, the method and header allowlists, the bounds, the
 * deadline, the refusal to follow a redirect or keep a cookie - is NATIVE.
 * Nothing in this package opens a socket or names an origin.
 *
 * Deliberately absent: event and window APIs — protocol v1 has no backend
 * contract behind them, and this package does not invent surfaces. Also
 * deliberately absent: a cancellation surface (e.g. AbortSignal) —
 * protocol v1 has no frontend-initiated cancellation; cancellation
 * originates native-side (source quiesce/teardown) and surfaces here only
 * as the `cancelled` error code.
 */
export { invoke, isPWebRuntime, PWEB_NATIVE_BINDING_NAME } from "./invoke.js";
export {
  handshake,
  PWEB_METHOD_HANDSHAKE,
  PWEB_PROTOCOL_VERSION,
  PWEB_SDK_SUPPORTED_PROTOCOLS,
} from "./handshake.js";
export {
  httpFetch,
  PWEB_METHOD_FETCH,
  PWEB_CAP_NETWORK_FETCH,
} from "./http.js";
export type {
  PWebFetchMethod,
  PWebFetchRequest,
  PWebFetchResponse,
} from "./http.js";
export { PWebError, toPWebError } from "./errors.js";
export {
  PWEB_ERROR_CODES,
  PWEB_ERROR_STATUS,
} from "./types.js";
export type {
  InvokeArgs,
  JsonValue,
  PWebErrorCode,
  PWebNativePrimitive,
  PWebRuntimeInfo,
} from "./types.js";
