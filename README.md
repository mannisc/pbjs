# PBJS — Cross-Window Bridge for PureBasic WebViews

PBJS is a **bidirectional, JSON-RPC-style bridge** between N independent WebView
windows (each typically a separately-bundled web app) and a single **PureBasic
native host**. There is no direct webview↔webview channel — **the native host is
the router** for all cross-window traffic.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PureBasic native host (single process, single UI thread)                 │
│   main.pb ── event loop ── WindowManager.pb ── JSWindow.pb (registry,     │
│                         │                       templates, pre-warmed pool)│
│                 pbjsBridge.pb  (router: Get/GetAll/Send/SendAll/Reply/Log  │
│                         │        + EscapeJSON + NotifyWindowEvent + queues)│
│        BindWebViewCallback ▲│▼ WebViewExecuteScript                        │
└────────────────────────────┼──────────────────────────────────────────── ┘
                  per-webview │ (JS→native bindings / native→JS injection)
   ┌─────────────────────────┼─────────────────────┬───────────────────────┐
   ▼                         ▼                      ▼                       ▼
window-A                window-B               window-C-1              window-C-N
 window.pbjs  ← pbjsBridgeScript.js injected into every window (builds the API)
```

This README is the **complete handbook**. For a one-screen orientation see
[CLAUDE.md](CLAUDE.md).

---

## Table of contents

1. [Architecture (3 layers)](#1-architecture)
2. [Getting started — hosting pbjs, and the page side](#2-getting-started)
3. [Request/response — `invoke` / `handle`](#3-requestresponse--invoke--handle)
4. [Fire-and-forget — `send` / `sendAll`](#4-fire-and-forget--send--sendall)
5. [Broadcast request/response — `invokeAll`](#5-broadcast-requestresponse--invokeall)
6. [Pub/sub topics — `channel`](#6-pubsub-topics--channel)
7. [Window management](#7-window-management)
8. [Lifecycle & readiness](#8-lifecycle--readiness)
9. [Robustness & diagnostics](#9-robustness--diagnostics)
10. [Cross-window state sync (Zustand & friends)](#10-cross-window-state-sync)
11. [Conventions & gotchas](#11-conventions--gotchas)
12. [File map](#12-file-map)
13. [Example](#13-example)
14. [Licence](#14-licence)

---

## 1. Architecture

| Layer | Files | Role |
|-------|-------|------|
| **JS bridge** | `pbjsBridge/pbjsBridgeScript.js` | Injected into **every** window; builds `window.pbjs`; Promise-based request/response; inbound buffering; console capture; lifecycle push handling. |
| **Native router** | `pbjsBridge/pbjsBridge.pb` (+ `pbjsBridgeDeclare.pb`) | Receives JS→native callbacks, routes messages between windows, injects JS, escapes JSON, queues messages for not-yet-ready windows, broadcasts lifecycle events. |
| **Window mgmt** | `modules/JSWindow.pb`, `modules/WindowManager.pb`, `pbjs.pb` | Creates/owns webview windows, the registry, multi-instance **templates** + a pre-warmed **window pool**, readiness tracking, theming, OS title bar. |

**Adjacent (separate) bridges** that co-reside but are *not* PBJS:
`pbjsFileSystem/*` exposes `window.fs.promises` (own handshake
`pbjs-fs-ready`); a host app may also run a terminal/IO bridge. Each framework
keeps its **own** readiness — compose them at the app level, don't unify
(see §8).

The native host runs everything on the **main UI thread**, so the bridge is as
fast as the loop is free. Worker threads exist only for HTML load, content
visibility, and pool prep.

> **Why not a dedicated routing thread?** It wouldn't help. The WebView
> inject/callback APIs are UI-thread-pinned (so the costly `WebViewExecuteScript`
> stays on the main thread regardless), and the heavy rendering/JS already runs
> out-of-process inside the WebView — the host is just a thin marshaler. Routing
> itself is an O(1) lookup + string build; threading it only adds hops + locks on
> the currently lock-free registry. To free the loop, make each message *cheaper*
> (value-injection F4/F5, micro-batching) rather than threading the router.

---

## 2. Getting started

Two sides: the PureBasic host that owns the windows, and the page that talks to
`window.pbjs`. Run the example first — it is both halves, working:

```bash
./build.sh --run          # build.cmd on Windows
```

That builds the web app, compiles `pbjsExample.pb`, and launches it: a plain
PureBasic window with two buttons, driving two pbjs windows. You should see the
web app in the first window, and the buttons open and resize the second.

### 2.1 Hosting pbjs — the PureBasic side

Five things, all of them load-bearing. Nothing here is optional, and the ways
each one fails are given because none of them announces itself.

**1 · Include it.** `pbjs.pb` pulls in everything in the right order:

```purebasic
XIncludeFile "pbjs/pbjs.pb"
```

If your app has its own modules that route through `Sink` or `WindowManager`,
include those two **before** your module and leave the rest to `pbjs.pb`:

```purebasic
XIncludeFile "pbjs/modules/WindowManager.pb"
XIncludeFile "pbjs/modules/JSSink.pb"
XIncludeFile "your/module.pb"          ; may now use Sink:: / WindowManager::
XIncludeFile "pbjs/pbjs.pb"            ; skips the two above, includes the rest
```

**Only those two.** `pbjs.pb` reaches `WindowManager.pb` and `JSSink.pb` with
`XIncludeFile`, so it skips them when they are already in — whichever directive
you used. Everything else it reaches with a plain `IncludeFile`, so pre-including
one of those includes it twice; `OsTheme.pb` in front of `pbjs.pb` stops the
compile with `Module already declared: OsTheme`.

`XIncludeFile` on your side is still the safer habit — it is what lets *your*
tree include the file from more than one place. (`JSSink.pb` survives a plain
double include anyway, being guarded on `Defined(Sink, #PB_Module)`;
`WindowManager.pb` is not, and does not.)

`pbjsConfig.pb` is the exception in the other direction: it is guarded on
`Defined(PbjsConfig, #PB_Module)`, so a host **can** declare that module first to
override the build flags. `-co PBJS_DevMode=1` on the compiler command line
works too. What does **not** work is writing `#PBJS_DevMode = 0` at the top level
of your `main.pb`: PureBasic modules cannot see top-level constants at all, so it
is silently ignored — no error, no warning, no effect.

**2 · Initialise before creating any window.**

```purebasic
OsTheme::InitOsTheme()
WindowManager::InitWindowManager()
```

**3 · Create windows, and give them content from a `DataSection`.** The page is
embedded in the executable, not read from disk:

```purebasic
*Window = JSWindow::CreateJSWindow("main-window", 100, 100, 900, 600, "My App",
                                   #PB_Window_SystemMenu | #PB_Window_SizeGadget,
                                   ?MainWindow, ?EndMainWindow)
JSWindow::OpenJSWindow(*Window)

DataSection
  MainWindow:
  IncludeBinary "web/dist/index.html"
  EndMainWindow:
EndDataSection
```

The two labels bracket the bytes; pbjs decodes them as UTF-8 and injects the
bridge script into the `<body>` tag. A single-file build is the point — one HTML
document with the CSS and JS inlined (the example uses
`vite-plugin-singlefile`), because there is no server and no second request.

**4 · Dispatch pbjs's own events from your main event handler.** This is the
step that is easy to miss and silent when missed:

```purebasic
Procedure.i HandleMainEvent(Event.i, EventWindow.i, EventGadget.i, EventType.i)
  JSWindow::HandlePoolRefillEvent(Event)      ; multi-instance pool warming
  JSWindow::HandleDeferredCloseEvent(Event)   ; macOS: deferred CloseWindow
  JSWindow::HandleDeferredReleaseEvent(Event) ; macOS: deferred WKWebView release
  ; … your own handling; return non-zero to consume the event
  ProcedureReturn 0
EndProcedure
```

Omit the first and `openInstance` still works but never gets a warm spare, so
every open takes the cold path. Omit the other two on macOS and windows fail to
close properly — `CloseWindow` cannot be called from inside the
`WaitWindowEvent` stack, and a `WKWebView` released too early takes pending
`postMessage` blocks with it. All three are no-ops for events that are not
theirs, so dispatching them unconditionally is correct.

⚠ `pbjsExample.pb` does **not** dispatch these — it uses no templates, so it
never needed the first, and it is small enough to have got away without the
other two. Do not read the example as the contract here; read this.

**5 · Run the loop, then clean up.**

```purebasic
WindowManager::RunEventLoop(@HandleMainEvent(), 0, @KeepRunning())
WindowManager::CleanupManagedWindows()
```

The three slots are `(HandleMainEvent, HandleNetworkEvent, ShouldKeepRunning)`.
The middle one is the network hook for web mode; pass `0` if you have none.
Getting the order wrong is silent — passing `ShouldKeepRunning` in the second
slot means it is called only when `NetworkServerEvent()` fires, which for most
apps is never. (That exact bug lived in this repo's own example.)

`RunEventLoop` returns when no managed window is open any more and
`ShouldKeepRunning` says so too.

### 2.2 In the page — the JavaScript side

The bridge script builds `window.pbjs`, sets `window.pbjsReady`, and dispatches a
`pbjs-ready` DOM event:

```js
if (!window.pbjsReady) {
  await new Promise((r) => window.addEventListener("pbjs-ready", r, { once: true }));
}
console.log(window.pbjs.windowName, window.pbjs.os); // "main-window", "mac"
```

Register your handlers as early as you can — an inbound message that arrives
before its handler is buffered and replayed, but a single-target request whose
handler never appears is dead-lettered after a grace (§9).

> **A note on the examples below.** They are written against a thin typed
> wrapper, which is the shape most apps end up with. `invoke`, `handle`,
> `handleAll`, `send`, `sendAll`, `getWindow`, `waitForWindow`, `openInstance`,
> `onCloseWindow`, `stats` and the `dnd*` calls are all on `window.pbjs`
> unchanged. Two things in this document are **not**: `pbjs.channel` (§6) and
> `pbjs.waitForReady` / `waitForFSReady` (§8) are wrapper conveniences over the
> primitives above, and the wrapper also unwraps `invoke`'s `{ success }`
> envelope so you get the bare value. Each of those is flagged where it appears.
> Roadmap step 2.9 ships a supported wrapper and the typings to go with it; until
> then, write the thin layer yourself or call `window.pbjs` directly.

---

## 3. Request/response — `invoke` / `handle`

The RPC mode: call a method on another window and `await` its reply.

### Caller — `invoke`

```ts
// invoke(targetWindow, name, params, data?, options?) → Promise<reply>
const reply = await pbjs.invoke("main-window", "getAgentStatus", {}, { id: 7 });
```

**The arguments — `params` vs `data` vs `options`:**

| Arg | Crosses the bridge? | Read by | Use for |
|-----|:---:|---------|---------|
| `params` | ✅ payload slot 1 | the receiver's handler | legacy/secondary slot — usually `{}` |
| `data` | ✅ payload slot 2 | the receiver's handler | **the payload** (convention: put everything here) |
| `options` | ❌ caller-local | the `invoke` wrapper itself | control bag: `{ signal, timeoutMs }` |

`params` and `data` are **two payload slots that both reach the handler**
(`handler(event, params, data)`); the receiver reads `const p = data || params`.
The split is historical — there's no live semantic difference — so by convention
**the payload goes in `data`** and `params` stays `{}`. `options` is a different
kind of thing: a **local control bag the bridge consumes itself** (never
serialized, never sent, never seen by the handler) — `{ signal }` for
cancellation and `{ timeoutMs }` for the deadline (both below).

- **Rejects** on: handler `throw` / `event.error(msg)`, target window
  missing/closed (immediate native error), a dead-letter (no handler after a
  grace — §9), or the timeout. So error handling is ordinary `try/catch`.
- **Resolves to the handler's return value.** The bridge's reply carries an
  internal `{ success: value }` envelope on the wire (it's what lets the source
  tell success from error and resolve-vs-reject), but a **typed wrapper unwraps
  it once** so app code gets the bare value. Vynce's `Pbjs.ts` does this; if you
  call the raw `window.pbjs.invoke` directly, read `reply.success` yourself.
- `options.signal` (an `AbortSignal`) cancels a superseded call: the pending
  entry is dropped and the promise rejects with an `AbortError`; a late reply is
  ignored. Use for resize/search/autocomplete that supersede themselves.

```ts
const ac = new AbortController();
pbjs.invoke("main-window", "search", {}, { q }, { signal: ac.signal })
    .then(use).catch(e => { if (e.name !== "AbortError") throw e; });
ac.abort(); // supersede
```

- `options.timeoutMs` sets this call's deadline; the default is **30 000 ms**. A
  store hydration and a "did you save?" round trip do not deserve the same one,
  and 30 s is a long time to discover a wedged handler. A value that is not a
  positive finite number falls back to the default rather than producing a
  request that never times out. `invokeAll` takes the same option as its fourth
  argument, and on timeout **resolves with whatever arrived** rather than
  rejecting.

```ts
await pbjs.invoke("main-window", "ping", {}, {}, { timeoutMs: 2000 });
const replies = await pbjs.invokeAll("getAgents", {}, {}, { timeoutMs: 5000 });
```

### Receiver — `handle` / `handleAll`

```ts
// handle(fromWindow, name, fn) — accept this method only from `fromWindow`
// handleAll(name, fn)          — accept from ANY window  (the common case)
//
// Registering over an existing handler for the same key REPLACES it and warns:
// the loser just stops receiving messages, with nothing to see. Re-registering
// the same function is silent (React effects re-run). Count: stats().handlersReplaced
pbjs.handleAll("getAgentStatus", (event, params, data) => {
  const payload = data || params;            // see the params/data note in §11
  return { status: lookup(payload.id) };     // returned value → caller's .success
});
```

The handler receives `(event, params, data)`:

- Return a value (sync or a `Promise`) → sent back as the reply (`event.success`
  is called for you). `throw` or `return`-a-rejected-Promise → `event.error`.
- `event.success(v)` / `event.error(msg)` / `event.reply(v)` — explicit reply.
- `event.fromWindow` — origin window name.

Late registration is fine: a message that arrives before its handler is
**buffered** and replayed when the handler registers (bounded — §9).

---

## 4. Fire-and-forget — `send` / `sendAll`

No ack, no `requestId`, no 30 s timer, returns `void`. The cheap primitive for
events, notifications, presence, and **store-sync patches**.

```ts
pbjs.send("terminal-window", "agentRenamed", {}, { id, name }); // one window
pbjs.sendAll("agentRenamed", {}, { id, name });                 // all others (sender excluded)
```

- The receiver's `handle`/`handleAll` fires normally; it just isn't expected to
  reply.
- `send` to a not-yet-ready window is buffered natively; to an absent window it
  is dropped silently. `sendAll` excludes the sender and dormant pool spares.
- **Rule of thumb:** need a return value or an error → `invoke`; otherwise →
  `send`/`sendAll` (or `channel`, §6).

---

## 5. Broadcast request/response — `invokeAll` (⚠️ discouraged)

```ts
const replies = await pbjs.invokeAll("getStuff", {}, {}); // → [{windowName, response}, …]
```

Multicasts to every other window and resolves when all expected windows reply
(or after 30 s with whatever arrived).

> **Discouraged — no production caller.** Once you have `channel`/`sendAll` for
> events and per-window `invoke` for RPC, `invokeAll` only fits a true "ask
> everyone and aggregate" case — and it has sharp edges: it can't surface
> per-window failure (resolves with partial results after 30 s — pbjs.md F8),
> each `response` is the raw `{ success }`/`{ error }` envelope (not unwrapped
> like `invoke`), and it must keep excluding dormant pool spares (F13). Prefer the
> alternatives unless you genuinely need every window's reply at once.

---

## 6. Pub/sub topics — `channel`

> ⚠ **Wrapper-only.** `channel` is not on `window.pbjs`. It is a small layer over
> `sendAll` + `handleAll` — one reserved message name per topic, a local
> subscriber set, and the sender filtered out — that every multi-window app ends
> up writing. Described here because the shape is worth copying; roadmap 2.9
> ships it.

A `BroadcastChannel`-like layer over `send`/`sendAll` that **decouples senders
from concrete window names** and allows **multiple local subscribers per topic**
(which raw `handleAll` does not).

```ts
const ch = pbjs.channel("agents");
const off = ch.subscribe((payload, { from }) => applyPatch(payload));
ch.post({ id, status: "running" });   // → every other window's subscribers
ch.send("terminal-window", { id });   // → one window's subscribers
off();                                 // unsubscribe one
ch.close();                            // remove all subscriptions from THIS handle
```

- **Echo-free:** the native broadcast excludes the sender, so a window never
  receives its own `post`. `meta.from` carries the origin for relays/diagnostics.
- **Primitive-safe:** payloads are wrapped as `{ v: payload }` on the wire, so
  `0` / `""` / `false` / `null` survive.
- **Namespaced** (`chan:` prefix) so topics can't collide with plain
  `handle`/`handleAll` names.

This is the transport the cross-window store-sync engine runs on (§10).

---

## 7. Window management

```ts
// Lookup / wait
const w   = await pbjs.getWindow("terminal-window");        // PBWindow | undefined
const w2  = await pbjs.waitForWindow("terminal-window");    // settles on the host's
                                                            // "ready" push; 6 s default

// Multi-instance templates + pre-warmed pool
const r = await pbjs.openInstance(
  "agent-window",            // template name (PB: JSWindow::RegisterTemplate)
  `agent-${id}`,             // dedupe key — reopen focuses the existing window
  { id, name },              // params → delivered as a "handleParameters" message
  { smartPosition: true },   // optional; reloadOnReuse also available
);                           // → { success, name, id } | { error }

// Lifecycle / chrome
pbjs.onCloseWindow(async () => { await cleanup(); return true; }); // allow/deny close
await pbjs.setWindowTitle(`MyApp — ${name}`);
await pbjs.focusWindow("terminal-window");
```

**Templates + pool** are a core strength: window creation (a fresh WebView, tens
of MB, multi-ms) is amortized off the click path. `openInstance` dedupes by
`template:key` (focus if open), else claims a ready spare from the pool, sends
params, and async-refills the pool. A `PBWindow` reference exposes
`open/close/hide/show/isOpen`.

The target window receives `openInstance` params via a `handleParameters`
message — register it early so the first message isn't missed:

```ts
pbjs.handleAll("handleParameters", (_e, params) => setState(params));
```

**Cross-window drag & drop** is a separate, generic service layered on top of
this transport — not part of the core API above. A source window starts a
session, native tracks the cursor and hit-tests the topmost window across the
whole desktop (a 15 ms timer, not client-rect math), and any window can register
as a drop target for typed payloads.

On `window.pbjs` the calls are flat, and every one resolves to the native
reply parsed from JSON:

```ts
if (pbjs.dndAvailable) {                       // the service is actually live
  const { sessionId } = await pbjs.dndStart({ type, payloadJson, badge });
  await pbjs.dndUpdateBadge(sessionId, badge);
  await pbjs.dndSetZoneActive(sessionId, true);
  await pbjs.dndDrop(sessionId);               // or dndCancel(sessionId)
}
await pbjs.dndRegisterTarget(["agent-tab"]);   // …and dndUnregisterTarget()
```

`dndAvailable` reports whether `DndService` *started* — host has it, `PBJS_DND`
is not `0`, macOS, not web mode — not merely whether the natives exist, which
they do regardless. macOS only today; feature-detect and degrade elsewhere.

The native half lives here (`modules/DndService.pb`, `modules/DragBadge.pb`)
and each carries its protocol and release-semantics notes in its own header —
that is the reference, since a consumer of pbjs has no other repo to open.

Flags: `PBJS_DND=0` disables the service outright; `PBJS_DND_DEBUG=0` turns off
the per-transition log at `$TMPDIR/pbjs_dnd_debug.log`.

---

## 8. Lifecycle & readiness

> ⚠ **`waitForReady` and `waitForFSReady` are wrapper-only** — they are not on
> `window.pbjs`. The primitives they wrap are: `window.pbjsReady` plus the
> `pbjs-ready` event (§2.2), and `window.fs` plus the `pbjs-fs-ready` event.
> Everything else in this section is the real bridge.

```ts
await pbjs.waitForReady();      // pbjs core ready (pbjs-ready event)
await pbjs.waitForFSReady();    // window.fs ready (pbjs-fs-ready, or 6s fallback)
pbjs.isReady;                   // sync boolean
pbjs.windowName;                // this window's runtime name
pbjs.os;                        // "windows" | "mac" | "linux" | "other"
```

**Three independent handshakes** (`pbjs`, `pbjsFileSystem`, and any host IO
bridge) each own their readiness. A window that needs several **composes** them
at the call site — this "needs both" fact is app-specific, not framework-level:

```ts
await Promise.all([pbjs.waitForReady(), pbjs.waitForFSReady()]);
```

> Don't build a unified `bridges.waitForAll()` — it couples independently-reusable
> frameworks for no gain (see pbjs.md §6.6 / F12).

**Readiness cache + native push.** The bridge keeps a `readyWindows` set so
`invoke`/`send` skip a redundant readiness probe on the warm path. The native
host **pushes** lifecycle events (`window.pbjsWindowEvent(name, kind)`):

- `ready` — warms peers' caches.
- `reloaded` / `closed` — evicts the cache **and rejects in-flight requests
  targeting that window immediately**, instead of leaking to the 30 s timeout
  (the orphaned-request fix). Fired from `JSReadyState` (reload) and
  `CloseJSWindow` (close).

---

## 9. Robustness & diagnostics

- **Dead-letter fast-fail.** A `get` (invoke) to a target with no handler fails
  the caller after a short grace (`5000 ms`, override `window.pbjsDeadLetterGraceMs`)
  with an explicit `No handler for '<name>'` error — instead of a silent 30 s
  timeout. A handler that registers within the grace dispatches first.
- **Bounded queues.** The JS inbound buffer (`unhandledMessages`, cap 500) and
  the native per-window `PendingMessages` (cap 500) both drop-oldest + count
  drops, so a window that never registers a handler can't grow them unboundedly.
- **Pool-spare safety.** `sendAll`/`invokeAll`/lifecycle broadcasts skip dormant
  pool spares, so warming windows never stall a broadcast (pbjs.md F13).
- **Log levels.** High-frequency IPC traces print to devtools via the *original*
  console (not forwarded to native). General `console.*` forwarding is gated by
  `window.pbjsLogLevel` (`"INFO" | "WARN" | "ERROR" | "OFF"`, default `INFO`).
- **Stats.** `window.pbjs.stats()` (or `pbjs.stats()`) returns a counter
  snapshot — in-flight requests, buffered/dropped messages, dead-letters,
  ready-cache + handler sizes. Query it from any window's devtools.

```ts
pbjs.stats();
// { window, pendingRequests, pendingGetAll, unhandledBuffered,
//   droppedUnhandled, deadLetters, readyWindows, handlers }
```

---

## 10. Cross-window state sync

PBJS's `channel` + `send`/`sendAll` are the ideal transport for keeping a store
(Zustand, Redux, Valtio, …) **eventually consistent across all windows**. Because
each window is its own bundle, a "shared store" is really **N replicas converged
over the bridge**.

> The concrete sync engine (`SyncCore`, the Zustand `shared` middleware, the
> read-mirror + DOM-event bridge, and the typed RPC facade) lives in the **host
> app** (Vynce: `react/shared/stores/`), built on the pbjs primitives below. See
> the [Vynce README](../README.md#cross-window-zustand-stores) for the full,
> copy-pasteable how-to. This section documents the **pattern** so you can build
> it on pbjs in any app.

### 10.1 The model — single-writer (`leader-wins`)

- One window is the **leader** (authority + the only persister). On a local
  change it `channel(name).post(slice)` — the **whole partialized slice**, which
  is self-healing (a dropped patch is corrected by the next).
- Every other window is a **replica / read mirror**: it `subscribe`s and applies
  patches; it never broadcasts its own synced slice. Replica writes are
  **explicit intents** — an `invoke`/facade call to the leader, which runs the
  action (incl. side effects) and broadcasts the authoritative result.

### 10.2 The three hard parts (all solved by the pattern)

1. **Echo suppression** — one boolean: while applying a remote patch, the local
   subscribe callback must not re-broadcast. (The bridge already excludes the
   sender, so this single flag is sufficient.)
2. **Hydration** — a new replica asks the leader for a snapshot **over the same
   channel** as patches (`snap-req` → `snap-resp`). One FIFO stream ⇒ ordering is
   inherent ⇒ **no sequence numbers / clocks needed**. Re-hydrate on a
   `leader-online` announce.
3. **Coalescing** — batch a synchronous burst of changes into one broadcast
   (last value wins). Use a `MessageChannel` task, **not** `requestAnimationFrame`
   (paused when hidden) or a bare `setTimeout` (throttled when long-hidden).

### 10.3 Typed RPC facade ("how you type pbjs")

PBJS is a deliberately **untyped transport** — `invoke`/`send` take `any`. Typing
belongs **one level up, in app code**: a small facade that wraps the residual
commands with real signatures. The typed wrapper already returns the handler's
bare value (the `{ success }` envelope is stripped there — §3), so the facade
just types it.

```ts
export const myBridge = {
  toggleThing(id: number): Promise<void> {
    return pbjs.invoke("main-window", "toggleThing", {}, { id }).then(() => {});
  },
  getThing(id: number): Promise<Thing> {
    return pbjs.invoke<Thing>("main-window", "getThing", {}, { id }); // already unwrapped
  },
};
```

State **reads** should come from the synced mirror, not RPC — keep the facade to
genuine commands.

---

## 11. Conventions & gotchas

- **`params` vs `data`.** Both slots are forwarded to handlers; by convention the
  **payload goes in `data`** and handlers read `const p = data || params;`. `params`
  is usually `{}`. (Historical split — keep the convention for compatibility.)
- **Reply envelope.** The typed wrapper's `invoke` returns the handler's bare
  value; only the **raw** `window.pbjs.invoke` exposes the `{ success }` wire
  envelope (§3). Don't re-unwrap at call sites that already use the wrapper.
- **Register handlers early.** Especially `handleParameters` and anything a peer
  may call at startup — buffering covers a short gap, not arbitrary delay (and a
  `get` past the grace now dead-letters).
- **`pbjs/` is generated/embedded.** In a host app the built bridge script is
  embedded into the native binary as a resource; **changing `pbjsBridgeScript.js`
  or any `.pb` requires a native rebuild** to take effect.
- **Single UI thread.** Anything that blocks the native loop blocks all IPC.
- **Don't unify handshakes** (§8 / F12). **Don't type the transport** (§10.3 / F6).

---

## 12. File map

```
pbjs/
├── pbjs.pb                        include THIS — pulls in everything, in order
├── pbjsConfig.pb                  build flags (#PBJS_DevMode, #PBJS_EnableDevTools)
├── pbjsBridge/
│   ├── pbjsBridgeScript.js        ← the injected JS bridge (window.pbjs)
│   ├── pbjsBridge.pb              ← native router (Get/GetAll/Send/SendAll/Reply,
│   │                                EscapeJSON, QueuePending, NotifyWindowEvent)
│   └── pbjsBridgeDeclare.pb       module interface
├── modules/
│   ├── JSWindow.pb                window registry, templates, pool, JSReadyState,
│   │                              CloseJSWindow (lifecycle push)
│   ├── WindowManager.pb           event loop integration
│   ├── JSSink.pb                  per-window script/callback routing (web mode)
│   ├── OsTheme.pb                 dark-mode detection + window colours
│   └── DndService.pb / DragBadge.pb   cross-window drag & drop (macOS)
├── pbjsFileSystem/                separate window.fs bridge (own handshake)
├── webviewBaseUrl/                spike: giving the webview a real origin (3.2)
├── reactExample/ + pbjsExample.pb  the one canonical example (§13)
├── build.sh / build.cmd           build the example end to end
├── tests/                         jsdom + native harnesses — tests/README.md
├── ci/                            the checks; ci/pre-push is the everyday gate
├── iplan/                         roadmap.md (the plan), checklist.md (what happened)
├── LICENSE    (MIT)
├── README.md  (this file)
└── CLAUDE.md  (one-screen summary)
```

---

## 13. Example

`pbjsExample.pb` is the **single canonical sample** — two pbjs windows plus a
plain PureBasic window driving them.

```bash
./build.sh --run          # build.cmd on Windows
```

Both steps, in order: the web app, then the executable. The order matters. The
`.pb` embeds the built page with `IncludeBinary` and
`reactExample/main-window/dist/` is gitignored, so on a fresh clone compiling
first fails with `Included file not found:
reactExample/main-window/dist/index.html`. That is the single most common way a
first build of this repo goes wrong, which is why it is a script.

By hand, if you would rather:

```bash
cd reactExample/main-window && npm ci && npm run build   # -> dist/index.html
cd ../.. && pbcompiler pbjsExample.pb --output pbjsExample
```

⚠ Read the example for the *shape* of a host, not for the contract: it uses no
multi-instance templates, so it never dispatches the three `JSWindow::Handle*Event`
calls §2.1 requires. Those are in §2.1 for a reason.

### Checks

```bash
ci/check-purebasic.sh      # syntax-check pbjs standalone + the example
node ci/check-sources.mjs  # include paths + host-only modules (no compiler needed)
```

`ci/check-purebasic.sh` finds your PureBasic install (or honours
`PUREBASIC_HOME`) and checks `ci/standalone-check.pb` — a file that includes
pbjs **and nothing else**. That is the one check worth having: pbjs is
developed as a nested repo inside a host app, so a dependency on a host-only
symbol compiles fine for its author and fails for everyone else.

To run both before every push:

```bash
ln -sf ../../ci/pre-push .git/hooks/pre-push
```

⚠ The compiler checks need a **licensed** PureBasic — the free version caps
source files at 800 lines each and `modules/JSWindow.pb` is ~3,500. That is
also why CI only builds the example and runs the compiler-free checks; the
`pbcompiler` job (`.github/workflows/purebasic.yml`) is written for a
self-hosted runner and stays dormant until one is registered.

---

## 14. Licence

MIT — see [LICENSE](LICENSE).
