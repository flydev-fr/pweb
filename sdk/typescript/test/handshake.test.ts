import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { PWebError } from "../src/errors.js";
import {
  handshake,
  PWEB_METHOD_HANDSHAKE,
  PWEB_PROTOCOL_VERSION,
} from "../src/handshake.js";
import { invoke } from "../src/invoke.js";
import { JsonValue } from "../src/types.js";
import { captured, envelope, installFake, removeFake } from "./support.js";

afterEach(removeFake);

async function expectMismatch(p: Promise<unknown>): Promise<PWebError> {
  try {
    await p;
  } catch (err) {
    assert.ok(err instanceof PWebError);
    assert.equal(err.code, "protocol_mismatch");
    return err;
  }
  assert.fail("expected protocol_mismatch rejection");
}

test("compatible handshake resolves the runtime info", async () => {
  installFake(async () => ({
    protocol: 1,
    runtime: "0.1.0",
    capabilities: ["settings.read"],
  }));
  const info = await handshake();
  assert.equal(info.protocol, PWEB_PROTOCOL_VERSION);
  assert.equal(info.runtime, "0.1.0");
  assert.deepEqual(info.capabilities, ["settings.read"]);
  assert.equal(captured[0]!.method, PWEB_METHOD_HANDSHAKE);
  assert.equal(captured[0]!.args, null);
});

test("capabilities may be absent — still compatible", async () => {
  installFake(async () => ({ protocol: 1, runtime: "0.1.0" }));
  const info = await handshake();
  assert.equal(info.capabilities, undefined);
});

test("unknown handshake members are stripped from the resolved projection", async () => {
  installFake(async () => ({
    protocol: 1,
    runtime: "0.1.0",
    capabilities: [],
    extra: "sneaky",
  }));
  const info = await handshake();
  assert.deepEqual(Object.keys(info).sort(), ["capabilities", "protocol", "runtime"]);
});

test("unsupported protocol rejects with protocol_mismatch", async () => {
  installFake(async () => ({ protocol: 2, runtime: "9.9.9", capabilities: [] }));
  await expectMismatch(handshake());
});

test("malformed handshake payloads reject with protocol_mismatch", async () => {
  const payloads: JsonValue[] = [
    null,
    42,
    "not an object",
    [1],
    {},
    { protocol: "1", runtime: "0.1.0" },
    { protocol: 1.5, runtime: "0.1.0" },
    { protocol: 1 },
    { protocol: 1, runtime: "" },
    { protocol: 1, runtime: "0.1.0", capabilities: "all" },
    { protocol: 1, runtime: "0.1.0", capabilities: [1, 2] },
  ];
  for (const payload of payloads) {
    installFake(async () => payload);
    await expectMismatch(handshake());
    removeFake();
  }
});

test("a native rejection during handshake surfaces as its own PWebError, untranslated", async () => {
  installFake(async () => {
    throw envelope("runtime_closed", "Runtime is closed", 503, null);
  });
  try {
    await handshake();
    assert.fail("expected rejection");
  } catch (err) {
    assert.ok(err instanceof PWebError);
    assert.equal(err.code, "runtime_closed");
  }
});

test("handshake capabilities are advisory — invocations still cross regardless", async () => {
  installFake(async (method) => {
    if (method === PWEB_METHOD_HANDSHAKE) {
      return { protocol: 1, runtime: "0.1.0", capabilities: [] };
    }
    return 42;
  });
  const info = await handshake();
  assert.deepEqual(info.capabilities, []);
  // empty advisory list — the SDK must still send the call; authorization
  // is the native policy's job on every invocation
  const value = await invoke<number>("CalculatorService.Add", { a: 20, b: 22 });
  assert.equal(value, 42);
  assert.equal(captured.length, 2);
});
