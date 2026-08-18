# PBJS roadmap — implementation checklist

Companion to [roadmap.md](roadmap.md). One row per roadmap step.

- **Done** — `[x]` implemented and verified, `[~]` partially done (see Info),
  `[ ]` not started.
- **Info** — what actually happened while implementing: surprises, deviations
  from the roadmap text, follow-ups, and anything the next reader needs that the
  roadmap could not know in advance.

---

## Phase 1 — Stop the bleeding, unblock standalone use

| # | Step | Done | Info |
|---|---|---|---|
| 1.1 | B1 — Delete `UseModule Ptym` | [x] | One line, `JSWindow.pb:228`. Confirmed dead as the roadmap predicted: nothing else referenced the module. Verified by the standalone check below, which previously died at exactly that line and now gets all the way through. |
| 1.2 | X1 — Delete `pbnodejs.pb` | [x] | `git rm`'d, 247 lines. Zero references anywhere — no `.pb`, `.pbp`, `.md` or `.js` mentioned it, so nothing needed updating alongside. |
| 1.3 | G1 — Fix or delete `example.pb` | [x] | **Deleted** it; `pbjsExample.pb` is now the single canonical sample. Two further defects surfaced that the roadmap did not list: (a) `pbjsExample.pb` passed `@KeepRunning()` in `RunEventLoop`'s **second** slot, which is `HandleNetworkEvent` — the keep-running hook was silently never called (fixed, now passed in the third slot); (b) `reactExample/main-window/src/index.css:6` had a **broken CSS declaration** `: light dark;` (the `color-scheme` property name was missing), which made `npm run build` fail outright under lightningcss. So the "working" example did not build either. Both fixed; the example now builds and compiles to a 611 KB executable. |
| 1.4 | B2 — Add a licence (MIT) | [x] | `LICENSE` at the repo root, © 2026 Manfred Schmidbartl. README gains a §14 Licence and a §13 Example (documenting the npm-build-before-compile step, which the roadmap flagged as documented nowhere). **Still to do by hand:** set the licence field on GitHub — that is a repo-settings action, not a file. |
| 1.5 | G7a — Standalone syntax-check CI | [~] | **The roadmap's plan — "macOS runner; resolve the compiler via the `PUREBASIC_HOME` pattern" — cannot work on a GitHub-hosted runner.** See "Deviations" §3 for the evidence. Delivered instead: `.github/workflows/ci.yml` (hosted; builds the example, asserts the embedded artifact, runs `ci/check-sources.mjs`), `.github/workflows/purebasic.yml` (**self-hosted, dormant until a runner is registered** — checked in configured, never silently skipping), `ci/check-purebasic.sh` + `ci/purebasic-home.sh` (compiler resolution mirroring the host's `scripts/purebasic-home.js`), `ci/check-sources.mjs` (compiler-free static checks) and `ci/pre-push` (the everyday local gate). Marked `[~]`: the compiler check is written and passing locally, but it is not running in cloud CI and will not until a self-hosted runner is registered — a deliberate choice, not an omission. Traps found on the way: `--check` is **`-k`**, while `-c` is `--commented` (the C dump); `pbcompiler --version` **exits 1 even on success**, which under `set -e` killed the script before any check ran; and `PUREBASIC_HOME` is mandatory but undocumented in the online CLI reference. |
| 1.6 | R8 + X4 — `pbjsConfig.pb`: build-mode home; gate devtools | [x] | **The roadmap's "create pbjsConfig.pb with constants" plan does not work as written** — see "Deviations" §1. PureBasic modules cannot see top-level constants *at all* (verified on 6.21: a `#FOO = 1` outside any module is "Constant not found" inside one), which is precisely why `#Debug_On` was in `DeclareModule OsTheme` to begin with. `pbjsConfig.pb` is therefore a `DeclareModule PbjsConfig`, and `JSWindow.pb` does `UseModule PbjsConfig`. Renamed `#Debug_On` → `#PBJS_DevMode` (6 sites) since the name never meant "debug" but "load content from a URL". Added `#PBJS_EnableDevTools`, defaulting to dev mode, now gating `#PB_WebView_Debug` at `JSWindow.pb:1564` — release builds no longer ship the inspector. No deprecated alias left in `OsTheme`: the roadmap made that conditional on a host referencing it, and none does (grepped the Vynce host). All three flag combinations verified to compile. |
| 1.7 | R1 — Close-veto protocol: timeout + auto-approve | [x] | Layers 1 and 2 only — **layer 3 (the repeated-close escape hatch) was explicitly rejected by the user**: an unanswered check must stay declined, and a genuinely wedged app is the OS's problem. Timeout is **4000 ms** (user's call, over the roadmap's 2–3 s) and the outcome is **declined**, not approved: `CancelClose` runs, the window stays open, the scope clears so later closes work again. JS side auto-approves `close-window` when no handler is registered. Found and fixed **a second door to the same wedge** the roadmap did not mention: `RequestClose`'s `Not CheckStarted` path also left `ClosingScope` set with no reply possible to ever clear it (see "Deviations" §2). No timer object and no generation counter — the arm timestamp *is* the generation, so a stale post from a finished round self-cancels. |
| 1.8 | R3 — Complete `EscapeJSON` (port the fs-bridge escaper) | [x] | Split into two procedures rather than extending one, because the existing `EscapeJSON` does **two** jobs: JSON escaping *and* `\'` for the single-quoted JS literal every injection site wraps it in. `\'` is invalid JSON, so it must not touch a value going *into* a frame. New `EscapeJSONValue` = RFC 8259 only (all C0 as `\u00XX`, ported from `pbjsFileSystem.pb`); `EscapeJSON` = that plus `\'`, so all existing call sites keep working unchanged. Applied `EscapeJSONValue` to `name`/`fromWindow`/`toWindow`/`errorMsg` at all 8 hand-built envelope sites. Double-escaping is correct here and was traced by hand: inner `\"` → outer `\\\"` → JS literal un-escape → `\"` → valid JSON. Both are exported; the value escaper is exported deliberately, since hosts must hand-build `paramsJson` for `SendSystemMessage`. |
| 1.9 | R2 — Wire the monitor-topology response | [x] | The dead `*MaxSizeChangedProc` per-window field is gone; replaced with **one** app-level hook (`WindowManager::SetMaxSizeChangedHandler`), because `WindowManager.pb` is included before `JSWindow.pb` and so cannot reference it — the same dependency inversion `SetResizeDrainHook` already uses. `JSWindow::HandleMaxDesktopSizeChanged` resizes every non-headless webview to the new max and re-fires `UpdateWebViewScale` (the page sizes off `pbjsUpdateScale`, not off the gadget, so skipping that would leave the layout on the old ceiling). Only w/h are touched — x/y carry real state (spares are parked off-screen pre-ready). Registered from `CreateJSWindow`. **Not verified at runtime:** needs physically docking into a larger display; the roadmap says automated coverage is impractical and I agree. |
| 1.10 | R4 — WindowManager registry cleanup + honest dispatch condition | [x] | **The roadmap's "do it in `CloseManagedWindow`" is the one place it must NOT go** — see "Deviations" §6. `CloseManagedWindow` is on the recycle path: a template instance's close runs through it and comes back alive in the pool, so deregistering there would strip the registry entries of live, reusable windows. Cleanup is called from `CloseJSWindow`'s teardown instead, which is provably past the recycle early-return. Making the list actually shrink also exposed a latent hazard the roadmap does not mention: `*Parent.AppWindow` pointers are held in `JSWindow\Parent` and `JSTemplates\Parent` and walked by four procedures, and they were only safe because the list never shrank. Added a `ManagedWindowRemoving` hook so those references are nulled before the record is freed. Removal is two-phase (mark, then sweep from the event loop) because every caller is inside a `ForEach` over the very list being modified. Also fixed: `#Timer_CheckDesktop` lives on whichever window was added first, so closing that window silently stopped the desktop poll — and with it 1.9's response; it is now re-homed. `WindowsByName` is cleaned too (same aliasing bug, PB reuses window *numbers*). The `KeepWindow` comparison→assignment fix is behaviour-neutral: `AddManagedWindow` has exactly one caller and `HandleEvent` always returns `#True`. |
| 1.11 | R6 — Pool refill drains fully | [x] | The roadmap's re-post is implemented (one spare per loop tick, preserving the creation stagger). But re-posting alone would not have fixed the pool: found a **second, worse leak** — a destroyed spare's handle was never removed from `PoolHandles()`, and since `RefillPoolAsync` sizes the shortfall as `PoolTargetSize - ListSize(PoolHandles())`, one stale entry makes an empty pool look full and refill stops **forever**. `OpenInstance`'s claim loop guards with `FindMapElement`, so the symptom was not a crash but a pool that quietly stopped warming while every open fell back to the cold path. Dead handles are now pruned in the teardown path. |
| 1.12 | R9 — Close-check ids from the counter, not the clock | [x] | `SendCloseCheck` now takes `NextSystemRequestId`, same as `SendSystemRequest`, with the same wrap guard. Exactly as the roadmap describes — no surprises. |
| 1.13 | P7 — Small-burns bundle (a–f) | [x] | **(a)** Deduped in `UpdateWebViewScale` itself rather than at the two call sites: `#PB_ProcessPureBasicEvents` is Windows-only so I could not verify from this machine whether the `WM_SIZE` branch actually suppresses `#PB_Event_SizeWindow`, and a shared-choke-point dedupe is correct either way (it also drops the `WM_SIZE` events that fire for moves and state changes). Added a `force` flag for 1.9's re-fire, where the gadget changed but the window's dimensions did not. **(b)** Two caches: decoded HTML keyed by source range (a cache hit now skips the worker thread entirely — read and written only on the main thread, preserving the "no worker touches a map" invariant), and the bridge script's invariant part, keyed on the DnD flag because `DndService::Init()` can run after the first window. **(c)** Dead paint deleted (the brush really was never assigned, so `FillRect` got NULL); the `Delay(32)` is **kept and documented** rather than "reconsidered" — it is a timing value on a platform I cannot test, and 2.5 is where it can become a deferred event instead of a block. **(d)** Per your instruction: `LogToDebugFile` is now a macro that is **empty in release**, so the calls and their string concatenation vanish rather than becoming no-op calls. It was doing open/write/close per line on the ready path of every window and spare, writing into `GetCurrentDirectory()` — which for an installed app may not be writable. **(e)** 8 O(n) scans replaced by O(1) map lookups via a new `GetJSWindowPtrByName`; uses `FindMapElement`, never `JSWindows(key)`, since a bare map access inserts a ghost. **(f)** 10 bridge-internal logs routed to `originalConsole`. Deliberately still forwarded to native: dead-letter and buffered-unhandled warnings, double-init, and `log.error` — real faults, rare, worth seeing without devtools. |

## Phase 2 — Idle costs, kept promises, adoptability

| # | Step | Done | Info |
|---|---|---|---|
| 2.1 | S4 — Test harnesses (jsdom + native Sink router) | [ ] | Not in this batch. |
| 2.2 | P1 — Let the event loop sleep | [ ] | Not in this batch. |
| 2.3 | P2 — Display-change events replace the 500 ms poll | [ ] | Not in this batch. Depends on 1.9. |
| 2.4 | R7 + P3 — Live theme: watch it, cache it, stop forking | [ ] | Not in this batch. |
| 2.5 | P4 — One scheduler instead of thread-per-delay | [ ] | Not in this batch. |
| 2.6 | P6 — Push-based `waitForWindow`; delete `isWindowReady` | [ ] | Not in this batch. |
| 2.7 | R10 + F4 + F5 — API sharp edges | [ ] | Not in this batch. |
| 2.8 | G3 + G2 — The host contract, written down | [ ] | Not in this batch. |
| 2.9 | G6 — Ship the typed wrapper + complete typings | [ ] | Not in this batch. |
| 2.10 | G4 + G5 — De-Vynce the library; fix the doc dead-ends | [ ] | Not in this batch. |

## Phase 3 — New surface, origin/packaging, structure

| # | Step | Done | Info |
|---|---|---|---|
| 3.1 | F1 — Window events for pages | [ ] | Not in this batch. |
| 3.2 | B3 — A real origin (Route C mac/Linux, Route B Windows) | [ ] | Not in this batch. Depends on 1.6. |
| 3.3 | F6 + X2 — Trust boundary + fs confinement | [ ] | Not in this batch. Ships with 3.2. |
| 3.4 | F2 + F3 + X5 — Window options, JS geometry, host-owned tunables | [ ] | Not in this batch. Depends on 1.6. |
| 3.5 | P5 — Measure the desktop-sized webview; then hybrid sizing | [ ] | Not in this batch. |
| 3.6 | X3 — Split DnD along the native-primitive line | [ ] | Not in this batch. |
| 3.7 | S1 + S2 + S3 — Structure (only after harnesses exist) | [ ] | Not in this batch. |
| 3.8 | G7b — Version it (tag v0.1.0, topics, README note) | [ ] | Not in this batch. |
| 3.9 | pbjs-capacitor | [ ] | Not in this batch. Depends on 3.2, 3.3, 2.9. |

---

## Deviations from the roadmap text

Recorded here so the roadmap stays the plan and this file records the reality.
Each of these is a place where the roadmap's prescription turned out to be
wrong or incomplete against the actual tree — worth reading before trusting the
roadmap's *How* on a later step.

### 1 · `pbjsConfig.pb` had to be a module (1.6)

The roadmap says "create `pbjsConfig.pb` … owning build-mode and tunables",
implying a file of plain constants. That does not work: **PureBasic modules
cannot see top-level constants at all.** Verified on 6.21 — a `#FOO = 1`
outside any module is `Constant not found` inside one, whether or not it sits
in a `CompilerIf`. This is also the real reason `#Debug_On` was declared in
`DeclareModule OsTheme`: not sloppiness, a language constraint.

So `pbjsConfig.pb` is a `DeclareModule PbjsConfig`, and every consumer needs
`UseModule PbjsConfig`. That changes how a host overrides a flag. Two
mechanisms, **both verified**, and one plausible-looking non-mechanism:

| Approach | Works? |
|---|---|
| `pbcompiler … -co PBJS_EnableDevTools=1` (`--constant`) | ✅ reaches module scope, seen by the `Defined()` guards |
| Host pre-declares `DeclareModule PbjsConfig` before including `pbjs.pb` | ✅ the file is guarded on `Defined(PbjsConfig, #PB_Module)` |
| Host writes `#PBJS_DevMode = 0` at the top level of its `main.pb` | ❌ **silently ignored** — invisible to the module, no warning |

That last row is a trap, so it is called out explicitly in `pbjsConfig.pb`'s
header. Renaming `#Debug_On` → `#PBJS_DevMode` goes slightly beyond "move it",
but the old name actively misled: it never meant "debug", it meant "load
content from a URL instead of the embedded HTML".

### 2 · The close wedge had a second door (1.7)

The roadmap identifies one way `ClosingScope` gets stuck — a check nobody
answers. There is another, in the same procedure: when `RequestClose` starts
**no** checks at all (`CheckStarted` stays false, e.g. no in-scope window is
visible), it returns `#True` and leaves `ClosingScope` set. Since only
reply-driven code clears it, and no reply can arrive when nothing was asked,
that state is permanent too — the same unquittable-app symptom by a different
route. Fixed alongside: the scope is dropped immediately on that path, which is
strictly better than letting the new 4 s watchdog mop it up.

### 3 · CI cannot run `pbcompiler` on a hosted runner (1.5)

The roadmap's *How* — "macOS runner; resolve the compiler via the
`PUREBASIC_HOME` pattern" — assumes the compiler can be obtained in CI. It
cannot, for two independent reasons:

- **The free version physically cannot compile this repo.** It caps source
  files at **800 lines each** (per file, not cumulative), and
  `modules/JSWindow.pb` is ~3,500. It answers `Error: Source too big for the
  Free version.` and exits 1. No file-splitting worth doing would fix that.
- **The full version is a per-user, login-gated download.** Installing it on a
  public runner is an unresolved licensing question (no EULA ships with the
  product; the terms exist only as website prose and say nothing about build
  machines). And secrets are not exposed to fork PRs, so a secret-gated
  download would silently skip on exactly the PRs a public repo needs checked.

Hence the split: hosted CI does what it honestly can, the compiler check is
self-hosted and opt-in, and `ci/check-sources.mjs` is documented as a *weaker,
different* gate rather than a substitute. It earns its place by catching both
defects Phase 1 actually fixed — a host-only `UseModule` and a wrong
`IncludeBinary` path — with no compiler at all. Both were re-introduced
deliberately to confirm it fails on them; the first attempt **missed the
IncludeBinary case**, because excusing any path containing `dist/` also excused
a wrong one. Now a missing `dist/` target is only forgiven when the directory
above `dist/` exists.

### 6 · Registry cleanup must not happen in `CloseManagedWindow` (1.10)

The roadmap says to remove the registry entries "in `CloseManagedWindow`". That
is the one procedure where it is unsafe, and the reason is the pool:

```
HandleEvent (user closed a template instance)
  └─ CloseManagedWindow          ← sets Open=#False, Closed=#True
      └─ CloseProc = CloseJSWindow
          └─ RECYCLE PATH: hide the window, push it back onto PoolHandles,
             ProcedureReturn      ← the window is ALIVE and will be re-shown
```

`CreateAndPrepareSpare` builds every instance with
`#JSWindow_Behaviour_CloseWindow`, so a perfectly ordinary "close this tab"
goes straight through `CloseManagedWindow` and comes back out as a warm spare.
Deregistering there would strip the handle-map entry that routes native events
for a window the pool is still holding, and `OpenInstance` would hand it to the
next caller. Only `CloseJSWindow` knows which of the two it just did, so it
calls `ForgetManagedWindow` itself, from the teardown branch — past the recycle
early-return. `CloseManagedWindow` now carries a comment saying why it must
stay dumb.

**Second-order consequence the roadmap does not mention.** Once the list really
shrinks, `*Parent.AppWindow` becomes a dangling-pointer hazard: `JSWindow\Parent`
and `JSTemplates\Parent` hold raw pointers into the list, and `HideJSWindow`,
`RequestClose`, `ResetCloseChecks` and `CheckCloseProgress` all walk the chain
and dereference `*Current\Window`. Those pointers were safe only because the
`DeleteElement` guarding them was unreachable — remove the bug without
addressing this and you trade a slow leak for an intermittent
use-after-free. Hence the `ManagedWindowRemoving` hook, fired immediately before
the record is freed, which JSWindow uses to null every reference to it.

Removal is deliberately two-phase (mark in `ForgetManagedWindow`, free in
`SweepRemovedWindows` from the event loop) because every caller sits inside a
`ForEach` over `ManagedWindows()`. The sweep walks by index rather than
`ForEach`, since PureBasic's `DeleteElement` leaves the current-element pointer
somewhere version-dependent and this loop must not depend on which.

### 4 · Bugs found that the roadmap did not list

Turned up while verifying the steps above; all fixed, none of them optional if
the acceptance criteria are to be met literally.

| Where | Problem |
|---|---|
| `reactExample/main-window/src/index.css:6` | `: light dark;` — the `color-scheme` property name was missing, so `npm run build` **failed outright** under lightningcss. The example did not build at all. |
| `reactExample/main-window/package-lock.json` | Out of sync with `package.json`; **`npm ci` refused to install** (18 missing rollup platform packages). The roadmap's own verify step for 1.5 (`npm ci && npm run build`) could never have passed. Regenerated. |
| `pbjsExample.pb` | `RunEventLoop(@HandleMainEvent(), @KeepRunning())` put the keep-running hook in the **second** slot, which is `HandleNetworkEvent`. It was never called. Now passed in the third slot. |
| `pbjsBridge.pb` | `EscapeJSON` does two jobs (JSON escaping **and** `\'` for the JS literal), so it could not simply be extended per 1.8 — `\'` is invalid JSON and must not touch a value going *into* a frame. Split into `EscapeJSONValue` + `EscapeJSON`. |
| `JSWindow.pb` — pool | A **destroyed** spare's handle was never pruned from `PoolHandles()`. `RefillPoolAsync` computes `need = PoolTargetSize - ListSize(PoolHandles())`, so a single stale entry makes an empty pool read as full and refill stops permanently. Silent: the claim loop skips dead handles, so it degrades to "every open takes the cold path" rather than failing. Found while implementing 1.11; the roadmap's re-post fix alone would not have restored the pool. |
| `WindowManager.pb` — timer | `#Timer_CheckDesktop` is added to the **first** managed window only. That window closing killed the desktop poll, and with it 1.9's monitor-topology response — silently, since nothing reports a timer that stopped. The timer is now re-homed to another live window when its host is removed. |

### 5 · Known-good deviations by user decision (1.7)

- Timeout is **4000 ms**, not the roadmap's 2–3 s.
- An unanswered check is **declined**, not approved. The window stays open.
- **No UX escape hatch.** The roadmap's layer 3 (a repeated close bypasses the
  pending check) was explicitly rejected: a page that has not answered may be
  mid-save, and a wedged app is the OS's problem to kill.

---

## Verification performed

Everything below was run, not assumed.

| Check | Result |
|---|---|
| `ci/check-purebasic.sh` — pbjs standalone, no host in scope | ✅ 6,630 lines, no error |
| `ci/check-purebasic.sh` — `pbjsExample.pb` | ✅ 6,742 lines, no error |
| `pbjsExample.pb` compiled to a real executable | ✅ 611 KB binary produced |
| Config matrix: default / `-co PBJS_EnableDevTools=1` / `-co PBJS_DevMode=1` | ✅ all three compile — both devtools branches are live code |
| `ci/check-sources.mjs` on the clean tree | ✅ 18 sources, 20 includes, 11 modules |
| `ci/check-sources.mjs` with both Phase-1 bugs re-introduced | ✅ fails, exit 1, both reported |
| Pool lifecycle traced by hand against 1.10 (spare unclaimed → app exit; instance closed → recycle; spare destroyed; non-template close; hide-behaviour close) | ✅ `ForgetManagedWindow` is reached on destruction paths only, never on the recycle path |
| Stale-entry aliasing after removal | ✅ `PendingRemoval` entries are skipped in dispatch, so a reused PB window number cannot match a dead record before the sweep |
| `npm ci && npm run build` in `reactExample/main-window` | ✅ after the lockfile repair; `dist/index.html` 196.77 kB |
| `ci/pre-push` hook end to end | ✅ exit 0 |
| **Vynce host** `main.pb --check` against the modified pbjs | ✅ 10,804 lines — the `#Debug_On` removal and the `AppWindow` struct-field removal broke no host code |

**Not verified, and cannot be here** — all compile-verified and hand-traced
only. The 2.1 harnesses are what would close this gap, and 1.10 in particular
is the change that most wants them:

- **1.9** needs physically docking into a larger display (the roadmap agrees
  automated coverage is impractical).
- **1.7**'s watchdog needs a deliberately hung page at runtime.
- **1.10** needs an open/close storm over template instances to confirm the
  list and handle map return to baseline, and that no parent-pointer walk
  touches a freed record. The pool paths were traced by hand instead (table
  above), and the nested-iteration hazard this introduced was caught by
  re-reading the code, not by a test — which is the argument for 2.1 in one
  sentence.
- **1.11**'s `poolTargetSize = 3` assertion (the roadmap's stated check) needs
  a running host; the code path was verified by inspection only.
- **1.13a** cannot be confirmed on this machine at all:
  `#PB_ProcessPureBasicEvents` is Windows-only, so whether the double resize
  exec actually occurs is still unknown. The dedupe is correct either way,
  which is why it was done that way.

## Left for a human

- **Set the licence field on GitHub** (1.4) — a repo-settings action, not a file.
- **Register a self-hosted runner** (1.5) if the compiler check should run in
  cloud CI; `.github/workflows/purebasic.yml` is ready and dormant until then.
- **Install the hook**: `ln -sf ../../ci/pre-push .git/hooks/pre-push`.
- Nothing here is committed — `iplan/` is untracked in this repo, and the rest
  is left in the working tree for review.
