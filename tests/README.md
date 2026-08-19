# pbjs tests

Two harnesses, one for each side of the bridge, plus a fixture that joins them.

| | What it drives | Needs | Runs in |
|---|---|---|---|
| **`js/`** | `pbjsBridge/pbjsBridgeScript.js` under a fake native, in jsdom | node | hosted CI (`.github/workflows/ci.yml`) |
| **`pb/`** | `pbjsBridge/pbjsBridge.pb`'s router, with no webview | a **licensed** PureBasic | self-hosted CI, or locally |
| **`fixtures/`** | frames the PB harness emitted, replayed in jsdom | — | hosted CI, via `js/native-frames.test.js` |

```bash
cd tests && npm ci && npm test     # the JS half
```

```bash
tests/pb/run.sh                    # the native half (compiles and runs)
```

Both are wired into `ci/pre-push`, which is the everyday gate:

```bash
ln -sf ../../ci/pre-push .git/hooks/pre-push
```

---

## Why these two seams

The bridge is 1,282 lines of JavaScript talking to ~770 lines of PureBasic over
a string protocol, and until roadmap step 2.1 neither side had a single test.
Both halves turned out to be testable without any UI at all, for reasons that
were already in the shipping code:

**The JS side** is an IIFE with three placeholders the host substitutes and
about twenty `window.pbjsNative*` functions the host binds. Substituting the
placeholders and installing fakes for those twenty functions *is* the host, as
far as the script can tell. `js/harness.js` is that fake — ~250 lines, and it
records every outbound frame so a test asserts on the wire rather than on
internals.

**The native side** has `modules/JSSink.pb`, the interception point web mode
already needed. A window whose sink is *headless* routes every script through an
app-installed `ExecHook` and every callback through a registry that
`Sink::DispatchCall` can invoke directly. That is a test double that shipped for
another reason:

```
Sink::RegisterHeadless(name)   -> a sink that needs no gadget
Sink::SetHooks(@OnExec(), …)   -> capture what would have run in the page
JSBridge::InitializeBridge(…)  -> binds pbjsNativeGet/Send/… onto that sink
Sink::DispatchCall(win, fn, …) -> call one, exactly as the webview would
```

So `pb/router-harness.pb` drives the real `HandleSend` / `HandleGet` /
`HandleSendAll` / `HandleGetAll` / `HandleReply` — which are module-private and
reachable no other way — and asserts on the real script strings the host would
have injected.

## The fixture is the seam between them

Testing each half separately would miss the thing that actually broke (roadmap
1.8 / finding R3): a frame PureBasic emitted happily and `JSON.parse` rejected,
inside `pbjsHandleMessage`, where the `catch` only logs. The message vanished
with no error anywhere.

So the PB harness writes every frame it emits to
`fixtures/native-frames.json`, and `js/native-frames.test.js` evaluates those
frames in jsdom exactly as `WebViewExecuteScript` would. Two real
implementations, one wire format, no model of either in between.

The fixture is **committed**, which is what lets the round trip run on a hosted
runner where no PureBasic compiler exists.

> ⚠ **Re-run `tests/pb/run.sh` and commit the result** after touching
> `EscapeJSON`, `EscapeJSONValue`, or any hand-built frame in `pbjsBridge.pb`.
> `git diff tests/fixtures` is then the review of what changed on the wire.
> `ci/pre-push` fails if the fixture drifts; the self-hosted workflow re-checks
> it with `git diff --exit-code`.

Two details that make the fixture worth having rather than decorative:

- **The control characters live where they can actually occur.** `params` and
  `data` arriving from a page were produced by `JSON.stringify` and can never
  contain a raw C0 character. The *hand-built* fields can: the handler name and
  the source window name (spliced by `HandleSend`), and `paramsJson` on the
  native-originated path (`SendSystemMessage`), which the host assembles itself
  — the ESC in a terminal title, verbatim. A fixture whose control characters
  sit inside an already-serialized `data` blob tests nothing; they are text by
  then, and the escaper never sees them.
- **The expected values are written with the harness's own escaper**
  (`Harness::JsonQuote`), not with `JSBridge::EscapeJSONValue`. Recording the
  expectation with the implementation under test would let a broken escaper
  produce a fixture that agrees with itself.

Both were verified by re-introducing R3 (dropping the short escapes and the
`\u00XX` sweep) and confirming that the PB harness fails 12 assertions and the
jsdom round trip fails 7 — with the production symptom, an empty `seen` array:
the message silently gone.

## What is NOT covered

Anything needing a real window lifecycle. `Harness::AddWindow` builds a
`JSWindow` record with a headless sink and no OS window, which is enough for
every routing decision the bridge makes — but there is nothing to open, close or
recycle. So these remain hand-traced (see `iplan/checklist.md`):

- **1.10 / R4** — the registry cleanup on close, which lives in `CloseJSWindow`'s
  teardown branch, past the pool's recycle early-return.
- **1.11 / R6** — the pool refill draining fully, which lives in
  `OpenInstance` / `RefillPoolAsync`.
- **1.7's watchdog** — the *native* half of the close veto. The auto-approve is
  in `js/close-veto.test.js`; the 4 s → declined timer is `JSWindow.pb` state
  driven by a real event loop.
- **1.9** — the monitor-topology response, which needs a display to change.

Covering the first two means a harness that opens real windows, and is worth
doing on its own terms rather than by widening this one.

## Layout

```
tests/
  js/
    harness.js              the fake native + bridge loader
    close-veto.test.js      R1 — auto-approve, veto, async handlers
    buffering.test.js       buffer, replay, the bounded queue and its counters
    dead-letter.test.js     F7 — the grace, and what must NOT dead-letter
    invoke.test.js          dispatch, settle, timeout, F9 AbortSignal, send/sendAll
    lifecycle.test.js       §6.5 push, orphan-reject, the readiness cache
    get-all.test.js         invokeAll's expected-count protocol
    native-frames.test.js   the cross-language round trip
  pb/
    harness.pb              assertions, captured Sink traffic, fake registry
    router-harness.pb       the cases
    run.sh                  compile + run
  fixtures/
    native-frames.json      generated by pb/run.sh, consumed by js/
```
