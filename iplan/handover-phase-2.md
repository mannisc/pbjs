# Handover — pbjs roadmap Phase 2

> **Status:** §1 is now history — PR #4 was merged (`77b05b2`) and Phase 2
> branched from the new `origin/main`, as it says to. §§2–4 and §7 are the
> durable part: environment facts, PureBasic traps and architecture notes that
> are true regardless of which step is in flight. §5's per-step notes are still
> the plan for 2.2–2.10; **2.1 is done** — see
> [checklist.md](checklist.md) for what it actually covered, and Deviations §7
> there for the two targets in §5's list that it turned out not to reach.

Written at the end of the Phase 1 session so the next one starts cold without
losing what was learned. Read [roadmap.md](roadmap.md) for the plan and
[checklist.md](checklist.md) for what Phase 1 actually did and where it
deviated. **This file is only the things neither of those records.**

---

## 1 · Where things stand

Phase 1 (1.1–1.13) is **implemented, verified as far as a compiler can, and in
review** — not merged.

- Branch `feat/roadmap-phase-1`, 3 commits, branched from `origin/main`.
- **PR: https://github.com/mannisc/pbjs/pull/4** — OPEN, MERGEABLE, CI green.
- Each commit compiles independently (checked before pushing).

**First decision of the next session:** merge PR #4 (`gh pr merge 4 --merge`,
then delete the branch) and branch Phase 2 from the new `origin/main`. Do not
stack Phase 2 on the Phase 1 branch — the roadmap's own ordering rule is that
2.1's harnesses land before the things they guard, and that is easier to review
on a trunk that already has Phase 1 in it.

There is a stale worktree at
`.claude/worktrees/window-management-analysis-666c2b` (detached at `51fd11e`).
It predates this work. Check whether it is still wanted before `git worktree
prune` surprises anyone.

---

## 2 · Environment facts — verified here, not written down anywhere else

The PureBasic CLI has several traps that cost real time to find.

| Fact | Detail |
|---|---|
| Compiler | `/Applications/PureBasic.app/Contents/Resources/compilers/pbcompiler` |
| `PUREBASIC_HOME` | **Mandatory.** `/Applications/PureBasic.app/Contents/Resources`. The compiler refuses to start without it, and this is **not** in the online CLI docs. |
| Syntax check | `-k` / `--check`. **`-c` is `--commented`** (the ~12 MB C dump), a completely different tool. |
| `--version` | **Exits 1 even on success.** Under `set -e` this kills a script before any check runs, with no error message. `ci/check-purebasic.sh` absorbs it with `|| true`. |
| Define a constant | `-co NAME=VALUE` / `--constant`. This **does** reach module scope. |
| Free version | Caps source files at **800 lines EACH** (per file, not cumulative). `modules/JSWindow.pb` is ~3,500, so the free compiler can never build this repo. This is why CI is split the way it is. |

### The three commands that verify a change

```bash
node ci/check-sources.mjs          # no compiler needed
ci/check-purebasic.sh              # standalone + example, real compiler
cd .. && PUREBASIC_HOME=/Applications/PureBasic.app/Contents/Resources \
  /Applications/PureBasic.app/Contents/Resources/compilers/pbcompiler main.pb --check -q
```

That third one is the one people forget: **pbjs is a nested repo inside Vynce,
and the host must keep compiling.** It caught nothing in Phase 1 only because
the removals were checked against it first.

Install the pre-push hook once: `ln -sf ../../ci/pre-push .git/hooks/pre-push`

---

## 3 · PureBasic language traps that shaped Phase 1

Every one of these produced a real bug in this codebase. Assume they will again.

1. **Modules cannot see top-level constants — at all.** A `#FOO = 1` outside any
   module is `Constant not found` inside one. This is why `#Debug_On` lived in
   `DeclareModule OsTheme` and why `pbjsConfig.pb` had to become a module.
   Consumers need `UseModule PbjsConfig`.
2. **`X = f()` inside `If a And X = f()` is a COMPARISON, not an assignment.**
   This is exactly the R4 bug: `KeepWindow` stayed 0, so the branch it guarded
   was unreachable for the life of the module.
3. **Map `()` access INSERTS a missing key.** Never `JSWindows(key)` on a
   page-supplied or uncertain id — always `FindMapElement` first. The module has
   guard comments about two historical ghost-element bugs; ~20 bare sites
   remain, and S1 (3.7) is where they get swept.
4. **Lists have ONE current-element pointer, like maps.** A `ForEach` over a
   list, inside another `ForEach` over the same list, corrupts the outer one. I
   introduced exactly this in `ForgetManagedWindow` and had to defer the work to
   the sweep. Use `PushListPosition`/`PopListPosition` or defer.
5. **`DeleteElement` leaves the current element version-dependent.** When
   deleting inside a walk, index with `SelectElement` rather than trusting
   `ForEach` to survive it (`SweepRemovedWindows` does this).

---

## 4 · Architecture knowledge Phase 2 will need

### The pool / recycle path — the thing most likely to be broken by accident

`CreateAndPrepareSpare` builds every template instance with
`#JSWindow_Behaviour_CloseWindow`. So an ordinary "close this window":

```
HandleEvent → CloseManagedWindow (sets Open=#False, Closed=#True)
            → CloseProc = CloseJSWindow
                → RECYCLE: hide, push onto PoolHandles, ProcedureReturn
                  ← the window is ALIVE and will be re-shown by OpenInstance
```

**`CloseManagedWindow` is therefore on the recycle path.** Anything that
"cleans up on close" must go in `CloseJSWindow`'s teardown branch, past the
recycle early-return — never in `CloseManagedWindow`. Phase 1 marked this with
a comment; do not undo it.

Pool spares are hidden windows with `Open=#False`. They still receive
`#CustomWindowEvent` (that is how `#Event_Prepare_Complete` reaches them), which
is why `HandleWindowEvent`'s dispatch condition is
`If Event = #CustomWindowEvent Or ManagedWindows()\Open`.

### Inverting the module order

`WindowManager.pb` is included **before** `JSWindow.pb`, so it cannot call into
it. The established pattern is a registered hook, and there are now three:
`SetResizeDrainHook`, `SetMaxSizeChangedHandler` (1.9),
`SetManagedWindowRemovingHandler` (1.10). **Use this pattern for 2.3** rather
than inventing a fourth mechanism.

### Host dispatch contract (undocumented, and 2.8 must fix that)

The host's `HandleMainEvent` **must** dispatch
`JSWindow::HandlePoolRefillEvent`, `HandleDeferredCloseEvent` and
`HandleDeferredReleaseEvent`. Omitting them silently breaks pooling and macOS
close. Note `pbjsExample.pb` does **not** do this — it uses no templates — so
the example does not demonstrate the contract 2.8 has to write down.

### New surface introduced by Phase 1

| Symbol | Where | Why it matters later |
|---|---|---|
| `PbjsConfig` module, `#PBJS_DevMode`, `#PBJS_EnableDevTools` | `pbjsConfig.pb` | 3.2 hangs the origin work off `#PBJS_DevMode`; 3.4 moves tunables here |
| `#PBJS_CloseCheckTimeoutMs` (4000) | `JSWindow.pb` | the close watchdog's deadline |
| `ForgetManagedWindow` / `SweepRemovedWindows` / `ManagedWindowRemoving` hook | `WindowManager.pb` | 3.7's `RemoveWindow()` convergence builds on these |
| `EscapeJSONValue` (RFC 8259 only) vs `EscapeJSON` (+ `\'` for the JS literal) | `pbjsBridge.pb` | do not confuse them; `\'` is invalid JSON |
| `GetJSWindowPtrByName` | `pbjsBridge.pb` | use it instead of adding new `ForEach JSWindows()` scans |
| `DecodedHtmlCache`, `bridgeTemplate` | `JSWindow.pb`, `pbjsBridge.pb` | main-thread only; the worker thread must never touch a map |
| `UpdateWebViewScale(..., force)` | `JSWindow.pb` | dedupes by last payload; pass `force` when the gadget changed but the window did not |

---

## 5 · Phase 2 notes, step by step

**Do 2.1 first.** The roadmap says so, and Phase 1 gives it an immediate job:
several Phase 1 changes are compile-verified only, and the harnesses are exactly
what would cover them. Suggest the first harness tests target, in order:

- the R1 close-veto auto-approve and the 4 s → *declined* watchdog (jsdom + the
  native router harness);
- the R3 escape round-trip with `\x08 \x0C \x1B` and a `"` in a handler name;
- the R4 registry cleanup — open/close N template instances, assert the list and
  handle map return to baseline, **and that a recycled instance does not**;
- the R6 pool — `poolTargetSize = 3` fills to 3 without further opens.

**2.2 (event loop sleep)** — check the interaction with `SweepRemovedWindows`,
which Phase 1 put on the per-tick path in `RunEventLoop`. With a blocking
`WaitWindowEvent()` it runs per event instead of ~60×/s, which is fine, but
confirm nothing depends on the old cadence. `PostEvent` wakes a blocked
`WaitWindowEvent`, so the close watchdog and pool refill still arrive.

**2.3 (display-change events)** — 1.9 gave the poll a real consumer, so the
event has somewhere to land. If you delete `#Timer_CheckDesktop`, also delete
the `TimerWindow` / `TimerNeedsRehome` re-homing plumbing 1.10 added for it in
`WindowManager.pb`; it exists only to keep that timer alive.

**2.5 (one scheduler)** — it must own the delayed events Phase 1 added or
touched: `#Event_Close_Watchdog`, `#Event_Force_Content_Visible`,
`#Event_Prepare_Complete`, `#Event_Content_Ready`. Cancellation-on-close is the
point, and it lets the close watchdog drop its arm-timestamp-as-generation
trick for a real cancellable timer. Also the natural home for the Win11
`Delay(32)` in `OpenManagedWindow`, which Phase 1 deliberately left blocking
because it is a timing value on an untestable platform.

**2.7 (F5c)** — `pbjs.stats()` exposing pool state pairs naturally with the
pool fixes in 1.11.

**2.9 (typings)** — ✅ **done.** `npm run lint` in `reactExample/main-window`
used to report **16 errors** (15 × `any` in `global.d.ts`, 1 react-refresh).
2.9 deleted that stale `global.d.ts` — the typings live in `pbjsClient/pbjs.d.ts`
now — which cleared 15; the survivor was `TodoContext.tsx` exporting both the
`TodoProvider` component and the `useTodo` hook, fixed by moving the context and
the hook into `contexts/useTodo.ts` so the `.tsx` exports only the component.
(Not `todoContext.ts`: a sibling differing only in casing resolves to the wrong
file on a case-insensitive filesystem, and TypeScript then fails the program
with TS1149/TS1261.) `ci.yml` now has the blocking **Lint** step the old comment
promised.

**2.10 (G4)** — the `VYNCE_DND` / `VYNCE_DND_DEBUG` rename lives in
`DndService.pb` around lines 577–583.

---

## 6 · Left for a human (not code)

- **Set the licence field on GitHub** — repo settings, not a file (1.4).
- **Register a self-hosted runner** if the `pbcompiler` check should run in
  cloud CI. `.github/workflows/purebasic.yml` is written and dormant; it
  triggers on `push` + `workflow_dispatch` only, never `pull_request`, because
  a fork controls that trigger and self-hosted runners execute what they are
  given (1.5).
- **Install the pre-push hook** (above).

---

## 7 · Working agreements that held up

- Conventional, scoped commits; subject a lowercase claim; body explains the
  mechanism and ends with a `Verified:` paragraph naming what was actually run.
- Branch from `origin/main`, never commit on `main`, one PR per branch, merge
  commit.
- Split commits so no file appears twice, and check each commit compiles — the
  history stays bisectable for a few seconds' work.
- **State plainly what was not verified.** Phase 1's runtime behaviour (close
  watchdog, topology response, pool, registry) is hand-traced and
  compile-checked only, and both the PR and the checklist say so rather than
  implying more.
