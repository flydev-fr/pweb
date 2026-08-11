/**
 * Wire-capture emitter for the cross-SDK parity gate.
 *
 * Performs the canonical list of logical calls through the REAL SDK entry
 * points against a capturing fake primitive, then prints the exact
 * captured wire requests (method + args, JSON-serialized the same way the
 * page shim would) between markers. The Pas2JS harness emits the same
 * list from its SDK; CI asserts semantic equality — method identical,
 * args JSON-equivalent, and no frontend-identifying field anywhere.
 */
import { handshake } from "../src/handshake.js";
import { invoke } from "../src/invoke.js";
import { captured, installFake } from "./support.js";

async function main(): Promise<void> {
  installFake(async (method) =>
    method === "pweb.handshake"
      ? { protocol: 1, runtime: "0.1.0", capabilities: [] }
      : 42,
  );
  await handshake();
  await invoke("CalculatorService.Add", { a: 20, b: 22 });
  await invoke("CalculatorService.Add", { b: 22, a: 20 });
  await invoke("CaseSensitive.MiXeD", {
    Weird_KEY: null,
    list: [1, "two", false, null],
    nested: { Inner: { deep: 3.5 } },
  });
  await invoke("Svc.NoArgs");
  const lines = captured.map((c) =>
    JSON.stringify({ method: c.method, args: c.args }),
  );
  console.log("PWEBSDK_CAPTURE_BEGIN");
  for (const line of lines) {
    console.log(line);
  }
  console.log("PWEBSDK_CAPTURE_END");
}

main().catch((err) => {
  console.error("capture failed:", err);
  process.exitCode = 1;
});
