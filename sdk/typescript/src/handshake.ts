import { PWebError } from "./errors.js";
import { invoke } from "./invoke.js";
import { JsonValue, PWebRuntimeInfo } from "./types.js";

/** Wire protocol version this SDK speaks. Mirrors the native
 * `PWEB_PROTOCOL_VERSION` in `src/rpc/pweb.rpc.intf.pas`; CI cross-checks
 * the two constants so they can never drift silently. */
export const PWEB_PROTOCOL_VERSION = 1;

/** Protocols this SDK accepts — set membership, never an ordering
 * comparison (wire-semantics.md "Protocol version"). */
export const PWEB_SDK_SUPPORTED_PROTOCOLS: readonly number[] = [
  PWEB_PROTOCOL_VERSION,
];

/** Runtime-owned handshake method (reserved `pweb.*` namespace). */
export const PWEB_METHOD_HANDSHAKE = "pweb.handshake";

function mismatch(detail: string): PWebError {
  return new PWebError("protocol_mismatch", `PWeb protocol mismatch: ${detail}`);
}

/**
 * Perform the runtime handshake and verify protocol compatibility.
 *
 * Calls `pweb.handshake` through the same native primitive as every other
 * invocation. Resolves with the runtime info when the reported protocol is
 * one this SDK supports; rejects with `protocol_mismatch` when the
 * protocol is unsupported OR the payload is not a well-formed handshake
 * response (a runtime whose handshake cannot be understood is by
 * definition not protocol-compatible). Applications should gate their
 * startup on this and must not continue against an incompatible runtime.
 *
 * `capabilities` in the result is advisory frontend metadata only — it is
 * never authorization state, and the SDK performs no client-side
 * allow/deny based on it. Native `ICapabilityPolicy` remains authoritative
 * on every invocation.
 */
export async function handshake(): Promise<PWebRuntimeInfo> {
  const raw = await invoke<JsonValue>(PWEB_METHOD_HANDSHAKE, null);
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw mismatch("handshake response is not an object");
  }
  const info = raw as { [key: string]: JsonValue };
  const protocol = info["protocol"];
  if (typeof protocol !== "number" || !Number.isInteger(protocol)) {
    throw mismatch("handshake response carries no integer protocol");
  }
  if (!PWEB_SDK_SUPPORTED_PROTOCOLS.includes(protocol)) {
    throw mismatch(
      `runtime protocol ${protocol} is not supported by this SDK ` +
        `(supported: ${PWEB_SDK_SUPPORTED_PROTOCOLS.join(", ")})`,
    );
  }
  const runtime = info["runtime"];
  if (typeof runtime !== "string" || runtime === "") {
    throw mismatch("handshake response carries no runtime version");
  }
  const capabilities = info["capabilities"];
  if (capabilities !== undefined) {
    if (
      !Array.isArray(capabilities) ||
      capabilities.some((c) => typeof c !== "string")
    ) {
      throw mismatch("handshake capabilities member is malformed");
    }
  }
  const result: { protocol: number; runtime: string; capabilities?: readonly string[] } = {
    protocol,
    runtime,
  };
  if (capabilities !== undefined) {
    result.capabilities = capabilities as readonly string[];
  }
  return result;
}
