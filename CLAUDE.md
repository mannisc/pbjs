# PBJS — agent quick reference

PBJS is a **bidirectional JSON-RPC bridge** between N WebView windows and a
single **PureBasic host** that acts as the router (no direct webview↔webview).
This file is the one-screen orientation. **Full handbook: [README.md](README.md)**
— consult it for anything beyond the cheatsheet below.

## The API in a nutshell — what is actually on `window.pbjs`

```ts
// request/response (await a reply; rejects on error/timeout/dead-letter)
const reply = await pbjs.invoke(targetWindow, name, params, data?, { signal?, timeoutMs? });
const all   = await pbjs.invokeAll(name, params, data, { timeoutMs? });  // rarely needed
pbjs.handleAll(name, (event, params, data) => returnValue);   // receiver (any window)
pbjs.handle(fromWindow, name, fn);                            // receiver (one source)
pbjs.removeHandler(fromWindow | null, name); pbjs.removeAllHandlers();

// fire-and-forget (no ack, returns void)
pbjs.send(targetWindow, name, params, data);
pbjs.sendAll(name, params, data);                            // all others (sender excluded)

// windows
await pbjs.getWindow(name); await pbjs.waitForWindow(name, timeoutMs?);
await pbjs.openInstance(template, key, params, reloadOnReuse?, opts?);  // pooled
pbjs.onCloseWindow(async () => true);

// drag & drop (macOS; feature-detect on pbjs.dndAvailable)
await pbjs.dndStart(spec); await pbjs.dndDrop(id); await pbjs.dndRegisterTarget(types);

// identity / diagnostics
pbjs.windowName; pbjs.os; pbjs.dndAvailable; pbjs.stats();
window.pbjsReady;  window.addEventListener("pbjs-ready", …)
```

⚠ **Two surfaces, and mixing them up is the recurring documentation bug.** The
list above is the **bridge**. `pbjs.channel(…)`, `waitForReady()`,
`waitForFSReady()`, `setWindowTitle()`, `focusWindow()`, `setWindowState()`,
`getWindowMetrics()`, `startWindowDrag()`, `isReady` and the nested `pbjs.drag.*`
shape are the **client** — `pbjsClient/pbjsClient.ts`, which now ships here
(roadmap 2.9, option (b)). It is optional: the bridge works without it.

Rule of thumb: `window.pbjs.dndStart` is bridge, `pbjs.drag.start` is client;
raw `invoke` gives you `{ success: value }`, the client's gives you the value.
`setWindowTitle`/`focusWindow` and friends had their natives bound with **no JS
caller at all** until the client landed. See `pbjsClient/README.md`.

⚠ **`pbjsClient/` is vendored into the host app and this repo is canonical** —
edit here, copy out. `ci/pre-push` fails on drift, and `ci/check-sources.mjs`
fails if a host-app name reappears in it.

## Must-know rules

- **`params` & `data` both reach the handler** (`handler(event, params, data)`) —
  payload goes in `data`, `params` ≈ `{}` (historical split). **`options`**
  (`{ signal, timeoutMs }`) is caller-local: consumed by the bridge, never sent
  to the handler. (Table in README §3.)
- **Registering over an existing handler replaces it and warns** — the loser just
  stops receiving messages. Re-registering the *same* function is silent.
  `stats().handlersReplaced`.
- **`invoke` (typed wrapper) resolves to the handler's bare value** — the
  `{ success }` wire envelope is stripped in the wrapper. Only the raw
  `window.pbjs.invoke` exposes it. Add types in an app-owned facade.
- **Need a reply → `invoke`; otherwise → `send`/`sendAll`.** `invokeAll` is
  rarely needed (and a `channel`-style topic layer belongs over `sendAll`).
- **Register handlers early** (esp. `handleParameters`): late `get`s buffer only
  briefly, then dead-letter after `pbjsDeadLetterGraceMs` (5 s).
- **Three handshakes** (`pbjs`, `fs`, host IO) — compose with `Promise.all`, don't
  unify them.
- **Editing `pbjsBridgeScript.js` or any `.pb` needs a native rebuild** to take
  effect (the script is embedded). `pbjs/` is a git-ignored nested repo.
- **There are tests now** — `tests/README.md`. `cd tests && npm test` (jsdom, no
  compiler) and `tests/pb/run.sh` (the native router). ⚠ After touching an
  escaper or a hand-built frame in `pbjsBridge.pb`, re-run the native harness
  and commit `tests/fixtures/native-frames.json`: the jsdom round trip asserts
  against that file, so a stale copy passes while testing the old wire format.
  `ci/pre-push` runs both and fails on the drift.

## Hosting it

Five load-bearing steps, each with the symptom of getting it wrong: README §2.1.
The one most often missed is dispatching `JSWindow::HandlePoolRefillEvent` /
`HandleDeferredCloseEvent` / `HandleDeferredReleaseEvent` from the host's main
event handler — omitting them silently breaks pooling and macOS close, and
`pbjsExample.pb` does **not** demonstrate them.

`./build.sh --run` builds the example end to end and launches it.

## Built-in robustness (README §9)

Readiness cache + native lifecycle push (`pbjsWindowEvent` → orphan-reject on
reload/close), dead-letter fast-fail, bounded queues (drop-oldest + counters),
pool-spare-filtered broadcasts, level-gated native logging (`window.pbjsLogLevel`),
`pbjs.stats()`.

## Cross-window stores

`sendAll` (with a `channel`-style layer over it) is the transport for keeping a store (Zustand/…)
consistent across windows: **single-writer leader broadcasts the whole slice;
replicas are read mirrors**; hydrate over the same FIFO channel (no clocks).
The host app owns the engine — see README §10 and the host's Zustand docs.
