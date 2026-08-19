// ============================================================================
// R1 — the close-veto protocol, JS half. (roadmap 1.7 / 2.1)
// ============================================================================
//
// This is the half that runs in the page. The native half (the 4 s watchdog and
// the ClosingScope it clears) lives in JSWindow.pb and is covered by
// tests/pb/router-harness.pb — it cannot be reached from jsdom, because the
// timer, the scope and the CancelClose call are all native state.
//
// What matters here is the auto-approve, and WHY it must be immediate rather
// than buffered: the host sets one global ClosingScope when it sends the check
// and clears it only on a reply. A page that buffers the check instead of
// answering wedges the close path for EVERY window — every later close click is
// silently consumed and the app cannot be quit. Phase 1 shipped this fix
// compile-verified only; these are the assertions that hold it.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window" });
});
afterEach(() => h?.restoreConsole());

/** The frame SendCloseCheck builds (pbjsBridge.pb): a system `get`. */
const closeCheck = (requestId = 7) => ({
  type: "get",
  fromWindow: "system",
  name: "close-window",
  params: {},
  data: {},
  requestId,
});

describe("close-window with no handler", () => {
  it("auto-approves immediately", () => {
    h.deliver(closeCheck(7));

    expect(h.native.reply).toHaveLength(1);
    const frame = h.native.reply[0];
    expect(frame.requestId).toBe(7);
    expect(frame.toWindow).toBe("system");
    expect(frame.fromWindow).toBe("main-window");
    expect(frame.dataParsed).toEqual({ success: true });
    expect(frame.isGetAll).toBe(false);
  });

  it("does not buffer the check", () => {
    h.deliver(closeCheck());
    // Buffering is the wedge: the close protocol has no replay point, so a
    // buffered check would sit there until the message expired.
    expect(h.pbjs.stats().unhandledBuffered).toBe(0);
  });

  it("does not dead-letter it either", async () => {
    // Dead-lettering would answer eventually, but with an ERROR — which the
    // host reads as "did not approve".
    window.pbjsDeadLetterGraceMs = 1;
    h.deliver(closeCheck());
    await new Promise((r) => setTimeout(r, 20));

    expect(h.pbjs.stats().deadLetters).toBe(0);
    expect(h.native.reply).toHaveLength(1);
    expect(h.native.reply[0].dataParsed).toEqual({ success: true });
  });

  it("answers every window's check, not just the first", () => {
    h.deliver(closeCheck(1));
    h.deliver(closeCheck(2));
    h.deliver(closeCheck(3));

    expect(h.native.reply.map((f) => f.requestId)).toEqual([1, 2, 3]);
    expect(h.native.reply.every((f) => f.dataParsed.success === true)).toBe(true);
  });

  it("stays silent when there is no requestId to answer", () => {
    // Nothing to reply to; the guard must not throw or invent a frame.
    const noId = closeCheck();
    delete noId.requestId;
    expect(() => h.deliver(noId)).not.toThrow();
    expect(h.native.reply).toHaveLength(0);
  });
});

describe("close-window with an onCloseWindow handler", () => {
  it("approves when the handler returns true", async () => {
    h.pbjs.onCloseWindow(() => true);
    h.deliver(closeCheck(11));
    await flush();

    expect(h.native.reply[0].dataParsed).toEqual({ success: true });
  });

  it("VETOES when the handler returns false", async () => {
    h.pbjs.onCloseWindow(() => false);
    h.deliver(closeCheck(12));
    await flush();

    // serializeResponse passes booleans through, so the veto arrives as
    // {success:false} — which HandleReply reads as "refused to close".
    expect(h.native.reply[0].dataParsed).toEqual({ success: false });
  });

  it("awaits an async handler before answering", async () => {
    let release;
    h.pbjs.onCloseWindow(() => new Promise((r) => (release = r)));

    h.deliver(closeCheck(13));
    await flush();
    expect(h.native.reply).toHaveLength(0); // still deciding — no premature approve

    release(false);
    await flush();
    expect(h.native.reply[0].dataParsed).toEqual({ success: false });
  });

  it("reports a throwing handler as an error, not as approval", async () => {
    h.pbjs.onCloseWindow(() => {
      throw new Error("save failed");
    });
    h.deliver(closeCheck(14));
    await flush();

    expect(h.native.reply[0].dataParsed).toEqual({ error: "save failed" });
  });

  it("treats an undefined return as approval", async () => {
    // dispatchMessage substitutes `true` for undefined. A handler that forgets
    // to return must not read as a veto — that would be an unquittable app.
    h.pbjs.onCloseWindow(() => {});
    h.deliver(closeCheck(15));
    await flush();

    expect(h.native.reply[0].dataParsed).toEqual({ success: true });
  });

  it("registers under system:close-window, so removeHandler restores auto-approve", async () => {
    h.pbjs.onCloseWindow(() => false);
    h.pbjs.removeHandler("system", "close-window");

    h.deliver(closeCheck(16));
    await flush();
    expect(h.native.reply[0].dataParsed).toEqual({ success: true });
  });
});
