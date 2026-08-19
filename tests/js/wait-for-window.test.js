// ============================================================================
// P6 — waitForWindow resolves from the host's push, not from a poll.
// ============================================================================
//
// Before roadmap 2.6 this polled getWindow every 100 ms for the full 6 s
// timeout — up to 60 rounds, each two native round-trips — and called
// isWindowReady() on every one of them. That second call was ceremony:
// pbjsNativeIsWindowReady is bound NOWHERE natively, so it always answered its
// hard-coded `true` and waitForWindow was an existence probe with extra steps.
//
// The host already pushes pbjsWindowEvent(name, "ready") to every peer the
// moment a window's page reports ready. These tests pin down that the push is
// now the primary signal, that the fallback poll is genuinely slow, and that
// the failure mode did not change.

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

describe("the happy path", () => {
  it("resolves from a single probe when the window already exists", async () => {
    await expect(h.pbjs.waitForWindow("other-window")).resolves.toMatchObject({
      name: "other-window",
    });
    expect(h.native.getWindow).toEqual(["other-window"]);
  });

  it("warms the readiness cache, so invoke skips the probe next time", async () => {
    await h.pbjs.waitForWindow("other-window");
    expect(h.pbjs.stats().readyWindows).toBe(1);

    h.pbjs.invoke("other-window", "x");
    await flush();
    expect(h.native.getWindow).toEqual(["other-window"]); // still just the one
  });

  it("leaves no waiter behind", async () => {
    await h.pbjs.waitForWindow("other-window");
    expect(h.pbjs.stats().waitingForWindows).toBe(0);
  });
});

describe("the push settles a waiter", () => {
  it("resolves on `ready` without waiting for the poll", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("late-window");

    await vi.advanceTimersByTimeAsync(0);
    expect(h.native.getWindow).toEqual(["late-window"]); // probed once, not found
    expect(h.pbjs.stats().waitingForWindows).toBe(1);

    // The window opens and its page reports ready; the host pushes.
    h.native.knownWindows.add("late-window");
    h.windowEvent("late-window", "ready");

    // No timer advance beyond microtasks — the poll interval is 1000 ms, so
    // resolving here proves the push did it.
    await vi.advanceTimersByTimeAsync(0);
    await expect(p).resolves.toMatchObject({ name: "late-window" });
    expect(h.pbjs.stats().waitingForWindows).toBe(0);
  });

  it("costs exactly one extra getWindow, shared by every waiter on that name", async () => {
    vi.useFakeTimers();
    const a = h.pbjs.waitForWindow("late-window");
    const b = h.pbjs.waitForWindow("late-window");
    const c = h.pbjs.waitForWindow("late-window");
    await vi.advanceTimersByTimeAsync(0);

    const probesFromWaiters = h.native.getWindow.length; // one per waiter
    h.native.knownWindows.add("late-window");
    h.windowEvent("late-window", "ready");
    await vi.advanceTimersByTimeAsync(0);

    await expect(a).resolves.toMatchObject({ name: "late-window" });
    await expect(b).resolves.toMatchObject({ name: "late-window" });
    await expect(c).resolves.toMatchObject({ name: "late-window" });
    // The push carries only a name, so one lookup fetches the object for all
    // three — not one per waiter.
    expect(h.native.getWindow.length).toBe(probesFromWaiters + 1);
  });

  it("a push for a window nobody is waiting on costs nothing", async () => {
    h.windowEvent("other-window", "ready");
    await flush();
    expect(h.native.getWindow).toEqual([]);
  });

  it("keeps waiting when the push arrives but the window still cannot be found", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("late-window", 6000);
    const rejected = expect(p).rejects.toThrow("not found after 6000ms");
    await vi.advanceTimersByTimeAsync(0);

    // Push without adding it to the known set: getWindow still answers nothing.
    h.windowEvent("late-window", "ready");
    await vi.advanceTimersByTimeAsync(0);
    expect(h.pbjs.stats().waitingForWindows).toBe(1); // not dropped

    await vi.advanceTimersByTimeAsync(6500);
    await rejected;
  });
});

describe("the fallback poll", () => {
  // It is not belt-and-braces. NotifyWindowEvent skips windows whose OWN page is
  // not Ready yet, so a window still loading misses every push sent during its
  // load — the poll is what covers a peer that became ready in that gap.

  it("re-probes at 1000 ms, not the old 100 ms", async () => {
    vi.useFakeTimers();
    h.pbjs.waitForWindow("ghost-window", 6000).catch(() => {});

    await vi.advanceTimersByTimeAsync(0);
    expect(h.native.getWindow).toHaveLength(1);

    // The old implementation would have probed nine more times by now, each
    // followed by an isWindowReady round trip.
    await vi.advanceTimersByTimeAsync(900);
    expect(h.native.getWindow).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(200);
    expect(h.native.getWindow).toHaveLength(2);
  });

  it("costs at most 6 probes over the whole 6 s timeout", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("ghost-window", 6000);
    const rejected = expect(p).rejects.toThrow("not found after 6000ms");
    await vi.advanceTimersByTimeAsync(6500);
    await rejected;

    // Was: up to 60 rounds of two native calls each.
    expect(h.native.getWindow.length).toBeLessThanOrEqual(6);
  });

  it("finds a window that appears without any push", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("late-window", 6000);
    await vi.advanceTimersByTimeAsync(0);

    h.native.knownWindows.add("late-window");
    await vi.advanceTimersByTimeAsync(1100);

    await expect(p).resolves.toMatchObject({ name: "late-window" });
  });

  it("honours window.pbjsWaitForWindowPollMs", async () => {
    vi.useFakeTimers();
    window.pbjsWaitForWindowPollMs = 50;
    h.pbjs.waitForWindow("ghost-window", 6000).catch(() => {});

    await vi.advanceTimersByTimeAsync(0);
    expect(h.native.getWindow).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(60);
    expect(h.native.getWindow).toHaveLength(2);
  });
});

describe("failure and cleanup", () => {
  it("rejects with the same message as before for a window that never appears", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("ghost-window", 6000);
    const rejected = expect(p).rejects.toThrow(
      "Window 'ghost-window' not found after 6000ms"
    );
    await vi.advanceTimersByTimeAsync(6500);
    await rejected;
    expect(h.pbjs.stats().waitingForWindows).toBe(0);
  });

  it("honours a custom timeout", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("ghost-window", 500);
    const rejected = expect(p).rejects.toThrow("not found after 500ms");
    await vi.advanceTimersByTimeAsync(600);
    await rejected;
  });

  it("stops polling once it has rejected", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("ghost-window", 500);
    const rejected = expect(p).rejects.toThrow("not found");
    await vi.advanceTimersByTimeAsync(600);
    await rejected;

    const after = h.native.getWindow.length;
    await vi.advanceTimersByTimeAsync(5000);
    expect(h.native.getWindow.length).toBe(after);
  });

  it("a `closed` push does not reject a waiter — it may be waiting for a reopen", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.waitForWindow("late-window", 6000);
    await vi.advanceTimersByTimeAsync(0);

    h.windowEvent("late-window", "closed");
    await vi.advanceTimersByTimeAsync(0);
    expect(h.pbjs.stats().waitingForWindows).toBe(1);

    h.native.knownWindows.add("late-window");
    h.windowEvent("late-window", "ready");
    await vi.advanceTimersByTimeAsync(0);
    await expect(p).resolves.toMatchObject({ name: "late-window" });
  });

  it("keeps waiters for different names apart", async () => {
    vi.useFakeTimers();
    const a = h.pbjs.waitForWindow("win-a", 6000);
    const b = h.pbjs.waitForWindow("win-b", 6000);
    const bRejected = expect(b).rejects.toThrow("Window 'win-b' not found");
    await vi.advanceTimersByTimeAsync(0);
    expect(h.pbjs.stats().waitingForWindows).toBe(2);

    h.native.knownWindows.add("win-a");
    h.windowEvent("win-a", "ready");
    await vi.advanceTimersByTimeAsync(0);

    await expect(a).resolves.toMatchObject({ name: "win-a" });
    expect(h.pbjs.stats().waitingForWindows).toBe(1);

    await vi.advanceTimersByTimeAsync(6500);
    await bRejected;
  });
});

describe("the deleted surface", () => {
  it("pbjs.isWindowReady is gone", () => {
    // It was a hard-coded `true`: pbjsNativeIsWindowReady is bound nowhere on
    // the native side, so nothing could ever have depended on its answer.
    expect(h.pbjs.isWindowReady).toBeUndefined();
  });

  it("nothing calls pbjsNativeIsWindowReady any more", async () => {
    let called = 0;
    window.pbjsNativeIsWindowReady = () => {
      called++;
      return Promise.resolve(true);
    };
    try {
      await h.pbjs.waitForWindow("other-window");
      expect(called).toBe(0);
    } finally {
      delete window.pbjsNativeIsWindowReady;
    }
  });
});
