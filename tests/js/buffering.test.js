// ============================================================================
// Inbound buffering, replay, and the bounded-queue drop counters.
// ============================================================================
//
// A message arriving before its handler is registered is the normal case, not
// an edge case: native pushes `handleParameters` at window-open time and React
// mounts its handlers in an effect. The buffer is what makes that survivable —
// and the cap is what stops a window that NEVER registers a handler from
// growing it without bound.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window" });
});
afterEach(() => h?.restoreConsole());

const message = (over = {}) => ({
  type: "send",
  fromWindow: "other-window",
  name: "updateAgent",
  params: {},
  data: { id: 1 },
  ...over,
});

describe("buffer and replay", () => {
  it("buffers a message with no handler", () => {
    h.deliver(message());
    expect(h.pbjs.stats().unhandledBuffered).toBe(1);
  });

  it("replays it when a matching handleAll registers", () => {
    h.deliver(message());

    const seen = [];
    h.pbjs.handleAll("updateAgent", (_e, params, data) => seen.push({ params, data }));

    expect(seen).toEqual([{ params: {}, data: { id: 1 } }]);
    expect(h.pbjs.stats().unhandledBuffered).toBe(0);
  });

  it("replays it when a source-specific handle registers", () => {
    h.deliver(message());

    const seen = [];
    h.pbjs.handle("other-window", "updateAgent", (_e, _p, data) => seen.push(data));

    expect(seen).toEqual([{ id: 1 }]);
    expect(h.pbjs.stats().unhandledBuffered).toBe(0);
  });

  it("does not replay to a handler registered for a DIFFERENT source", () => {
    h.deliver(message({ fromWindow: "other-window" }));

    const seen = [];
    h.pbjs.handle("third-window", "updateAgent", (_e, _p, d) => seen.push(d));

    expect(seen).toEqual([]);
    expect(h.pbjs.stats().unhandledBuffered).toBe(1);
  });

  it("replays several buffered messages in arrival order", () => {
    h.deliver(message({ data: { id: 1 } }));
    h.deliver(message({ data: { id: 2 } }));
    h.deliver(message({ data: { id: 3 } }));

    const seen = [];
    h.pbjs.handleAll("updateAgent", (_e, _p, d) => seen.push(d.id));
    expect(seen).toEqual([1, 2, 3]);
  });

  it("leaves unrelated messages buffered when one name's handler registers", () => {
    h.deliver(message({ name: "a" }));
    h.deliver(message({ name: "b" }));

    h.pbjs.handleAll("a", () => {});
    expect(h.pbjs.stats().unhandledBuffered).toBe(1);

    h.pbjs.handleAll("b", () => {});
    expect(h.pbjs.stats().unhandledBuffered).toBe(0);
  });

  it("routes to the source-specific handler in preference to the global one", () => {
    const order = [];
    h.pbjs.handleAll("ping", () => order.push("global"));
    h.pbjs.handle("other-window", "ping", () => order.push("specific"));

    h.deliver(message({ name: "ping" }));
    expect(order).toEqual(["specific"]);
  });
});

describe("the buffer is bounded", () => {
  it("drops the oldest past MAX_UNHANDLED_MESSAGES and counts the drops", () => {
    // The cap is 500 (MAX_UNHANDLED_MESSAGES). Overfill it by 3.
    for (let i = 0; i < 503; i++) h.deliver(message({ data: { id: i } }));

    const stats = h.pbjs.stats();
    expect(stats.unhandledBuffered).toBe(500);
    expect(stats.droppedUnhandled).toBe(3);

    // Drop-OLDEST, so the survivors are the last 500 (ids 3..502).
    const seen = [];
    h.pbjs.handleAll("updateAgent", (_e, _p, d) => seen.push(d.id));
    expect(seen).toHaveLength(500);
    expect(seen[0]).toBe(3);
    expect(seen[seen.length - 1]).toBe(502);
  });

  it("says so in the warning it forwards to native", () => {
    for (let i = 0; i < 502; i++) h.deliver(message());
    const last = h.console.warn[h.console.warn.length - 1].join(" ");
    expect(last).toContain("Buffered unhandled message");
    expect(last).toContain("dropped 2 over cap");
  });
});

describe("stale buffered messages", () => {
  it("are discarded on replay once past MESSAGE_TIMEOUT_MS", () => {
    h.deliver(message({ data: { id: "stale" } }));

    // replayUnhandledMessages ages messages off `_bufferedAt`. Backdate past
    // the 30 s MESSAGE_TIMEOUT_MS rather than waiting for it.
    const realNow = Date.now;
    Date.now = () => realNow() + 31_000;
    try {
      const seen = [];
      h.pbjs.handleAll("updateAgent", (_e, _p, d) => seen.push(d));
      expect(seen).toEqual([]);
    } finally {
      Date.now = realNow;
    }
    expect(h.pbjs.stats().unhandledBuffered).toBe(0);
  });

  it("keeps fresh ones while discarding stale ones in the same sweep", () => {
    const realNow = Date.now;
    const t0 = realNow();

    Date.now = () => t0; // old
    h.deliver(message({ data: { id: "old" } }));

    Date.now = () => t0 + 31_000; // new — and now "old" is 31 s stale
    h.deliver(message({ data: { id: "new" } }));

    try {
      const seen = [];
      h.pbjs.handleAll("updateAgent", (_e, _p, d) => seen.push(d.id));
      expect(seen).toEqual(["new"]);
    } finally {
      Date.now = realNow;
    }
  });
});

describe("handler dispatch", () => {
  it("passes (event, params, data) with the wire's split intact", () => {
    let call;
    h.pbjs.handleAll("x", (e, params, data) => (call = { e, params, data }));
    h.deliver(message({ name: "x", params: { a: 1 }, data: { b: 2 } }));

    expect(call.params).toEqual({ a: 1 });
    expect(call.data).toEqual({ b: 2 });
    expect(call.e.fromWindow).toBe("other-window");
    expect(call.e.toWindow).toBe("main-window");
    expect(call.e.type).toBe("send");
  });

  it("does not reply to a fire-and-forget send even if the handler returns", async () => {
    h.pbjs.handleAll("x", () => ({ ignored: true }));
    h.deliver(message({ name: "x" }));
    await flush();
    expect(h.native.reply).toHaveLength(0);
  });

  it("survives a throwing handler on the send path", () => {
    h.pbjs.handleAll("x", () => {
      throw new Error("boom");
    });
    expect(() => h.deliver(message({ name: "x" }))).not.toThrow();
  });

  it("answers a `get` with the handler's return value", async () => {
    h.pbjs.handleAll("x", () => ({ ok: 1 }));
    h.deliver(message({ name: "x", type: "get", requestId: 42 }));
    await flush();

    expect(h.native.reply[0].requestId).toBe(42);
    expect(h.native.reply[0].toWindow).toBe("other-window");
    expect(h.native.reply[0].dataParsed).toEqual({ success: { ok: 1 } });
  });

  it("refuses a second reply to the same request", async () => {
    h.pbjs.handleAll("x", (e) => {
      e.success(1);
      e.success(2);
      return 3;
    });
    h.deliver(message({ name: "x", type: "get", requestId: 43 }));
    await flush();

    expect(h.native.reply).toHaveLength(1);
    expect(h.native.reply[0].dataParsed).toEqual({ success: 1 });
  });

  it("marks a getAll reply as such, so the sender aggregates it", async () => {
    h.pbjs.handleAll("x", () => "hi");
    h.deliver(message({ name: "x", type: "getAll", requestId: 44 }));
    await flush();

    expect(h.native.reply[0].isGetAll).toBe(true);
  });

  it("ignores a malformed inbound frame instead of throwing", () => {
    expect(() => h.deliverRaw("{not json")).not.toThrow();
  });
});
