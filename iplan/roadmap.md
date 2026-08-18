# PBJS roadmap — window management & framework hardening

**Status:** canonical plan. This file absorbs and supersedes two sources:

1. The **window-management deep review** (2026-08-17, rev 2) — 30 findings
   R1–R10 / P1–P7 / F1–F6 / S1–S4, read against `JSWindow.pb`,
   `WindowManager.pb`, `pbjsBridge.pb`, `pbjsBridgeScript.js`, `JSSink.pb`,
   `OsTheme.pb` (~7,500 lines). Published artifact: "PBJS Window Review".
2. The **reuse-readiness review** (`iplan/suggestions.md`) — 15 findings
   B1–B3, G1–G7, X1–X5. **All 15 re-validated against the tree at `51fd11e`
   on 2026-08-17/18: confirmed, none rejected.** Its actionable content and
   measured data are carried inside the steps below; after review,
   `suggestions.md` is to be deleted.

All `file:line` references are against pbjs @ `51fd11e`. Line numbers drift;
the symbol names don't.

**How to read a step:** each has *Do* (the change), *Why* (evidence),
*How* (concrete approach, including any measured data needed), *Verify*,
*Effort*, *Depends on*. Steps are ordered by intended execution order inside
each phase. IDs are kept so the two source reviews stay cross-referenceable.

---

## Phase overview

| Phase | Theme | Effort | Steps |
|---|---|---|---|
| **1** | Stop the bleeding; unblock standalone use | ≈ 3–4 days, all local | 1.1–1.13 |
| **2** | Idle costs, kept promises, adoptability | ≈ 1–2 weeks | 2.1–2.10 |
| **3** | New surface, origin/packaging, structure | measure/design-first | 3.1–3.9 |

Rules that shaped the ordering:

- Trivial unblocks first (1.1–1.4), then the CI that locks them in (1.5),
  then correctness fixes.
- `pbjsConfig.pb` (1.6) is a **prerequisite** for the B3 origin work (3.2) —
  the URL path cannot be gated on `#PB_Compiler_Debugger`.
- The test harnesses (2.1) come before everything they can guard.
- fs-bridge confinement (inside 3.3) ships **in the same release** as the B3
  origin work (3.2) — a URL-loading pbjs with an unconfined `window.fs` is a
  remote-code-to-disk hole.
- The structural refactors (3.7) come last, after harnesses exist.

---

# Phase 1 — Stop the bleeding, unblock standalone use

## 1.1 · B1 — Delete `UseModule Ptym`

- **Do:** delete `modules/JSWindow.pb:228` (`UseModule Ptym`).
- **Why:** pbjs does not compile outside Vynce. `Ptym` is Vynce's PTY module;
  it resolves only because Vynce's `main.pb` includes `ptym/ptym.pb` before
  `pbjs/pbjs.pb` — a load-bearing, undocumented include order. Verified with
  the PB 6.21 syntax checker: a file containing only `IncludeFile "pbjs.pb"`
  fails with `Line 228 - Module not found: Ptym.`
- **How:** the line is dead — the only other `Ptym` occurrences in the repo are
  two comments (`:2043`, `:2855`), and a syntax check with an **empty** `Ptym`
  shim passes (6,221 lines clean), proving no symbol from the module is used.
  Just delete it. For any *future* optional host coupling, the correct pattern
  already exists in the tree: `PbjsStartupTraceMark` (`JSWindow.pb:12`) —
  `CompilerIf Defined(<module>, #PB_Module)`, which compiles to nothing when
  the host module is absent. B1 was that idea done wrong.
- **Verify:** syntax-check a file whose entire content is
  `IncludeFile "pbjs.pb"` — must pass with no shim. (Becomes CI in 1.5.)
- **Effort:** 1 line. **Depends on:** —

## 1.2 · X1 — Delete `pbnodejs.pb`

- **Do:** delete `pbnodejs.pb` (247 lines) from the repo root (or move to
  `examples/` if kept as a teaching artifact — not next to `pbjs.pb` where it
  reads as a supported module).
- **Why:** referenced by zero `.pb`/`.pbp` files (verified). Self-described
  demo ("This demonstrates how to bridge Node.js filesystem methods"),
  superseded by `pbjsFileSystem/`, and buggy on its own terms: hardcoded file
  handle `0`, and `fs_readFileSync` interpolates file contents into JSON with
  no escaping.
- **Verify:** grep for `pbnodejs` returns nothing; standalone syntax check
  still passes.
- **Effort:** trivial. **Depends on:** —

## 1.3 · G1 — Fix or delete `example.pb`

- **Do:** either delete `example.pb` and make `pbjsExample.pb` the single
  canonical sample, or repair it. One example that works beats two where the
  one literally named "example" is broken.
- **Why:** two independent faults, both verified: `example.pb:48` calls
  `CreateJSWindow(600, 100, …)` — the **old** signature (current one,
  `JSWindow.pb:40`, takes `windowName.s` first); `example.pb:78` embeds
  `react/main-window/dist/index.html` — no `react/` directory exists (the
  example app is at `reactExample/`).
- **Verify:** the remaining example compiles after `npm install && npm run
  build` in `reactExample/main-window/`.
- **Effort:** small. **Depends on:** —

## 1.4 · B2 — Add a licence

- **Do:** add `LICENSE` at the repo root (MIT for maximum adoption / minimum
  reading, or Apache-2.0 for the explicit patent grant). Note it in
  `README.md`; set the GitHub licence field.
- **Why:** no `LICENSE`/`COPYING` anywhere (verified); GitHub reports
  `licenseInfo: null`. A public repo without a licence is all-rights-reserved:
  no third party (including a future `pbjs-capacitor`) may legally use it.
  Cheapest credibility fix available for an "Electron alternative".
- **Effort:** minutes. **Depends on:** deciding MIT vs Apache-2.0.

## 1.5 · G7a — Standalone syntax-check CI

- **Do:** a GitHub Action that (a) syntax-checks pbjs **standalone**
  (`pbcompiler --check` on a file that only includes `pbjs.pb`), (b) builds
  the example (`npm ci && npm run build` in `reactExample/main-window`, then
  compile the sample `.pb`).
- **Why:** locks in 1.1 forever — this class of leak (a Vynce-only symbol
  working locally) currently fails **in a stranger's terminal**, because pbjs
  is developed as a nested repo inside Vynce where `Ptym`, `StartupTrace` and
  the `iplan/` docs all happen to exist. The CI job is the smallest thing that
  makes the library's real boundary observable (suggestions §9 — endorsed).
  It is also the carrier workflow for the 2.1 test harnesses.
- **How:** macOS runner; resolve the compiler via the `PUREBASIC_HOME` pattern
  Vynce already uses in `scripts/purebasic-home.js`.
- **Effort:** small. **Depends on:** 1.1 (else the job fails on day one).

## 1.6 · R8 + X4 — `pbjsConfig.pb`: give build-mode a home; gate devtools

- **Do:** create `pbjsConfig.pb`, included first from `pbjs.pb`, owning
  build-mode and tunables. Move `#Debug_On` there (deprecated alias in
  `OsTheme` if any host references it). Gate `#PB_WebView_Debug` on it, with
  an explicit opt-in constant for release-diagnostics builds.
- **Why (two findings, one root cause — build-mode has no home):**
  - **X4:** `#Debug_On = #PB_Compiler_Debugger` is declared in `OsTheme.pb:27`
    — the *theming* module — yet gates content-loading branches in
    `JSWindow.pb` (incl. whether a URL can be loaded at all). Nobody auditing
    content loading reads OsTheme; that misplacement is a large part of why
    the B3 blocker stayed invisible.
  - **R8:** the inverse case — `WebViewGadget(..., #PB_WebView_Debug)` at
    `JSWindow.pb:1564` is **unconditional**, so shipped apps expose
    devtools/inspection on windows that hold full native bindings.
- **Verify:** release compile has no devtools context menu; debug build does;
  `OsTheme.pb` no longer defines build flags.
- **Effort:** small. **Depends on:** —. **Blocks:** 3.2 (the `startUrl`/baseURL
  path must be selectable independently of "is the PB debugger attached").

## 1.7 · R1 — Close-veto protocol: timeout + auto-approve

- **Do:** three layers:
  1. JS: in `pbjsHandleMessage` (`pbjsBridgeScript.js:1113–1120`), a
     `close-window` request with **no registered handler** must auto-reply
     `success:true` instead of being ignored — no handler means no veto.
  2. Native: a watchdog while `ClosingScope != 0` (2–3 s): treat unanswered
     windows as approved (set `BypassCloseCheck`, call `CheckCloseProgress`)
     or `CancelClose` — either ends the wedge.
  3. UX escape hatch: a repeated close on the same scope bypasses the pending
     check (user intent is unambiguous).
- **Why:** `RequestClose` (`JSWindow.pb:2760`) sends checks and sets the
  global `ClosingScope`; progress happens **only** in `HandleReply` /
  `CheckCloseProgress` (`:2677`) when replies arrive. A ready window without
  an `onCloseWindow` handler never replies (JS deliberately ignores unhandled
  `close-window`), a hung page never replies at all → `ClosingScope` stays
  set forever and **every subsequent close click on any window is silently
  consumed** (`RequestClose` returns 0 while a scope is pending). App becomes
  unquittable short of a kill. Latent in Vynce only because every window
  registers a handler. Note the asymmetry that proves the hole: the
  *not-ready* case is already auto-approved (`SendCloseCheck`,
  `pbjsBridge.pb:545–548`); the ready-but-handlerless case is not.
- **Verify:** harness test (2.1): window with no close handler → close
  completes; hung handler → watchdog fires; veto (`return false`) still
  cancels.
- **Effort:** hours. **Depends on:** —

## 1.8 · R3 — Complete `EscapeJSON` (port the fs-bridge escaper)

- **Do:** extend `EscapeJSON` (`pbjsBridge.pb:76–93`) to escape **every**
  remaining C0 control character (` `–`` beyond the handled
  `\r \n \t`) as `\u00XX`. Also escape or validate `name`/`fromWindow` at the
  hand-built envelope sites (`HandleSend :161`, `HandleGet :202`,
  `HandleSendAll :277`, `HandleGetAll :341`, `HandleReply :451`,
  `SendParameters :512`, `SendCloseCheck :537`, `SendSystemMessage :569`,
  `SendSystemRequest :598`) — a `"` in a handler name currently corrupts the
  inner JSON frame.
- **Why:** any payload string containing an unhandled control char (ESC in a
  terminal title, a pasted control char in a name) produces invalid JSON in
  the injected literal; `JSON.parse` throws inside `pbjsHandleMessage`, the
  catch logs, and the message — a store-sync patch, a reply — is **silently
  dropped**.
- **How:** **do not reinvent** — `pbjsFileSystem/pbjsFileSystem.pb:63` already
  documents and solves exactly this ("JSON forbids ANY raw C0 control
  character (U+0000..U+001F) inside a string") for the fs bridge. Port that
  escaper into `EscapeJSON`.
- **Verify:** harness round-trip of a payload containing `\x08`, `\x0C`,
  `\x1B`; regression test becomes part of the 2.1 router harness.
- **Effort:** hours. **Depends on:** —

## 1.9 · R2 — Wire the monitor-topology response

- **Do:** when `UpdateMaxDesktopSize()` (`WindowManager.pb:360–382`) detects
  growth, walk `JSWindows()` and `ResizeGadget` every webview to the new
  `MaxDesktopWidth × MaxDesktopHeight`, then re-fire `UpdateWebViewScale`.
  Delete the never-assigned `MaxSizeChangedProc` plumbing (`:23`, `:385–391`).
- **Why:** webview gadgets are created once at startup desktop size
  (`JSWindow.pb:1564`). The 500 ms poll detects a larger display but its only
  consumer, `MaxSizeChangedProc`, is **assigned by nothing** (verified —
  declaration and call site only). Dock into a bigger monitor → every
  window's webview is smaller than the window can get; maximized windows show
  a bare right/bottom stripe.
- **Verify:** manual: launch on laptop screen, dock into larger display,
  maximize — full coverage. (Automated coverage impractical.)
- **Effort:** hours. **Depends on:** —. **Related:** 2.3 replaces the poll
  itself with events; land R2 first so the event has a real consumer.

## 1.10 · R4 — WindowManager registry cleanup + honest dispatch condition

- **Do:**
  1. In `CloseManagedWindow` (`WindowManager.pb:194–203`): remove the
     window's `ManagedWindowsHandles()` entry (capture the hWnd at
     `AddManagedWindow` time — after `CloseWindow` it is unrecoverable) and
     arrange removal of the list element outside iteration.
  2. Rewrite `HandleWindowEvent`'s condition (`:276–287`): today
     `KeepWindow = CallFunctionFast(...)` inside the `If` is a **comparison**,
     not an assignment — it behaves correctly only because `KeepWindow` stays
     0, and the `DeleteElement` branch it guards is effectively unreachable.
     Make it an explicit call + test.
- **Why:** closed windows are only flagged `Closed=#True`; the list and the
  handle map grow monotonically (every event dispatch scans dead entries),
  and `GetManagedWindowFromWindowHandle` (`:352–357`) is keyed by native
  handle — which the OS **recycles** — so a new window can alias a stale
  entry and route events into a dead `AppWindow`.
- **Verify:** open/close N template instances; assert list size and map size
  return to baseline (router harness can drive this natively in 2.1).
- **Effort:** half a day. **Depends on:** —

## 1.11 · R6 — Pool refill drains fully

- **Do:** at the end of `HandlePoolRefillEvent` (`JSWindow.pb:2041–2060`), if
  `PoolRefillQueue()` is non-empty, `PostEvent(#Event_Pool_Refill)` again.
- **Why:** `RefillPoolAsync` (`:2022–2038`) enqueues *need* entries but posts
  **one** event; the handler dequeues **one**. With `poolTargetSize > 1` the
  remaining spares wait for some unrelated future refill trigger — the API
  advertises a knob that doesn't work past 1. One-spare-per-loop-tick also
  preserves the (desirable) creation stagger.
- **Verify:** register a template with `poolTargetSize = 3`; assert 3 spares
  exist without further opens.
- **Effort:** 2 lines. **Depends on:** —

## 1.12 · R9 — Close-check ids from the counter, not the clock

- **Do:** `SendCloseCheck` (`pbjsBridge.pb:531–551`) uses
  `requestId = ElapsedMilliseconds()`; switch to the existing
  `NextSystemRequestId` counter (used correctly by `SendSystemRequest`,
  `:590–594`).
- **Why:** `RequestClose` issues checks to N windows in a tight loop —
  same-millisecond collisions are routine. It works today only because close
  replies are routed by source window, not id; it's a latent trap for anyone
  extending the protocol.
- **Effort:** 2 lines. **Depends on:** —

## 1.13 · P7 — Small-burns bundle

Independent local cleanups; none needs design:

- **(a) Double resize exec (Windows):** `WindowCallback WM_SIZE`
  (`JSWindow.pb:3223`) *and* `#PB_Event_SizeWindow` (`:2933`) both call
  `UpdateWebViewScale` per resize step. Dedupe by last w/h, as the mac
  observer (`MacOSFrameDidChange`) already does.
- **(b) Per-spare HTML decode:** every spare re-decodes the multi-MB embedded
  HTML (`LoadHtml`, `:1497–1519`) and re-runs bridge-script prep
  (`PrepateBridgeScript`, `pbjsBridge.pb:648–688`, decode + 3 ReplaceStrings).
  Cache the decoded base HTML and the bridge script per template; substitute
  only the window name per instance.
- **(c) Win10 first-show dead code:** `OpenManagedWindow`
  (`WindowManager.pb:117–140`) blocks the main thread with `Delay(32)` and
  calls `FillRect_(hdc, @rect, brush)` with an **uninitialized** `brush`
  (no-op). Delete the dead paint; reconsider the delay.
- **(d) Log I/O:** `LogToDebugFile` (`JSWindow.pb:383–400`) opens/closes the
  file per line on the ready path — buffer or gate it.
- **(e) O(n) router lookups:** `HandleSend`/`HandleGet`/`HandleReply` resolve
  the target via `ForEach JSWindows()` scans (`pbjsBridge.pb:168, 210, 242,
  284…`) when `FindMapElement(JSWindows(), Str(id))` is O(1).
- **(f) JS chatter:** `getWindow`/`open`/`openInstance` log through the
  forwarding `console.log` (each cold call ships logs over the bridge); route
  bridge-internal logs through `originalConsole` like the IPC traces.

- **Effort:** ~1 day for the bundle. **Depends on:** —

---

# Phase 2 — Idle costs, kept promises, adoptability

## 2.1 · S4 — Test harnesses (do this first; it guards the rest)

- **Do:**
  1. **JS harness (jsdom):** load `pbjsBridgeScript.js` with a ~50-line fake
     native (stub the `pbjsNative*` binds; drive inbound via
     `pbjsHandleMessage`/`pbjsHandleResponse`/`pbjsWindowEvent`). Cover:
     buffering + replay, dead-letter grace, AbortSignal, orphan-reject on
     `closed`/`reloaded`, `getAll` expected-count edge cases (0 targets, late
     count), the R1 auto-approve, drop counters.
  2. **Native router harness (Sink-based):** register headless sinks
     (`Sink::RegisterHeadless`), install an `ExecHook` that captures scripts
     (`JSSink.pb:69–73 SetHooks`, `:184 DispatchCall`), and exercise
     `pbjsBridge` end to end without a single webview: queueing to not-ready
     windows, spare filtering, escape correctness (R3's regression), registry
     cleanup (R4's regression).
- **Why:** the framework has zero tests, and its most intricate logic (the
  1,255-line bridge script; the router's queue/filter/escape behavior) is
  exactly what's cheap to test now — the Sink seam made the native side
  testable without UI. Everything later in Phase 2/3 (scheduler, refactors,
  B3) needs this net.
- **How:** rides the 1.5 CI workflow. Vynce already tests its sync engine in
  jsdom (`react/shared/stores/sync/`) — same pattern.
- **Effort:** 1–2 days. **Depends on:** 1.5 (workflow exists).

## 2.2 · P1 — Let the event loop sleep

- **Do:** in `RunEventLoop` (`WindowManager.pb:295–348`): when no network
  server is active, call blocking `WaitWindowEvent()`; when one is (web
  mode), poll `NetworkServerEvent()` from a 100–250 ms window timer instead
  of inline at 60 Hz — and drain it in a `While NetworkServerEvent()` loop
  per wake so bursts don't serialize at one event per tick.
- **Why:** `WaitWindowEvent(16)` wakes ~60×/s forever, even fully idle —
  constant CPU/battery, keeps the process out of App Nap, and caps network
  throughput at ~60 events/s. The keep-running scan over all managed windows
  runs per wake too.
- **Verify:** idle wakeups in Activity Monitor before/after (~60/s → ~0);
  web-mode relay still works (Vynce `npm run dev:web` smoke).
- **Effort:** half a day. **Depends on:** knowing the host's web-mode wiring
  (Vynce `webproxy.pb` supplies the network server).

## 2.3 · P2 — Display-change events replace the 500 ms poll

- **Do:** subscribe natively — `WM_DISPLAYCHANGE` (the Windows
  `WindowCallback` already exists), `NSApplicationDidChangeScreenParametersNotification`
  (macOS observer pattern already exists for resize), GDK `monitors-changed`
  (Linux) — and call the 1.9 response. Drop `#Timer_CheckDesktop`
  (`WindowManager.pb:64, 91–94`) or keep it at 5 s as belt-and-braces.
- **Why:** `ExamineDesktops()` twice a second forever, previously feeding
  dead code (R2).
- **Effort:** half a day. **Depends on:** 1.9.

## 2.4 · R7 + P3 — Live theme: watch it, cache it, stop forking

- **Do (one change, two findings):**
  1. **Cache:** detect theme once at init; serve `IsDarkModeActiveCached`
     (exists at `OsTheme.pb:16`, written once at `:226`, never read as a
     cache); invalidate only from watchers.
  2. **Watchers:** `WM_SETTINGCHANGE`/ImmersiveColorSet (Windows), KVO on
     `NSApp.effectiveAppearance` (macOS), GTK
     `notify::gtk-application-prefer-dark-theme` (Linux). On change: update
     `themeBackgroundColor`, `SetWindowColor` every window, and broadcast
     `updateDarkMode(isDark)` to every sink.
  3. **macOS detection:** replace the `RunProgram("/usr/bin/defaults")`
     subprocess (`OsTheme.pb:52`) with `NSApp.effectiveAppearance` via
     CocoaMessage — no fork at all.
- **Why:** the bridge ships `registerDarkModeChangeHandler`/`updateDarkMode`
  (`pbjsBridgeScript.js:202–230`) but **no native code ever calls them** —
  theme is a startup snapshot; a mid-run OS theme flip leaves every window
  stale. And detection currently runs **per window created** (via
  `PreparePbjsBasicScript` → `IsDarkModeActive()`), spawning `defaults` on
  macOS and up to three processes (`gsettings` ×2, `gdbus`) on Linux — on
  every pool refill.
- **Verify:** flip OS theme with the app running: chrome + pages update;
  `ps` shows no `defaults`/`gsettings` spawns after init.
- **Effort:** 1–2 days (three platforms). **Depends on:** —

## 2.5 · P4 — One scheduler instead of thread-per-delay

- **Do:** replace `PostEventAfterDelay`'s thread spawn
  (`JSWindow.pb:323–351`) with a main-thread deadline list serviced by a
  single `AddWindowTimer` (e.g. 50 ms granularity, or re-armed to the nearest
  deadline). Entries carry `(window, eventType, deadline)` and are
  **cancellable when their window closes**.
- **Why:** every delayed event spawns a full OS thread whose job is
  sleep-then-post — 2–4 threads per window prepare/open (prepare timeout ×2
  on Windows, content-ready delay, reveal watchdogs, fullscreen re-show).
  Stale posts landing on recycled window numbers are then absorbed by
  latches (`PrepareWaiting`) — complexity that exists *because* timers
  outlive their windows. Cancellation removes the cause.
- **Verify:** harness + manual open/close storm; thread count flat; prepare
  timeout and reveal watchdog still fire (deliberately break a page to test).
- **Effort:** 1 day. **Depends on:** 2.1 (net for behavior changes).

## 2.6 · P6 — Push-based `waitForWindow`; delete vestigial `isWindowReady`

- **Do:** resolve `waitForWindow` waiters from the existing
  `pbjsWindowEvent("ready")` push (`pbjsBridgeScript.js:1159–1175`), keeping
  one slow poll as fallback; delete the `isWindowReady` surface
  (`:425–433`).
- **Why:** the cold path polls `getWindow` every 100 ms (two native
  round-trips each) up to 6 s. Meanwhile `pbjsNativeIsWindowReady` is bound
  **nowhere** (verified — not in `BindWebviewEvents`, `JSWindow.pb:1523–1541`),
  so the "ready" half of the check is hard-coded `true` — `waitForWindow` is
  an existence check with extra steps. Correctness currently survives via
  native buffering (`QueuePending`), so this is latency + dead surface, not
  data loss.
- **Verify:** jsdom harness: waiter resolves on a pushed `ready`; unknown
  window still rejects after timeout.
- **Effort:** half a day. **Depends on:** 2.1.

## 2.7 · R10 + F4 + F5 — API sharp edges

- **R10 — activation control:** every reveal/focus path calls
  `activateIgnoringOtherApps:` (`JSWindow.pb:1121–1123, 1801–1805,
  1940–1954`; deprecated since macOS 14) / `SetForegroundWindow_`
  unconditionally — a background-triggered `openInstance` (CLI/REST-driven)
  yanks the user out of another app. Add `activate` (default true) to
  `openInstance`/`focusWindow`; false → `orderFront:` +
  `requestUserAttention` / taskbar flash. Migrate to `NSApp.activate` on
  macOS 14+.
- **F4 — per-invoke timeout:** `options.timeoutMs` on `invoke` (default
  30 000; timer at `pbjsBridgeScript.js:590–602`). The `options` bag and
  settle plumbing already exist from AbortSignal.
- **F5 — four one-hour fixes:**
  (a) `handleAll` silently replaces an existing handler for the same key
  (`:893–916`) — warn on replace;
  (b) `openInstance` result gains `alreadyOpen` so callers can distinguish
  focused-existing from opened-fresh (`JSOpenInstance`, `JSWindow.pb:2374–2383`);
  (c) expose pool state (spares ready/warming) via `pbjs.stats()` + allow
  runtime `poolTargetSize` adjustment;
  (d) (folded into 1.13f if not already done) bridge-internal logs off the
  forwarding console.
- **Effort:** 1–2 days combined. **Depends on:** —

## 2.8 · G3 + G2 — The host contract, written down

- **Do:** add a "Hosting pbjs in your app" section to `README.md` plus a
  root quick start that runs the example end to end (install → build web app
  → compile `.pb` → what you should see; ideally `build.sh`/`build.cmd`
  using the `PUREBASIC_HOME` resolution pattern from Vynce's
  `scripts/purebasic-home.js`).
- **Why:** README §2 opens with `import { pbjs } from "@shared/services/Pbjs"`
  — a Vynce path for a wrapper **not in this repo** — and the host contract
  is discoverable only by reading Vynce's `main.pb`. The contract to
  document (all five verified):
  1. `XIncludeFile` order: `OsTheme` → `WindowManager` → `JSSink` →
     `pbjs.pb` (and why — Sink may be included earlier by the host);
  2. `OsTheme::InitOsTheme()` + `WindowManager::InitWindowManager()` before
     any window;
  3. dispatch `JSWindow::HandlePoolRefillEvent` /
     `HandleDeferredCloseEvent` / `HandleDeferredReleaseEvent` from the
     host's main event handler — **omitting these silently breaks pooling
     and macOS close**;
  4. `WindowManager::RunEventLoop(...)` then `CleanupManagedWindows()`;
  5. the `IncludeBinary` + `DataSection` content pattern.
  Also: `reactExample/main-window/dist/` is gitignored, so both examples
  fail on `IncludeBinary` until the npm build runs — currently documented
  nowhere.
- **Effort:** half a day. **Depends on:** 1.3 (one canonical example).

## 2.9 · G6 — Ship the typed wrapper + complete typings

- **Do:** ship a supported consumer entry point (`pbjs.d.ts` + a small typed
  wrapper, or `@pbjs/client`), so README §2's import is real for
  non-Vynce consumers.
- **Why:** the only typings in the repo
  (`reactExample/main-window/src/global.d.ts`) cover ~30% of the surface —
  `invoke`, `invokeAll`, `handle`, `handleAll`, `removeHandler`,
  `removeAllHandlers`, `windowName` — missing `send`, `sendAll`, `channel`,
  `openInstance`, `getWindow`, `waitForWindow`, `waitForReady`,
  `waitForFSReady`, `onCloseWindow`, `setWindowTitle`, `focusWindow`, `os`,
  `isReady`, `stats`. They are also **stale, not just incomplete**: they
  declare `pbjsBridgeReady`, a flag the bridge never sets (it sets
  `pbjsReady` + the `pbjs-ready` event).
- **Effort:** small–medium. **Depends on:** —. **Feeds:** 3.9 (the Capacitor
  package builds on it).

## 2.10 · G4 + G5 — De-Vynce the library; fix the doc dead-ends

- **G4:** rename `VYNCE_DND` / `VYNCE_DND_DEBUG` →
  `PBJS_DND` / `PBJS_DND_DEBUG`, and `$TMPDIR/vynce_dnd_debug.log` →
  `pbjs_dnd_debug.log` (`DndService.pb:577–583`). Pre-release — change it
  cleanly, no compat shim. (If 3.6 lands first, do it there.)
- **G5:** 12 references in library code point at documents that exist only
  in the Vynce repo (`iplan/webversion/plan.md`, `iplan/cross-window-dnd/`,
  `iplan/agent-window-multi-instance/`, `iplan/startupREVIEWED.md`,
  `iplan/pbjszustand.md`, `docs/dnd.md`) — this repo's `iplan/` contains
  only this roadmap (and, until deleted, suggestions.md). Move the
  pbjs-relevant plans here, or strip the references. Don't leave pointers to
  documents the reader cannot reach.
- **Effort:** small. **Depends on:** —

---

# Phase 3 — New surface, origin/packaging, structure

## 3.1 · F1 — Window events for pages

- **Do:** a `pbjs.window.on("focus" | "blur" | "state" | "moved" |
  "display")` channel: one injected dispatch function
  (`window.pbjsWindowStateEvent(kind, payload)` — mirror of the existing
  `pbjsWindowEvent` lifecycle push), fed from the per-OS observation points
  that already exist: the macOS notification observer
  (`MacOSFrameDidChange`, extend the registration to
  `didBecomeKey`/`didResignKey`/`didMiniaturize`/fullscreen notifications),
  the Windows `WindowCallback` (`WM_ACTIVATE`, `WM_SIZE` w/ min/max state,
  `WM_MOVE`), GTK signals (Linux).
- **Why:** the only window signal a page receives today is
  `pbjsUpdateScale(w, h, maximized)`. No focus/blur, minimize/restore,
  fullscreen, move, or display-change — so pages can't pause work when
  hidden, persist per-window geometry, or adapt to fullscreen without
  polling native metrics. Highest-leverage new capability in this plan.
- **Effort:** 2–3 days across platforms. **Depends on:** 2.1 (harness),
  ideally 2.5 (scheduler) landed.

## 3.2 · B3 — A real origin (Route C mac/Linux, Route B Windows)

**The problem (measured in suggestions.md; code side re-verified at HEAD):**
pbjs's only release content path is an embedded HTML string
(`SetGadgetItemText(#PB_WebView_HtmlCode)`); `debugUrl` is compiled out
(`#Debug_On`); there is no baseURL/scheme/URL capability anywhere (grep
verified). String-loaded content gets an **opaque (null) origin**. Measured
on macOS/WKWebView:

| Web API | today (`origin=null`) | with baseURL (`http://app.localhost`) |
|---|---|---|
| `isSecureContext` | false | true |
| `localStorage` / `sessionStorage` | **throws SecurityError** | OK |
| `indexedDB.open()` | **throws** (global present — naive feature-detect passes, first call dies) | opens OK |
| `document.cookie` | **silently dropped** (worst mode: nothing to catch) | OK |
| `crypto.randomUUID` / `crypto.subtle` | absent | OK |
| `caches`, `navigator.serviceWorker`, `navigator.clipboard`, `storage.estimate()` | absent/broken | present (SW still needs packaging) |

Windows/WebView2 (`NavigateToString`) and Linux/WebKitGTK (`load_html`, NULL
base) produce an opaque origin by the same spec rules — untested, assumed.

- **Do (in order):**
  1. **macOS — Route C:** load via `loadHTMLString:baseURL:` with a
     **per-app** base like `http://<appname>.localhost/` (a distinct,
     potentially-trustworthy origin; never bare `http://localhost` — origins
     are a global namespace and would share storage with anything else).
     **Implementation shortcut validated at HEAD:** the WKWebView is
     reachable via the existing `FindWKWebView` subview walker
     (`JSWindow.pb:1045–1078`) — call the load through CocoaMessage on it
     instead of `SetGadgetItemText`. Measured results: `file:///tmp/` and
     `http://…localhost/` bases both give secure context + working
     storage/IDB; an unregistered custom scheme (`app://…`) fails to load
     entirely.
  2. **Linux — Route C:** `webkit_web_view_load_html(view, html, base_uri)`
     — has the parameter, untested; same shape. (If `base_uri` disappoints,
     the Linux fallback is Route B via
     `webkit_web_view_get_context()` → `webkit_web_context_register_uri_scheme()`,
     registered before first use of the scheme — also untested.)
  3. **Windows — Route B (only route; also the better one):**
     `NavigateToString` has **no** baseURL, so use
     `ICoreWebView2::SetVirtualHostNameToFolderMapping` (or
     `AddWebResourceRequestedFilter`) via
     `#PB_WebView_ICoreController` — callable on an already-created webview;
     cost is hand-declaring COM vtables in PB. Untested (no Windows host at
     review time).
  4. Config: the load mode hangs off `pbjsConfig.pb` (1.6), **not**
     `#Debug_On`.
- **What Route C does NOT fix:** packaging. Content is still one file;
  relative subresources would resolve against the base and hit the network;
  service workers stay impossible (need a fetchable script URL). The
  single-file constraint means `vite-plugin-singlefile`-style bundling stays
  mandatory — no code-splitting, no lazy routes, no web workers, no wasm,
  and a real app inlines to a multi-MB PB string. That is nonetheless fine
  for the storage-shaped majority — of Capacitor's origin-dependent
  surfaces (Preferences, Filesystem-web, Cookies, Device.getId, Clipboard,
  Geolocation, LocalNotifications, @ionic/storage, sqlite-web, Firebase/
  Auth0/MSAL), **all are fixed by an origin alone**; only Push and PWA
  offline need real packaging (Route A/B multi-file — see "Not on the
  roadmap" for Route A's status). The other common Capacitor plugins touch
  no origin-gated API and work today with no fix at all: camera, share,
  toast, dialog, haptics, app, network, browser, status-bar, splash-screen.
- **Verify:** the origin probe table above re-run per platform (write it as
  a tiny probe page in the repo); `localStorage` round-trip survives app
  restart; two different pbjs apps get distinct storage buckets.
- **Effort:** days (mac hours, Linux hours, Windows the bulk via COM).
  **Depends on:** 1.6. **Must ship with:** 3.3.

## 3.3 · F6 + X2 — Trust boundary + fs confinement (same release as 3.2)

- **Do:**
  1. **Document the boundary:** remote/untrusted content must never load in
     a pbjs window — every page gets the full native surface (close/open
     windows, drag, DnD, fs). A README security section (currently absent).
  2. **Confine the fs bridge** (`pbjsFileSystem/`, 693 lines .pb + .js):
     `JSFileSystem::SetRoot(path$)`; calls before
     a root is set **fail closed**; canonicalize incoming paths and reject
     anything escaping the root after resolving `..` and symlinks. One
     helper, routed through by all ten ops (verified list:
     `FS_Access, FS_ReadFile, FS_WriteFile, FS_Readdir, FS_Mkdir, FS_Rmdir,
     FS_Unlink, FS_Rename, FS_Stat, FS_Exists` —
     `pbjsFileSystem/pbjsFileSystem.pb:101–309`, all currently passing the
     page's path verbatim to the OS; no root/allowlist/`..` handling
     exists).
  3. **Per-window opt-out:** a window showing third-party content should be
     able to have no `window.fs` at all. The include is already opt-in
     (`pbjs.pb` does not pull `pbjsFileSystem` — verified); keep that, and
     move it under `plugins/` in the 3.6/S2 restructure.
  4. Optional **restricted window mode**: register no bindings beyond a
     whitelist — cheap now that `BindWebviewEvents` is one function
     (`JSWindow.pb:1523–1541`).
- **Why:** X2 validated hard: any script in any pbjs window can read,
  overwrite or delete any file the user can. Acceptable while content is
  embedded and trusted; **the moment 3.2 lands a URL/origin path, an
  unconfined `window.fs` is a remote-code-to-disk hole**. Sequence them
  together.
- **Effort:** medium (the confinement helper is small; the audit of callers
  is the work). **Depends on:** ships with 3.2.

## 3.4 · F2 + F3 + X5 — Window options, JS geometry, host-owned tunables

- **F2 — creation options bag** on `CreateJSWindow`/`RegisterTemplate` (+
  JSON mirror on `openInstance`): min/max size, resizable, always-on-top,
  start-hidden, activate-on-open (2.7's flag), per-window background
  override, traffic-light offset (macOS), titlebar height for the
  custom-chrome contract. Applied at the existing per-OS setup points in
  `CreateJSWindow`.
- **F3 — JS geometry write path:**
  `pbjsNativeSetWindowBounds(name, x, y, w, h)` with monitor clamping —
  reuse the clamp logic `OpenInstance`'s cascade already contains
  (`JSWindow.pb:2294–2330`). Today JS can read metrics but not set them
  (the DnD drop-point placement had to thread its own `atScreenX/Y` through
  `openInstance` for exactly this lack).
- **X5 — host-settable policy constants:** theme palette
  (`OsTheme.pb:17–20` — the pre-paint background should match the *app's*
  first frame, not pbjs's taste) and fade timings (`#PBJS_BodyFadeMs`,
  `JSWindow.pb:1256`; the 310/510/150 ms per-platform constants,
  `:1318–1325`). Defaults stay; setters/config move to `pbjsConfig.pb`.
- **Effort:** 2–3 days. **Depends on:** 1.6.

## 3.5 · P5 — Measure the desktop-sized webview; then hybrid sizing

- **Do:** first **measure** actual GPU/backing memory per window on each
  platform (gadget is created at `MaxDesktopWidth × MaxDesktopHeight`,
  `JSWindow.pb:1564` — on a 5K display a fully-backed layer would be
  ~56 MB/window; WebView2 most suspect). If real: **hybrid sizing** — keep
  the oversized gadget only *during* live resize (enter/exit size-move on
  Windows — the `WindowCallback` already sees `WM_ENTERSIZEMOVE`/`EXITSIZEMOVE`;
  `windowWillStartLiveResize`/`DidEndLiveResize` on macOS), snap it to the
  true client size at rest.
- **Why:** the oversize-and-clip trick buys resize smoothness but makes
  `innerWidth`/`vw`/`vh`/`position:fixed` lie to any page not written
  against the CSS-variable contract (`pbjsUpdateScale` /
  `--container-width`) — a hard limit on "drop any webapp in" (relevant to
  3.2/3.9), plus the suspected memory cost.
- **Verify:** memory instrument per platform before/after; live-resize
  smoothness unchanged (that was the whole point of the trick — don't
  regress it).
- **Effort:** measurement 1 day; hybrid sizing 2–3 days if justified.
  **Depends on:** measurement gates the change.

## 3.6 · X3 — Split DnD along the native-primitive line

- **Do:** split `DndService.pb` (795) + `DragBadge.pb` (263) +
  `DndServiceDeclare.pb` (22) — 1,080 lines, ~17% of what `pbjs.pb` pulls in:
  - **Stays in pbjs (~250–350 lines):** cursor tracking
    (`Dnd::Track`), desktop hit-testing (`HitTest` — topmost registered
    pbjs window, excluding spares/headless/overlay: the genuinely hard,
    genuinely native part), a content-agnostic overlay window (keep the
    hard-won window-level + `ignoresMouseEvents` work; expose "surface +
    canvas, you draw"), and the `dnd:*` message routing.
  - **Moves to the app (Vynce):** `DrawTerminalGlyph`
    (`DragBadge.pb:137` — the only icon that exists), the Tailwind palette
    (`:160–171` — blue-500 `RGBA(59,130,246)`, gray-500, gray-200), the
    `"New Window"` hint copy, and the `#Style_NewWindow`/`#Style_Revert`
    enum (`:24–25`) — Vynce's tab-tear release semantics as a library
    enumeration. Mechanism: `Dnd::SetBadgeRenderer(*proc)` invoked on the
    tick with canvas + session state — the JSSink pattern applied to
    drawing. No renderer registered → plain labelled rectangle or no badge.
  - **Gate the compile:** separate `IncludeFile` that `pbjs.pb` does not
    pull in by default (the arrangement `pbjsFileSystem` already has), and
    compile it out on non-mac (today it's a runtime-only gate in `Init()` —
    Windows/Linux compile 1,080 lines that can never run).
  - Fold in the 2.10 G4 rename if not already done.
- **Why:** the protocol is honestly generic (opaque `type` + `payloadJson`);
  the implementation is Vynce's tab-tearing feature — app policy, brand
  colors, and English copy baked into library source. Note for context: the
  15 ms drag-time timer (`#TickMs`, `DndService.pb:48`) is main-loop but
  drag-scoped — acceptable, unchanged by the split.
- **Effort:** medium (2–3 days). **Depends on:** none technically; do before
  publicizing the repo — it's what a reviewer notices first.

## 3.7 · S1 + S2 + S3 — Structure (only after harnesses exist)

- **S1 — one identity:** finish adopting `ResolveJSWindowByName`
  (`JSWindow.pb:717–725`) in the six JS-callback procedures that still
  inline name-or-id resolution; then converge the five registries
  (`JSWindows` by PB number, `WindowsByName`, `ManagedWindowsHandles` by
  native handle, `TemplateInstances`, per-template `PoolHandles`) on one
  window record with secondary indexes and a single `RemoveWindow()` that
  maintains all of them (1.10 is the down payment). Include the `FindJS()`
  accessor sweep: PB map `()` access auto-inserts missing keys — the module
  has had two documented ghost-element bugs (guard comments at
  `JSWindow.pb:425–432`, `:2844`) and ~20 bare `JSWindows(Str(...))` sites
  remain, including hot `HandleEvent`.
- **S2 — split the trench coat:** `JSWindow.pb` (3,343 lines) along its own
  banner seams: Registry / Prepare&Reveal (per-OS) / Pool&Templates /
  CloseProtocol / Headless / Chrome / Bootstrap-script builder. Rewrite the
  close path as explicit phases — veto → observers → detach handlers →
  teardown → destroy — so the `CloseJSWindow` ↔ `CloseManagedWindow` mutual
  recursion and its re-entrancy bail-out disappear, and the inlined
  duplicate of `FindWKWebView` (`:2523–2549`, annotated "crash-sensitive,
  must not gain a call") can be unified once the phases make the call graph
  safe.
- **S3 — no `End` in library code:** `CheckCloseProgress` calls `End` for
  scope −1 (`:2747`), terminating the process from inside a module and
  skipping host cleanup. Replace with a "loop should exit" signal the host
  observes (the `ShouldKeepRunning` hook already exists). Document which
  close protocol owns what (pbjs veto mechanism vs. the host's app-close
  policy, `docs/app-close.md` in Vynce).
- **Effort:** the big one — a week+. **Depends on:** 2.1 harnesses; 1.7/1.10
  landed (they change the close path first, smaller).

## 3.8 · G7b — Version it

- **Do:** tag `v0.1.0`; add repo topics (`purebasic`, `webview`,
  `electron-alternative`, `desktop`); note the release in README.
- **Why:** no release, no topics, no version anywhere — a consumer cannot
  pin or tell whether `main` is safe today.
- **Effort:** minutes. **Depends on:** 1.1–1.5, 2.8 (the tag should be
  honest: compiles standalone, has a licence, has a quick start).

## 3.9 · pbjs-capacitor (last, and only after 3.2 + 3.3)

- **Do:** the bridging package, once an origin exists. Capacitor's host
  contract is small (from suggestions §5, preserved here):
  - Page expects global `window.Capacitor` with a `Plugins` proxy.
  - A plugin call marshals `{callbackId, pluginId, methodName, options}` to
    native; native replies via
    `window.Capacitor.fromNative({callbackId, success, data|error})`.
  - **Callbacks may fire more than once** (watchers) — model the reply
    channel on `send` (fire-and-forget), **not** `invoke`'s one-shot
    promise.
  - Mapping: JS→native = one new `capacitorBridge` bind via `Sink::Bind`;
    native→JS = `Sink::Exec` (exists); plugin registry = new PB-side
    name→procedure map; the `window.Capacitor` shim injects via the existing
    `SetPreRenderJS` hook (`JSWindow.pb:43`) — documented opaque pre-page
    JS, exactly the requirement; do not add a second injection mechanism.
  - Reference plugins to prove the protocol: Preferences (needs only 3.2's
    origin) and Filesystem (sits on the 3.3-confined fs bridge).
- **Why last:** the bridge was never the hard part; the origin (3.2) and the
  fs confinement (3.3) were. Sequenced after both, per the validated
  suggestions plan.
- **Verify / acceptance:** an unmodified (single-file-bundled) Capacitor app
  with Preferences + Filesystem working end to end, storage surviving an app
  restart. The fuller proof — service-worker registration and a lazy route on
  an uninlined `www/` — belongs to the drawered multi-file routes (Route A /
  Route B multi-file) and only becomes a target if those are ever built.
- **Effort:** days, in its own repo. **Depends on:** 3.2, 3.3, 2.9.

---

# Not on the roadmap (decided, with reasons)

- **Value-injection / replacing `WebViewExecuteScript`** (prior audit F4/F5
  — declined): injection path is empirically fast; the per-platform rewrite
  is the robustness risk. 1.8 hardens the existing path instead.
- **Threading the router:** webview inject/callback APIs are UI-thread-pinned;
  threading adds hops and locks on a lock-free registry for nothing.
- **Unified readiness handshake / typing the transport** (F12/F6 of the
  prior audit): app-layer concerns, as decided.
- **Micro-batching injected scripts:** legitimate transport-level
  optimization, but `pbjs.stats()` shows no backlog — drawer until it does.
- **B3 Route B on macOS (custom scheme handler):** measured blocker —
  WKWebView **copies** its configuration at init (two `-configuration` calls
  return different pointers), so a post-hoc
  `setURLSchemeHandler:forURLScheme:` mutates a dead copy and fails
  silently; `NSURLProtocol` is ignored by WKWebView. Doing it right means
  abandoning `WebViewGadget` and owning the WKWebView (own config, own
  `evaluateJavaScript`, own script-message handlers) — a separate strategic
  decision, not a roadmap step.
- **B3 Route A (loopback static server):** superseded by Route C as the
  starting point (Route C: no server, no port, no firewall prompt, embedded
  model intact). Revisit only if service workers, lazy chunks, wasm, or an
  uninlined Capacitor `www/` become real requirements. If built: bind
  127.0.0.1 only, random port, per-launch token or Origin/Host check,
  strict CSP; expect Windows firewall/AV questions.

---

# Provenance

- Window-management review findings (R/P/F/S): artifact "PBJS Window Review"
  rev 2 (2026-08-17), all evidence re-stated inline above.
- Reuse review (B/G/X): `iplan/suggestions.md`, all 15 findings validated
  2026-08-17/18 against `51fd11e`, none rejected. Measured data preserved
  here: the origin probe table + per-OS route matrix (3.2), the Capacitor
  surface mapping incl. the no-fix-needed plugin list (3.2), the Capacitor
  host contract + acceptance (3.9), the host contract five steps (2.8), the
  fs-bridge op list (3.3), the DnD split inventory (3.6), the WKWebView
  configuration-copy measurement and Route A guard rails (Not on the
  roadmap), the `PbjsStartupTraceMark` extension pattern (1.1), the
  nested-repo diagnosis (1.5).
- `suggestions.md` was **deleted on 2026-08-18** after a section-by-section
  transfer review confirmed everything actionable and every measurement
  lives in this file. Its remaining unique content was narrative rationale,
  summarized here where load-bearing.
