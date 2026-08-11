/** Test-only fake of the native primitive. Installs/removes
 * `globalThis.__pweb_invoke` and records every crossing invocation so the
 * exact wire request (method + args) can be asserted and exported for the
 * cross-SDK parity gate. */
import { PWEB_NATIVE_BINDING_NAME } from "../src/invoke.js";
import { InvokeArgs, JsonValue } from "../src/types.js";

export interface CapturedCall {
  method: string;
  args: InvokeArgs;
}

export type FakeHandler = (
  method: string,
  args: InvokeArgs,
) => Promise<JsonValue>;

export const captured: CapturedCall[] = [];

const globalStore = globalThis as { [key: string]: unknown };

export function installFake(handler: FakeHandler): void {
  globalStore[PWEB_NATIVE_BINDING_NAME] = (
    method: string,
    args: InvokeArgs,
  ): Promise<JsonValue> => {
    captured.push({ method, args });
    return handler(method, args);
  };
}

/** Installs a raw value (possibly not a function, or a function that
 * throws/returns garbage) to probe the SDK's runtime boundary. */
export function installRaw(value: unknown): void {
  globalStore[PWEB_NATIVE_BINDING_NAME] = value;
}

export function removeFake(): void {
  delete globalStore[PWEB_NATIVE_BINDING_NAME];
  captured.length = 0;
}

/** The canonical envelope shape the CAP-2 binding rejects with. */
export function envelope(
  code: string,
  message: string,
  status: number,
  data: JsonValue,
): { [key: string]: JsonValue } {
  return { code, message, status, data };
}
