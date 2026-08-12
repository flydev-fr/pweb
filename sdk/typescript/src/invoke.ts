import { PWebError, toPWebError } from "./errors.js";
import { InvokeArgs, JsonValue, PWebNativePrimitive } from "./types.js";

/** JS global name of the native invocation primitive bound by the CAP-2
 * binding (`webview_bind`). An internal transport detail — applications
 * use `invoke()`, never this global directly. */
export const PWEB_NATIVE_BINDING_NAME = "__pweb_invoke";

function nativePrimitive(): PWebNativePrimitive | null {
  const candidate = (globalThis as { [key: string]: unknown })[
    PWEB_NATIVE_BINDING_NAME
  ];
  return typeof candidate === "function"
    ? (candidate as PWebNativePrimitive)
    : null;
}

/** True when the PWeb native binding is present in this JS context.
 * Detection only — never a capability statement. */
export function isPWebRuntime(): boolean {
  return nativePrimitive() !== null;
}

/**
 * Invoke a PWeb method through the native binding.
 *
 * - `method` passes through byte-exact (`Service.Method`, case-sensitive;
 *   the backend is authoritative for validation — the SDK never
 *   canonicalizes, folds case, or rewrites the identity).
 * - `args` is a named-arguments object or null/undefined (both sent as
 *   JSON null). Keys pass through exactly as supplied.
 * - Resolves with whatever JSON value the service produced — object,
 *   array, string, number, boolean, or null. A success value that looks
 *   like an error envelope is still a success.
 * - Rejects with {@link PWebError}; when the native binding is absent the
 *   promise rejects immediately with code `runtime_closed` (there is no
 *   fallback transport and no hung promise).
 */
export function invoke<T extends JsonValue = JsonValue>(
  method: string,
  args?: InvokeArgs,
): Promise<T> {
  if (typeof method !== "string" || method === "") {
    return Promise.reject(
      new PWebError("invalid_request", "Method must be a non-empty string"),
    );
  }
  const wireArgs: InvokeArgs = args === undefined || args === null ? null : args;
  if (wireArgs !== null && (typeof wireArgs !== "object" || Array.isArray(wireArgs))) {
    return Promise.reject(
      new PWebError(
        "invalid_request",
        "Arguments must be a named-argument object or null",
      ),
    );
  }
  const primitive = nativePrimitive();
  if (primitive === null) {
    return Promise.reject(
      new PWebError("runtime_closed", "PWeb native binding is not available"),
    );
  }
  return new Promise<T>((resolve, reject) => {
    let raw: Promise<JsonValue>;
    try {
      raw = Promise.resolve(primitive(method, wireArgs));
    } catch {
      reject(new PWebError("internal_error"));
      return;
    }
    raw.then(
      // a conforming runtime never resolves undefined (JSON null is the
      // literal null); normalize defensively so the JsonValue-typed
      // surface never carries a non-JSON value
      (value) => resolve((value === undefined ? null : value) as T),
      (reason) => reject(toPWebError(reason)),
    );
  });
}
