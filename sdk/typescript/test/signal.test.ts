import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { PWebError } from "../src/errors.js";
import {
  lastSeq,
  offSignal,
  onSignal,
  PWEB_METHOD_SIGNAL_SUBSCRIBE,
  PWEB_METHOD_SIGNAL_UNSUBSCRIBE,
  PWEB_SIGNAL_EVENT,
  PWEB_SIGNAL_TOPIC_SOCKET,
} from "../src/signal.js";
import {
  PWEB_METHOD_SOCKET_OPEN,
  PWEB_METHOD_SOCKET_RECEIVE,
  PWEB_SOCKET_KEEPALIVE_MS,
  PWebSocket,
} from "../src/socket.js";
import { InvokeArgs, JsonValue } from "../src/types.js";
import { captured, envelope, installFake, removeFake } from "./support.js";

// THE PAGE'S WINDOW, played by the test: node's global object has no
// addEventListener, so the one the SDK installs its listener on is this
type Listener = (event: unknown) => void;
const listeners: { type: string; listener: Listener }[] = [];
(globalThis as unknown as { addEventListener: unknown }).addEventListener = (
  type: string,
  listener: Listener,
): void => {
  listeners.push({ type, listener });
};

// what the runtime's one injected script does, and nothing more
function signal(detail: unknown): void {
  for (const l of listeners) {
    if (l.type === PWEB_SIGNAL_EVENT) {
      l.listener({ detail });
    }
  }
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(removeFake);

function answering(seqs: Record<string, number>): (method: string, args: InvokeArgs) => Promise<JsonValue> {
  return async (method, args) => {
    const topic = (args as { topic: string } | null)?.topic ?? "";
    if (method === PWEB_METHOD_SIGNAL_SUBSCRIBE) {
      if (!(topic in seqs)) {
        throw envelope("forbidden", "Invocation is not allowed", 403, null);
      }
      return { topic, seq: seqs[topic] ?? 0 };
    }
    return {};
  };
}

test("the first callback subscribes once; ready carries the sequence", async () => {
  installFake(answering({ "t1.jobs": 7 }));
  const seen: number[] = [];
  const a = onSignal("t1.jobs", (seq) => seen.push(seq));
  const b = onSignal("t1.jobs", (seq) => seen.push(seq * 10));
  assert.equal(await a.ready, 7);
  assert.equal(await b.ready, 7);
  assert.equal(captured.filter((c) => c.method === PWEB_METHOD_SIGNAL_SUBSCRIBE).length, 1);
  assert.deepEqual(captured[0]!.args, { topic: "t1.jobs" });
  assert.equal(lastSeq("t1.jobs"), 7);
  signal([["t1.jobs", 8]]);
  assert.deepEqual(seen, [8, 80]);
  a.off();
  b.off();
});

test("the sequence is what is trusted: old, repeated and malformed pairs are ignored", async () => {
  installFake(answering({ "t2.jobs": 5, "t2.logs": 0 }));
  const seen: string[] = [];
  const s = onSignal("t2.jobs", (seq, topic) => seen.push(`${topic}:${seq}`));
  const l = onSignal("t2.logs", (seq, topic) => seen.push(`${topic}:${seq}`));
  await s.ready;
  await l.ready;
  signal([["t2.jobs", 4]]); // older than the subscription's
  signal([["t2.jobs", 5]]); // the same
  signal([["t2.jobs", 6], ["t2.logs", 1], ["t2.unknown", 9]]);
  signal([["t2.jobs", 6]]); // repeated
  for (const bad of [
    null, 42, "x", {}, [["t2.jobs"]], [["t2.jobs", 9, 1]], [[1, 9]],
    [["t2.jobs", "9"]], [["t2.jobs", -1]], [["t2.jobs", 9.5]],
    [["t2.jobs", Number.MAX_SAFE_INTEGER + 1]],
  ]) {
    signal(bad);
  }
  signal([["t2.jobs", 7]]);
  assert.deepEqual(seen, ["t2.jobs:6", "t2.logs:1", "t2.jobs:7"]);
  assert.equal(lastSeq("t2.jobs"), 7);
  assert.equal(lastSeq("t2.unknown"), undefined);
  s.off();
  l.off();
});

test("the last callback unsubscribes, once; off is idempotent", async () => {
  installFake(answering({ "t3.jobs": 0 }));
  const cb1 = (): void => undefined;
  let calls = 0;
  const cb2 = (): void => {
    calls++;
  };
  const a = onSignal("t3.jobs", cb1);
  onSignal("t3.jobs", cb2);
  await a.ready;
  a.off();
  a.off();
  assert.equal(captured.filter((c) => c.method === PWEB_METHOD_SIGNAL_UNSUBSCRIBE).length, 0);
  signal([["t3.jobs", 1]]);
  assert.equal(calls, 1);
  offSignal("t3.jobs", cb2);
  offSignal("t3.jobs", cb2);
  await tick();
  const unsubs = captured.filter((c) => c.method === PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
  assert.equal(unsubs.length, 1);
  assert.deepEqual(unsubs[0]!.args, { topic: "t3.jobs" });
  signal([["t3.jobs", 2]]);
  assert.equal(calls, 1, "a callback ran after it was removed");
  assert.equal(lastSeq("t3.jobs"), undefined);
});

test("a refused subscription rejects ready and leaves nothing behind", async () => {
  installFake(answering({}));
  let calls = 0;
  const s = onSignal("t4.secret", () => {
    calls++;
  });
  await assert.rejects(s.ready, (err: unknown) => err instanceof PWebError && err.code === "forbidden");
  signal([["t4.secret", 1]]);
  assert.equal(calls, 0);
  assert.equal(lastSeq("t4.secret"), undefined);
  // a later subscription asks again
  installFake(answering({ "t4.secret": 3 }));
  const again = onSignal("t4.secret", () => undefined);
  assert.equal(await again.ready, 3);
  again.off();
});

test("an answer without a sequence is an internal error", async () => {
  installFake(async () => ({ topic: "t5.jobs" }));
  const s = onSignal("t5.jobs", () => undefined);
  await assert.rejects(s.ready, (err: unknown) => err instanceof PWebError && err.code === "internal_error");
});

test("an argument that is not a topic or a callback is refused locally", () => {
  assert.throws(() => onSignal("", () => undefined), PWebError);
  assert.throws(() => onSignal("t6.jobs", 5 as unknown as () => void), PWebError);
  assert.equal(captured.length, 0);
});

test("a callback that throws does not stop the others", async () => {
  installFake(answering({ "t7.jobs": 0 }));
  let reached = false;
  const a = onSignal("t7.jobs", () => {
    throw new Error("boom");
  });
  const b = onSignal("t7.jobs", () => {
    reached = true;
  });
  await a.ready;
  signal([["t7.jobs", 1]]);
  assert.ok(reached);
  a.off();
  b.off();
});

test("the socket loop receives on the signal, never waits natively, and unsubscribes on close", async () => {
  const queue: JsonValue[][] = [[{ type: "open", protocol: "" }]];
  installFake(async (method, args) => {
    if (method === PWEB_METHOD_SOCKET_OPEN) {
      return { id: "s1" };
    }
    if (method === PWEB_METHOD_SIGNAL_SUBSCRIBE) {
      return { topic: PWEB_SIGNAL_TOPIC_SOCKET, seq: 0 };
    }
    if (method === PWEB_METHOD_SOCKET_RECEIVE) {
      return { events: queue.shift() ?? [] };
    }
    return {};
  });
  const got: string[] = [];
  // the URL is never read by the fake; no scheme is spelled in SDK sources
  const s = new PWebSocket("socket-url-under-test");
  s.onopen = (): void => {
    got.push("open");
  };
  s.onmessage = (e): void => {
    got.push(String(e.data));
  };
  s.onclose = (e): void => {
    got.push(`close:${e.code}`);
  };
  for (let i = 0; i < 20 && got.length === 0; i++) {
    await tick();
  }
  assert.deepEqual(got, ["open"]);
  const receivesAfterOpen = captured.filter((c) => c.method === PWEB_METHOD_SOCKET_RECEIVE).length;
  // quiet: no signal, no receive
  for (let i = 0; i < 10; i++) {
    await tick();
  }
  assert.equal(captured.filter((c) => c.method === PWEB_METHOD_SOCKET_RECEIVE).length, receivesAfterOpen,
    "a quiet socket received without a signal");
  // the native door queued an event: the window's topic moved
  queue.push([{ type: "message", text: "hello" }]);
  signal([[PWEB_SIGNAL_TOPIC_SOCKET, 1]]);
  for (let i = 0; i < 20 && got.length < 2; i++) {
    await tick();
  }
  assert.deepEqual(got, ["open", "hello"]);
  // every receive carried the id and nothing else: waitMs is retired, so the
  // loop can only ask for what is queued now
  for (const c of captured.filter((x) => x.method === PWEB_METHOD_SOCKET_RECEIVE)) {
    assert.deepEqual(Object.keys(c.args as object), ["id"]);
  }
  queue.push([{ type: "close", code: 1000, reason: "", wasClean: true, category: "remote", undelivered: 0 }]);
  signal([[PWEB_SIGNAL_TOPIC_SOCKET, 2]]);
  for (let i = 0; i < 20 && got.length < 3; i++) {
    await tick();
  }
  assert.deepEqual(got, ["open", "hello", "close:1000"]);
  for (let i = 0; i < 10; i++) {
    await tick();
  }
  assert.equal(captured.filter((c) => c.method === PWEB_METHOD_SIGNAL_UNSUBSCRIBE).length, 1,
    "a closed socket left its topic subscribed");
  assert.equal(lastSeq(PWEB_SIGNAL_TOPIC_SOCKET), undefined);
});

// THE KEEPALIVE IS WHAT KEEPS A QUIET SOCKET ALIVE. Nothing waits natively
// any more, so the door closes a socket it has not been polled from for
// PWEB_SOCKET_IDLE_MS, and the only thing that polls it is this timer. The
// test above proves a quiet socket does NOT receive early; this one proves it
// receives once the keepalive is due, with the clock under the test's control.
test("a quiet socket receives when the keepalive falls due", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const queue: JsonValue[][] = [[{ type: "open", protocol: "" }]];
  installFake(async (method) => {
    if (method === PWEB_METHOD_SOCKET_OPEN) {
      return { id: "s-keepalive" };
    }
    if (method === PWEB_METHOD_SIGNAL_SUBSCRIBE) {
      return { topic: PWEB_SIGNAL_TOPIC_SOCKET, seq: 0 };
    }
    if (method === PWEB_METHOD_SOCKET_RECEIVE) {
      return { events: queue.shift() ?? [] };
    }
    return {};
  });
  // the fake answers on microtasks, so draining them is what advances the loop
  const settle = async (): Promise<void> => {
    for (let i = 0; i < 50; i++) {
      await Promise.resolve();
    }
  };
  const opened: string[] = [];
  const s = new PWebSocket("socket-url-under-test");
  s.onopen = (): void => {
    opened.push("open");
  };
  await settle();
  assert.deepEqual(opened, ["open"]);
  const quiet = captured.filter((c) => c.method === PWEB_METHOD_SOCKET_RECEIVE).length;
  // one millisecond short of the keepalive: still nothing
  t.mock.timers.tick(PWEB_SOCKET_KEEPALIVE_MS - 1);
  await settle();
  assert.equal(captured.filter((c) => c.method === PWEB_METHOD_SOCKET_RECEIVE).length, quiet,
    "a socket received before its keepalive was due");
  t.mock.timers.tick(1);
  await settle();
  const after = captured.filter((c) => c.method === PWEB_METHOD_SOCKET_RECEIVE);
  assert.equal(after.length, quiet + 1,
    "the keepalive did not receive: the door would close this socket as idle");
  const last = after[after.length - 1];
  assert.ok(last !== undefined);
  assert.deepEqual(Object.keys(last.args as object), ["id"]);
  s.close();
  t.mock.timers.reset();
});
