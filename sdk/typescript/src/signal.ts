/**
 * `@pweb/runtime` — the native signal channel (CAP-16).
 *
 * SIGNAL, THEN PULL. The runtime tells the page that a topic moved — the
 * topic's name and a sequence number, nothing else — and the page reads what
 * it needs through `invoke`, on the same capability path as every other call.
 * No data rides the channel, so a signal carries no authority: it only says
 * that now would be a good moment to read something the page was already
 * allowed to read.
 *
 * Subscribing is one invoke of `pweb.signalSubscribe`, authorised natively by
 * the capability `signal.<topic>` (the socket door's own topic, `pweb.socket`,
 * by `network.socket`). A topic the application never declared and a topic
 * the page may not read are the same refusal: `forbidden`.
 *
 * THE RECOVERY PATTERN. A signal may be lost — before the subscription
 * exists, across a navigation, across a development reload — and that costs
 * latency, never correctness, because the page never trusts a signal to
 * carry state:
 *
 *     const sub = onSignal("jobs", () => void refresh());
 *     await sub.ready;   // subscribed; resolves with the current sequence
 *     await refresh();   // read everything ONCE, after subscribing
 *
 *     async function refresh() {
 *       const page = await invoke("Jobs.Since", { since: cursor });
 *       cursor = page.next;   // YOUR cursor is the truth; the sequence is a wake-up
 *     }
 *
 * The sequence numbers are what this module trusts: a pair whose sequence is
 * not newer than the last one seen for its topic is ignored, whatever order
 * the engine delivered it in.
 *
 * WHAT THE RUNTIME SENDS is one script per tick, at most
 * `PWEB_SIGNAL_TICKS_PER_SECOND` a second, that dispatches a `pweb:signal`
 * DOM event on `window` whose `detail` is `[[topic, seq], ...]`. Nothing here
 * is a global function the runtime calls, so a page without this module has
 * no listener and the dispatch does nothing.
 */
import { invoke } from "./invoke.js";
import { PWebError, toPWebError } from "./errors.js";
import type { JsonValue } from "./types.js";

/** The runtime-owned methods, spelled once. */
export const PWEB_METHOD_SIGNAL_SUBSCRIBE = "pweb.signalSubscribe";
export const PWEB_METHOD_SIGNAL_UNSUBSCRIBE = "pweb.signalUnsubscribe";

/** The DOM event the runtime dispatches on `window`. */
export const PWEB_SIGNAL_EVENT = "pweb:signal";

/** The name `pweb.handshake` lists in `features` when the channel exists. */
export const PWEB_SIGNAL_FEATURE = "signal";

/** The socket door's window-scoped topic. */
export const PWEB_SIGNAL_TOPIC_SOCKET = "pweb.socket";

/** The native bounds this module must respect — cross-checked against
 * `src/rpc/pweb.rpc.signal.pas` by the CAP-16 contract gate. */
export const PWEB_SIGNAL_TICKS_PER_SECOND = 20;
export const PWEB_SIGNAL_MAX_SUBSCRIPTIONS = 32;
export const PWEB_SIGNAL_MAX_TOPIC_BYTES = 64;

/** Called with the topic's new sequence number. */
export type PWebSignalCallback = (seq: number, topic: string) => void;

export interface PWebSignalSubscription {
  readonly topic: string;
  /** Resolves with the topic's sequence once the native subscription
   * exists; rejects with a `PWebError` (`forbidden`, `invalid_request`,
   * `service_error` with category `signal_limit`, ...). */
  readonly ready: Promise<number>;
  /** Remove this callback. The native subscription goes with the last
   * callback of its topic. Idempotent. */
  off(): void;
}

interface TopicState {
  readonly callbacks: Set<PWebSignalCallback>;
  last: number | undefined;
  ready: Promise<number>;
}

type EventTargetLike = {
  addEventListener?: (type: string, listener: (event: unknown) => void) => void;
};

const topics = new Map<string, TopicState>();
let listening = false;

function listen(): void {
  if (listening) {
    return;
  }
  const target = globalThis as unknown as EventTargetLike;
  if (typeof target.addEventListener !== "function") {
    return;
  }
  target.addEventListener(PWEB_SIGNAL_EVENT, receive);
  listening = true;
}

function receive(event: unknown): void {
  const detail =
    event !== null && typeof event === "object"
      ? (event as { detail?: unknown }).detail
      : undefined;
  if (!Array.isArray(detail)) {
    return;
  }
  for (const pair of detail as unknown[]) {
    if (!Array.isArray(pair) || pair.length !== 2) {
      continue;
    }
    const topic: unknown = pair[0];
    const seq: unknown = pair[1];
    if (
      typeof topic !== "string" ||
      typeof seq !== "number" ||
      !Number.isSafeInteger(seq) ||
      seq < 0
    ) {
      continue;
    }
    deliver(topic, seq);
  }
}

function deliver(topic: string, seq: number): void {
  const state = topics.get(topic);
  if (state === undefined) {
    return;
  }
  // THE SEQUENCE IS WHAT IS TRUSTED: an old or repeated one says nothing new
  if (state.last !== undefined && seq <= state.last) {
    return;
  }
  state.last = seq;
  for (const callback of [...state.callbacks]) {
    try {
      callback(seq, topic);
    } catch {
      // one callback never stops the others
    }
  }
}

function release(topic: string, owner: TopicState, callback: PWebSignalCallback): void {
  owner.callbacks.delete(callback);
  if (owner.callbacks.size > 0 || topics.get(topic) !== owner) {
    return;
  }
  topics.delete(topic);
  // the native subscription goes with the last callback; a refusal here
  // changes nothing the page relies on
  invoke(PWEB_METHOD_SIGNAL_UNSUBSCRIBE, { topic }).catch(() => undefined);
}

/**
 * Call `callback` whenever `topic` moves. The first callback of a topic
 * subscribes natively; `ready` settles when that answer arrives.
 */
export function onSignal(
  topic: string,
  callback: PWebSignalCallback,
): PWebSignalSubscription {
  if (typeof topic !== "string" || topic === "") {
    throw new PWebError("invalid_request", "A signal topic must be a non-empty string");
  }
  if (typeof callback !== "function") {
    throw new PWebError("invalid_request", "A signal callback must be a function");
  }
  listen();
  let state = topics.get(topic);
  if (state === undefined) {
    const fresh: TopicState = {
      callbacks: new Set<PWebSignalCallback>(),
      last: undefined,
      ready: Promise.resolve(0),
    };
    fresh.ready = invoke<JsonValue>(PWEB_METHOD_SIGNAL_SUBSCRIBE, { topic }).then(
      (value) => {
        const seq =
          value !== null && typeof value === "object" && !Array.isArray(value)
            ? (value as { [key: string]: JsonValue })["seq"]
            : undefined;
        if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < 0) {
          throw new PWebError("internal_error", "A subscription answer carried no sequence");
        }
        if (topics.get(topic) === fresh && (fresh.last === undefined || seq > fresh.last)) {
          fresh.last = seq;
        }
        return seq;
      },
      (reason: unknown) => {
        if (topics.get(topic) === fresh) {
          topics.delete(topic);
        }
        throw toPWebError(reason);
      },
    );
    // observed here so an application that never awaits `ready` does not
    // leave an unhandled rejection behind; awaiting it still rejects
    fresh.ready.catch(() => undefined);
    topics.set(topic, fresh);
    state = fresh;
  }
  const owner = state;
  owner.callbacks.add(callback);
  let active = true;
  return {
    topic,
    ready: owner.ready,
    off(): void {
      if (!active) {
        return;
      }
      active = false;
      release(topic, owner, callback);
    },
  };
}

/** Remove `callback` from `topic`; nothing happens when it is not there. */
export function offSignal(topic: string, callback: PWebSignalCallback): void {
  const state = topics.get(topic);
  if (state === undefined || !state.callbacks.has(callback)) {
    return;
  }
  release(topic, state, callback);
}

/** The last sequence this page saw for `topic`, or `undefined` when it is
 * not subscribed. The start of "read everything since N". */
export function lastSeq(topic: string): number | undefined {
  return topics.get(topic)?.last;
}
