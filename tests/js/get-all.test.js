// ============================================================================
// invokeAll — the expected-count protocol and its edge cases.
// ============================================================================
//
// invokeAll is the one call whose completion depends on a SECOND native message:
// HandleGetAll counts the eligible targets and pushes that count separately
// (pbjsSetGetAllExpectedCount). The count can therefore arrive before, between
// or after the replies, and "zero eligible targets" has to resolve rather than
// hang. Those orderings are the whole test surface.
//
// The native side of the same contract — that the count loop and the multicast
// loop use the SAME predicate, so a pool spare cannot be counted but not asked —
// is asserted in tests/pb/router-harness.pb.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { loadBridge, flush } from "./harness.js";

let h;

beforeEach(async () => {
  h = await loadBridge({ windowName: "main-window" });
});
afterEach(() => {
  vi.useRealTimers();
  h?.restoreConsole();
});

/** Start a broadcast and hand back its requestId. */
async function broadcast(name = "getAgents") {
  const p = h.pbjs.invokeAll(name, { a: 1 }, { b: 2 });
  await flush();
  return { p, requestId: h.native.getAll[0].requestId };
}

it("builds the frame native expects", async () => {
  await broadcast();
  const frame = h.native.getAll[0];
  expect(frame.type).toBe("getAll");
  expect(frame.fromWindow).toBe("main-window");
  expect(frame.name).toBe("getAgents");
  expect(JSON.parse(frame.params)).toEqual({ a: 1 });
  expect(JSON.parse(frame.data)).toEqual({ b: 2 });
});

it("rejects a missing name without dispatching", async () => {
  await expect(h.pbjs.invokeAll("")).rejects.toThrow("name must be a non-empty string");
  expect(h.native.getAll).toHaveLength(0);
});

describe("count arrives first (the ordinary case)", () => {
  it("resolves once every expected reply is in", async () => {
    const { p, requestId } = await broadcast();
    h.setGetAllExpectedCount(requestId, 2);

    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });
    expect(h.pbjs.stats().pendingGetAll).toBe(1); // still one short

    h.respond({ requestId, isGetAll: true, fromWindow: "b-window", data: { success: 2 } });

    await expect(p).resolves.toEqual([
      { windowName: "a-window", response: { success: 1 } },
      { windowName: "b-window", response: { success: 2 } },
    ]);
    expect(h.pbjs.stats().pendingGetAll).toBe(0);
  });
});

describe("count arrives late", () => {
  it("resolves the moment the count catches up with the replies", async () => {
    const { p, requestId } = await broadcast();

    // Replies before the count: expectedCount is still 0, and the `> 0` guard
    // is what stops the first reply from resolving an empty broadcast early.
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });
    h.respond({ requestId, isGetAll: true, fromWindow: "b-window", data: { success: 2 } });
    expect(h.pbjs.stats().pendingGetAll).toBe(1);

    h.setGetAllExpectedCount(requestId, 2);
    await expect(p).resolves.toHaveLength(2);
  });

  it("still waits when the late count is higher than what has arrived", async () => {
    const { p, requestId } = await broadcast();
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });
    h.setGetAllExpectedCount(requestId, 3);
    expect(h.pbjs.stats().pendingGetAll).toBe(1);

    h.respond({ requestId, isGetAll: true, fromWindow: "b-window", data: { success: 2 } });
    h.respond({ requestId, isGetAll: true, fromWindow: "c-window", data: { success: 3 } });
    await expect(p).resolves.toHaveLength(3);
  });
});

describe("zero targets", () => {
  it("resolves with [] instead of hanging", async () => {
    const { p, requestId } = await broadcast();
    h.setGetAllExpectedCount(requestId, 0);
    await expect(p).resolves.toEqual([]);
  });

  it("resolves [] even if replies somehow arrived first", async () => {
    const { p, requestId } = await broadcast();
    h.respond({ requestId, isGetAll: true, fromWindow: "ghost", data: { success: 1 } });
    h.setGetAllExpectedCount(requestId, 0);
    // count === 0 short-circuits to [], deliberately discarding the stray reply:
    // native said nobody was asked, so nobody's answer is expected.
    await expect(p).resolves.toEqual([]);
  });
});

describe("stragglers and strays", () => {
  it("ignores a reply that arrives after the promise settled", async () => {
    const { p, requestId } = await broadcast();
    h.setGetAllExpectedCount(requestId, 1);
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });
    await p;

    expect(() =>
      h.respond({ requestId, isGetAll: true, fromWindow: "late", data: { success: 2 } })
    ).not.toThrow();
    expect(h.pbjs.stats().pendingGetAll).toBe(0);
  });

  it("ignores a count for an unknown requestId", () => {
    expect(() => h.setGetAllExpectedCount(4242, 3)).not.toThrow();
  });

  it("collects error responses rather than rejecting the whole broadcast", async () => {
    const { p, requestId } = await broadcast();
    h.setGetAllExpectedCount(requestId, 2);
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { error: "nope" } });
    h.respond({ requestId, isGetAll: true, fromWindow: "b-window", data: { success: 2 } });

    // One window failing is not the broadcast failing — the caller sees both.
    await expect(p).resolves.toEqual([
      { windowName: "a-window", response: { error: "nope" } },
      { windowName: "b-window", response: { success: 2 } },
    ]);
  });
});

describe("timeout", () => {
  it("resolves with whatever arrived after 30 s", async () => {
    vi.useFakeTimers();
    const p = h.pbjs.invokeAll("x");
    await vi.advanceTimersByTimeAsync(0);
    const { requestId } = h.native.getAll[0];

    h.setGetAllExpectedCount(requestId, 2);
    h.respond({ requestId, isGetAll: true, fromWindow: "a-window", data: { success: 1 } });

    await vi.advanceTimersByTimeAsync(30_000);
    // Resolves, never rejects: a partial answer is more useful than an error,
    // and the caller can see which windows are missing.
    await expect(p).resolves.toEqual([
      { windowName: "a-window", response: { success: 1 } },
    ]);
  });
});

describe("two broadcasts in flight", () => {
  it("keeps their responses apart", async () => {
    const p1 = h.pbjs.invokeAll("a");
    const p2 = h.pbjs.invokeAll("b");
    await flush();
    const [id1, id2] = h.native.getAll.map((f) => f.requestId);
    expect(id1).not.toBe(id2);

    h.setGetAllExpectedCount(id1, 1);
    h.setGetAllExpectedCount(id2, 1);
    h.respond({ requestId: id2, isGetAll: true, fromWindow: "w2", data: { success: "b" } });
    h.respond({ requestId: id1, isGetAll: true, fromWindow: "w1", data: { success: "a" } });

    await expect(p1).resolves.toEqual([{ windowName: "w1", response: { success: "a" } }]);
    await expect(p2).resolves.toEqual([{ windowName: "w2", response: { success: "b" } }]);
  });
});
