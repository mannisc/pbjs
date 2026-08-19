// ============================================================================
// F7 dead-letter — fast-fail a `get` whose handler never registers.
// ============================================================================
//
// Without it, invoking a name nobody handles costs the caller the full 30 s
// request timeout. The grace exists because late registration is legitimate
// (handlers mount in React effects); the timer is what distinguishes "late" from
// "never".
//
// The interesting property is the interaction with replay: a handler that
// registers inside the grace splices the message out of the buffer, so the
// timer must find it gone and do nothing. Both halves are asserted here.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadBridge } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window" });
  // The real grace is 5 s. Shorten it through the documented override rather
  // than faking timers, so the override itself is under test.
  window.pbjsDeadLetterGraceMs = 10;
});
afterEach(() => h?.restoreConsole());

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const getMsg = (over = {}) => ({
  type: "get",
  fromWindow: "other-window",
  name: "getAgentStatus",
  params: {},
  data: {},
  requestId: 5,
  ...over,
});

it("rejects the sender when no handler appears within the grace", async () => {
  h.deliver(getMsg());
  expect(h.native.reply).toHaveLength(0); // buffered, still hoping

  await wait(40);

  expect(h.native.reply).toHaveLength(1);
  const frame = h.native.reply[0];
  expect(frame.requestId).toBe(5);
  expect(frame.toWindow).toBe("other-window");
  expect(frame.isGetAll).toBe(false);
  expect(frame.dataParsed.error).toBe(
    "No handler for 'getAgentStatus' on main-window"
  );
  expect(h.pbjs.stats().deadLetters).toBe(1);
  expect(h.pbjs.stats().unhandledBuffered).toBe(0);
});

it("does nothing when the handler registers inside the grace", async () => {
  h.deliver(getMsg());

  const seen = [];
  h.pbjs.handleAll("getAgentStatus", () => {
    seen.push(1);
    return "ok";
  });

  await wait(40);

  expect(seen).toEqual([1]);
  expect(h.pbjs.stats().deadLetters).toBe(0);
  // Exactly one reply — the handler's, not a dead-letter on top of it.
  expect(h.native.reply).toHaveLength(1);
  expect(h.native.reply[0].dataParsed).toEqual({ success: "ok" });
});

it("does not dead-letter a fire-and-forget send", async () => {
  h.deliver({ ...getMsg(), type: "send", requestId: undefined });
  await wait(40);

  expect(h.pbjs.stats().deadLetters).toBe(0);
  expect(h.native.reply).toHaveLength(0);
  // Still buffered: a send has nobody to fail, so it waits for its handler.
  expect(h.pbjs.stats().unhandledBuffered).toBe(1);
});

it("does not dead-letter a getAll", async () => {
  // A broadcast to a window that does not implement the name is normal, and
  // the sender's expectedCount already accounts for who can answer.
  h.deliver(getMsg({ type: "getAll" }));
  await wait(40);

  expect(h.pbjs.stats().deadLetters).toBe(0);
  expect(h.native.reply).toHaveLength(0);
});

it("honours window.pbjsDeadLetterGraceMs", async () => {
  window.pbjsDeadLetterGraceMs = 200;
  h.deliver(getMsg());

  await wait(60);
  expect(h.pbjs.stats().deadLetters).toBe(0); // the default 5 s is not in play,
  // but neither is a 10 ms one — the override is being read.

  await wait(250);
  expect(h.pbjs.stats().deadLetters).toBe(1);
});

it("falls back to the 5 s default when the override is not a number", async () => {
  window.pbjsDeadLetterGraceMs = "soon";
  h.deliver(getMsg());
  await wait(60);
  expect(h.pbjs.stats().deadLetters).toBe(0);
});

it("counts each dead-lettered request separately", async () => {
  h.deliver(getMsg({ requestId: 1, name: "a" }));
  h.deliver(getMsg({ requestId: 2, name: "b" }));
  await wait(40);

  expect(h.pbjs.stats().deadLetters).toBe(2);
  expect(h.native.reply.map((f) => f.requestId).sort()).toEqual([1, 2]);
});

it("warns on the forwarding console, so it is visible without devtools", async () => {
  h.deliver(getMsg());
  await wait(40);

  const warned = h.console.warn.map((a) => a.join(" ")).join("\n");
  expect(warned).toContain("[PBJS] Dead-letter: no handler for 'getAgentStatus'");
  expect(warned).toContain("rejected sender other-window");
});
