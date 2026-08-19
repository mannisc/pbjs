; ============================================================================
; NATIVE ROUTER HARNESS — pbjsBridge end to end, with no webview at all.
; ============================================================================
; Roadmap step 2.1 (S4), the native half.
;
; HOW IT WORKS
; ------------
; Sink is the interception point the web-mode design already put between the
; router and the page (modules/JSSink.pb). A window whose sink is HEADLESS
; routes every script through an app-installed ExecHook and every callback
; through a registry that Sink::DispatchCall can invoke directly. That is
; exactly a test double, and it was already in the shipping code:
;
;   Sink::RegisterHeadless(name)   -> a sink that needs no gadget
;   Sink::SetHooks(@OnExec(), …)   -> capture what would have run in the page
;   JSBridge::InitializeBridge(…)  -> binds pbjsNativeGet/Send/… onto that sink
;   Sink::DispatchCall(win, fn, …) -> call one, exactly as the webview would
;
; So the harness drives the real HandleSend / HandleGet / HandleSendAll /
; HandleGetAll / HandleReply — which are module-private and reachable no other
; way — and asserts on the real script strings the host would have injected.
;
; WHAT IT DOES NOT COVER
; ----------------------
; Anything that needs a real window lifecycle: the registry cleanup of roadmap
; 1.10 (R4) and the pool refill of 1.11 (R6) both run inside CloseJSWindow /
; OpenInstance, which create and destroy OS windows and webviews. A headless
; sink has no lifecycle to close. Those two remain hand-traced; see
; iplan/checklist.md.
;
; RUN
; ---
;     tests/pb/run.sh
;
; Exit code is the result: 0 all passed, 1 something failed.
; ============================================================================

IncludeFile "../../pbjs.pb"
IncludeFile "harness.pb"

UseModule Harness

; ----------------------------------------------------------------------------
;- Helpers
; ----------------------------------------------------------------------------

; The webview hands a bound callback ONE argument: a JSON array of strings.
; Wrap a frame the way BindWebViewCallback would.
Procedure.s AsCallbackArgs(frameJson.s)
  Protected escaped.s = JSBridge::EscapeJSONValue(frameJson)
  ProcedureReturn "[" + Chr(34) + escaped + Chr(34) + "]"
EndProcedure

; Drive one of the router's native callbacks on a window's sink.
Procedure CallNative(win.s, fn.s, frameJson.s)
  Sink::DispatchCall(win, fn, AsCallbackArgs(frameJson))
EndProcedure

Procedure.s Q(text.s)
  ProcedureReturn Chr(34) + text + Chr(34)
EndProcedure

; The same token as it appears INSIDE the injected JS literal. The frame is
; built with real quotes and then escaped as a whole on its way into
; pbjsHandleMessage('…'), so every structural quote arrives as \" — searching a
; captured script for a raw "name":"ping" finds nothing.
Procedure.s QE(text.s)
  ProcedureReturn "\" + Chr(34) + text + "\" + Chr(34)
EndProcedure

; Extract the single-quoted literal from `pbjsHandleMessage('…');`, so a test
; can assert on what JS will actually be handed.
Procedure.s LiteralOf(script.s)
  Protected open.i = FindString(script, "('")
  If open = 0
    ProcedureReturn ""
  EndIf
  Protected close.i = FindString(script, "');", open)
  If close = 0
    ProcedureReturn ""
  EndIf
  ProcedureReturn Mid(script, open + 2, close - open - 2)
EndProcedure

OpenConsole("pbjs router harness")
InstallHooks()

; ============================================================================
;- 1. EscapeJSONValue — RFC 8259 and nothing else  (roadmap 1.8 / R3)
; ============================================================================
; The bug this replaced: only three characters were escaped, so any other C0
; control character reached JSON.parse raw. JSON forbids ALL of U+0000–U+001F
; inside a string, so the parse threw inside pbjsHandleMessage — where the catch
; only logs. The message (a store-sync patch, a reply) was silently dropped.

Section("EscapeJSONValue — the short escapes")
CheckEqS(JSBridge::EscapeJSONValue("a" + Chr(8)  + "b"), "a\bb", "backspace -> \b")
CheckEqS(JSBridge::EscapeJSONValue("a" + Chr(9)  + "b"), "a\tb", "tab -> \t")
CheckEqS(JSBridge::EscapeJSONValue("a" + Chr(10) + "b"), "a\nb", "newline -> \n")
CheckEqS(JSBridge::EscapeJSONValue("a" + Chr(12) + "b"), "a\fb", "form feed -> \f")
CheckEqS(JSBridge::EscapeJSONValue("a" + Chr(13) + "b"), "a\rb", "carriage return -> \r")

Section("EscapeJSONValue — every other C0 as \u00XX")
CheckEqS(JSBridge::EscapeJSONValue(Chr(27)), "\u001B", "ESC -> \u001B")
CheckEqS(JSBridge::EscapeJSONValue(Chr(1)),  "\u0001", "SOH -> \u0001")
CheckEqS(JSBridge::EscapeJSONValue(Chr(31)), "\u001F", "US -> \u001F")
CheckEqS(JSBridge::EscapeJSONValue(Chr(7)),  "\u0007", "BEL -> \u0007")
CheckEqS(JSBridge::EscapeJSONValue(Chr(11)), "\u000B", "VT -> \u000B")

Section("EscapeJSONValue — quotes and backslashes")
CheckEqS(JSBridge::EscapeJSONValue(Q("hi")), "\" + Chr(34) + "hi\" + Chr(34), "double quote -> \" + Chr(34))
CheckEqS(JSBridge::EscapeJSONValue("a\b"), "a\\b", "backslash doubled")
; The backslash pass must run FIRST, or the one \b introduces gets doubled too
; and the value arrives in JS as a literal backslash followed by 'b'.
CheckEqS(JSBridge::EscapeJSONValue("\" + Chr(8)), "\\\b", "backslash then backspace: only the original is doubled")
CheckEqS(JSBridge::EscapeJSONValue("Tim's shell"), "Tim's shell", "apostrophe untouched — \' is not valid JSON")

Section("EscapeJSON — the JS-literal escaper on top")
CheckEqS(JSBridge::EscapeJSON("Tim's shell"), "Tim\'s shell", "apostrophe escaped for the single-quoted literal")
CheckEqS(JSBridge::EscapeJSON(Chr(27)), "\u001B", "on its own it is the value escaper plus apostrophes, nothing more")
; The doubling that matters happens at the INJECTION SITE: a frame whose values
; EscapeJSONValue already escaped is escaped once more by EscapeJSON on its way
; into the literal. JS then un-escapes one layer and hands JSON.parse the other.
CheckEqS(JSBridge::EscapeJSON(JSBridge::EscapeJSONValue(Chr(27))), "\\u001B",
         "escaped twice on the way to the page — one layer per hop")
CheckEqS(JSBridge::EscapeJSON("plain"), JSBridge::EscapeJSONValue("plain"), "identical to the value escaper when there is no apostrophe")

; ============================================================================
;- 2. Routing: a message reaches exactly the target
; ============================================================================
ResetRegistry()
AddWindow("main-window")
AddWindow("other-window")

Section("send routes to the named window only")
ClearCaptured()
CallNative("main-window", "pbjsNativeSend",
           "{" + Q("type") + ":" + Q("send") +
           "," + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("other-window") +
           "," + Q("name") + ":" + Q("ping") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") + "}")

CheckEqI(CapturedCount(), 1, "exactly one script emitted")
CheckEqS(CapturedWindow(0), "other-window", "delivered to the target")
Check(Bool(FindString(CapturedScript(0), "pbjsHandleMessage('") = 1), "wrapped as pbjsHandleMessage('…')")
Check(Bool(FindString(CapturedScript(0), QE("name") + ":" + QE("ping")) > 0), "carries the handler name")

Section("send to an unknown window is dropped, not queued anywhere")
ClearCaptured()
CallNative("main-window", "pbjsNativeSend",
           "{" + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("ghost-window") +
           "," + Q("name") + ":" + Q("ping") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") + "}")
CheckEqI(CapturedCount(), 0, "nothing emitted")

Section("a bare map lookup must not create a ghost window")
; JSWindows(key) INSERTS a missing key — a phantom window that then appears in
; every broadcast loop for the rest of the run. GetJSWindowPtrByName guards with
; FindMapElement precisely for this, and the send above went through it.
CheckEqI(MapSize(JSWindow::JSWindows()), 2, "registry still holds only the two real windows")
CheckEqI(JSBridge::GetJSWindowByName("ghost-window"), -1, "unknown name answers -1")
CheckEqI(MapSize(JSWindow::WindowsByName()), 2, "and the name index did not grow either")

; ============================================================================
;- 3. Queueing to a not-ready window
; ============================================================================
; A window exists from the moment it is registered, but its page is not ready
; until the bridge script has run. Anything sent in between must be buffered and
; replayed, or the openInstance -> handleParameters handshake loses its payload.

Section("a message to a not-ready window is queued, not executed")
ResetRegistry()
AddWindow("main-window")
AddWindow("cold-window", #False)   ; registered, page not ready
ClearCaptured()

CallNative("main-window", "pbjsNativeSend",
           "{" + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("cold-window") +
           "," + Q("name") + ":" + Q("ping") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") + "}")

CheckEqI(CapturedCount(), 0, "nothing executed on the page")
CheckEqI(PendingCount("cold-window"), 1, "one script waiting in PendingMessages")

Section("flushing replays it")
SetReady("cold-window", #True)
JSBridge::FlushPendingMessages(WindowPtr("cold-window"))
CheckEqI(CapturedCount(), 1, "the queued script ran")
CheckEqI(PendingCount("cold-window"), 0, "and the queue is empty")

Section("the queue preserves order")
ResetRegistry()
AddWindow("main-window")
AddWindow("cold-window", #False)
ClearCaptured()
Define i.i
For i = 1 To 3
  CallNative("main-window", "pbjsNativeSend",
             "{" + Q("fromWindow") + ":" + Q("main-window") +
             "," + Q("toWindow") + ":" + Q("cold-window") +
             "," + Q("name") + ":" + Q("msg" + Str(i)) +
             "," + Q("params") + ":" + Q("{}") +
             "," + Q("data") + ":" + Q("{}") + "}")
Next
SetReady("cold-window", #True)
JSBridge::FlushPendingMessages(WindowPtr("cold-window"))
CheckEqI(CapturedCount(), 3, "all three replayed")
Check(Bool(FindString(CapturedScript(0), "msg1") > 0), "first in, first out (1)")
Check(Bool(FindString(CapturedScript(1), "msg2") > 0), "first in, first out (2)")
Check(Bool(FindString(CapturedScript(2), "msg3") > 0), "first in, first out (3)")

Section("the queue is bounded — drop oldest past #MaxPendingMessages")
ResetRegistry()
AddWindow("main-window")
AddWindow("cold-window", #False)
ClearCaptured()
For i = 1 To 505
  CallNative("main-window", "pbjsNativeSend",
             "{" + Q("fromWindow") + ":" + Q("main-window") +
             "," + Q("toWindow") + ":" + Q("cold-window") +
             "," + Q("name") + ":" + Q("m" + Str(i)) +
             "," + Q("params") + ":" + Q("{}") +
             "," + Q("data") + ":" + Q("{}") + "}")
Next
CheckEqI(PendingCount("cold-window"), 500, "capped at 500")
SetReady("cold-window", #True)
JSBridge::FlushPendingMessages(WindowPtr("cold-window"))
Check(Bool(FindString(CapturedScript(0), QE("name") + ":" + QE("m6")) > 0), "the survivors are the newest 500")

; ============================================================================
;- 4. Broadcasts skip pool spares  (F13)
; ============================================================================
; A pool spare is a dormant, off-screen template window that no caller owns. It
; never registers the app's handlers, so including it in a broadcast is at best
; wasted work — and for invokeAll it is a hang, because expectedCount would
; count a window that can never reply.

ResetRegistry()
AddWindow("main-window")
AddWindow("other-window")
AddWindow("spare-1", #True, #True, #True)
AddWindow("spare-2", #True, #True, #True)

Section("sendAll skips spares and the sender")
ClearCaptured()
CallNative("main-window", "pbjsNativeSendAll",
           "{" + Q("type") + ":" + Q("sendAll") +
           "," + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("name") + ":" + Q("patch") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") + "}")

CheckEqI(CapturedCount(), 1, "one recipient out of four windows")
CheckEqS(CapturedWindow(0), "other-window", "the one non-spare peer")
CheckEqI(CapturedCountFor("main-window"), 0, "the sender is excluded")
CheckEqI(CapturedCountFor("spare-1"), 0, "spare-1 excluded")
CheckEqI(CapturedCountFor("spare-2"), 0, "spare-2 excluded")

Section("getAll counts the same windows it asks")
ClearCaptured()
CallNative("main-window", "pbjsNativeGetAll",
           "{" + Q("type") + ":" + Q("getAll") +
           "," + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("name") + ":" + Q("getAgents") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("requestId") + ":7}")

; The count goes back to the SOURCE window; the broadcast goes to the targets.
Check(Bool(FindString(FirstScriptFor("main-window"), "pbjsSetGetAllExpectedCount(7, 1)") > 0),
      "expectedCount is 1 — spares are not counted")
CheckEqI(CapturedCountFor("other-window"), 1, "and exactly that one window was asked")
CheckEqI(CapturedCountFor("spare-1"), 0, "no spare was asked")

Section("getAll with no eligible target still tells the caller")
ResetRegistry()
AddWindow("main-window")
AddWindow("spare-1", #True, #True, #True)
ClearCaptured()
CallNative("main-window", "pbjsNativeGetAll",
           "{" + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("name") + ":" + Q("getAgents") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("requestId") + ":9}")
; Zero is an ANSWER, not silence: the JS side resolves [] on count 0, and would
; otherwise sit on its 30 s timeout.
Check(Bool(FindString(FirstScriptFor("main-window"), "pbjsSetGetAllExpectedCount(9, 0)") > 0),
      "count 0 is sent so invokeAll resolves []")
CheckEqI(CapturedCount(), 1, "and nothing was broadcast")

; ============================================================================
;- 5. get — the immediate error paths
; ============================================================================
; Both exist so the caller's .catch() fires now rather than after the 30 s
; pending-request timeout.

Section("get to an unknown window answers the caller with an error")
ResetRegistry()
AddWindow("main-window")
ClearCaptured()
CallNative("main-window", "pbjsNativeGet",
           "{" + Q("type") + ":" + Q("get") +
           "," + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("ghost-window") +
           "," + Q("name") + ":" + Q("getStatus") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("requestId") + ":3}")

CheckEqI(CapturedCount(), 1, "one script — the error response")
CheckEqS(CapturedWindow(0), "main-window", "sent back to the caller")
Check(Bool(FindString(CapturedScript(0), "pbjsHandleResponse('") = 1), "delivered as a response, not a message")
Check(Bool(FindString(CapturedScript(0), "Window not found: ghost-window") > 0), "says which window")

Section("get to a registered but CLOSED window is a different error")
ResetRegistry()
AddWindow("main-window")
AddWindow("shut-window", #True, #False)   ; registered, Open = #False
ClearCaptured()
CallNative("main-window", "pbjsNativeGet",
           "{" + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("shut-window") +
           "," + Q("name") + ":" + Q("getStatus") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("requestId") + ":4}")

CheckEqI(CapturedCountFor("shut-window"), 0, "the closed window is not asked")
Check(Bool(FindString(FirstScriptFor("main-window"), "Window not open: shut-window") > 0),
      "the caller is told it is closed, not missing")

Section("get to a live window is delivered and NOT answered by the router")
ResetRegistry()
AddWindow("main-window")
AddWindow("other-window")
ClearCaptured()
CallNative("main-window", "pbjsNativeGet",
           "{" + Q("fromWindow") + ":" + Q("main-window") +
           "," + Q("toWindow") + ":" + Q("other-window") +
           "," + Q("name") + ":" + Q("getStatus") +
           "," + Q("params") + ":" + Q("{}") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("requestId") + ":5}")

CheckEqI(CapturedCount(), 1, "one script")
CheckEqS(CapturedWindow(0), "other-window", "delivered to the target")
Check(Bool(FindString(CapturedScript(0), QE("requestId") + ":5") > 0), "requestId travels with it")
CheckEqI(CapturedCountFor("main-window"), 0, "the caller hears nothing yet")

Section("reply routes back to the requester")
ClearCaptured()
CallNative("other-window", "pbjsNativeReply",
           "{" + Q("requestId") + ":5" +
           "," + Q("toWindow") + ":" + Q("main-window") +
           "," + Q("fromWindow") + ":" + Q("other-window") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("isGetAll") + ":" + Q("false") + "}")

CheckEqI(CapturedCount(), 1, "one script")
CheckEqS(CapturedWindow(0), "main-window", "back to the requester")
Check(Bool(FindString(CapturedScript(0), "pbjsHandleResponse('") = 1), "as a response")
Check(Bool(FindString(CapturedScript(0), QE("requestId") + ":5") > 0), "correlated by requestId")

Section("a reply to a not-ready window is queued too")
ResetRegistry()
AddWindow("main-window", #False)
AddWindow("other-window")
ClearCaptured()
CallNative("other-window", "pbjsNativeReply",
           "{" + Q("requestId") + ":6" +
           "," + Q("toWindow") + ":" + Q("main-window") +
           "," + Q("fromWindow") + ":" + Q("other-window") +
           "," + Q("data") + ":" + Q("{}") +
           "," + Q("isGetAll") + ":" + Q("false") + "}")
CheckEqI(CapturedCount(), 0, "not executed")
CheckEqI(PendingCount("main-window"), 1, "queued for the reload")

; ============================================================================
;- 6. NotifyWindowEvent — the §6.5 lifecycle push
; ============================================================================
Section("lifecycle push reaches every ready peer, and nobody else")
ResetRegistry()
AddWindow("main-window")
AddWindow("other-window")
AddWindow("cold-window", #False)
AddWindow("spare-1", #True, #True, #True)
ClearCaptured()

JSBridge::NotifyWindowEvent("main-window", "closed")

CheckEqI(CapturedCount(), 1, "one recipient")
CheckEqS(CapturedWindow(0), "other-window", "the ready, non-spare peer")
CheckEqI(CapturedCountFor("main-window"), 0, "not the subject itself")
CheckEqI(CapturedCountFor("cold-window"), 0, "not a window whose page is not ready")
CheckEqI(CapturedCountFor("spare-1"), 0, "not a pool spare")
Check(Bool(FindString(CapturedScript(0), "pbjsWindowEvent('main-window','closed')") > 0),
      "carries the subject and the kind")

Section("a lifecycle push is never queued")
; Deliberate: a not-ready window has not built its readiness cache yet, so the
; event has nothing to correct. Queueing it would replay stale lifecycle news at
; a page that just loaded.
CheckEqI(PendingCount("cold-window"), 0, "nothing queued for the cold window")

; ============================================================================
;- 7. Registry lookups
; ============================================================================
Section("name/handle lookups")
ResetRegistry()
Define mainHandle.i = AddWindow("main-window")
CheckEqI(JSBridge::GetJSWindowByName("main-window"), mainHandle, "name -> handle")
CheckEqS(JSBridge::GetJSWindowNameByID(mainHandle), "main-window", "handle -> name")
CheckEqS(JSBridge::GetJSWindowNameByID(424242), "", "unknown handle answers empty")
CheckEqI(JSBridge::GetJSWindowByName("nope"), -1, "unknown name -> -1")
CheckEqI(MapSize(JSWindow::JSWindows()), 1, "no ghost element was inserted by any of that")

; ============================================================================
;- 7b. The delayed-event scheduler  (roadmap 2.5)
; ============================================================================
; PostEventAfterDelay used to spawn a thread per call whose only job was to
; sleep and then PostEvent. It is now one main-thread deadline list, which makes
; it testable — and, more to the point, CANCELLABLE, which is the actual reason
; it moved: a sleeping thread's post outlived its window and landed on whatever
; PB window number had been recycled since.
;
; WindowManager::ServiceDelayedEvents() returns the milliseconds until the next deadline, which
; is what RunEventLoop uses to size its WaitWindowEvent — so these assertions
; also cover 2.2's wait computation. What is NOT covered here is the loop
; itself: PostEvent needs a real PB window to deliver to, and this harness has
; none. The queue's bookkeeping is the half that can be checked without a GUI.

Section("scheduling and draining")
WindowManager::CancelDelayedEvents(0)
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "starts empty")

WindowManager::PostEventAfterDelay(0, 50, 101)
WindowManager::PostEventAfterDelay(0, 5000, 102)
CheckEqI(WindowManager::PendingDelayedEventCount(), 2, "two entries queued")

Define nextIn.i = WindowManager::ServiceDelayedEvents()
Check(Bool(nextIn > 0 And nextIn <= 50), "reports the NEAREST deadline, not the furthest")
CheckEqI(WindowManager::PendingDelayedEventCount(), 2, "nothing fired yet")

Delay(70)
nextIn = WindowManager::ServiceDelayedEvents()
CheckEqI(WindowManager::PendingDelayedEventCount(), 1, "the due entry drained")
Check(Bool(nextIn > 4000), "and the remaining one is still ~5 s out")

Section("an empty queue means 'sleep until an event arrives'")
WindowManager::CancelDelayedEvents(0)
CheckEqI(WindowManager::ServiceDelayedEvents(), 0, "0 = no deadline to wake for")

Section("a zero delay is due immediately, not dropped")
WindowManager::PostEventAfterDelay(0, 0, 103)
CheckEqI(WindowManager::PendingDelayedEventCount(), 1, "queued")
WindowManager::ServiceDelayedEvents()
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "drained on the very next service")

Section("a negative delay is clamped, not treated as far future")
WindowManager::PostEventAfterDelay(0, -1000, 104)
WindowManager::ServiceDelayedEvents()
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "drained immediately")

Section("cancellation — the point of the whole change")
WindowManager::CancelDelayedEvents(0)
WindowManager::PostEventAfterDelay(11, 5000, 201)
WindowManager::PostEventAfterDelay(11, 5000, 202)
WindowManager::PostEventAfterDelay(22, 5000, 201)
CheckEqI(WindowManager::PendingDelayedEventCount(), 3, "three queued across two windows")

WindowManager::CancelDelayedEvent(11, 201)
CheckEqI(WindowManager::PendingDelayedEventCount(), 2, "one kind cancelled for one window")

WindowManager::CancelDelayedEvents(11)
CheckEqI(WindowManager::PendingDelayedEventCount(), 1, "the rest of that window's went too")
; The survivor is window 22's, still ~5 s out — cancelling window 11 did not
; touch it, and did not fire it either.
Check(Bool(WindowManager::ServiceDelayedEvents() > 4000), "…and window 22's is untouched, still pending")

WindowManager::CancelDelayedEvents(22)
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "the other window's cancelled independently")

Section("cancelling what is not there is a no-op, not a corruption")
WindowManager::CancelDelayedEvents(999)
WindowManager::CancelDelayedEvent(999, 1)
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "still empty, no crash")

Section("a window forgotten by the manager loses its pending events")
; This is the whole cancellation story end to end: ForgetManagedWindow is what
; every teardown path calls, so a delayed event cannot outlive its window.
WindowManager::PostEventAfterDelay(0, 5000, 301)
CheckEqI(WindowManager::PendingDelayedEventCount(), 1, "armed")
Define *fake.WindowManager::AppWindow = AllocateStructure(WindowManager::AppWindow)
*fake\Window = 0
*fake\Hwnd = 0
*fake\PendingRemoval = #False
WindowManager::ForgetManagedWindow(*fake)
CheckEqI(WindowManager::PendingDelayedEventCount(), 0, "ForgetManagedWindow cancelled it")
FreeStructure(*fake)
; ForgetManagedWindow bumped the removal counter for a record that is not in the
; list; clear it so the harness's later sections are not sweeping a ghost.
WindowManager::SweepRemovedWindows()

Section("many entries, mixed deadlines")
WindowManager::CancelDelayedEvents(0)
Define k.i
For k = 1 To 50
  WindowManager::PostEventAfterDelay(0, 5000 + k, 400 + k)
Next
For k = 1 To 25
  WindowManager::PostEventAfterDelay(0, 1, 500 + k)
Next
CheckEqI(WindowManager::PendingDelayedEventCount(), 75, "all 75 queued")
Delay(20)
WindowManager::ServiceDelayedEvents()
CheckEqI(WindowManager::PendingDelayedEventCount(), 50, "exactly the 25 due ones drained")
WindowManager::CancelDelayedEvents(0)

; ============================================================================
;- 8. Escaping round trip — emit the fixture the jsdom side consumes
; ============================================================================
; The PB assertions above check what the escapers PRODUCE. They cannot check the
; actual claim: that a real JavaScript engine reads the result back as the same
; values. R3's bug was exactly a frame PureBasic emitted happily and JSON.parse
; rejected, inside pbjsHandleMessage — where the catch only logs, so the message
; vanished with no error anywhere.
;
; So the frames below are written to tests/fixtures/native-frames.json and
; tests/js/native-frames.test.js evaluates them in jsdom. Two real
; implementations, one wire format, no model of either in between.
;
; WHERE A RAW CONTROL CHARACTER ACTUALLY COMES FROM — this is what makes the
; cases below realistic rather than decorative. `params` and `data` arriving
; from a page were produced by JSON.stringify and can never contain one. The
; hand-built fields can:
;
;   * the handler NAME and the SOURCE WINDOW name, which HandleSend/HandleGet
;     extract from the caller's frame and splice into a new one;
;   * `paramsJson` on the native-originated path (SendSystemMessage), which the
;     HOST assembles itself — the ESC in a terminal title, verbatim.
;
; A fixture whose control characters sit inside an already-serialized `data`
; blob tests nothing: they are text by then, and the escaper never sees them.
;
; The fixture is COMMITTED so the jsdom suite runs where no PureBasic compiler
; exists. Re-run this harness after touching an escaper or a hand-built frame,
; and commit the diff — `git diff tests/fixtures` is the review of what changed
; on the wire.

Structure FixtureCase
  Id.s
  Label.s
  Vehicle.s     ; "send" (router path) | "system" (native-originated path)
  Handler.s
  From.s
  ParamsJson.s  ; expected `params`, as JSON text
  DataJson.s    ; expected `data`, as JSON text
  Script.s
EndStructure
Global NewList Fixtures.FixtureCase()

; --- vehicle 1: the router path (a page sent it) ---------------------------
; handlerName and fromWindow are hand-spliced by HandleSend after being pulled
; out of the caller's frame, so raw control characters in them reach
; EscapeJSONValue. dataJson is passed through verbatim, as JSON.stringify left it.
Procedure AddSendFixture(id.s, label.s, handlerName.s, fromWindow.s, dataJson.s)
  AddElement(Fixtures())
  Fixtures()\Id         = id
  Fixtures()\Label      = label
  Fixtures()\Vehicle    = "send"
  Fixtures()\Handler    = handlerName
  Fixtures()\From       = fromWindow
  Fixtures()\ParamsJson = "{}"
  Fixtures()\DataJson   = dataJson

  ClearCaptured()
  CallNative("main-window", "pbjsNativeSend",
             "{" + Q("fromWindow") + ":" + JsonQuote(fromWindow) +
             "," + Q("toWindow") + ":" + Q("other-window") +
             "," + Q("name") + ":" + JsonQuote(handlerName) +
             "," + Q("params") + ":" + Q("{}") +
             "," + Q("data") + ":" + JsonQuote(dataJson) + "}")
  Fixtures()\Script = CapturedScript(0)
EndProcedure

; --- vehicle 2: the native-originated path (the host sent it) ---------------
; SendSystemMessage takes a paramsJson the HOST built. EscapeJSONValue is
; exported precisely so the host can build it, and this is the path a terminal
; title with an ESC in it travels.
Procedure AddSystemFixture(id.s, label.s, handlerName.s, titleValue.s)
  Protected paramsJson.s = "{" + Q("title") + ":" + Q(JSBridge::EscapeJSONValue(titleValue)) + "}"

  AddElement(Fixtures())
  Fixtures()\Id         = id
  Fixtures()\Label      = label
  Fixtures()\Vehicle    = "system"
  Fixtures()\Handler    = handlerName
  Fixtures()\From       = "system"
  Fixtures()\ParamsJson = "{" + Q("title") + ":" + JsonQuote(titleValue) + "}"
  Fixtures()\DataJson   = "{}"

  ClearCaptured()
  JSBridge::SendSystemMessage(WindowPtr("other-window"), handlerName, paramsJson)
  Fixtures()\Script = CapturedScript(0)
EndProcedure

ResetRegistry()
AddWindow("main-window")
AddWindow("other-window")

Section("round-trip fixture")

AddSendFixture("plain", "an ordinary message",
               "updateAgent", "main-window",
               "{" + Q("id") + ":1}")

AddSendFixture("apostrophe", "an apostrophe would terminate the JS literal",
               "rename" + Chr(39) + "d", "main-window",
               "{" + Q("title") + ":" + Q("ok") + "}")

AddSendFixture("quote-in-name", "a double quote inside the handler name",
               "say" + Chr(34) + "hi" + Chr(34), "main-window",
               "{" + Q("ok") + ":true}")

AddSendFixture("quote-in-source", "a double quote in the SOURCE window name",
               "ping", "weird" + Chr(34) + "window",
               "{" + Q("v") + ":1}")

AddSendFixture("backslash-in-name", "a backslash in the handler name",
               "path" + Chr(92) + "sep", "main-window",
               "{" + Q("v") + ":1}")

; The R3 regression itself: C0 characters with no short escape. Pre-1.8 these
; reached JSON.parse raw and the whole frame was dropped.
AddSendFixture("c0-in-name", "ESC and BEL in a handler name",
               "term" + Chr(27) + "x" + Chr(7), "main-window",
               "{" + Q("v") + ":1}")

AddSendFixture("c0-in-source", "backspace and form feed in the source window name",
               "ping", "win" + Chr(8) + Chr(12) + "dow",
               "{" + Q("v") + ":1}")

AddSendFixture("unicode", "non-ASCII must survive the UTF-8 round trip",
               "grüße", "main-window",
               "{" + Q("text") + ":" + Q("grüße — 日本語 🎉") + "}")

AddSystemFixture("esc-sequence", "a real ANSI escape sequence, as a terminal title carries",
                 "terminalTitle", Chr(27) + "]0;build done" + Chr(7))

AddSystemFixture("c0-controls", "backspace, form feed and ESC in one host-built value",
                 "terminalTitle", "a" + Chr(8) + "b" + Chr(12) + "c" + Chr(27) + "d")

AddSystemFixture("all-c0", "every C0 character in one value",
                 "terminalTitle",
                 Chr(1)+Chr(2)+Chr(3)+Chr(4)+Chr(5)+Chr(6)+Chr(7)+Chr(8)+Chr(9)+
                 Chr(10)+Chr(11)+Chr(12)+Chr(13)+Chr(14)+Chr(15)+Chr(16)+Chr(17)+
                 Chr(18)+Chr(19)+Chr(20)+Chr(21)+Chr(22)+Chr(23)+Chr(24)+Chr(25)+
                 Chr(26)+Chr(27)+Chr(28)+Chr(29)+Chr(30)+Chr(31))

AddSystemFixture("apostrophe-value", "an apostrophe in a host-built value",
                 "rename", "Tim's shell")

AddSystemFixture("backslash-value", "a Windows path in a host-built value",
                 "openPath", "C:" + Chr(92) + "Users" + Chr(92) + "me")

AddSystemFixture("newline-tab", "newline and tab, which have short escapes",
                 "log", "line1" + Chr(10) + "line2" + Chr(9) + "end")

; --- write it out ----------------------------------------------------------
Define fixturePath.s = "../fixtures/native-frames.json"
Define out.s = "["
Define first.i = #True
ForEach Fixtures()
  If Not first
    out + ","
  EndIf
  first = #False
  out + Chr(10) + "  {"
  out + Chr(10) + "    " + Q("id") + ": " + JsonQuote(Fixtures()\Id) + ","
  out + Chr(10) + "    " + Q("label") + ": " + JsonQuote(Fixtures()\Label) + ","
  out + Chr(10) + "    " + Q("vehicle") + ": " + JsonQuote(Fixtures()\Vehicle) + ","
  out + Chr(10) + "    " + Q("handler") + ": " + JsonQuote(Fixtures()\Handler) + ","
  out + Chr(10) + "    " + Q("fromWindow") + ": " + JsonQuote(Fixtures()\From) + ","
  out + Chr(10) + "    " + Q("params") + ": " + Fixtures()\ParamsJson + ","
  out + Chr(10) + "    " + Q("data") + ": " + Fixtures()\DataJson + ","
  out + Chr(10) + "    " + Q("script") + ": " + JsonQuote(Fixtures()\Script)
  out + Chr(10) + "  }"
Next
out + Chr(10) + "]" + Chr(10)

Define fh.i = CreateFile(#PB_Any, fixturePath)
If fh
  WriteString(fh, out, #PB_UTF8)
  CloseFile(fh)
  Check(#True, "wrote " + Str(ListSize(Fixtures())) + " frames to tests/fixtures/native-frames.json")
Else
  Check(#False, "could not write " + fixturePath)
EndIf

; Two properties every emitted frame must have, checked here so a break is
; reported by this harness too and not only by the jsdom suite.
Define wellFormed.i = #True
Define noRawControls.i = #True
Define literal.s
Define ci.i
ForEach Fixtures()
  If FindString(Fixtures()\Script, "pbjsHandleMessage('") = 0
    wellFormed = #False
  EndIf
  literal = LiteralOf(Fixtures()\Script)
  ; A bare apostrophe is the one character that ends the literal early and turns
  ; the whole frame into a SyntaxError.
  If FindString(ReplaceString(literal, Chr(92) + Chr(39), ""), Chr(39)) > 0
    wellFormed = #False
  EndIf
  ; And a raw C0 character is the one that makes JSON.parse throw.
  For ci = 1 To Len(literal)
    If Asc(Mid(literal, ci, 1)) < 32
      noRawControls = #False
    EndIf
  Next
Next
Check(wellFormed, "every frame is a well-formed single-quoted literal")
Check(noRawControls, "no frame carries a raw control character into JSON.parse")

; ============================================================================
Define code.i = Report()
CloseConsole()
End code
