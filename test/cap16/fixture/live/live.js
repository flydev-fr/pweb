/*
 * CAP-16 LIVE - the page half, over the REAL @pweb/runtime (staged beside
 * this file as ./sdk/ by test/cap16/build_cap16.ps1) and the REAL host
 * composition (PWebHostRun in test/cap16/signallive.pas).
 *
 * Phase 1: the handshake feature, a refused subscription, a signal and its
 * latency, a flood with the page's own timer watched, a revocation.
 * Then a reload, with signals emitted while the document is being replaced.
 * Phase 2: the subscriptions the replacement dropped, the recovery by
 * re-read, a socket echo through the migrated loop, a blob a SERVICE created
 * for this page (12-5), read by URL. Then the report.
 *
 * Nothing here calls the native primitive directly: every call is the SDK's.
 */
import {
  handshake,
  invoke,
  lastSeq,
  onSignal,
  PWebSocket,
} from "./sdk/index.js";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const PHASE2 = "cap16-phase2";
const report = {};

function sampler(periodMs) {
  let last = performance.now();
  let max = 0;
  let samples = 0;
  const id = setInterval(() => {
    const now = performance.now();
    const late = now - last - periodMs;
    if (late > max) {
      max = late;
    }
    samples++;
    last = now;
  }, periodMs);
  return {
    stop() {
      clearInterval(id);
      return { maxLateMs: Math.round(max * 10) / 10, samples };
    },
  };
}

function waitFor(predicate, ms) {
  return new Promise((resolve) => {
    const start = performance.now();
    const poll = () => {
      if (predicate()) {
        resolve(true);
      } else if (performance.now() - start > ms) {
        resolve(false);
      } else {
        setTimeout(poll, 5);
      }
    };
    poll();
  });
}

function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

async function attempt(name, fn) {
  try {
    await fn();
  } catch (err) {
    report[name + "Error"] = String((err && err.code) || err);
  }
}

async function phase1() {
  const config = await invoke("Cap16.Config", null);
  report.config = config;
  const info = await handshake();
  report.features = info.features ?? null;

  // a topic the window may not read: forbidden, and not one script
  await attempt("denied", async () => {
    const before = (await invoke("Cap16.Evals", null)).evals;
    const denied = onSignal("cap16.denied", () => {
      report.deniedDelivered = true;
    });
    try {
      await denied.ready;
      report.denied = "subscribed";
    } catch (err) {
      report.denied = err.code;
    }
    await invoke("Cap16.Emit", { topic: "cap16.denied", count: 5 });
    await sleep(300);
    const after = (await invoke("Cap16.Evals", null)).evals;
    report.deniedEvals = after - before;
  });

  // one signal, and how long it took to arrive
  let ticks = 0;
  const onTick = () => {
    ticks++;
    document.getElementById("ticks").textContent = String(ticks);
  };
  let tick = onSignal("cap16.tick", onTick);
  report.tickSubscribed = await tick.ready;
  const t0 = performance.now();
  await invoke("Cap16.Emit", { topic: "cap16.tick", count: 1 });
  report.tickArrived = await waitFor(() => ticks >= 1, 3000);
  report.tickLatencyMs = Math.round((performance.now() - t0) * 10) / 10;

  // the flood, with the page's own timer watched
  let floodEvents = 0;
  const flood = onSignal("cap16.flood", () => {
    floodEvents++;
  });
  await flood.ready;
  const idle = sampler(10);
  await sleep(1000);
  report.jitterIdle = idle.stop();
  const busy = sampler(10);
  await invoke("Cap16.Flood", { ms: 3000, perSecond: 10000 });
  await sleep(3500);
  report.jitterFlood = busy.stop();
  const result = await invoke("Cap16.FloodResult", null);
  report.flood = result;
  report.floodEvents = floodEvents;
  report.floodLastSeq = lastSeq("cap16.flood") ?? -1;
  flood.off();

  // the revocation: no tick after the revoking call returned
  const revoked = await invoke("Cap16.Revoke", null);
  report.revoke = revoked;
  const ticksAtRevoke = ticks;
  await invoke("Cap16.Emit", { topic: "cap16.tick", count: 50 });
  await sleep(500);
  report.ticksAfterRevoke = ticks - ticksAtRevoke;
  await invoke("Cap16.Restore", null);
  // a revoked subscription is gone natively: hear the topic again by
  // subscribing again
  tick.off();
  tick = onSignal("cap16.tick", onTick);
  report.resubscribed = await tick.ready;

  // the reload: signals emitted while the document is being replaced
  await invoke("Cap16.EmitLater", { topic: "cap16.tick", count: 5, delayMs: 150 });
  await invoke("Cap16.Phase", { phase: 1, report });
  window.name = PHASE2;
  window.location.reload();
}

async function phase2() {
  const carried = await invoke("Cap16.Carried", null);
  Object.assign(report, carried);
  const config = report.config;
  report.phase = 2;
  await sleep(400);
  // the replacement dropped every subscription of the old document
  report.subsAtPhase2 = (await invoke("Cap16.Subs", null)).subscriptions;
  // THE RECOVERY: subscribe, then read everything since what we knew
  const tick = onSignal("cap16.tick", () => undefined);
  report.phase2Seq = await tick.ready;
  report.recovered = await invoke("Cap16.TickCount", { since: report.resubscribed ?? 0 });
  tick.off();

  // the socket door, through the migrated loop
  if (config.port > 0) {
    await attempt("socket", async () => {
      report.socketEcho = await new Promise((resolve) => {
        const s = new PWebSocket("ws://127.0.0.1:" + config.port + "/echo?row=s16_echo");
        const timer = setTimeout(() => resolve("timeout"), 15000);
        s.onopen = () => s.send("cap16-echo");
        s.onmessage = (e) => {
          clearTimeout(timer);
          resolve(typeof e.data === "string" ? e.data : "binary");
          s.close(4000, "done");
        };
        s.onerror = (e) => {
          clearTimeout(timer);
          resolve("error-" + (e.category ?? e.code));
        };
      });
    });
  } else {
    report.socketEcho = "not_applicable";
  }

  // 12-5: a blob a SERVICE created for this page, read by URL
  await attempt("blob", async () => {
    const handle = await invoke("Live.Snapshot", { since: 0 });
    report.blobHandle = { size: handle.size, type: handle.type, token: handle.token.length };
    const response = await fetch(handle.url);
    const bytes = new Uint8Array(await response.arrayBuffer());
    report.blobStatus = response.status;
    report.blobBytes = bytes.length;
    report.blobFnv = fnv1a(bytes);
  });

  document.getElementById("state").textContent = "done";
  await invoke("Cap16.Report", { report });
}

(async () => {
  try {
    if (window.name === PHASE2) {
      await phase2();
    } else {
      await phase1();
    }
  } catch (err) {
    report.fatal = String((err && (err.code || err.message)) || err);
    await invoke("Cap16.Report", { report });
  }
})();
