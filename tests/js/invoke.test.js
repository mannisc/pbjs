// ============================================================================
// invoke() — dispatch, settle, timeout, and F9 AbortSignal cancellation.
// ============================================================================
//
// invoke has two paths into the same dispatch: a FAST one when the target is in
// the readiness cache, and a COLD one that probes with waitForWindow first.
// Most of the subtlety is in when an entry enters and leaves that cache, so the
// tests below assert the native traffic (how many probes were made), not just
// the promise's outcome.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window", knownWindows: ["other-window"] });
});
afterEach(() => {
  vi.useRealTimers();
  h?.restoreConsole();
});

describe("argument validation", () => {
  it("rejects a missing target window", async () => {
    await expect(h.pbjs.invoke("", "x")).rejects.toThrow(
      "windowName must be a non-empty string"
    );
  });
  it("rejects a missing name", async () => {
    await expect(h.pbjs.invoke("other-window", "")).rejects.toThrow(
      "name must be a non-empty string"
    );
  });
  it("dispatches nothing when validation fails", async () => {
    await h.pbjs.invoke("", "x").catch(() => {});
    expect(h.native.get).toHaveLength(0);
  });
});

describe("dispatch and settle", () => {
  it("builds the frame native expects, with params and data pre-stringified", async () => {
    const p = h.pbjs.invoke("other-window", "getStatus", { a: 1 }, { b: 2 });
    await flush();

    expect(h.native.get).toHaveLength(1);
    const frame = h.native.get[0];
    expect(frame.type).toBe("get");
    expect(frame.fromWindow).toBe("main-window");
    expect(frame.toWindow).toBe("other-window");
    expect(frame.name).toBe("getStatus");
    // params/data are JSON *strings* on the wire — HandleGet splices them into
    // the outbound frame verbatim rather than re-serializing.
    expect(JSON.parse(frame.params)).toEqual({ a: 1 });
    expect(JSON.parse(frame.data)).toEqual({ b: 2 });
    expect(typeof frame.requestId).toBe("number");

    h.respond({ requestId: frame.requestId, fromWindow: "other-window", data: { success: 9 } });
    await expect(p).resolves.toEqual({ success: 9 });
  });

  it("defaults absent params/data to {}", async () => {
    h.pbjs.invoke("other-window", "x");
    await flush();
    expect(JSON.parse(h.native.get[0].params)).toEqual({});
    expect(JSON.parse(h.native.get[0].data)).toEqual({});
  });

  it("rejects on an error response", async () => {
    const p = h.pbjs.invoke("other-window", "x");
    await flush();
    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { error: "Window not open: other-window" },
    });
    await expect(p).rejects.toThrow("Window not open: other-window");
  });

  it("stringifies a non-string error payload rather than reporting [object Object]", async () => {
    const p = h.pbjs.invoke("other-window", "x");
    await flush();
    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { error: { code: 7 } },
    });
    await expect(p).rejects.toThrow('{"code":7}');
  });

  it("ignores a response for an unknown requestId", async () => {
    expect(() =>
      h.respond({ requestId: 9999, fromWindow: "other-window", data: { success: 1 } })
    ).not.toThrow();
  });

  it("ignores a malformed response frame", () => {
    expect(() => window.pbjsHandleResponse("{nope")).not.toThrow();
  });

  it("allocates a fresh requestId per call", async () => {
    h.pbjs.invoke("other-window", "a");
    h.pbjs.invoke("other-window", "b");
    await flush();
    const [x, y] = h.native.get.map((f) => f.requestId);
    expect(x).not.toBe(y);
  });
});

describe("the readiness cache decides which path invoke takes", () => {
  it("probes once on the cold path, then never again", async () => {
    const p1 = h.pbjs.invoke("other-window", "a");
    await flush();
    expect(h.native.getWindow).toEqual(["other-window"]); // one probe
    h.respond({ requestId: h.native.get[0].requestId, fromWindow: "other-window", data: {} });
    await p1;

    h.pbjs.invoke("other-window", "b");
    await flush();
    expect(h.native.getWindow).toEqual(["other-window"]); // still one — fast path
    expect(h.native.get).toHaveLength(2);
  });

  it("takes the fast path immediately after a pushed `ready` event", async () => {
    h.windowEvent("other-window", "ready");
    h.pbjs.invoke("other-window", "a");
    await flush();

    expect(h.native.getWindow).toEqual([]); // no probe at all
    expect(h.native.get).toHaveLength(1);
  });

  it("does NOT evict on an error response", async () => {
    h.windowEvent("other-window", "ready");
    const p = h.pbjs.invoke("other-window", "a");
    await flush();
    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { error: "Window not found: other-window" },
    });
    await p.catch(() => {});

    // Staying cached is deliberate: a closed window answers instantly with an
    // error, so the next call fails fast instead of polling waitForWindow for 6 s.
    h.pbjs.invoke("other-window", "b");
    await flush();
    expect(h.native.getWindow).toEqual([]);
  });

  it("DOES evict on a timeout, so the next call re-probes", async () => {
    vi.useFakeTimers();
    h.windowEvent("other-window", "ready");
    const p = h.pbjs.invoke("other-window", "a");
    // Attach the expectation BEFORE advancing: the rejection lands during the
    // advance, and a handler attached afterwards is one turn too late.
    const rejected = expect(p).rejects.toThrow("Request timeout for a to other-window");
    await vi.advanceTimersByTimeAsync(0);
    expect(h.native.get).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(30_000);
    await rejected;

    // An open-but-unresponsive window is the genuinely stale case.
    h.pbjs.invoke("other-window", "b").catch(() => {});
    await vi.advanceTimersByTimeAsync(0);
    expect(h.native.getWindow).toEqual(["other-window"]);
  });

  it("rejects when the cold-path probe never finds the window", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("ghost-window", "a");
    const rejected = expect(p).rejects.toThrow(
      "Window 'ghost-window' not found after 6000ms"
    );
    // waitForWindow polls getWindow every 100 ms for 6 s.
    await vi.advanceTimersByTimeAsync(6_500);
    await rejected;
    expect(h.native.get).toHaveLength(0); // never dispatched
  });
});

describe("F9 — AbortSignal", () => {
  it("rejects an already-aborted signal without dispatching", async () => {
    const ac = new AbortController();
    ac.abort();

    const p = h.pbjs.invoke("other-window", "x", {}, {}, { signal: ac.signal });
    await expect(p).rejects.toMatchObject({ name: "AbortError" });
    expect(h.native.get).toHaveLength(0);
    expect(h.native.getWindow).toHaveLength(0); // not even a probe
  });

  it("rejects an in-flight request when the signal fires", async () => {
    h.windowEvent("other-window", "ready");
    const ac = new AbortController();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { signal: ac.signal });
    await flush();
    expect(h.native.get).toHaveLength(1);

    ac.abort();
    await expect(p).rejects.toMatchObject({ name: "AbortError" });
    expect(h.pbjs.stats().pendingRequests).toBe(0);
  });

  it("ignores a native reply that arrives after the abort", async () => {
    h.windowEvent("other-window", "ready");
    const ac = new AbortController();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { signal: ac.signal });
    await flush();
    const { requestId } = h.native.get[0];

    ac.abort();
    await expect(p).rejects.toMatchObject({ name: "AbortError" });

    // The pending entry is gone, so the late reply finds nothing and is dropped
    // rather than settling an already-rejected promise.
    expect(() =>
      h.respond({ requestId, fromWindow: "other-window", data: { success: 1 } })
    ).not.toThrow();
  });

  it("aborting after a normal settle changes nothing", async () => {
    h.windowEvent("other-window", "ready");
    const ac = new AbortController();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { signal: ac.signal });
    await flush();
    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { success: 1 },
    });
    await expect(p).resolves.toEqual({ success: 1 });

    expect(() => ac.abort()).not.toThrow();
  });

  it("aborts a request still waiting on the cold-path probe", async () => {
    vi.useFakeTimers();
    const ac = new AbortController();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { signal: ac.signal });
    const rejected = expect(p).rejects.toMatchObject({ name: "AbortError" });

    ac.abort(); // during waitForWindow, before dispatchGet
    await vi.advanceTimersByTimeAsync(200);

    await rejected;
    // The abort is applied inside dispatchGet's own already-aborted check, so
    // the frame is built and then abandoned rather than never allocated.
    expect(h.pbjs.stats().pendingRequests).toBe(0);
  });

  it("leaves other in-flight requests alone", async () => {
    h.windowEvent("other-window", "ready");
    const ac = new AbortController();
    const cancelled = h.pbjs.invoke("other-window", "a", {}, {}, { signal: ac.signal });
    const kept = h.pbjs.invoke("other-window", "b");
    await flush();

    ac.abort();
    await expect(cancelled).rejects.toMatchObject({ name: "AbortError" });

    const keptId = h.native.get[1].requestId;
    h.respond({ requestId: keptId, fromWindow: "other-window", data: { success: "b" } });
    await expect(kept).resolves.toEqual({ success: "b" });
  });
});

describe("send()", () => {
  it("fires immediately on the fast path and returns void", async () => {
    h.windowEvent("other-window", "ready");
    expect(h.pbjs.send("other-window", "ping", {}, { a: 1 })).toBeUndefined();
    expect(h.native.send).toHaveLength(1);
    expect(h.native.send[0].type).toBe("send");
    expect(JSON.parse(h.native.send[0].data)).toEqual({ a: 1 });
  });

  it("waits for the window on the cold path rather than dropping the message", async () => {
    h.pbjs.send("other-window", "ping", {}, {});
    expect(h.native.send).toHaveLength(0); // probing first
    await flush();
    expect(h.native.send).toHaveLength(1);
  });

  it("gives up quietly when the window never appears", async () => {
    vi.useFakeTimers();
    h.pbjs.send("ghost-window", "ping", {}, {});
    await vi.advanceTimersByTimeAsync(6_500);
    expect(h.native.send).toHaveLength(0);
  });

  it("validates its arguments without throwing at the caller", () => {
    expect(() => h.pbjs.send("", "x", {}, {})).not.toThrow();
    expect(() => h.pbjs.send("other-window", "", {}, {})).not.toThrow();
    expect(h.native.send).toHaveLength(0);
  });
});

describe("sendAll()", () => {
  it("broadcasts without probing — there is no single target to wait on", () => {
    h.pbjs.sendAll("patch", {}, { v: 1 });
    expect(h.native.sendAll).toHaveLength(1);
    expect(h.native.getWindow).toHaveLength(0);
    expect(h.native.sendAll[0].fromWindow).toBe("main-window");
    expect(h.native.sendAll[0].type).toBe("sendAll");
  });

  it("validates its name", () => {
    expect(() => h.pbjs.sendAll("", {}, {})).not.toThrow();
    expect(h.native.sendAll).toHaveLength(0);
  });
});
