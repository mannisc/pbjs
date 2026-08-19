# Manual test plan — roadmap 2.2, 2.3, 2.4, 2.5

Companion to [checklist.md](checklist.md). These four steps are the ones whose
acceptance criteria need a running app, a second display, an OS theme flip, or a
platform that was not available where they were written.

**What was already verified, so you do not have to repeat it:** everything in
§0. **What needs your hands:** everything after it.

Legend: **[mac]** **[win]** **[linux]** — the platform a check needs.
A check with no tag applies everywhere.

---

## 0 · Already verified here (macOS 26.5, PureBasic 6.21, arm64)

Listed so you can skip it, and so you know exactly how far the automated net
reaches.

| | Result |
|---|---|
| `cd tests && npm test` | 155 passed |
| `tests/pb/run.sh` | 97 passed — **20 of them the new scheduler**: nearest-deadline reporting, draining, zero/negative delays, per-window and per-kind cancellation, `ForgetManagedWindow` cancelling, 75 mixed-deadline entries |
| `ci/check-purebasic.sh` | standalone + example, both OK |
| Vynce host `main.pb --check` | 11,701 lines, no error |
| `./build.sh` + run | launches, stays up, **idle CPU measured** (§1) |
| macOS theme detection | no `defaults` subprocess remains on the detect path |

**Not reachable from here at all:** every Windows and Linux code path in these
four steps. They compile as part of the same sources but no Windows or Linux
compiler ran. Treat §2/§3/§4 on those platforms as *unverified*, not as
*expected to work*.

---

## 1 · 2.2 — the event loop sleeps

### 1.1 Idle CPU, before and after

The headline claim. Cumulative CPU time is the honest measure; instantaneous
`%CPU` in Activity Monitor bounces too much to compare.

```bash
./build.sh
./pbjsExample &
APP=$!
sleep 8                       # let startup and the WebView settle
ps -o cputime= -p $APP        # T1
sleep 12
ps -o cputime= -p $APP        # T2
kill $APP
```

Idle CPU = `(T2 − T1) / 12`.

Measured here, two rounds, **untouched app, no window focused**:

| | round 1 | round 2 |
|---|---|---|
| before (`WaitWindowEvent(16)`) | 4.33 % | 2.08 % |
| after (default 250 ms) | 2.83 % | 1.25 % |
| after + `SetIdleTimeout(0)` | 0.92 % | 1.00 % |

✅ **Pass:** "after" is materially below "before" on the same machine in the same
session. The absolute numbers move with background load — compare the ratio, not
the number, and take both readings back to back.

To reproduce the "before" column, build from `origin/main` into a second binary
and measure that one; do not compare against a number from a different day.

### 1.2 The app still responds

With the loop now sleeping, an event that used to be picked up by the next 16 ms
tick has to actually wake it.

- Click **Open PBJS Window** → the second window appears immediately.
- Click **Resize PBJS Window** → it moves and resizes immediately.
- Type into the editor gadget → no lag.
- Close the native window → the app exits.

✅ **Pass:** nothing feels slower than before. ❌ **Fail:** any control that
needs a second click, or a visible delay before something happens.

### 1.3 The web-mode network path **[Vynce]**

`NetworkServerEvent()` is the one thing left that can only be found by looking,
and the drain loop is new.

```bash
cd /path/to/vynce && npm run dev:web
```

- The main window loads in a browser tab.
- Open an agent window from it — the dev popover gives you the instance URL.
- Drive some traffic (start an agent, watch terminal output stream).

✅ **Pass:** the relay behaves exactly as before, and **output under load is not
choppier** — the drain loop exists so a burst is not served one message per
100 ms poll. ❌ **Fail:** stuttering output, or a window that attaches slowly.

### 1.4 The quit path still times out **[Vynce]**

This is the check that matters most, because it is why the default is 250 ms and
not a full block. See checklist Deviations §11.

1. Run Vynce normally.
2. Wedge the renderer: DevTools console on main-window → `while(true){}`.
3. Quit the app (⌘Q).

✅ **Pass:** the app still quits, after its own timeout, logging
`main-window did not answer in time — closing anyway`.
❌ **Fail:** the app hangs forever. That would mean `ShouldKeepRunning` has
stopped being polled — check nobody has called `SetIdleTimeout(0)`.

---

## 2 · 2.3 — display-change events

### 2.1 The response fires on a topology change

Needs a second display, or a resolution change on the one you have.

1. Run `./pbjsExample` (or Vynce) with a window open, **not** maximized.
2. Attach an external display, or change the main display's resolution in
   System Settings → Displays.

✅ **Pass:** the window's page still fills its window afterwards. Maximize it
onto the *larger* display — the content fills the whole window.
❌ **Fail:** a maximized window shows a blank stripe down the right or bottom
edge. That is the 1.9 symptom: the webview gadget is still sized to the old
desktop maximum.

Repeat with the display **detached** — nothing should break; the response only
grows the gadget.

### 2.2 It is the event, not the 5 s poll

The poll is still there as belt-and-braces at 5 s (checklist 2.3), so a working
poll can mask a broken hook. Distinguish them by timing:

✅ **Event working:** the layout corrects **within a frame or two** of the
display change. ❌ **Only the poll working:** it corrects, but visibly late —
up to five seconds.

Per platform, the hook under test is:

- **[mac]** `NSApplicationDidChangeScreenParametersNotification`
- **[win]** `WM_DISPLAYCHANGE` in `JSWindow::WindowCallback`
- **[linux]** GDK `monitors-changed`

### 2.3 The poll is no longer twice a second

```bash
# macOS: watch for ExamineDesktops-driven work
sudo fs_usage -w -f filesys $(pgrep -x pbjsExample) 2>/dev/null | head -40
```

✅ **Pass:** no periodic burst twice a second. (A 5 s one is expected and
correct.)

---

## 3 · 2.4 — live theme

### 3.1 No subprocess per window **[mac]** **[linux]**

This is the P3 half, and the easiest thing to get wrong quietly.

```bash
# Run this BEFORE launching, then launch and open several windows.
sudo fs_usage -w -f exec 2>/dev/null | grep -E "defaults|gsettings|gdbus"
```

✅ **Pass on macOS:** **zero** `defaults` executions, at launch and for every
window opened afterwards. Detection is now `NSApp.effectiveAppearance`.
✅ **Pass on Linux:** at most one burst of `gsettings`/`gdbus` at startup, and
**none** per window created afterwards. Before 2.4 every window — and every pool
spare — re-ran detection.
❌ **Fail:** a spawn each time a window opens. In Vynce, pre-warming the pool is
the loudest case: open and close agent windows and watch.

### 3.2 A theme flip reaches the chrome and the pages

The R7 half. The bridge has shipped `updateDarkMode()` from the beginning with
nothing native ever calling it, so before this step a flip changed nothing until
restart.

1. Launch the app with several windows open (in Vynce: main window + an agent
   window + the execution window).
2. Flip the OS theme:
   - **[mac]** System Settings → Appearance → Light ↔ Dark
   - **[win]** Settings → Personalisation → Colours → Choose your mode
   - **[linux]** your DE's appearance setting

✅ **Pass:**
- every window's native background/titlebar follows the new theme;
- **every page** follows too — the `dark` class appears on/disappears from
  `<html>`, and anything registered via `pbjs.registerDarkModeChangeHandler`
  runs;
- **windows opened after the flip** come up in the new theme.

❌ **Fail:** chrome changes but pages do not (the broadcast is not reaching
`Sink::Exec`), or nothing changes at all (the watcher never fired).

Check a page directly, in its DevTools console:

```js
document.documentElement.classList.contains("dark")   // matches the OS theme
pbjs.isDarkMode()                                     // same answer
```

### 3.3 Timing, and the 5 s backstop **[mac]** **[win]**

`AppleInterfaceThemeChangedNotification` can arrive a beat before
`NSApp.effectiveAppearance` has caught up, in which case the immediate refresh
reads the old value and the 5 s service tick corrects it.

✅ **Pass:** the flip lands **immediately**, or within 5 s at the very worst.
❌ **Fail:** it never lands. Then the watcher is not firing at all and the
service tick is not either — check `OsTheme::InitOsTheme()` runs *before*
`WindowManager::InitWindowManager()` (README §2.1).

### 3.4 Linux has no backstop — by design **[linux]**

`ServiceTick` deliberately does **not** re-check the theme on Linux, because
detecting there costs up to three subprocesses and a 5 s poll would be worse
than the problem 2.4 set out to fix (checklist 2.4).

✅ **Pass:** the flip lands via the GTK signal.
⚠ **Known limitation, not a bug:** if your desktop environment does not emit
`notify::gtk-application-prefer-dark-theme` or `notify::gtk-theme-name`, the
theme stays as detected at launch — which is exactly the pre-2.4 behaviour. Say
which DE if you hit this; the fix is another signal, not a poll.

---

## 4 · 2.5 — one scheduler

### 4.1 Thread count is flat under an open/close storm

The direct evidence that thread-per-delay is gone. Each window prepare/open used
to spawn two to four threads whose only job was to sleep.

**[Vynce]**, since it is the one with multi-instance templates:

```bash
# Baseline with the app idle:
ps -M $(pgrep -f Vynce | head -1) | wc -l
```

1. Open and close ~20 agent windows, briskly.
2. Re-read the thread count.

✅ **Pass:** the count is essentially unchanged — same figure ±a couple.
❌ **Fail:** it climbs with the number of windows opened.

### 4.2 The reveal watchdog still fires

Cancellation must not have cancelled something real. Break a page deliberately:

1. In `reactExample/main-window/src/main.tsx`, add `while(true){}` at the top.
2. `./build.sh --run`.

✅ **Pass:** the window still becomes **visible** rather than staying invisible
forever — `#Event_Force_Content_Visible` fired on its deadline even though the
page never reported ready. ❌ **Fail:** an invisible window.

Undo the edit afterwards.

### 4.3 The prepare timeout still fires **[Vynce]**

Same shape, on the pool path: a template instance whose page never reports ready
must still complete its prepare rather than stranding a spare.

✅ **Pass:** open an agent window with a deliberately broken page — it still
appears, and the pool still refills behind it.

### 4.4 The close veto still times out **[Vynce]**

The close watchdog now cancels on re-arm (checklist 2.5), so re-arming is the
interesting case.

1. Register a handler that never answers, in main-window's DevTools:
   ```js
   pbjs.handleAll("close-window", () => new Promise(() => {}));
   ```
2. Try to close the window. Wait.
3. Try again, twice, a second apart — this is the re-arm path.

✅ **Pass:** each attempt is **declined after ~4 s** and the window stays open,
every time — not just the first. The scope clears between attempts, so attempt 3
behaves like attempt 1. ❌ **Fail:** the second or third attempt is silently
swallowed and no further close ever works. That is the R1 wedge returning.

### 4.5 Nothing lands on a recycled window **[Vynce]**

The reason cancellation exists. Hard to force deliberately; watch for the
symptom over normal use:

✅ **Pass:** opening and closing agent windows repeatedly never produces a
window that flashes, reveals early, or reveals twice.

---

## 5 · Regression sweep

Worth one pass after the above, because these four steps touch the event loop,
the window registry and the theme — i.e. everything.

| | ✅ Pass |
|---|---|
| App starts, all windows appear | no white flash, no invisible window |
| Cross-window IPC | agent rename in an agent-window reflects in main-window |
| Drag & drop **[mac]** | tab tear-out between windows still works |
| Resize | drag a window edge — content tracks the drag, no lag |
| Multi-instance | open the same agent twice → focuses the existing window |
| Quit | ⌘Q with agents running → confirmation dialog, then a clean exit |
| `$TMPDIR/pbjs_dnd_debug.log` | note the **new** name (2.10 renamed it) |

---

## 6 · If something fails

Report the **step number** and:

- which platform;
- whether the 5 s service tick eventually corrected it (that isolates
  watcher-vs-response);
- for 2.2, both cumulative-CPU readings and whether `SetIdleTimeout` was called;
- for 2.5, the thread count before and after.

The most likely places for a first failure, in order:

1. **Windows and Linux watchers** — compiled but never run anywhere (§0).
2. **The Linux GTK signal names** — DE-dependent (§3.4).
3. **The macOS theme notification race** — should self-correct within 5 s (§3.3).
