// ============================================================================
// 2.7 — F4 (per-request timeout) and F5a (warn when a handler is replaced).
// ============================================================================

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window", knownWindows: ["other-window"] });
  h.windowEvent("other-window", "ready"); // fast path, so the tests are about timeouts
});
afterEach(() => {
  vi.useRealTimers();
  h?.restoreConsole();
});

describe("F4 — options.timeoutMs on invoke", () => {
  it("still defaults to 30 s", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("other-window", "x");
    const rejected = expect(p).rejects.toThrow("Request timeout for x to other-window");

    await vi.advanceTimersByTimeAsync(29_900);
    expect(h.pbjs.stats().pendingRequests).toBe(1); // not yet

    await vi.advanceTimersByTimeAsync(200);
    await rejected;
  });

  it("honours a shorter deadline", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { timeoutMs: 500 });
    const rejected = expect(p).rejects.toThrow("Request timeout");

    await vi.advanceTimersByTimeAsync(600);
    await rejected;
    expect(h.pbjs.stats().pendingRequests).toBe(0);
  });

  it("honours a longer one", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { timeoutMs: 60_000 });
    const rejected = expect(p).rejects.toThrow("Request timeout");

    await vi.advanceTimersByTimeAsync(31_000);
    expect(h.pbjs.stats().pendingRequests).toBe(1); // the default would have fired

    await vi.advanceTimersByTimeAsync(30_000);
    await rejected;
  });

  it("evicts the readiness cache on a custom-deadline timeout too", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { timeoutMs: 100 });
    const rejected = expect(p).rejects.toThrow("Request timeout");
    await vi.advanceTimersByTimeAsync(200);
    await rejected;

    // An unresponsive window is the genuinely stale case, whatever deadline
    // discovered it.
    expect(h.pbjs.stats().readyWindows).toBe(0);
  });

  it("a reply before the deadline settles normally", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, { timeoutMs: 500 });
    await vi.advanceTimersByTimeAsync(0);

    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { success: 1 },
    });
    await expect(p).resolves.toEqual({ success: 1 });

    // And the timer must not fire afterwards on an already-settled request.
    await vi.advanceTimersByTimeAsync(1000);
    expect(h.pbjs.stats().pendingRequests).toBe(0);
  });

  for (const bad of [0, -1, NaN, Infinity, "500", null]) {
    it(`falls back to the default for timeoutMs = ${String(bad)}`, async () => {
      vi.useFakeTimers();
      const p = h.pbjs.invoke("other-window", "x", {}, {}, { timeoutMs: bad });
      const rejected = expect(p).rejects.toThrow("Request timeout");

      await vi.advanceTimersByTimeAsync(29_900);
      // The point: a bad value must not produce a request that never times out.
      expect(h.pbjs.stats().pendingRequests).toBe(1);

      await vi.advanceTimersByTimeAsync(200);
      await rejected;
    });
  }

  it("composes with an AbortSignal", async () => {
    vi.useFakeTimers();
    const ac = new AbortController();
    const p = h.pbjs.invoke("other-window", "x", {}, {}, {
      timeoutMs: 10_000,
      signal: ac.signal,
    });
    const rejected = expect(p).rejects.toMatchObject({ name: "AbortError" });
    await vi.advanceTimersByTimeAsync(0);

    ac.abort();
    await rejected;
  });

  it("applies per call, not globally", async () => {
    vi.useFakeTimers();
    const quick = h.pbjs.invoke("other-window", "a", {}, {}, { timeoutMs: 500 });
    const slow = h.pbjs.invoke("other-window", "b");
    const quickRejected = expect(quick).rejects.toThrow("Request timeout for a");
    const slowRejected = expect(slow).rejects.toThrow("Request timeout for b");

    await vi.advanceTimersByTimeAsync(600);
    await quickRejected;
    expect(h.pbjs.stats().pendingRequests).toBe(1); // b is still waiting

    await vi.advanceTimersByTimeAsync(30_000);
    await slowRejected;
  });
});

describe("F4 — options.timeoutMs on invokeAll", () => {
  // Same knob, because the one call that fans out to N windows is the one most
  // likely to want a different deadline; leaving it out is an arbitrary trap.

  it("resolves with the partial result at the custom deadline", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invokeAll("x", {}, {}, { timeoutMs: 500 });
    await vi.advanceTimersByTimeAsync(0);
    const { requestId } = h.native.getAll[0];

    h.setGetAllExpectedCount(requestId, 2);
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });

    await vi.advanceTimersByTimeAsync(600);
    await expect(p).resolves.toEqual([
      { windowName: "a-window", response: { success: 1 } },
    ]);
  });

  it("still defaults to 30 s", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invokeAll("x");
    await vi.advanceTimersByTimeAsync(29_900);
    expect(h.pbjs.stats().pendingGetAll).toBe(1);

    await vi.advanceTimersByTimeAsync(200);
    await expect(p).resolves.toEqual([]);
  });
});

describe("F5a — replacing a handler is reported", () => {
  const warnings = () => h.console.warn.map((a) => a.join(" ")).join("\n");

  it("warns when handleAll replaces a different function", () => {
    h.pbjs.handleAll("updateAgent", () => 1);
    h.pbjs.handleAll("updateAgent", () => 2);

    expect(warnings()).toContain("Handler replaced for '*:updateAgent'");
    expect(warnings()).toContain("main-window");
    expect(h.pbjs.stats().handlersReplaced).toBe(1);
  });

  it("warns for handle() too — same silent failure", () => {
    h.pbjs.handle("other-window", "ping", () => 1);
    h.pbjs.handle("other-window", "ping", () => 2);

    expect(warnings()).toContain("Handler replaced for 'other-window:ping'");
    expect(h.pbjs.stats().handlersReplaced).toBe(1);
  });

  it("stays quiet when the SAME function is re-registered", () => {
    // React effects re-run, and StrictMode double-invokes them in development.
    // A warning on ordinary remounts is one people learn to ignore.
    const fn = () => 1;
    h.pbjs.handleAll("updateAgent", fn);
    h.pbjs.handleAll("updateAgent", fn);
    h.pbjs.handleAll("updateAgent", fn);

    expect(warnings()).not.toContain("Handler replaced");
    expect(h.pbjs.stats().handlersReplaced).toBe(0);
  });

  it("stays quiet on a first registration", () => {
    h.pbjs.handleAll("a", () => 1);
    h.pbjs.handle("other-window", "b", () => 1);
    expect(warnings()).not.toContain("Handler replaced");
  });

  it("stays quiet after removeHandler — that is a deliberate handover", () => {
    h.pbjs.handleAll("updateAgent", () => 1);
    h.pbjs.removeHandler(null, "updateAgent");
    h.pbjs.handleAll("updateAgent", () => 2);

    expect(warnings()).not.toContain("Handler replaced");
    expect(h.pbjs.stats().handlersReplaced).toBe(0);
  });

  it("does not confuse a global handler with a source-specific one", () => {
    // Different keys ("*:ping" vs "other-window:ping") — both may legitimately
    // exist, and the specific one wins at dispatch.
    h.pbjs.handleAll("ping", () => 1);
    h.pbjs.handle("other-window", "ping", () => 2);
    expect(warnings()).not.toContain("Handler replaced");
  });

  it("the replacement still takes effect — this warns, it does not block", () => {
    const seen = [];
    h.pbjs.handleAll("ping", () => seen.push("first"));
    h.pbjs.handleAll("ping", () => seen.push("second"));

    h.deliver({ type: "send", fromWindow: "other-window", name: "ping", params: {}, data: {} });
    expect(seen).toEqual(["second"]);
  });

  it("counts each replacement", () => {
    h.pbjs.handleAll("a", () => 1);
    h.pbjs.handleAll("a", () => 2);
    h.pbjs.handleAll("a", () => 3);
    expect(h.pbjs.stats().handlersReplaced).toBe(2);
  });
});

describe("stats() reports the new counters", () => {
  it("includes them from the start", async () => {
    const s = h.pbjs.stats();
    expect(s).toMatchObject({
      window: "main-window",
      handlersReplaced: 0,
      waitingForWindows: 0,
    });
  });

  it("tracks in-flight requests", async () => {
    h.pbjs.invoke("other-window", "x");
    await flush();
    expect(h.pbjs.stats().pendingRequests).toBe(1);
  });
});
