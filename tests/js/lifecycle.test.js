// ============================================================================
// §6.5 lifecycle push — pbjsWindowEvent, and the orphaned-request fix.
// ============================================================================
//
// The host calls pbjsWindowEvent on every OTHER window when one window's
// lifecycle changes (NotifyWindowEvent, pbjsBridge.pb). It does two jobs: it
// keeps each page's readiness cache honest, and it fails in-flight requests to a
// window that just went away — which is the difference between an error in
// 1 ms and a promise that hangs for the full 30 s.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({
    windowName: "main-window",
    knownWindows: ["other-window", "third-window"],
  });
});
afterEach(() => {
  vi.useRealTimers();
  h?.restoreConsole();
});

describe('kind: "ready"', () => {
  it("warms the cache so the next invoke skips the probe", async () => {
    h.windowEvent("other-window", "ready");
    expect(h.pbjs.stats().readyWindows).toBe(1);

    h.pbjs.invoke("other-window", "x");
    await flush();
    expect(h.native.getWindow).toEqual([]);
  });

  it("is idempotent", () => {
    h.windowEvent("other-window", "ready");
    h.windowEvent("other-window", "ready");
    expect(h.pbjs.stats().readyWindows).toBe(1);
  });
});

describe('kind: "closed" / "reloaded"', () => {
  for (const kind of ["closed", "reloaded"]) {
    it(`rejects in-flight requests to a window that ${kind}`, async () => {
      h.windowEvent("other-window", "ready");
      const p = h.pbjs.invoke("other-window", "x");
      await flush();
      expect(h.pbjs.stats().pendingRequests).toBe(1);

      h.windowEvent("other-window", kind);

      await expect(p).rejects.toThrow(`Target window other-window ${kind}`);
      expect(h.pbjs.stats().pendingRequests).toBe(0);
      expect(h.pbjs.stats().readyWindows).toBe(0);
    });
  }

  it("rejects every request to that window, not just the first", async () => {
    h.windowEvent("other-window", "ready");
    const a = h.pbjs.invoke("other-window", "a");
    const b = h.pbjs.invoke("other-window", "b");
    await flush();

    h.windowEvent("other-window", "closed");
    await expect(a).rejects.toThrow("closed");
    await expect(b).rejects.toThrow("closed");
  });

  it("leaves requests to OTHER windows untouched", async () => {
    h.windowEvent("other-window", "ready");
    h.windowEvent("third-window", "ready");
    const doomed = h.pbjs.invoke("other-window", "a");
    const kept = h.pbjs.invoke("third-window", "b");
    await flush();

    h.windowEvent("other-window", "closed");
    await expect(doomed).rejects.toThrow("closed");

    expect(h.pbjs.stats().pendingRequests).toBe(1);
    h.respond({
      requestId: h.native.get[1].requestId,
      fromWindow: "third-window",
      data: { success: "b" },
    });
    await expect(kept).resolves.toEqual({ success: "b" });
  });

  it("forces the next call back onto the cold path", async () => {
    h.windowEvent("other-window", "ready");
    h.windowEvent("other-window", "closed");

    h.pbjs.invoke("other-window", "x");
    await flush();
    expect(h.native.getWindow).toEqual(["other-window"]);
  });
});

describe("input guards", () => {
  it("ignores a missing or non-string window name", () => {
    expect(() => h.windowEvent(undefined, "closed")).not.toThrow();
    expect(() => h.windowEvent(123, "closed")).not.toThrow();
    expect(() => h.windowEvent("", "ready")).not.toThrow();
    expect(h.pbjs.stats().readyWindows).toBe(0);
  });

  it("treats an unknown kind as a teardown, not as readiness", () => {
    // Anything that is not "ready" falls through to the eviction branch. That
    // is the safe default: a name the page does not understand must not be read
    // as proof the window is alive.
    h.windowEvent("other-window", "ready");
    h.windowEvent("other-window", "vanished");
    expect(h.pbjs.stats().readyWindows).toBe(0);
  });
});

describe("readiness is also warmed by traffic", () => {
  it("a successful reply marks the responder ready", async () => {
    const p = h.pbjs.invoke("other-window", "x");
    await flush();
    h.respond({
      requestId: h.native.get[0].requestId,
      fromWindow: "other-window",
      data: { success: 1 },
    });
    await p;
    expect(h.pbjs.stats().readyWindows).toBe(1);
  });

  it("a broadcast reply marks the responder ready", async () => {
    h.pbjs.invokeAll("x");
    await flush();
    const { requestId } = h.native.getAll[0];

    h.respond({
      requestId,
      isGetAll: true,
      fromWindow: "third-window",
      data: { success: 1 },
    });
    expect(h.pbjs.stats().readyWindows).toBe(1);

    h.pbjs.invoke("third-window", "y");
    await flush();
    expect(h.native.getWindow).toEqual([]); // fast path, thanks to the broadcast
  });
});

describe("the bridge's own readiness", () => {
  it("sets pbjsReady and fires pbjs-ready", async () => {
    let fired = 0;
    window.addEventListener("pbjs-ready", () => fired++);
    const h2 = await loadBridge({ windowName: "second-window" });
    expect(window.pbjsReady).toBe(true);
    expect(fired).toBe(1);
    expect(h2.pbjs.windowName).toBe("second-window");
    h2.restoreConsole();
  });

  it("reports the host's injected identity", () => {
    expect(h.pbjs.windowName).toBe("main-window");
    expect(h.pbjs.os).toBe("mac");
    expect(h.pbjs.version).toBe("UNIFIED_V2");
    // The DnD flag is "is the service live", not "does the native exist".
    expect(h.pbjs.dndAvailable).toBe(false);
  });

  it("reads dndAvailable from the injected flag", async () => {
    const h2 = await loadBridge({ windowName: "w", dnd: true });
    expect(h2.pbjs.dndAvailable).toBe(true);
    h2.restoreConsole();
  });
});
