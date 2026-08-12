import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { PWebError, toPWebError } from "../src/errors.js";
import { invoke, isPWebRuntime } from "../src/invoke.js";
import { JsonValue } from "../src/types.js";
import { captured, envelope, installFake, installRaw, removeFake } from "./support.js";

afterEach(removeFake);

async function expectPWebError(
  p: Promise<unknown>,
  code: string,
): Promise<PWebError> {
  try {
    await p;
  } catch (err) {
    assert.ok(err instanceof PWebError, `expected PWebError, got ${String(err)}`);
    assert.equal(err.code, code);
    return err;
  }
  assert.fail(`expected rejection with code ${code}, but the promise resolved`);
}

test("integer success resolves 42", async () => {
  installFake(async () => 42);
  const value = await invoke<number>("CalculatorService.Add", { a: 20, b: 22 });
  assert.equal(value, 42);
});

test("all JSON success shapes pass through unchanged", async () => {
  const shapes: JsonValue[] = [
    { user: "ada", roles: ["admin"] },
    [1, "two", null, { three: 3 }],
    "plain string",
    true,
    false,
    0,
    3.5,
    null,
  ];
  for (const shape of shapes) {
    installFake(async () => shape);
    const value = await invoke("Any.Method", null);
    assert.deepEqual(value, shape);
    removeFake();
  }
});

test("null success resolves null — distinct from an error", async () => {
  installFake(async () => null);
  const value = await invoke("Void.Method", {});
  assert.equal(value, null);
});

test("a success value shaped like an error envelope is still a success", async () => {
  const suspicious = envelope("forbidden", "Invocation is not allowed", 403, null);
  installFake(async () => suspicious);
  const value = await invoke("Metadata.ErrorTable", null);
  assert.deepEqual(value, suspicious);
});

test("method identity passes through byte-exact — no case folding", async () => {
  installFake(async () => null);
  await invoke("calculatorService.add", null);
  await invoke("CalculatorService.Add", null);
  assert.equal(captured[0]!.method, "calculatorService.add");
  assert.equal(captured[1]!.method, "CalculatorService.Add");
});

test("argument keys, casing, and null values pass through unchanged", async () => {
  installFake(async () => null);
  const args = { A: 1, a: 2, Weird_KEY: null, nested: { Inner: [1, 2] } };
  await invoke("Svc.Method", args);
  assert.deepEqual(captured[0]!.args, args);
  // same object identity — the SDK does not clone or rewrite arguments
  assert.equal(captured[0]!.args, args);
});

test("omitted and null args are both sent as null", async () => {
  installFake(async () => null);
  await invoke("Svc.NoArgs");
  await invoke("Svc.NullArgs", null);
  assert.equal(captured[0]!.args, null);
  assert.equal(captured[1]!.args, null);
});

test("service_error preserves structured data", async () => {
  const data = { domainCode: "insufficient_funds", balance: 12.5 };
  installFake(async () => {
    throw envelope("service_error", "Insufficient funds", 422, data);
  });
  const err = await expectPWebError(invoke("Bank.Withdraw", { amount: 100 }), "service_error");
  assert.equal(err.message, "Insufficient funds");
  assert.equal(err.status, 422);
  assert.deepEqual(err.data, data);
});

test("internal_error stays redacted — data null, no added detail", async () => {
  installFake(async () => {
    throw envelope("internal_error", "Internal error", 500, null);
  });
  const err = await expectPWebError(invoke("Svc.Blows"), "internal_error");
  assert.equal(err.message, "Internal error");
  assert.equal(err.status, 500);
  assert.equal(err.data, null);
});

test("busy metadata (data.retryAfterMs) is preserved", async () => {
  installFake(async () => {
    throw envelope("busy", "Runtime is busy", 429, { retryAfterMs: 250 });
  });
  const err = await expectPWebError(invoke("Svc.Busy"), "busy");
  assert.deepEqual(err.data, { retryAfterMs: 250 });
});

test("every frozen code maps through with its envelope fields", async () => {
  const codes: Array<[string, number]> = [
    ["invalid_request", 400],
    ["method_not_found", 404],
    ["forbidden", 403],
    ["busy", 429],
    ["cancelled", 499],
    ["service_error", 422],
    ["internal_error", 500],
    ["runtime_closed", 503],
    ["protocol_mismatch", 426],
  ];
  for (const [code, status] of codes) {
    installFake(async () => {
      throw envelope(code, `msg ${code}`, status, null);
    });
    const err = await expectPWebError(invoke("Svc.Method"), code);
    assert.equal(err.message, `msg ${code}`);
    assert.equal(err.status, status);
    removeFake();
  }
});

test("status is informative only — an absent status falls back per code, code still discriminates", async () => {
  installFake(async () => {
    throw { code: "forbidden", message: "no", data: null };
  });
  const err = await expectPWebError(invoke("Svc.Method"), "forbidden");
  assert.equal(err.status, 403); // frozen-table fallback, not a discriminator
});

test("status presence rule: integers preserved (negative included), non-integers fall back", async () => {
  const cases: Array<[unknown, number]> = [
    [418, 418], // any integer passes through as received
    [-7, -7],
    ["500", 403], // mistyped -> frozen default for the code
    [1.5, 403],
    [Number.NaN, 403],
  ];
  for (const [wireStatus, expected] of cases) {
    installFake(async () => {
      throw { code: "forbidden", message: "no", status: wireStatus, data: null };
    });
    const err = await expectPWebError(invoke("Svc.Method"), "forbidden");
    assert.equal(err.status, expected, `status ${String(wireStatus)}`);
    removeFake();
  }
});

test("an already-typed PWebError rejection passes through unchanged", async () => {
  const original = new PWebError("busy", "custom", 429, { retryAfterMs: 9 });
  installFake(async () => {
    throw original;
  });
  const err = await expectPWebError(invoke("Svc.Method"), "busy");
  assert.equal(err, original);
  assert.equal(toPWebError(original), original);
});

test("a primitive resolving undefined is normalized to null", async () => {
  installFake(async () => undefined as unknown as JsonValue);
  const value = await invoke("Svc.Method", null);
  assert.equal(value, null);
});

test("isPWebRuntime reports presence truthfully in both directions", () => {
  removeFake();
  assert.equal(isPWebRuntime(), false);
  installFake(async () => null);
  assert.equal(isPWebRuntime(), true);
  installRaw("not a function");
  assert.equal(isPWebRuntime(), false);
});

test("malformed rejection payloads map to a local internal_error without leaking content", async () => {
  const malformed: unknown[] = [
    new Error("Failed to parse binding result as JSON"), // upstream shim path
    "raw string reason",
    12345,
    null,
    undefined,
    { notAnEnvelope: true },
    { code: "unauthorized", message: "not a v1 code", status: 401 },
    { code: 42 },
    ["array", "reason"],
  ];
  for (const reason of malformed) {
    installFake(async () => {
      throw reason;
    });
    const err = await expectPWebError(invoke("Svc.Method"), "internal_error");
    assert.equal(err.message, "Internal error"); // generic — nothing copied over
    assert.equal(err.data, null);
    removeFake();
  }
});

test("absent binding rejects immediately with runtime_closed — no hang, no fallback", async () => {
  removeFake();
  const err = await expectPWebError(invoke("CalculatorService.Add", { a: 20, b: 22 }), "runtime_closed");
  assert.ok(err.message.length > 0);
});

test("a non-function global is not treated as the primitive", async () => {
  installRaw({ invoke: "not callable" });
  await expectPWebError(invoke("Svc.Method"), "runtime_closed");
});

test("a synchronously-throwing primitive settles the promise with internal_error", async () => {
  installRaw(() => {
    throw new Error("native blew up synchronously");
  });
  const err = await expectPWebError(invoke("Svc.Method"), "internal_error");
  assert.equal(err.message, "Internal error");
});

test("invalid SDK input is rejected locally before crossing the primitive", async () => {
  installFake(async () => 1);
  await expectPWebError(invoke(""), "invalid_request");
  await expectPWebError(
    invoke("Svc.Method", [1, 2] as unknown as { [k: string]: JsonValue }),
    "invalid_request",
  );
  assert.equal(captured.length, 0); // nothing crossed the wire
});

test("the SDK performs no capability-authority logic — every call crosses to native", async () => {
  // even a method a cached capability list would 'deny' is sent; the
  // backend policy is authoritative and answers forbidden itself
  installFake(async () => {
    throw envelope("forbidden", "Invocation is not allowed", 403, null);
  });
  await expectPWebError(invoke("secrets.read", {}), "forbidden");
  assert.equal(captured.length, 1);
  assert.equal(captured[0]!.method, "secrets.read");
});
