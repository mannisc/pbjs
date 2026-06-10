# PBJS — agent quick reference

PBJS is a **bidirectional JSON-RPC bridge** between N WebView windows and a
single **PureBasic host** that acts as the router (no direct webview↔webview).
This file is the one-screen orientation. **Full handbook: [README.md](README.md)**
— consult it for anything beyond the cheatsheet below.

## The API in a nutshell (`window.pbjs`, or the app's typed wrapper)

```ts
// request/response (await a reply; rejects on error/timeout/dead-letter)
const reply = await pbjs.invoke(targetWindow, name, params, data?, { signal? });
pbjs.handleAll(name, (event, params, data) => returnValue);   // receiver (any window)
pbjs.handle(fromWindow, name, fn);                            // receiver (one source)

// fire-and-forget (no ack, returns void)
pbjs.send(targetWindow, name, params, data);
pbjs.sendAll(name, params, data);                            // all others (sender excluded)

// pub/sub topics (multi-subscriber, echo-free, primitive-safe)
const ch = pbjs.channel(name); ch.post(x); ch.send(win, x); const off = ch.subscribe(fn);

// windows
await pbjs.getWindow(name); await pbjs.waitForWindow(name);
await pbjs.openInstance(template, key, params, opts?);        // multi-instance + pooled
pbjs.onCloseWindow(async () => true); await pbjs.setWindowTitle(t); await pbjs.focusWindow(name);

// lifecycle / diagnostics
await pbjs.waitForReady(); await pbjs.waitForFSReady();
pbjs.windowName; pbjs.os; pbjs.isReady; pbjs.stats();
```

## Must-know rules

- **Payload in `data`**; handlers read `const p = data || params;` (`params` ≈ `{}`).
- **`invoke` (typed wrapper) resolves to the handler's bare value** — the
  `{ success }` wire envelope is stripped in the wrapper. Only the raw
  `window.pbjs.invoke` exposes it. Add types in an app-owned facade.
- **Need a reply → `invoke`; otherwise → `send`/`sendAll`/`channel`.** `invokeAll`
  is rarely needed.
- **Register handlers early** (esp. `handleParameters`): late `get`s buffer only
  briefly, then dead-letter after `pbjsDeadLetterGraceMs` (5 s).
- **Three handshakes** (`pbjs`, `fs`, host IO) — compose with `Promise.all`, don't
  unify them.
- **Editing `pbjsBridgeScript.js` or any `.pb` needs a native rebuild** to take
  effect (the script is embedded). `pbjs/` is a git-ignored nested repo.

## Built-in robustness (README §9)

Readiness cache + native lifecycle push (`pbjsWindowEvent` → orphan-reject on
reload/close), dead-letter fast-fail, bounded queues (drop-oldest + counters),
pool-spare-filtered broadcasts, level-gated native logging (`window.pbjsLogLevel`),
`pbjs.stats()`.

## Cross-window stores

`channel` + `send`/`sendAll` are the transport for keeping a store (Zustand/…)
consistent across windows: **single-writer leader broadcasts the whole slice;
replicas are read mirrors**; hydrate over the same FIFO channel (no clocks).
The host app owns the engine — see README §10 and the host's Zustand docs.
