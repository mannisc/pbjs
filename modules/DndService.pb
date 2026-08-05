; =============================================================================
;- DND SERVICE — generic cross-window drag & drop sessions
; =============================================================================
; One session at a time. The SOURCE window's JS owns the lifecycle (its webview
; keeps receiving pointer events outside the window during a captured drag, so
; it reliably sees start / drop / Esc). This module owns everything the page
; cannot do: follow the cursor across the desktop (15ms timer polling
; DesktopMouseX/Y), topmost-aware window hit-testing, the native cursor badge
; (DragBadge.pb), and routing dnd:* messages between windows over the normal
; pbjs transport.
;
; Protocol (canonical doc: vynce docs/dnd.md; plan: iplan/cross-window-dnd/):
;   JS → native (Sink binds, all windows):
;     pbjsNativeDndStart(win, specJson)        → {sessionId} | {error}
;     pbjsNativeDndDrop(win, sessionId)        → {pending:true} | {error}
;     pbjsNativeDndCancel(win, sessionId)      → {}
;     pbjsNativeDndUpdateBadge(win, sessionId, badgeJson) → {}
;     pbjsNativeDndSetZoneActive(win, sessionId, "1"/"0") → {}
;     pbjsNativeDndRegisterTarget(win, typesJson) → {}
;     pbjsNativeDndUnregisterTarget(win)       → {}
;   native → JS (system messages / requests):
;     to source:  dnd:state {sessionId, over, window?}
;                 dnd:dropResult {sessionId, result}
;                 dnd:cancelled {sessionId}
;     to target:  dnd:enter/dnd:over/dnd:leave, and dnd:drop as a
;                 SendSystemRequest (the handler's return value resolves the
;                 source's drop()).
;
; THREADING / COCOA RULE (docs/app-close.md): the JS* entry points run inside
; webview callbacks — they only mutate state and send bridge scripts (both are
; safe there; HandleSend does the latter constantly). Everything that touches
; windows (badge show/move/hide, focus) happens on the timer tick, which runs
; on the main event loop.
;
; Platform: fully implemented on macOS. The module compiles everywhere; on
; other platforms Init() leaves the service disabled and the JS natives report
; "unavailable", which makes the web layer fall back to its legacy behavior.
;
; Debug: $TMPDIR/vynce_dnd_debug.log (disable with VYNCE_DND_DEBUG=0) — one
; line per state transition, mirroring the graph-debug (gdlog) pattern.
; Feature flag: VYNCE_DND=0 disables the whole service.

Module DndService
  UseModule JSWindow
  UseModule WindowManager

  ; --- constants ------------------------------------------------------------
  #TickMs = 15
  ; Large id — small timer ids collide with app timers (see main.pb note).
  #DndTimer = 941
  ; Drop reply timeout: ~2s at 15ms ticks.
  #DropTimeoutTicks = 133
  ; Watchdog: button up this many consecutive ticks with no drop()/cancel()
  ; from JS → the source page is wedged; auto-cancel so the badge can't stick.
  #ButtonUpCancelTicks = 10
  #MaxPayloadBytes = 65536

  Enumeration ; over classification
    #Over_None
    #Over_Source
    #Over_Target
  EndEnumeration

  Enumeration ; session state
    #S_Idle
    #S_Active
    #S_Dropping
    #S_DropResolved
  EndEnumeration

  ; --- state ----------------------------------------------------------------
  Structure DndState
    State.i
    Id.s
    Source.s
    Type.s
    PayloadJson.s      ; pre-stringified by the JS wrapper; embedded verbatim
    BadgeIcon.s
    BadgeLabel.s
    BadgeDirty.i
    Over.i
    TargetWindow.s
    ZoneActive.i
    ButtonUpTicks.i
    DropTicks.i
    DropRequested.i
    ; The id SendSystemRequest returned for the in-flight dnd:drop request (0 =
    ; none). OnDropReply compares its requestId param against this — NOT just
    ; State/TargetWindow — so a reply that arrives after its own request timed
    ; out or was abandoned can never be mistaken for a reply to a later
    ; request that happens to reuse the same target window.
    DropRequestId.i
    CancelRequested.i
    ResolvedJson.s
    ResolvedAccepted.i
    HasSentOver.i
    LastSentX.i
    LastSentY.i
    LastStyle.i
  EndStructure
  Global S.DndState

  Global Enabled.i = #False
  Global Initialized.i = #False
  Global SessionCounter.i = 0
  ; windowName -> "|type1|type2|" (registered drop-target types per window)
  Global NewMap TargetTypes.s()

  ; --- debug log ------------------------------------------------------------
  Global DebugEnabled.i = #True
  Global DebugPath.s

  Procedure DLog(msg.s)
    If Not DebugEnabled : ProcedureReturn : EndIf
    Protected f = OpenFile(#PB_Any, DebugPath, #PB_File_Append | #PB_File_SharedRead | #PB_File_SharedWrite)
    If f
      WriteStringN(f, Str(ElapsedMilliseconds()) + " " + msg, #PB_UTF8)
      CloseFile(f)
    EndIf
  EndProcedure

  ; --- small helpers --------------------------------------------------------

  ; Minimal JSON string escaping for values this module embeds into JSON it
  ; assembles by hand (names, ids, types). Payload JSON arrives pre-encoded.
  Procedure.s JsonStr(s.s)
    Protected r.s = ReplaceString(s, Chr(92), Chr(92) + Chr(92))
    r = ReplaceString(r, Chr(34), Chr(92) + Chr(34))
    r = ReplaceString(r, Chr(13), Chr(92) + "r")
    r = ReplaceString(r, Chr(10), Chr(92) + "n")
    r = ReplaceString(r, Chr(9), Chr(92) + "t")
    ProcedureReturn r
  EndProcedure

  ; Resolve a runtime window name to its live JSWindow entry (0 if gone).
  Procedure.i JSWinByName(name.s)
    If name <> "" And FindMapElement(WindowsByName(), name)
      Protected h.i = WindowsByName()
      If FindMapElement(JSWindows(), Str(h))
        ProcedureReturn @JSWindows()
      EndIf
    EndIf
    ProcedureReturn 0
  EndProcedure

  ; Fire-and-forget system message to a window (guards a vanished window).
  Procedure SendToWindow(win.s, name.s, paramsJson.s)
    Protected *js.JSWindow = JSWinByName(win)
    If *js
      JSBridge::SendSystemMessage(*js, name, paramsJson)
    EndIf
  EndProcedure

  Procedure.i AcceptsType(win.s, type.s)
    If FindMapElement(TargetTypes(), win)
      If FindString(TargetTypes(), "|" + type + "|")
        ProcedureReturn #True
      EndIf
    EndIf
    ProcedureReturn #False
  EndProcedure

  ; Reset the session slot to idle. State-only — badge/visual cleanup is the
  ; tick's job (it hides the badge whenever the state is idle).
  Procedure ResetState()
    S\State = #S_Idle
    S\Id = "" : S\Source = "" : S\Type = "" : S\PayloadJson = ""
    S\BadgeIcon = "" : S\BadgeLabel = "" : S\BadgeDirty = #False
    S\Over = #Over_None : S\TargetWindow = "" : S\ZoneActive = #False
    S\ButtonUpTicks = 0 : S\DropTicks = 0
    S\DropRequested = #False : S\DropRequestId = 0 : S\CancelRequested = #False
    S\ResolvedJson = "" : S\ResolvedAccepted = #False
    S\HasSentOver = #False : S\LastSentX = -100000 : S\LastSentY = -100000
    S\LastStyle = -1
  EndProcedure

  Procedure.s StateJson()
    Protected over.s
    Select S\Over
      Case #Over_Source : over = "source"
      Case #Over_Target : over = "target"
      Default : over = "none"
    EndSelect
    Protected j.s = ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\",\"over\":\"" + over + ~"\""
    If S\Over = #Over_Target
      j + ~",\"window\":\"" + JsonStr(S\TargetWindow) + ~"\""
    EndIf
    ProcedureReturn j + "}"
  EndProcedure

  ; Event payload for dnd:enter / dnd:drop (full) and shared coord math.
  ; x/y are CSS px in the target window's content area (macOS: points == px).
  Procedure.s TargetEventJson(win.s, sx.i, sy.i)
    Protected cx.i = sx, cy.i = sy
    If FindMapElement(WindowsByName(), win)
      Protected h.i = WindowsByName()
      If IsWindow(h)
        cx = sx - WindowX(h, #PB_Window_InnerCoordinate)
        cy = sy - WindowY(h, #PB_Window_InnerCoordinate)
      EndIf
    EndIf
    ProcedureReturn ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\",\"type\":\"" + JsonStr(S\Type) +
                    ~"\",\"sourceWindow\":\"" + JsonStr(S\Source) +
                    ~"\",\"payload\":" + S\PayloadJson +
                    ~",\"x\":" + Str(cx) + ~",\"y\":" + Str(cy) +
                    ~",\"screenX\":" + Str(sx) + ~",\"screenY\":" + Str(sy) + "}"
  EndProcedure

  Procedure.s OverEventJson(win.s, sx.i, sy.i)
    Protected cx.i = sx, cy.i = sy
    If FindMapElement(WindowsByName(), win)
      Protected h.i = WindowsByName()
      If IsWindow(h)
        cx = sx - WindowX(h, #PB_Window_InnerCoordinate)
        cy = sy - WindowY(h, #PB_Window_InnerCoordinate)
      EndIf
    EndIf
    ProcedureReturn ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\",\"x\":" + Str(cx) + ~",\"y\":" + Str(cy) +
                    ~",\"screenX\":" + Str(sx) + ~",\"screenY\":" + Str(sy) + "}"
  EndProcedure

  ; --- macOS platform layer -------------------------------------------------
  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS

    Structure DndPoint
      x.d
      y.d
    EndStructure

    ; Topmost window at the cursor, ANY app, excluding the badge. Returns the
    ; matching registry window's runtime name, or "" (foreign window, desktop,
    ; or one of our non-hit-testable windows: spares, headless).
    Procedure.s HitTestWindowName()
      Protected pt.DndPoint
      CocoaMessage(@pt, 0, "NSEvent mouseLocation")
      ; +[NSWindow windowNumberAtPoint:belowWindowWithNumber:] is a CLASS method
      ; with two keywords. PB's "ClassName selector:" 0-target shorthand (used
      ; correctly elsewhere in this codebase, e.g. "NSNumber numberWithBool:")
      ; only resolves the class for a SINGLE keyword segment — folding the class
      ; name into the first of two chained keyword segments ("NSWindow
      ; windowNumberAtPoint:@", ..., "belowWindowWithNumber:", ...) sent nothing
      ; to a real object and crashed with "does not respond to method" (caught
      ; live: a real drag hit this the first time the tick loop actually ran).
      ; Two-step fix: resolve the Class object explicitly, then send the full
      ; multi-keyword message to THAT pointer exactly like a normal instance
      ; call — the chained-keyword form is already proven throughout JSWindow.pb
      ; for real instance targets; only the class-resolution step was missing.
      Protected windowClass.i = CocoaMessage(0, 0, "NSWindow class")
      Protected num.i = CocoaMessage(0, windowClass, "windowNumberAtPoint:@", @pt,
                                     "belowWindowWithNumber:", DragBadge::CocoaWindowNumber())
      If num <= 0
        ProcedureReturn ""
      EndIf
      ForEach JSWindows()
        If Not JSWindows()\Headless And Not JSWindows()\IsPoolSpare And IsWindow(JSWindows()\Window)
          If CocoaMessage(0, WindowID(JSWindows()\Window), "windowNumber") = num
            ProcedureReturn JSWindows()\Name
          EndIf
        EndIf
      Next
      ProcedureReturn ""
    EndProcedure

    Procedure.i IsMouseButtonDown()
      ; Bit 0 = left button.
      ProcedureReturn CocoaMessage(0, 0, "NSEvent pressedMouseButtons") & 1
    EndProcedure

    Procedure Resolve(resultJson.s, accepted.i = #False)
      S\ResolvedJson = resultJson
      S\ResolvedAccepted = accepted
      S\State = #S_DropResolved
      DLog("[resolve] accepted=" + Str(accepted) + " " + resultJson)
    EndProcedure

    Procedure FocusTargetWindow(win.s)
      If FindMapElement(WindowsByName(), win)
        Protected h.i = WindowsByName()
        If IsWindow(h)
          Protected *W.AppWindow = GetManagedWindowFromWindowHandle(WindowID(h))
          If *W
            FocusInstance(*W)
          EndIf
        EndIf
      EndIf
    EndProcedure

    ; Deliver the final DropResult to the source, focus the target on an
    ; accepted move, drop the badge, go idle. Runs on the tick (Cocoa-safe).
    Procedure DeliverResolved()
      SendToWindow(S\Source, "dnd:dropResult",
                   ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\",\"result\":" + S\ResolvedJson + "}")
      If S\ResolvedAccepted And S\TargetWindow <> ""
        FocusTargetWindow(S\TargetWindow)
      EndIf
      DragBadge::Hide()
      DLog("[deliver] result to " + S\Source)
      ResetState()
    EndProcedure

    ; Cancel from the tick: notify target + source, drop the badge, go idle.
    ; Can run while a dnd:drop request is still in flight (Esc, or the source
    ; window closing, races the target's reply) — free that request's slot
    ; proactively rather than leaving it in PendingSystemRequests until (if
    ; ever) a reply shows up.
    Procedure CleanupCancelled(reason.s)
      If S\Over = #Over_Target And S\TargetWindow <> ""
        SendToWindow(S\TargetWindow, "dnd:leave", ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
      EndIf
      SendToWindow(S\Source, "dnd:cancelled", ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
      If S\DropRequestId
        JSBridge::CancelPendingSystemRequest(S\DropRequestId)
      EndIf
      DragBadge::Hide()
      DLog("[cancel] " + reason)
      ResetState()
    EndProcedure

    Procedure UpdateBadgeVisual(mx.i, my.i)
      Protected wantVisible.i = #False
      Protected style.i = DragBadge::#Style_NewWindow
      Select S\Over
        Case #Over_None
          wantVisible = #True
          style = DragBadge::#Style_NewWindow
        Case #Over_Target
          If Not S\ZoneActive
            wantVisible = #True
            style = DragBadge::#Style_Revert
          EndIf
      EndSelect
      If wantVisible
        If Not DragBadge::IsVisible() Or style <> S\LastStyle Or S\BadgeDirty
          DragBadge::Show(S\BadgeIcon, S\BadgeLabel, style, mx, my)
          S\LastStyle = style
          S\BadgeDirty = #False
        Else
          DragBadge::Move(mx, my)
        EndIf
      Else
        DragBadge::Hide()
      EndIf
    EndProcedure

    ; The 15ms heartbeat. Idle ticks return immediately; the timer runs for the
    ; app's lifetime so no Cocoa (AddWindowTimer) ever happens in a webview
    ; callback.
    Procedure OnTick()
      If EventTimer() <> #DndTimer
        ProcedureReturn
      EndIf

      If S\State = #S_Idle
        If DragBadge::IsVisible()
          DragBadge::Hide()
        EndIf
        ProcedureReturn
      EndIf

      If S\State = #S_DropResolved
        DeliverResolved()
        ProcedureReturn
      EndIf

      ; Source window vanished (close, recycle, HMR reload leaves the entry but
      ; resets Ready — a fully gone window drops out of the registry)?
      If JSWinByName(S\Source) = 0
        CleanupCancelled("source window gone")
        ProcedureReturn
      EndIf

      If S\CancelRequested
        CleanupCancelled("cancel requested")
        ProcedureReturn
      EndIf

      If S\State = #S_Dropping
        S\DropTicks + 1
        If S\DropTicks > #DropTimeoutTicks
          ; Give up on the target ever replying. Free its slot now — if a
          ; reply does eventually straggle in, OnDropReply's requestId check
          ; will already find no match (DropRequestId is cleared by
          ; ResetState via DeliverResolved), but there's no reason to also
          ; leave PendingSystemRequests holding the bag until then.
          JSBridge::CancelPendingSystemRequest(S\DropRequestId)
          Resolve(~"{\"accepted\":false,\"reason\":\"timeout\"}")
        EndIf
        ProcedureReturn
      EndIf

      ; ---- #S_Active ----
      Protected mx.i = DesktopMouseX()
      Protected my.i = DesktopMouseY()

      ; 1. Classify what's under the cursor.
      Protected hit.s = HitTestWindowName()
      Protected newOver.i
      Protected newTarget.s = ""
      If hit = S\Source
        newOver = #Over_Source
      ElseIf hit <> "" And AcceptsType(hit, S\Type)
        newOver = #Over_Target
        newTarget = hit
      Else
        newOver = #Over_None
      EndIf

      If newOver <> S\Over Or newTarget <> S\TargetWindow
        If S\Over = #Over_Target And S\TargetWindow <> "" And S\TargetWindow <> newTarget
          SendToWindow(S\TargetWindow, "dnd:leave", ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
        EndIf
        S\Over = newOver
        S\TargetWindow = newTarget
        If newOver <> #Over_Target
          S\ZoneActive = #False
        EndIf
        If newOver = #Over_Target
          S\ZoneActive = #False
          S\HasSentOver = #False
          SendToWindow(newTarget, "dnd:enter", TargetEventJson(newTarget, mx, my))
        EndIf
        SendToWindow(S\Source, "dnd:state", StateJson())
        DLog("[over] -> " + StateJson())
      EndIf

      ; 2. Position stream to the active target (throttled to real movement).
      If S\Over = #Over_Target
        If Not S\HasSentOver Or Abs(mx - S\LastSentX) >= 2 Or Abs(my - S\LastSentY) >= 2
          SendToWindow(S\TargetWindow, "dnd:over", OverEventJson(S\TargetWindow, mx, my))
          S\HasSentOver = #True
          S\LastSentX = mx
          S\LastSentY = my
        EndIf
      EndIf

      ; 3. Drop requested by the source?
      If S\DropRequested
        S\DropRequested = #False
        Select S\Over
          Case #Over_Target
            Protected *tjs.JSWindow = JSWinByName(S\TargetWindow)
            If *tjs
              S\State = #S_Dropping
              S\DropTicks = 0
              S\DropRequestId = JSBridge::SendSystemRequest(*tjs, "dnd:drop", TargetEventJson(S\TargetWindow, mx, my))
              DLog("[drop] -> target " + S\TargetWindow + " req=" + Str(S\DropRequestId))
            Else
              Resolve(~"{\"accepted\":false,\"reason\":\"no-target\",\"screenX\":" + Str(mx) + ~",\"screenY\":" + Str(my) + "}")
            EndIf
          Case #Over_Source
            Resolve(~"{\"accepted\":false,\"reason\":\"over-source\"}")
          Default
            Resolve(~"{\"accepted\":false,\"reason\":\"no-target\",\"screenX\":" + Str(mx) + ~",\"screenY\":" + Str(my) + "}")
        EndSelect
        ProcedureReturn
      EndIf

      ; 4. Badge.
      UpdateBadgeVisual(mx, my)

      ; 5. Stuck-session watchdog.
      If IsMouseButtonDown()
        S\ButtonUpTicks = 0
      Else
        S\ButtonUpTicks + 1
        If S\ButtonUpTicks >= #ButtonUpCancelTicks
          CleanupCancelled("watchdog: button up, no drop()")
        EndIf
      EndIf
    EndProcedure

    ; Reply to the dnd:drop system request. Runs inside a webview callback →
    ; state-only; DeliverResolved happens on the next tick.
    ;
    ; dataJson is NOT the target's onDrop return value directly — every "get"
    ; -type reply is wrapped by the bridge script's dispatchMessage() as
    ; {"success": <resolved value>} (event.success/.reply), or {"error":
    ; <message>} if the handler rejected/threw (same convention documented on
    ; HandleAppCloseSystemResponse in main.pb). Unwrap "success" first — the
    ; earlier version of this code read revert/reject off the TOP level and
    ; so never saw them (always fell through to accepted:true), silently
    ; discarding every revert/reject a target ever sent.
    Procedure OnDropReply(requestName.s, fromWindow.s, dataJson.s, requestId.i)
      ; Correlate by requestId, not just State/TargetWindow: a reply for a
      ; request this session already gave up on (timeout, cancel) must never
      ; be mistaken for the CURRENT request even if a later drop happens to
      ; target the very same window while the old reply is still in flight.
      If S\State <> #S_Dropping Or requestId <> S\DropRequestId
        DLog("[dropReply] stale (state=" + Str(S\State) + " req=" + Str(requestId) + " expected=" + Str(S\DropRequestId) + ")")
        ProcedureReturn
      EndIf
      If Trim(dataJson) = "" : dataJson = "{}" : EndIf
      Protected revert.i = #False
      Protected reject.i = #False
      Protected responseJson.s = "{}"
      Protected json = ParseJSON(#PB_Any, dataJson)
      If json
        Protected v = JSONValue(json)
        Protected unwrapped = 0
        If JSONType(v) = #PB_JSON_Object
          If GetJSONMember(v, "error")
            reject = #True
          Else
            unwrapped = GetJSONMember(v, "success")
          EndIf
        EndIf
        If unwrapped
          If JSONType(unwrapped) = #PB_JSON_Object
            If GetJSONMember(unwrapped, "revert") And JSONType(GetJSONMember(unwrapped, "revert")) = #PB_JSON_Boolean And GetJSONBoolean(GetJSONMember(unwrapped, "revert"))
              revert = #True
            EndIf
            If GetJSONMember(unwrapped, "reject")
              reject = #True
            EndIf
          EndIf
          responseJson = ComposeJSON(unwrapped)
        ElseIf Not reject
          ; No recognizable {success:...}/{error:...} envelope — the reply
          ; didn't come from the normal dispatchMessage() path. Don't treat
          ; an unrecognized shape as an accept.
          reject = #True
        EndIf
        FreeJSON(json)
      Else
        reject = #True
      EndIf
      If revert
        Resolve(~"{\"accepted\":false,\"reason\":\"reverted\"}")
      ElseIf reject
        Resolve(~"{\"accepted\":false,\"reason\":\"rejected\"}")
      Else
        Resolve(~"{\"accepted\":true,\"window\":\"" + JsonStr(S\TargetWindow) + ~"\",\"response\":" + responseJson + "}", #True)
      EndIf
    EndProcedure

  CompilerEndIf

  ; A registered drop-target window that closes/recycles without running its
  ; React unmount cleanup (abrupt close, crash, HMR reload mid-teardown) would
  ; otherwise leave its TargetTypes() entry behind forever — harmless (a
  ; vanished window can never win HitTestWindowName's IsWindow() check, so a
  ; stale entry can't become an active target), but unbounded over an app
  ; session's lifetime of open/close cycles. Piggybacks on the same generic
  ; observer main.pb's own WindowClosing uses.
  Procedure WindowClosing(*Window.AppWindow, *JSWindow.JSWindow)
    If *JSWindow And FindMapElement(TargetTypes(), *JSWindow\Name)
      DeleteMapElement(TargetTypes())
    EndIf
  EndProcedure

  ; --- public ---------------------------------------------------------------

  Procedure Init()
    If Initialized : ProcedureReturn : EndIf
    Initialized = #True
    ResetState()
    ; Registered unconditionally (ahead of the VYNCE_DND/platform gate below):
    ; TargetTypes() can be populated on any platform/flag state (registerTarget
    ; natives aren't themselves gated on Enabled), so the cleanup should apply
    ; the same way regardless of whether the rest of the service is live.
    JSWindow::RegisterWindowClosingObserver(@WindowClosing())
    CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
      If GetEnvironmentVariable("VYNCE_DND") = "0"
        ProcedureReturn
      EndIf
      If GetEnvironmentVariable("VYNCE_DND_DEBUG") = "0"
        DebugEnabled = #False
      EndIf
      DebugPath = GetTemporaryDirectory() + "vynce_dnd_debug.log"
      DragBadge::Init()
      If DragBadge::GetWindow() = 0
        DLog("[Init] badge window creation failed — service disabled")
        ProcedureReturn
      EndIf
      ; Permanent low-cost heartbeat; idle ticks return immediately. Keeping it
      ; always-on means session start never has to touch Cocoa (no
      ; AddWindowTimer inside a webview callback).
      AddWindowTimer(DragBadge::GetWindow(), #DndTimer, #TickMs)
      BindEvent(#PB_Event_Timer, @OnTick(), DragBadge::GetWindow())
      JSBridge::RegisterSystemResponseHandlerFor("dnd:drop", @OnDropReply())
      Enabled = #True
      DLog("[Init] DnD service enabled (tick " + Str(#TickMs) + "ms)")
    CompilerEndIf
  EndProcedure

  Procedure.i IsEnabled()
    ProcedureReturn Enabled
  EndProcedure

  ; --- JS-bound natives -----------------------------------------------------
  ; Args arrive as one JSON array of strings; return an allocated UTF8 JSON
  ; buffer. Webview-callback context: state + bridge scripts only, no Cocoa.

  Procedure ExtractParams(JsonParameters.s, Array Parameters.s(1))
    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)
      ProcedureReturn #True
    EndIf
    ProcedureReturn #False
  EndProcedure

  Procedure JSDndStart(JsonParameters.s)
    If Not Enabled
      ProcedureReturn UTF8(~"{\"error\":\"dnd unavailable\"}")
    EndIf
    Dim Parameters.s(0)
    If Not ExtractParams(JsonParameters, Parameters()) Or ArraySize(Parameters()) < 1
      ProcedureReturn UTF8(~"{\"error\":\"bad args\"}")
    EndIf
    Protected win.s = Parameters(0)
    Protected spec.s = Parameters(1)
    If Len(spec) > #MaxPayloadBytes
      ProcedureReturn UTF8(~"{\"error\":\"payload too large\"}")
    EndIf
    Protected *src.JSWindow = JSWinByName(win)
    If *src = 0
      ProcedureReturn UTF8(~"{\"error\":\"unknown window\"}")
    EndIf
    If *src\Headless
      ; Web mode: badge/hit-testing make no sense for browser tabs.
      ProcedureReturn UTF8(~"{\"error\":\"dnd unavailable in web mode\"}")
    EndIf

    Protected type.s = "", payloadJson.s = "{}", icon.s = "terminal", label.s = ""
    Protected json = ParseJSON(#PB_Any, spec)
    If json = 0
      ProcedureReturn UTF8(~"{\"error\":\"bad spec\"}")
    EndIf
    Protected v = JSONValue(json)
    If JSONType(v) = #PB_JSON_Object
      If GetJSONMember(v, "type") : type = GetJSONString(GetJSONMember(v, "type")) : EndIf
      If GetJSONMember(v, "payloadJson") : payloadJson = GetJSONString(GetJSONMember(v, "payloadJson")) : EndIf
      Protected b = GetJSONMember(v, "badge")
      If b And JSONType(b) = #PB_JSON_Object
        If GetJSONMember(b, "icon") : icon = GetJSONString(GetJSONMember(b, "icon")) : EndIf
        If GetJSONMember(b, "label") : label = GetJSONString(GetJSONMember(b, "label")) : EndIf
      EndIf
    EndIf
    FreeJSON(json)
    If type = ""
      ProcedureReturn UTF8(~"{\"error\":\"missing type\"}")
    EndIf
    If Trim(payloadJson) = "" : payloadJson = "{}" : EndIf

    ; A second start while a session is live supersedes it (single cursor —
    ; defensive). Notify the old source; visuals correct themselves on the
    ; next tick from the fresh state.
    If S\State <> #S_Idle
      DLog("[start] superseding live session " + S\Id)
      If S\Over = #Over_Target And S\TargetWindow <> ""
        SendToWindow(S\TargetWindow, "dnd:leave", ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
      EndIf
      SendToWindow(S\Source, "dnd:cancelled", ~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
      ResetState()
    EndIf

    SessionCounter + 1
    S\State = #S_Active
    S\Id = win + "#" + Str(SessionCounter)
    S\Source = win
    S\Type = type
    S\PayloadJson = payloadJson
    S\BadgeIcon = icon
    S\BadgeLabel = label
    ; The drag starts inside the source window; the first tick reclassifies.
    S\Over = #Over_Source
    DLog("[start] " + S\Id + " type=" + type + " label=" + label)
    ProcedureReturn UTF8(~"{\"sessionId\":\"" + JsonStr(S\Id) + ~"\"}")
  EndProcedure

  Procedure JSDndDrop(JsonParameters.s)
    Dim Parameters.s(0)
    If Not ExtractParams(JsonParameters, Parameters()) Or ArraySize(Parameters()) < 1
      ProcedureReturn UTF8(~"{\"error\":\"bad args\"}")
    EndIf
    If S\State <> #S_Active Or Parameters(1) <> S\Id
      ProcedureReturn UTF8(~"{\"error\":\"no session\"}")
    EndIf
    S\DropRequested = #True
    DLog("[dropRequested] " + S\Id)
    ProcedureReturn UTF8(~"{\"pending\":true}")
  EndProcedure

  Procedure JSDndCancel(JsonParameters.s)
    Dim Parameters.s(0)
    If ExtractParams(JsonParameters, Parameters()) And ArraySize(Parameters()) >= 1
      If S\State <> #S_Idle And Parameters(1) = S\Id
        S\CancelRequested = #True
        DLog("[cancelRequested] " + S\Id)
      EndIf
    EndIf
    ProcedureReturn UTF8("{}")
  EndProcedure

  Procedure JSDndUpdateBadge(JsonParameters.s)
    Dim Parameters.s(0)
    If ExtractParams(JsonParameters, Parameters()) And ArraySize(Parameters()) >= 2
      If S\State <> #S_Idle And Parameters(1) = S\Id
        Protected json = ParseJSON(#PB_Any, Parameters(2))
        If json
          Protected v = JSONValue(json)
          If JSONType(v) = #PB_JSON_Object
            If GetJSONMember(v, "icon") : S\BadgeIcon = GetJSONString(GetJSONMember(v, "icon")) : EndIf
            If GetJSONMember(v, "label") : S\BadgeLabel = GetJSONString(GetJSONMember(v, "label")) : EndIf
            S\BadgeDirty = #True
          EndIf
          FreeJSON(json)
        EndIf
      EndIf
    EndIf
    ProcedureReturn UTF8("{}")
  EndProcedure

  Procedure JSDndSetZoneActive(JsonParameters.s)
    Dim Parameters.s(0)
    If ExtractParams(JsonParameters, Parameters()) And ArraySize(Parameters()) >= 2
      ; Only the window currently hovered as the target may claim the zone.
      If S\State = #S_Active And Parameters(1) = S\Id And Parameters(0) = S\TargetWindow
        If Parameters(2) = "1"
          S\ZoneActive = #True
        Else
          S\ZoneActive = #False
        EndIf
      EndIf
    EndIf
    ProcedureReturn UTF8("{}")
  EndProcedure

  Procedure JSDndRegisterTarget(JsonParameters.s)
    Dim Parameters.s(0)
    If ExtractParams(JsonParameters, Parameters()) And ArraySize(Parameters()) >= 1
      Protected win.s = Parameters(0)
      Protected types.s = "|"
      Protected json = ParseJSON(#PB_Any, Parameters(1))
      If json
        Dim typeArr.s(0)
        If JSONType(JSONValue(json)) = #PB_JSON_Array
          ExtractJSONArray(JSONValue(json), typeArr())
          Protected i.i
          For i = 0 To ArraySize(typeArr())
            If typeArr(i) <> ""
              types + typeArr(i) + "|"
            EndIf
          Next
        EndIf
        FreeJSON(json)
      EndIf
      If types <> "|"
        TargetTypes(win) = types
        DLog("[registerTarget] " + win + " " + types)
      EndIf
    EndIf
    ProcedureReturn UTF8("{}")
  EndProcedure

  Procedure JSDndUnregisterTarget(JsonParameters.s)
    Dim Parameters.s(0)
    If ExtractParams(JsonParameters, Parameters()) And ArraySize(Parameters()) >= 0
      If FindMapElement(TargetTypes(), Parameters(0))
        DeleteMapElement(TargetTypes())
        DLog("[unregisterTarget] " + Parameters(0))
      EndIf
    EndIf
    ProcedureReturn UTF8("{}")
  EndProcedure

  ; Bind the JS-facing natives on a window's sink. Called from
  ; JSWindow::BindWebviewEvents for every real and headless window.
  Procedure BindNatives(sink.i)
    Sink::Bind(sink, "pbjsNativeDndStart", @JSDndStart())
    Sink::Bind(sink, "pbjsNativeDndDrop", @JSDndDrop())
    Sink::Bind(sink, "pbjsNativeDndCancel", @JSDndCancel())
    Sink::Bind(sink, "pbjsNativeDndUpdateBadge", @JSDndUpdateBadge())
    Sink::Bind(sink, "pbjsNativeDndSetZoneActive", @JSDndSetZoneActive())
    Sink::Bind(sink, "pbjsNativeDndRegisterTarget", @JSDndRegisterTarget())
    Sink::Bind(sink, "pbjsNativeDndUnregisterTarget", @JSDndUnregisterTarget())
  EndProcedure

EndModule
