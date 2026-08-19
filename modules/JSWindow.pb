
; =============================================================================
;- JS WINDOW
; =============================================================================

DeclareModule JSWindow
  UseModule WindowManager

  ; Startup-trace hook: marks land on the host's startup timeline when the
  ; host defines it (vynce StartupTrace.pb); compiles to nothing when pbjs is
  ; built standalone.
  Macro PbjsStartupTraceMark(label)
    CompilerIf Defined(StartupTrace, #PB_Module)
      StartupTrace::Mark(label)
    CompilerEndIf
  EndMacro

  ; Callback prototype for resize/move events
  Prototype ResizeCallback(windowName.s, x.l, y.l, w.l, h.l)
  
  Enumeration #PB_Event_FirstCustomValue
    #Event_Loaded_Html
    #Event_Content_Ready
    #Event_Prepare_Complete
    #Event_Pool_Refill
    #Event_Deferred_Close
    #Event_Deferred_Release
    #Event_Prepare_Uncloak
    #Event_Show_WebView
    #Event_Force_Content_Visible
    #Event_Close_Watchdog
  EndEnumeration
  Enumeration #PB_Event_FirstCustomValue
    #JSWindow_Behaviour_HideWindow
    #JSWindow_Behaviour_CloseWindow
  EndEnumeration
  
  ; webWindow: #True = HEADLESS window (web mode) — real invisible PB window,
  ; NO WebViewGadget; the page runs in a browser tab bridged via Sink hooks.
  Declare CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, *Parent.AppWindow = 0, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0, debugUrl.s="", webWindow.b = #False)
  ; Set an opaque JS string to inject before this window's content/React loads.
  ; pbjs injects it verbatim and never interprets it — the app owns its meaning.
  Declare SetPreRenderJS(*Window.AppWindow, js.s)

  ; Move this window's content-ready handshake from "the DOM parsed" to "the
  ; page says so". By default pbjs reports ready at DOMContentLoaded and the
  ; window is revealed there — which for a framework app means revealing an
  ; empty document, with the UI arriving a few frames later. Opt in, and the
  ; page owns the moment instead: it calls `window.pbjsContentReady()` once it
  ; has painted, and only then is the window revealed.
  ;
  ; pbjs stays framework-agnostic — it just stops firing the signal itself,
  ; exposes the function, and stretches its reveal watchdog to match. Two
  ; fallbacks keep the contract unbreakable: the injected script reports anyway
  ; after #PBJS_DeferredReadyFallbackMs, and the window is revealed regardless
  ; after #PBJS_DeferredRevealWatchdogMs. Call before the window is opened.
  Declare SetDeferContentReady(*Window.AppWindow, defer.b = #True)
  Declare RegisterWindowClosingObserver(*callback)
  Declare PrepareJSWindow(*Window.AppWindow)
  Declare OpenJSWindow(*Window.AppWindow )    
  Declare HideJSWindow(*Window.AppWindow, FromManagedWindow)
  Declare CloseJSWindow(*Window.AppWindow)
  Declare ResizeJSWindow(*Window.AppWindow, x, y, w, h)
  Declare GetWebView(*Window.AppWindow)
  
  ; Multi-instance template metadata. A template is a recipe for
  ; building real JSWindow instances on demand (no PB window of its own).
  ; Pointer stability: entries are never deleted during an app run, so
  ; *JSWindow\OwningTemplate raw pointers stay valid.
  Structure JSWindowTemplate
    Name.s
    *HtmlStart
    *HtmlEnd
    X.l
    Y.l
    W.l
    H.l
    Title.s
    Flags.l
    *Parent.AppWindow
    *WindowReadyCallback
    *ResizeCallback.ResizeCallback
    DebugUrl.s
    PoolTargetSize.i
    NextSeq.i
    WebMode.b                   ; #True = instances are headless web windows
    List PoolHandles.i()        ; PB window handles of warm spares
  EndStructure

  Structure JSWindow
    Name.s
    *Parent.AppWindow

    Window.i
    WebViewGadget.i   ; 0 for headless windows
    ; Routing handle for the window's page: == WebViewGadget for real windows,
    ; negative Sink handle for headless ones. All script/bind traffic goes
    ; through Sink::Exec/Bind/IsValid with this value.
    Sink.i
    Headless.b        ; #True = web-mode window (no gadget, never shown)

    ;Stages
    OpenTime.i
    LoadedCode.b
    Ready.b
    Open.b
    Visible.b
    ; The page reports content-readiness itself (SetDeferContentReady). Changes
    ; both what the injected script does and how long the reveal watchdog waits.
    DeferContentReady.b

    BypassCloseCheck.b ; Flag to indicate if we can skip the JS check

    CloseBehaviour.i
    LastLocation.s

    Html.s

    StartupJS.s
    WindowJS.s
    ; Opaque app-supplied JS, injected verbatim before page content/React
    ; (release HTML-wrap; pushed in dev). pbjs never parses or inspects it —
    ; it has no knowledge of the script's contents. Set via SetPreRenderJS.
    PreRenderJS.s

    List PendingMessages.s()

    *HtmlStart
    *HtmlEnd
    *WindowReadyProc.ProtoWindowReady
    *ResizeProc.ResizeCallback  ; Optional callback for resize/move events

    ; Prepare window state
    PrepareOriginalX.i
    PrepareOriginalY.i
    ; #True while a pool-spare prepare is in flight (PrepareJSWindow set it,
    ; #Event_Prepare_Complete has not run yet). Latched off by the FIRST
    ; #Event_Prepare_Complete — ready-driven or timeout — so the loser's post
    ; and any stale timer landing on a recycled window number are no-ops.
    PrepareWaiting.b

    ; Multi-instance support (#Null / 0 / "" for non-template windows)
    *OwningTemplate.JSWindowTemplate
    IsPoolSpare.b
    InstanceKey.s              ; opaque caller string; "" for spares

    ; Recycle-to-pool flags (see CloseJSWindow / OpenInstance)
    NeedsReload.b     ; #True = recycled without reload; invisible to reloadOnReuse=True callers
    ReloadOnRecycle.b ; stored at claim time: #True = reload HTML when this instance is recycled

    ; Cascade position — set by OpenInstance when smartPosition is requested.
    ; Event_Prepare_Complete uses this instead of PrepareOriginalX/Y when set.
    HasCascadePosition.b
    CascadeX.i
    CascadeY.i

    ; Last payload handed to pbjsUpdateScale, so an identical one can be
    ; dropped instead of re-injected. See UpdateWebViewScale.
    LastScaleW.i
    LastScaleH.i
    LastScaleMax.b

  EndStructure
  
  Global NewMap JSWindows.JSWindow()
  Global NewMap WindowsByName.i()

  ; Generic window-close observers. Mirrors the *WindowReadyCallback hook in the
  ; opposite direction: callbacks are invoked as (*Window, *JSWindow) just before
  ; a window's webview is torn down. pbjs stays domain-agnostic — it has no idea
  ; what observers do; the application layer (main.pb) registers them (e.g. to
  ; deregister a closed webview from ptym). See Prototype ProtoWindowReady.
  Global NewList WindowClosingObservers.i()

  ; Multi-instance support — see Structure JSWindowTemplate above.
  Global NewMap JSTemplates.JSWindowTemplate()
  ; Per-(template, instanceKey) -> PB window handle.
  ; Key format: templateName + ":" + instanceKey
  Global NewMap TemplateInstances.i()
  ; Async pool refill — RefillPoolAsync enqueues, HandlePoolRefillEvent drains.
  Global NewList PoolRefillQueue.i()
  Global PoolRefillMutex = CreateMutex()

  Global AppClosing = #False

  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
    ; Handles whose CloseWindow() must be deferred to the next event-loop tick.
    ; Calling CloseWindow() from inside WaitWindowEvent's call stack crashes on macOS.
    Global NewList DeferredCloseHandles.i()
    ; WKWebViews retained before CloseWindow and released one tick later via
    ; #Event_Deferred_Release, keeping WKUserContentController alive so any
    ; pending XPC postMessage deliveries land on removed (silent) handlers.
    Global NewList WKWebViewsToRelease.i()
  CompilerEndIf
  Global ClosingScope = 0 ; 0: None, -1: App, >0: WindowID
  Global ReloadedJS = #False

  Declare RequestClose(Scope)
  Declare CheckCloseProgress()
  Declare CancelClose(Reason.s="")

  ; Multi-instance public API: a template is a window recipe, and OpenInstance
  ; materializes (or focuses) one named instance of it, claiming a pre-warmed
  ; spare from the pool when there is one. README §7.
  Declare.i RegisterTemplate(templateName.s, x, y, w, h, title.s, flags, *htmlStart, *htmlStop, *Parent.AppWindow = 0, *WindowReadyCallback = 0, *ResizeCallback.ResizeCallback = 0, debugUrl.s = "", poolTargetSize = 1, webMode.b = #False)

  ; Web mode: browser tab (re)attached / detached for a headless window —
  ; called by the app's proxy layer (WebProxy). Attach replays binds and the
  ; dev-reload bootstrap sequence; detach resets Ready so messages buffer.
  Declare HandleHeadlessAttach(windowName.s)
  Declare HandleHeadlessDetach(windowName.s)
  Declare.i FindTemplate(templateName.s)
  ; atScreenX/atScreenY: explicit position for the new instance in desktop
  ; coordinates (DnD drop-point placement). #JSWindow_NoPosition = unset.
  #JSWindow_NoPosition = -2147483647
  Declare.i OpenInstance(templateName.s, instanceKey.s, paramsJson.s, reloadOnReuse.b = #False, callerWindowName.s = "", atScreenX.i = #JSWindow_NoPosition, atScreenY.i = #JSWindow_NoPosition)
  Declare RefillPoolAsync(*Template.JSWindowTemplate)
  Declare HandlePoolRefillEvent(Event.i)
  Declare HandleDeferredCloseEvent(Event.i)
  Declare HandleDeferredReleaseEvent(Event.i)
  Declare FocusInstance(*Window.AppWindow)

  ; Register a hook called repeatedly *during* an OS modal resize/move loop
  ; (Windows). pbjs owns the window proc — the only callback Windows invokes
  ; while the modal loop blocks PB's event loop — so anything that must stay live
  ; mid-drag (e.g. draining a PTY output queue) plugs in here. Generic: pbjs has
  ; no knowledge of the hook's owner. Pass 0 to clear. No-op off Windows.
  Declare SetResizeDrainHook(*proc)

EndDeclareModule


Module JSWindow
  UseModule OsTheme
  ; Build-mode flags (#PBJS_DevMode, #PBJS_EnableDevTools) — pbjsConfig.pb.
  ; PB modules cannot see top-level constants, so this UseModule is what makes
  ; them visible here at all.
  UseModule PbjsConfig

  Declare UpdateWebViewScale(gadget, width, height, force.b = #False)
  Declare HandleEvent(*Window.AppWindow, Event.i, Gadget.i, Type.i)
  Declare ForceContentVisible(window)
  Declare JSIsWindowOpen(JsonParameters.s)
  Declare.i CreateAndPrepareSpare(*T.JSWindowTemplate)
  Declare JSOpenInstance(JsonParameters.s)
  
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare WindowCallback(hWnd, uMsg, WParam, LParam)

    #DWMWA_CLOAK = 13   ; not among PB's predefined Windows constants

    ; DWM-cloak a window: it stays fully composed (WebView2 keeps loading and
    ; rendering) but DWM presents zero pixels — no frame, no shadow, no
    ; animation — and the Win10/11 taskbar and Alt-Tab filter it out. Used only
    ; during pool-spare preparation (PrepareJSWindow -> Event_Prepare_Complete).
    ; Failure is harmless: the alpha-0 + off-screen guards remain in place as
    ; fallback, so we never branch on the result (0 is both S_OK and the
    ; dll-missing stub value).
    Procedure SetWindowCloak(WinID.i, enable.i)
      Protected cloak.l = Bool(enable)  ; BOOL = 4 bytes; DWM validates cbAttribute strictly
      Protected hr = OsTheme::DwmSetWindowAttributeDynamic(WinID, #DWMWA_CLOAK, @cloak, SizeOf(Long))
      Debug "[SetWindowCloak] hwnd=" + Str(WinID) + " enable=" + Str(enable) + " hr=" + Str(hr)
    EndProcedure
  CompilerEndIf

  ; Resize-drain hook (see SetResizeDrainHook). Called from WindowCallback while
  ; the OS modal resize/move loop is running so subscribers stay live mid-drag.
  Global ResizeDrainHook.i = 0
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    #JSWIN_RESIZE_DRAIN_TIMER    = 47011
    #JSWIN_RESIZE_DRAIN_INTERVAL = 16   ; ms — drains while the mouse is held still
  CompilerEndIf

  Procedure SetResizeDrainHook(*proc)
    ResizeDrainHook = *proc
  EndProcedure

  Prototype.i ProtoWindowReady(*Window, *JSWindow)

  ; A page put into deferred content-readiness (SetDeferContentReady) promises
  ; to call window.pbjsContentReady() once it has painted. If it never does —
  ; crash before first render, broken bundle — this timer reports ready anyway,
  ; so the host contract (Ready → FlushPendingMessages → Content_Ready →
  ; WindowReadyProc) can never be lost.
  ;
  ; Two layered watchdogs, different jobs: ForceContentVisible reveals the
  ; window so the user never faces a dead app, and this one still delivers the
  ; ready handshake afterwards, so the bridges attach either way.
  #PBJS_DeferredReadyFallbackMs = 1200

  ; Last-resort reveal when a page never reports content-ready at all
  ; (ForceContentVisible). 600 ms is right for the default handshake, which
  ; fires at DOMContentLoaded.
  #PBJS_RevealWatchdogMs = 600

  ; A deferred-ready window reports LATER BY DESIGN — it waits for its first
  ; painted frame — and the page-side fallback above already covers anything
  ; that parsed but never signalled. So this watchdog only has to catch a page
  ; that never ran JS at all, and it must sit clear of both: at 600 ms it would
  ; win the race on a cold start and reveal exactly the blank frame the whole
  ; deferral exists to avoid.
  #PBJS_DeferredRevealWatchdogMs = 2500

  ; Ceiling on how long a pool-spare prepare waits for the page's ready
  ; handshake before #Event_Prepare_Complete fires anyway (replaces the old
  ; prepare thread's 200 × 10 ms poll — see PrepareJSWindow).
  #PBJS_PrepareReadyTimeoutMs = 2000

  ; How long a close-veto check may go unanswered before the close is treated
  ; as DECLINED and the pending scope is cleared. See CheckCloseWatchdog.
  ;
  ; Deliberately generous: an onCloseWindow handler is allowed to be slow —
  ; async work, a "save your changes?" prompt awaiting the user. Firing early
  ; would close a window out from under a legitimate handler still deciding,
  ; which is a data-loss bug, whereas firing late costs a few seconds on a page
  ; that is already broken. 4 s sits clear of any handler doing real work.
  #PBJS_CloseCheckTimeoutMs = 4000

  ; "#rrggbb" for a PureBasic RGB() colour. The injected page style needs the
  ; host's theme background as CSS so the document canvas is already painted in
  ; the app's colour before the page's own stylesheet — let alone its framework —
  ; has produced anything. Without it the canvas is transparent and the webview
  ; composites its default white, which is the startup flash.
  Procedure.s ColorToCssHex(color.i)
    ProcedureReturn "#" + RSet(Hex(Red(color)), 2, "0") +
                          RSet(Hex(Green(color)), 2, "0") +
                          RSet(Hex(Blue(color)), 2, "0")
  EndProcedure

  ; ---------------------------------------------------------------------------
  ; Sleep-and-post timer threads.
  ;
  ; The ONLY work a JSWindow worker thread may do is sleep, then post an event
  ; (the ShowGadgetThread pattern). Everything else — JSWindows() lookups,
  ; state checks, UI calls — must happen on the main thread: either before the
  ; spawn (resolved into *Args by the caller) or in the handler of the posted
  ; event. PB maps are not thread-safe: all lookups share one current-element
  ; pointer, and reading a missing key even inserts an element — so a
  ; thread-side JSWindows() access racing a main-thread add/delete corrupts
  ; the map or dereferences a freed element.
  Structure DelayedEventArgs
    Window.i
    DelayMs.i
    EventType.i
  EndStructure

  Procedure DelayedEventThread(*Args.DelayedEventArgs)
    Protected window    = *Args\Window
    Protected delayMs   = *Args\DelayMs
    Protected eventType = *Args\EventType
    FreeStructure(*Args)
    If delayMs > 0
      Delay(delayMs)
    EndIf
    If IsWindow(window)
      PostEvent(#CustomWindowEvent, window, 0, eventType)
    EndIf
  EndProcedure

  ; Main-thread spawner for DelayedEventThread.
  Procedure PostEventAfterDelay(window, delayMs, eventType)
    Protected *Args.DelayedEventArgs = AllocateStructure(DelayedEventArgs)
    *Args\Window    = window
    *Args\DelayMs   = delayMs
    *Args\EventType = eventType
    If CreateThread(@DelayedEventThread(), *Args) = 0
      FreeStructure(*Args)
    EndIf
  EndProcedure

  ; Runs on the MAIN thread (called from JSReadyState): it reads JSWindows(),
  ; which no worker thread may touch. Only the sleep-and-post is threaded.
  Procedure MakeContentVisible(window)

    ; The delay below buys the page a beat to paint between "ready" and the
    ; reveal. A deferred-ready window has already had it — it reported only
    ; AFTER painting — so the wait would be pure latency on the one path that
    ; cares most about it.
    Protected delayMs = 0
    Protected deferred.b = #False
    If FindMapElement(JSWindows(), Str(window))
      deferred = JSWindows()\DeferContentReady
    EndIf

    If Not deferred
      CompilerIf #PB_Compiler_OS = #PB_OS_Linux
        delayMs = 100
      CompilerElseIf #PB_Compiler_OS = #PB_OS_MacOS
        delayMs = 16
      CompilerElse
        ; Windows: was 100ms. An early show is flash-safe — the window bg is
        ; pre-set to themeBackgroundColor and the body sits at opacity:0 until
        ; pbjs-document-ready.
        delayMs = 24
      CompilerEndIf
    EndIf

    PostEventAfterDelay(window, delayMs, #Event_Content_Ready)
  EndProcedure
  
  ; Append one line to logs/debug.log — DEV BUILDS ONLY.
  ;
  ; It opens and closes the file per line, and it is called from the ready path
  ; that every window and every pool spare runs through, so in a shipped build
  ; it was paying filesystem syscalls per window for output nobody reads. Worse,
  ; it wrote into GetCurrentDirectory() — wherever the app happened to be
  ; launched from, which for an installed app may be read-only or not the user's
  ; to write to.
  ;
  ; Compiled out entirely in release: the macro body is empty, so the calls and
  ; even their string concatenation disappear rather than becoming no-op calls.
  CompilerIf #PBJS_DevMode
    Procedure LogToDebugFileImpl(message.s)
      Protected logDir.s = GetCurrentDirectory() + "logs/"
      Protected filename.s = logDir + "debug.log"

      If FileSize(logDir) <> -2
        CreateDirectory(logDir)
      EndIf

      Protected file = OpenFile(#PB_Any, filename, #PB_File_Append)
      If Not file
        file = CreateFile(#PB_Any, filename)
      EndIf

      If file
        WriteStringN(file, "[PBJS] " + FormatDate("%hh:%ii:%ss", Date()) + " " + message)
        CloseFile(file)
      EndIf
    EndProcedure

    Macro LogToDebugFile(message)
      LogToDebugFileImpl(message)
    EndMacro
  CompilerElse
    ; No procedure at all, and the argument expression is never evaluated.
    Macro LogToDebugFile(message)
    EndMacro
  CompilerEndIf
  Procedure JSReadyState(JsonParameters.s)
    LogToDebugFile("JSReadyState Raw: " + JsonParameters)
    
    Protected window.i = 0
    Protected json = ParseJSON(#PB_Any, JsonParameters)
    
    If json
      Protected *root = JSONValue(json)
      If JSONType(*root) = #PB_JSON_Array And JSONArraySize(*root) > 0
        Protected *val = GetJSONElement(*root, 0)
        
        If JSONType(*val) = #PB_JSON_String
          window = Val(GetJSONString(*val))
        ElseIf JSONType(*val) = #PB_JSON_Number
          window = GetJSONInteger(*val)
        EndIf
      EndIf
      FreeJSON(json)
    EndIf
    
    LogToDebugFile("Parsed Window ID: " + Str(window))
    
    ; Resolve the subject ONCE, guarded: `window` is page-supplied JSON, and a
    ; bare JSWindows(Str(window)) dereference would auto-create a ghost map
    ; element for a 0 / unknown / already-closed id (PB map () access inserts
    ; missing keys — the same reason the flush below must not run unresolved).
    Protected *ReadyJS.JSWindow = 0
    If window <> 0 And IsWindow(window)
      If FindMapElement(JSWindows(), Str(window))
        *ReadyJS = @JSWindows()
      EndIf
    EndIf

    If *ReadyJS
      Protected reloaded.i = *ReadyJS\Ready
      Protected subjectName.s = *ReadyJS\Name

      If Not reloaded
        LogToDebugFile("JSReadyState: Initial Ready for window " + Str(window))
        PbjsStartupTraceMark("JS bridge ready (callbackReadyState): " + subjectName)
      Else
        LogToDebugFile("JSReadyState: Subsequent Ready (Reload) for window " + Str(window))
        ; Reject peers' in-flight requests to this window before its new page
        ; (which doesn't know the old requestIds) silently drops them. (§6.5)
        JSBridge::NotifyWindowEvent(subjectName, "reloaded")
      EndIf

      *ReadyJS\Ready = #True
      *ReadyJS\NeedsReload = #False  ; content freshly loaded (initial or after reload)
      MakeContentVisible(window)
      ReloadedJS = #True

      ; A pool spare mid-prepare completes the moment its page reports ready —
      ; the event-driven replacement for the old PrepareJSWindowThread poll
      ; (which read JSWindows() off the main thread). The timeout timer's
      ; later duplicate post is absorbed by the PrepareWaiting latch in the
      ; #Event_Prepare_Complete handler.
      If *ReadyJS\PrepareWaiting
        PostEvent(#CustomWindowEvent, window, 0, #Event_Prepare_Complete)
      EndIf

      ; Warm peers' readiness cache now that this window can answer.
      JSBridge::NotifyWindowEvent(subjectName, "ready")

      ; FLUSH PENDING MESSAGES
      JSBridge::FlushPendingMessages(*ReadyJS)
    Else
      LogToDebugFile("ERROR: JSReadyState for invalid/unknown window id " + Str(window))
    EndIf

    ProcedureReturn UTF8(~"{\"success\":true}")
  EndProcedure
  
  Procedure JSGetWindow(JsonParameters.s)
    Dim Parameters.s(0)
    
    Debug "JSGetWindow CALLED with: " + JsonParameters
    
    If ParseJSON(0, JsonParameters) = 0
      Debug "ParseJSON failed"
      ProcedureReturn UTF8(~"{\"error\": \"ParseJSON failed. Input: " + JsonParameters + ~"\"}")
    EndIf
    
    ExtractJSONArray(JSONValue(0), Parameters())
    windowName.s = Parameters(0)
    
    Debug "Looking for: " + windowName
    Debug "Total Windows in Map: " + Str(MapSize(JSWindows()))
    
    ForEach JSWindows()
      Debug " - Map Entry: " + JSWindows()\Name + " -> " + Str(JSWindows()\Window)
      If Trim(JSWindows()\Name)=Trim(windowName)
        Debug "MATCH FOUND!"
        ProcedureReturn UTF8(~"{\"id\":"+Str(JSWindows()\Window)+"}")
        Break 
      EndIf 
    Next 
    
    Debug "NO MATCH FOUND for " + windowName
    
    Protected DebugInfo.s = "MapSize: " + Str(MapSize(JSWindows())) + ". Available: "
    ForEach JSWindows()
      DebugInfo + "'" + JSWindows()\Name + "', "
    Next
    
    ProcedureReturn UTF8(~"{\"error\": \"Window not found. Input: " + windowName + ". " + DebugInfo + ~"\"}")
  EndProcedure
  
  Procedure JSOpenWindow(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i
    
    Debug "JSOpenWindow CALLED with: " + JsonParameters
    
    If ParseJSON(0, JsonParameters)
      ExtractJSONArray(JSONValue(0), Parameters())
      windowId.s = Parameters(0)
      
      ; Try to find by Name first
      ForEach JSWindows()
        If Trim(JSWindows()\Name) = Trim(windowId) And IsWindow(JSWindows()\Window)
          window = JSWindows()\Window
          found = #True
          Debug "JSOpenWindow found by Name: " + windowId + " -> " + Str(window)
          Break
        EndIf
      Next
      
      ; If not found by name, try ID
      If Not found
        window = Val(windowId)
        Debug "JSOpenWindow using ID: " + Str(window)
      EndIf
      
      If IsWindow(window)
        *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
        If *Window
          Debug "JSOpenWindow found managed window, attempting to open..."
          If ArraySize(Parameters()) > 0
            WindowParameters.s = Parameters(1)
            If WindowParameters <> ""
              ; Find JSWindow
              *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
              If *JSWindow 
                JSBridge::SendParameters(*JSWindow, WindowParameters)
              EndIf
            EndIf
          EndIf
          
          OpenJSWindow(*Window) ; Manual open logic is internal
          
          ProcedureReturn UTF8(~"{\"success\":true}")  
        Else
           Debug "JSOpenWindow ERROR: *Window is null for ID " + Str(window)
        EndIf
      Else
         Debug "JSOpenWindow ERROR: IsWindow(window) failed for ID " + Str(window)
      EndIf
    Else
       Debug "JSOpenWindow ERROR: ParseJSON failed for input: " + JsonParameters
    EndIf 
    
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  
  Procedure JSHideWindow(JsonParameters.s)
    
    Dim Parameters.s(0)
    Protected window.i, found.i
    
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    Param.s = Parameters(0)
    
    ; Try to find by Name first
    ForEach JSWindows()
      If Trim(JSWindows()\Name) = Trim(Param)
        window = JSWindows()\Window
        found = #True
        Break
      EndIf
    Next
    
    ; If not found by name, try ID
    If Not found
      window = Val(Param)
    EndIf
    If IsWindow(window) 
      *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
      If *Window
        HideJSWindow(*Window, #False ) 
        ProcedureReturn UTF8(~"{\"success\":true}")  
      EndIf 
    EndIf
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  Procedure JSCloseWindow(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i
    
    If ParseJSON(0, JsonParameters)
      ExtractJSONArray(JSONValue(0), Parameters())
      Param.s = Parameters(0)
      
      ; Try to find by Name first
      ForEach JSWindows()
        If Trim(JSWindows()\Name) = Trim(Param)
          window = JSWindows()\Window
          found = #True
          Break
        EndIf
      Next
      
      ; If not found by name, try ID
      If Not found
        window = Val(Param)
      EndIf
      If IsWindow(window) 
        *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
        If *Window
          CloseJSWindow(*Window) 
          ProcedureReturn UTF8(~"{\"success\":true}")  
        EndIf 
      EndIf 
    EndIf
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  Procedure JSIsWindowOpen(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i
    Protected ReturnString.s = ~"{\"isOpen\":false}"
    
    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      Param.s = Parameters(0)
      FreeJSON(json)
      
      ; Try to find by Name first
      ForEach JSWindows()
        If Trim(JSWindows()\Name) = Trim(Param)
          If IsWindow(JSWindows()\Window)
            window = JSWindows()\Window
            found = #True
            Break
          EndIf
        EndIf
      Next
      
      ; If not found by name, try ID
      If Not found
        window = Val(Param)
      EndIf
      
      If IsWindow(window)
        *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
        If *Window
          If *Window\Open
             ReturnString = ~"{\"isOpen\":true}"
          Else
             ReturnString = ~"{\"isOpen\":false}"
          EndIf
        EndIf
      EndIf
    EndIf
    
    ProcedureReturn UTF8(ReturnString)
  EndProcedure
  
  
  
  Procedure JSSetWindowTitle(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i

    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ReDim Parameters(1)
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)

      Protected targetName.s = Trim(Parameters(0))
      Protected newTitle.s    = Parameters(1)

      ForEach JSWindows()
        If Trim(JSWindows()\Name) = targetName
          window = JSWindows()\Window
          found = #True
          Break
        EndIf
      Next

      If Not found
        window = Val(targetName)
      EndIf

      If IsWindow(window)
        SetWindowTitle(window, newTitle)
        ; Headless: also forward to the browser tab (document.title).
        If FindMapElement(JSWindows(), Str(window))
          If JSWindows()\Headless
            Sink::WinCmd(JSWindows()\Sink, "title", newTitle)
          EndIf
        EndIf
        ProcedureReturn UTF8(~"{\"success\":true}")
      EndIf
    EndIf
    ProcedureReturn UTF8(~"{\"error\":\"Window not found\"}")
  EndProcedure

  ; Shared name->window resolution for the window-chrome calls below. Same
  ; lookup JSSetWindowTitle/JSFocusWindow do inline: runtime name first, then a
  ; raw PB window id as fallback.
  Procedure.i ResolveJSWindowByName(name.s)
    Protected trimmed.s = Trim(name)
    ForEach JSWindows()
      If Trim(JSWindows()\Name) = trimmed
        ProcedureReturn JSWindows()\Window
      EndIf
    Next
    ProcedureReturn Val(trimmed)
  EndProcedure

  ; JS → PB: drive the minimize/maximize/close buttons the page draws. PB's
  ; SetWindowState is cross-platform, so this one implementation serves macOS,
  ; Windows and Linux.
  ;
  ; "close" deliberately POSTS #PB_Event_CloseWindow rather than calling
  ; CloseJSWindow directly (which is what pbjsNativeCloseWindow does): posting
  ; raises exactly the event the OS close button used to raise, so the app-close
  ; confirmation protocol in docs/app-close.md, any registered veto handler and
  ; the per-window hide-vs-close behaviour all still apply. Calling
  ; CloseJSWindow here would tear the window down behind all of that.
  ;
  ; Parameters: [windowName, "minimize"|"maximize"|"restore"|"toggle"|"close"]
  Procedure JSSetWindowState(JsonParameters.s)
    Dim Parameters.s(0)

    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)

      If ArraySize(Parameters()) >= 1
        Protected window.i = ResolveJSWindowByName(Parameters(0))
        If IsWindow(window)
          Select LCase(Trim(Parameters(1)))
            Case "minimize"
              SetWindowState(window, #PB_Window_Minimize)
            Case "maximize"
              SetWindowState(window, #PB_Window_Maximize)
            Case "restore"
              SetWindowState(window, #PB_Window_Normal)
            Case "toggle"
              If GetWindowState(window) = #PB_Window_Maximize
                SetWindowState(window, #PB_Window_Normal)
              Else
                SetWindowState(window, #PB_Window_Maximize)
              EndIf
            Case "close"
              PostEvent(#PB_Event_CloseWindow, window, 0)
            Default
              ProcedureReturn UTF8(~"{\"error\":\"unknown state\"}")
          EndSelect
          ProcedureReturn UTF8(~"{\"success\":true}")
        EndIf
      EndIf
    EndIf
    ProcedureReturn UTF8(~"{\"error\":\"Window not found\"}")
  EndProcedure

  ; JS → PB: the REAL window size, which the page cannot get for itself.
  ; The WebViewGadget is created at MaxDesktopWidth x MaxDesktopHeight and merely
  ; clipped by the window, so window.innerWidth/innerHeight are the desktop size,
  ; not the window size (e.g. 1512x982 reported inside an 1291x850 window).
  ; Anything anchored right or bottom — the Windows/Linux button cluster — must
  ; be positioned from these numbers instead of CSS. Pulled by the page on mount;
  ; UpdateWebViewScale keeps it fresh on every resize.
  Procedure JSGetWindowMetrics(JsonParameters.s)
    Dim Parameters.s(0)

    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)

      Protected window.i = ResolveJSWindowByName(Parameters(0))
      If IsWindow(window)
        Protected maximized.s = "false"
        If GetWindowState(window) = #PB_Window_Maximize
          maximized = "true"
        EndIf
        ProcedureReturn UTF8(~"{\"width\":" + Str(WindowWidth(window)) +
                             ~",\"height\":" + Str(WindowHeight(window)) +
                             ~",\"maximized\":" + maximized + "}")
      EndIf
    EndIf
    ProcedureReturn UTF8(~"{\"error\":\"Window not found\"}")
  EndProcedure

  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    ; Hands a press to the window manager so it performs the move itself
    ; (works on both X11 and Wayland, unlike setting the window position).
    ImportC ""
      gtk_box_new(orientation.i, spacing.i)
      gtk_window_set_titlebar(*window, *widget)
      gtk_window_begin_move_drag(*window, button.i, root_x.i, root_y.i, timestamp.i)
      gtk_window_set_decorated(*window, setting.i)
      gtk_widget_get_style_context(*widget)
      gtk_css_provider_new()
      gtk_css_provider_load_from_data(*provider, *data, length.i, *error)
      gtk_style_context_add_provider(*context, *provider, priority.l)
      g_object_unref(*object)
    EndImport

    ; gtk_widget_set_opacity is declared HERE rather than called as PureBasic's
    ; built-in gtk_widget_set_opacity_(), because not every PureBasic build
    ; declares it. The ARM build (the only one for Raspberry Pi OS, and what
    ; runs on arm64 Debian) fails the whole compile with
    ;
    ;   Line 1807 - gtk_widget_set_opacity_() is not a function, array, list,
    ;   map or macro
    ;
    ; PureBasic's `name_()` syntax resolves against the compiler's own OS-API
    ; database, and that database is built per PureBasic release — a missing
    ; entry says nothing about the machine. gtk_widget_set_opacity() itself has
    ; existed since GTK 3.8 (2013) and is present on every host this can run
    ; on: webkit2gtk requires GTK3, so GTK3 is already a hard dependency of the
    ; webview. Importing the symbol directly sidesteps the compiler's database
    ; and lets the linker resolve it against the GTK that is already linked.
    ;
    ; The declared name deliberately has NO trailing underscore, so on builds
    ; where PureBasic DOES declare gtk_widget_set_opacity_() the two names
    ; cannot collide — both end up calling the same symbol.
    ;
    ; The `.d` matters and is not decoration: the C parameter is a double, and
    ; on AArch64 and x86-64 alike doubles pass in FLOATING-POINT registers.
    ; Declaring it integer-width would put the value in the wrong register and
    ; hand GTK garbage rather than an opacity. Verified against the C backend,
    ; which emits `f_gtk_widget_set_opacity(integer,double)` — a real double,
    ; so the platform C compiler assigns the register.
    ImportC ""
      gtk_widget_set_opacity(*widget, opacity.d)
    EndImport
  CompilerEndIf

  ; JS → PB: start a native window drag from the page's own title bar.
  ; With the content view spanning the full frame the OS no longer receives a
  ; caption mousedown, so DefaultWindowComponent forwards it here. Each platform
  ; hands the drag straight back to the window manager, so snapping, Spaces,
  ; multi-monitor and Aero Snap all keep working — this is deliberately NOT a
  ; hand-rolled move loop.
  ; Parameters: [windowName, screenX, screenY] (coords only used on Linux).
  Procedure JSStartWindowDrag(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i

    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)

      Protected targetName.s = Trim(Parameters(0))

      ForEach JSWindows()
        If Trim(JSWindows()\Name) = targetName
          window = JSWindows()\Window
          found = #True
          Break
        EndIf
      Next

      If Not found
        window = Val(targetName)
      EndIf

      If IsWindow(window)
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          ; currentEvent is still the mousedown AppKit is dispatching when the
          ; script message lands, which is exactly what this selector wants.
          Protected ev.i = CocoaMessage(0, CocoaMessage(0, 0, "NSApplication sharedApplication"), "currentEvent")
          If ev
            Debug "[JSWIN-DRAG] performWindowDragWithEvent: eventType=" + Str(CocoaMessage(0, ev, "type"))
            CocoaMessage(0, WindowID(window), "performWindowDragWithEvent:", ev)
            ProcedureReturn UTF8(~"{\"success\":true}")
          EndIf
          ProcedureReturn UTF8(~"{\"error\":\"no current event\"}")

        CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
          ; Hand the press to the window manager as if it had landed on the
          ; caption. ReleaseCapture first or the webview child HWND keeps the
          ; mouse and the drag never starts.
          ReleaseCapture_()
          SendMessage_(WindowID(window), #WM_NCLBUTTONDOWN, #HTCAPTION, 0)
          ProcedureReturn UTF8(~"{\"success\":true}")

        CompilerElse
          ; GTK needs the press position in ROOT coordinates; the page sends
          ; screenX/screenY. button 1, timestamp 0 = CurrentTime.
          If ArraySize(Parameters()) >= 2
            gtk_window_begin_move_drag(WindowID(window), 1,
                                       Val(Parameters(1)), Val(Parameters(2)), 0)
            ProcedureReturn UTF8(~"{\"success\":true}")
          EndIf
          ProcedureReturn UTF8(~"{\"error\":\"missing screen coords\"}")
        CompilerEndIf
      EndIf
    EndIf
    ProcedureReturn UTF8(~"{\"error\":\"Window not found\"}")
  EndProcedure

  ; Bring a window to the foreground by its runtime name. Reuses the same
  ; name->window resolution as JSSetWindowTitle and the cross-platform
  ; FocusInstance used by OpenInstance's re-focus path. Used by the JS
  ; cross-window singleton agent-tab logic (pbjs.focusWindow).
  Procedure JSFocusWindow(JsonParameters.s)
    Dim Parameters.s(0)
    Protected window.i, found.i

    Protected json = ParseJSON(#PB_Any, JsonParameters)
    If json
      ExtractJSONArray(JSONValue(json), Parameters())
      FreeJSON(json)

      Protected targetName.s = Trim(Parameters(0))

      ForEach JSWindows()
        If Trim(JSWindows()\Name) = targetName
          window = JSWindows()\Window
          found = #True
          Break
        EndIf
      Next

      If Not found
        window = Val(targetName)
      EndIf

      If IsWindow(window)
        Protected *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
        If *Window
          FocusInstance(*Window)
          ProcedureReturn UTF8(~"{\"success\":true}")
        EndIf
      EndIf
    EndIf
    ProcedureReturn UTF8(~"{\"error\":\"Window not found\"}")
  EndProcedure



  ; force: re-send even if the payload is unchanged. Only the monitor-topology
  ; response needs it — there the gadget's backing size changed while the
  ; window's dimensions did not, so the page must be told again.
  Procedure UpdateWebViewScale(*JSWindow.JSWindow, width, height, force.b = #False)

    ; Third argument is the maximized flag, so a page-drawn maximize/restore
    ; button can flip its icon without polling. Extra arg is ignored by any
    ; older consumer that only declared (w, h).
    Protected maximized.b = #False
    If GetWindowState(*JSWindow\Window) = #PB_Window_Maximize
      maximized = #True
    EndIf

    ; Drop a repeat of the payload we last sent. Two independent sources feed
    ; this per resize step on Windows — the WM_SIZE branch of WindowCallback and
    ; PureBasic's own #PB_Event_SizeWindow — so a drag could inject the same
    ; script twice per frame, and WM_SIZE also fires for moves and state changes
    ; that leave the size alone. Deduping here rather than at either call site
    ; covers both without depending on which of the two actually runs. (The mac
    ; frame observer already does this locally; this is the same idea at the
    ; shared choke point.)
    If Not force
      If width = *JSWindow\LastScaleW And height = *JSWindow\LastScaleH And maximized = *JSWindow\LastScaleMax
        ProcedureReturn
      EndIf
    EndIf

    Protected maximizedArg.s = "false"
    If maximized
      maximizedArg = "true"
    EndIf
    Protected script$ = "if(window.pbjsUpdateScale) window.pbjsUpdateScale(" + Str(width) + "," + Str(height) + "," + maximizedArg + ");"

    ; Headless: the browser tab owns its viewport — the invisible PB window's
    ; dimensions are meaningless there; the web adapter drives pbjsUpdateScale
    ; from browser resize events instead (plan C5).
    If *JSWindow\Headless
      ProcedureReturn
    EndIf

    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      If IsIconic_(WindowID(*JSWindow\Window))
        ProcedureReturn
      EndIf
    CompilerEndIf

    If Not IsGadget(*JSWindow\WebViewGadget) Or width = 0 Or height = 0
      ProcedureReturn
    EndIf

    ; Recorded only once the send actually happens — the early returns above
    ; (headless, minimised, zero-size) must not poison the cache, or the next
    ; genuine update with those same numbers would be dropped.
    *JSWindow\LastScaleW   = width
    *JSWindow\LastScaleH   = height
    *JSWindow\LastScaleMax = maximized

    WebViewExecuteScript(*JSWindow\WebViewGadget, script$)
  EndProcedure
  
  ; A managed window's AppWindow record is about to be freed. Drop every
  ; reference this module holds to it, or the next parent-walk dereferences
  ; freed memory.
  ;
  ; This matters now in a way it never did before: until the dispatch condition
  ; in HandleWindowEvent was fixed, the list never actually shrank, so these raw
  ; pointers stayed valid by accident. `\Parent` is walked by HideJSWindow,
  ; RequestClose, ResetCloseChecks and CheckCloseProgress — all of which follow
  ; the chain upward and read `*Current\Window`.
  Procedure HandleManagedWindowRemoving(*Window.AppWindow)
    If *Window = 0 : ProcedureReturn : EndIf

    ForEach JSWindows()
      If JSWindows()\Parent = *Window
        JSWindows()\Parent = 0
      EndIf
    Next

    ; Templates outlive every instance they build, so a template still pointing
    ; at a dead parent would hand it to every future spare.
    ForEach JSTemplates()
      If JSTemplates()\Parent = *Window
        JSTemplates()\Parent = 0
      EndIf
    Next
  EndProcedure

  ; ---------------------------------------------------------------------------
  ;- Monitor topology changed (the desktop bounding box grew)
  ; ---------------------------------------------------------------------------
  ; Every webview gadget is created ONCE at the startup desktop maximum
  ; (CreateJSWindow: WebViewGadget(..., MaxDesktopWidth, MaxDesktopHeight)) and
  ; is then only ever repositioned, never resized — the oversize-and-clip trick
  ; that keeps live resizing smooth. Attach a bigger display and that ceiling is
  ; suddenly too low: a window can now grow past its own webview, so a maximized
  ; window paints the page over part of its surface and leaves a bare stripe
  ; down the right and bottom edges.
  ;
  ; WindowManager already detected this and called into a per-window callback
  ; field that nothing ever assigned. This is the consumer that was missing.
  ; Registered from CreateJSWindow (WindowManager is included first, so it
  ; cannot reach into this module by itself).
  ;
  ; Only w/h are touched: x/y carry real state elsewhere (spares are parked far
  ; off-screen before content is ready, and #Event_Content_Ready brings them
  ; back to 0,0), so #PB_Ignore both.
  Procedure HandleMaxDesktopSizeChanged(width, height)
    Debug "[JSWindow] desktop grew to " + Str(width) + "x" + Str(height) + " — resizing webviews"
    If width <= 0 Or height <= 0
      ProcedureReturn
    EndIf

    ForEach JSWindows()
      If MapKey(JSWindows()) = "" : Continue : EndIf
      If JSWindows()\Headless : Continue : EndIf          ; browser tab owns its own viewport
      If Not IsGadget(JSWindows()\WebViewGadget) : Continue : EndIf

      ResizeGadget(JSWindows()\WebViewGadget, #PB_Ignore, #PB_Ignore, width, height)

      ; The page sizes itself off pbjsUpdateScale, not off the gadget, so the
      ; CSS variables have to be re-sent or the layout keeps the old ceiling.
      ; Forced: the window's own dimensions have NOT changed here — only the
      ; gadget behind it did — so the ordinary dedupe would drop this.
      If IsWindow(JSWindows()\Window)
        UpdateWebViewScale(@JSWindows(), WindowWidth(JSWindows()\Window), WindowHeight(JSWindows()\Window), #True)
      EndIf
    Next
  EndProcedure

  Procedure GetWebView(*Window.AppWindow)
    Protected windowKey.s = Str(*Window\Window)
    If FindMapElement(JSWindows(), windowKey)
      ProcedureReturn JSWindows(windowKey)\WebViewGadget
    EndIf
    ProcedureReturn 0
  EndProcedure
  
  ;#######MACOS RESIZE
  
  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
    
    Structure MacOSResizeState
      *Window.AppWindow
      LastWidth.i
      LastHeight.i
      Active.b
      NSWindow.i
      ObserverObject.i
      isFulscreen.i
    EndStructure
    
    Global NewMap MacOSResizeStates.MacOSResizeState()
    Global MacOSResizeMonitorMutex = CreateMutex()
    #NSKeyValueObservingOptionNew = 1 << 0
    
    ; Find NSWindow by matching pointer
    Procedure FindNSWindowForPBWindow(pbWindow.i)
      Protected sharedApp = CocoaMessage(0, 0, "NSApplication sharedApplication")
      Protected windowsArray = CocoaMessage(0, sharedApp, "windows")
      Protected count = CocoaMessage(0, windowsArray, "count")
      Protected i.i, nsWin.i
      
      For i = 0 To count - 1
        nsWin = CocoaMessage(0, windowsArray, "objectAtIndex:", i)
        If nsWin = pbWindow
          ProcedureReturn nsWin
        EndIf
      Next
      
      ProcedureReturn 0
    EndProcedure
    
    
    ; Re-show the webview a beat after a fullscreen transition. No UI work may
    ; happen on this thread: HideGadget off the main thread trips AppKit's
    ; "NSWindow drag regions should only be invalidated on the Main Thread"
    ; assert (SIGABRT on fullscreen exit), so this only sleeps and posts — the
    ; actual un-hide runs in HandleEvent's #Event_Show_WebView case.
    Procedure ShowGadgetThread(window)
      Delay(200)
      If IsWindow(window)
        PostEvent(#CustomWindowEvent, window, 0, #Event_Show_WebView)
      EndIf
    EndProcedure

    ; GadgetID() hands back a container NSView, not the WKWebView itself, and the
    ; nesting depth varies with the PureBasic / macOS version — so walk the
    ; subview tree. (CloseJSWindow does the same search inline; it is left alone
    ; deliberately, that path is crash-sensitive and must not gain a call.)
    Procedure.i FindWKWebView(gadget)
      If Not IsGadget(gadget)
        ProcedureReturn 0
      EndIf
      Protected root.i = GadgetID(gadget)
      Protected wkClass.i = objc_getClass_("WKWebView")
      If root = 0 Or wkClass = 0
        ProcedureReturn 0
      EndIf

      Protected queue.i = CocoaMessage(0, 0, "NSMutableArray array")
      CocoaMessage(0, queue, "addObject:", root)
      Protected depth.i
      Protected idx.i
      Protected count.i
      Protected view.i
      Protected nextLevel.i

      While CocoaMessage(0, queue, "count") > 0 And depth < 3
        nextLevel = CocoaMessage(0, 0, "NSMutableArray array")
        count = CocoaMessage(0, queue, "count")
        For idx = 0 To count - 1
          view = CocoaMessage(0, queue, "objectAtIndex:", idx)
          If CocoaMessage(0, view, "isKindOfClass:", wkClass)
            ProcedureReturn view
          EndIf
          CocoaMessage(0, nextLevel, "addObjectsFromArray:", CocoaMessage(0, view, "subviews"))
        Next
        queue = nextLevel
        depth + 1
      Wend

      ProcedureReturn 0
    EndProcedure

    ; Stop the WKWebView drawing its own opaque white backdrop. Until the web
    ; process commits a first frame there is nothing to composite, and that
    ; default backdrop IS the startup flash. With it off, the NSWindow's
    ; themeBackgroundColor shows through instead; the moment the page paints, the
    ; injected `html { background }` (PreparePbjsBasicScript) makes the surface
    ; opaque again, so the transparent phase costs nothing after startup.
    Procedure MacClearWebViewBackdrop(gadget)
      Protected wk.i = FindWKWebView(gadget)
      If wk
        CocoaMessage(0, wk, "setValue:", CocoaMessage(0, 0, "NSNumber numberWithBool:", #False),
                             "forKey:$", @"drawsBackground")
      EndIf
    EndProcedure

    ; ---------------------------------------------------------------------
    ; FIRST REVEAL (macOS)
    ; ---------------------------------------------------------------------
    ; Ordering the window in is what starts WebKit rendering. A WKWebView in a
    ; window that has never been on screen does no rendering work at all, so the
    ; first frame can only be produced from here on — measured, not assumed:
    ; requestAnimationFrame does not run in the page before this call, and it
    ; makes no difference whether the window is ordered back, moved off screen
    ; or held at a fraction of a percent alpha. AppKit treats all of those as
    ; occluded, and an occluded window is exactly what stops the engine.
    ;
    ; (This is why Windows needs its DWM-cloak dance in PrepareJSWindow and mac
    ; has no equivalent: there is no macOS state that is invisible to the user
    ; and visible to the compositor at the same time.)
    ;
    ; So the reveal cannot land on painted pixels, and — measured — it must not
    ; try to hide that behind an alpha fade either. Ordering the window in at
    ; alpha 0 and animating up to 1 keeps it occluded through the first part of
    ; the animation, so the rendering pass starts LATER than with a plain show:
    ; reveal → first painted frame averaged ~530 ms over a 120 ms fade against
    ; ~305 ms without one, and with far worse variance. The reveal is therefore
    ; immediate, and what covers the remaining gap is the themed canvas the page
    ; carries from its first parse (PreparePbjsBasicScript) — a window in the
    ; app's own colour, never a white one.
    Procedure MacRevealWindow(*JSWindow.JSWindow)
      ; On screen and in front: this is the app's first window, it belongs key.
      HideWindow(*JSWindow\Window, #False)
      Protected nsApp = CocoaMessage(0, 0, "NSApplication sharedApplication")
      CocoaMessage(0, nsApp, "activateIgnoringOtherApps:", #True)
      CocoaMessage(0, WindowID(*JSWindow\Window), "makeKeyAndOrderFront:", #Null)
    EndProcedure
    
    
    ; Callback - called from Objective-C observer
    ProcedureC MacOSFrameDidChange(*self, sel, notification)
      ; Get our context from the notification's object
      Protected nsWindow = CocoaMessage(0, notification, "object")
      ; Find our state by matching the window
      LockMutex(MacOSResizeMonitorMutex)
      ForEach MacOSResizeStates()
        If MacOSResizeStates()\NSWindow = nsWindow And MacOSResizeStates()\Active
          Protected *State.MacOSResizeState = @MacOSResizeStates()
          
          
          *JSWindow.JSWIndow = JSWindows(Str(MacOSResizeStates()\Window\Window))
          
          webViewGadget = *JSWindow\WebViewGadget
          
          
          
          ; Define the constant for the FullScreen bit in the styleMask
          ; Note: PureBasic uses different naming for these constants, but the value is the key.
          ; The value for NSWindowStyleMaskFullScreen is 1 << 14, or 16384 (0x4000)
          #NSWindowStyleMaskFullScreen = 16384 
          
          ; ... inside your ProcedureC MacOSFrameDidChange ...
          
          Protected styleMask.i = CocoaMessage(0, nsWindow, "styleMask") 
          
          ; Check if the FullScreen bit is set
          Protected isFullScreen.b = Bool((styleMask & #NSWindowStyleMaskFullScreen) <> 0)
          
          If isFullScreen
            
            MacOSResizeStates()\isFulscreen = #True
            HideGadget(webViewGadget,#True)
            CocoaMessage(0, WindowID(MacOSResizeStates()\Window\Window), "display")
            
            CreateThread(@ShowGadgetThread(), MacOSResizeStates()\Window\Window)
          ElseIf MacOSResizeStates()\isFulscreen 
            MacOSResizeStates()\isFulscreen = #False
            
            HideGadget(webViewGadget,#True)
            CocoaMessage(0, WindowID(MacOSResizeStates()\Window\Window), "display")
            
            CreateThread(@ShowGadgetThread(), MacOSResizeStates()\Window\Window)
          EndIf 
          
          Protected currentW.i = WindowWidth(*State\Window\Window)
          Protected currentH.i = WindowHeight(*State\Window\Window)
          
          
          If currentW <> *State\LastWidth Or currentH <> *State\LastHeight
            *State\LastWidth = currentW
            *State\LastHeight = currentH
            UpdateWebViewScale(*JSWindow, currentW, currentH)
          EndIf
          
          Break
        EndIf
      Next
      UnlockMutex(MacOSResizeMonitorMutex)
    EndProcedure
    
    Procedure MacOSRegisterResizeNotifications(*Window.AppWindow)
      LockMutex(MacOSResizeMonitorMutex)
      
      Protected key.s = Str(*Window\Window)
      
      If Not FindMapElement(MacOSResizeStates(), key)
        MacOSResizeStates(key)\Window = *Window
        MacOSResizeStates(key)\LastWidth = WindowWidth(*Window\Window)
        MacOSResizeStates(key)\LastHeight = WindowHeight(*Window\Window)
        MacOSResizeStates(key)\Active = #True
        
        Protected nsWindow.i = FindNSWindowForPBWindow(WindowID(*Window\Window))
        
        If nsWindow
          MacOSResizeStates(key)\NSWindow = nsWindow
          
          ; Create observer object
          Protected observerClass = objc_allocateClassPair_(objc_getClass_("NSObject"), "PBWindowResizeObserver", 0)
          If observerClass = 0
            observerClass = objc_getClass_("PBWindowResizeObserver")
          Else
            class_addMethod_(observerClass, sel_registerName_("windowDidResize:"), @MacOSFrameDidChange(), "v@:@")
            objc_registerClassPair_(observerClass)
          EndIf
          
          Protected observer = CocoaMessage(0, CocoaMessage(0, observerClass, "alloc"), "init")
          MacOSResizeStates(key)\ObserverObject = observer
          
          ; Register for notifications instead of KVO
          Protected notificationCenter = CocoaMessage(0, 0, "NSNotificationCenter defaultCenter")
          CocoaMessage(0, notificationCenter,
                       "addObserver:", observer,
                       "selector:", sel_registerName_("windowDidResize:"),
                       "name:$", @"NSWindowDidResizeNotification",
                       "object:", nsWindow)
        EndIf
      EndIf
      
      UnlockMutex(MacOSResizeMonitorMutex)
    EndProcedure
    
    Procedure MacOSUnregisterResizeNotifications(*Window.AppWindow)
      LockMutex(MacOSResizeMonitorMutex)
      
      Protected key.s = Str(*Window\Window)
      If FindMapElement(MacOSResizeStates(), key)
        MacOSResizeStates(key)\Active = #False
        
        If MacOSResizeStates(key)\ObserverObject
          
          Protected notificationCenter = CocoaMessage(0, 0, "NSNotificationCenter defaultCenter")
          CocoaMessage(0, notificationCenter, "removeObserver:", MacOSResizeStates(key)\ObserverObject)
          CocoaMessage(0, MacOSResizeStates(key)\ObserverObject, "release")
        EndIf
        
        DeleteMapElement(MacOSResizeStates(), key)
      EndIf
      
      UnlockMutex(MacOSResizeMonitorMutex)
    EndProcedure
    
  CompilerEndIf
  
  
  ; The content fade for a first show. The window is already on screen carrying
  ; its themed background, so this ramps the UI in over it rather than covering
  ; for anything. Short on purpose: long enough that the UI arrives instead of
  ; blinking into existence, short enough that it never reads as waiting.
  #PBJS_BodyFadeMs = 90

  Procedure SetBodyFadeIn(*JSWindow.JSWindow)
    If Sink::IsValid(*JSWindow\Sink)
      If *JSWindow\Visible
        fadeInTime = #PBJS_BodyFadeMs
      Else
        fadeInTime = 0
      EndIf

      ; A deferred-ready page deliberately left its body hidden when it reported
      ; ready. The class it is waiting for is added HERE, in the same turn that
      ; put the window on screen, so the fade plays where the user can see it.
      ; (The default handshake adds the class itself at DOMContentLoaded, long
      ; before this, and its fade is spent behind a window nobody sees.)
      ;
      ; No requestAnimationFrame around it: the transition cannot advance until
      ; the engine is rendering anyway, and waiting for a frame that only comes
      ; once rendering starts would just add a frame to the appearance.
      Protected revealBody.s = ""
      If *JSWindow\DeferContentReady
        revealBody = "document.body.classList.add('pbjs-document-ready');"
      EndIf

      bodyFadeInScript.s =  "(function(){const style=document.createElement('style');" +
                            "style.id='pbjs-dynamic-style-pbjs-document-ready';" +
                            "style.textContent='body.pbjs-document-ready{" +
                            "transition:opacity " + fadeInTime + "ms ease-out!important;" +
                            "}';" +
                            "document.head.appendChild(style);" +
                            revealBody +
                            "})()";
      Sink::Exec(*JSWindow\Sink, bodyFadeInScript)
    EndIf
  EndProcedure
  
  
  
  Procedure PreparePbjsBasicScript(*JSWindow.JSWindow)
    window.i = *JSWindow\Window
    webViewGadget.i = *JSWindow\WebViewGadget
    width = WindowWidth(window)
    height = WindowHeight(window)
    ; Same colour the host already gave the native window (SetWindowColor in
    ; CreateJSWindow), handed to the page so BOTH layers are themed from the
    ; first frame: the window while the webview has nothing, the canvas while
    ; the app has nothing.
    Protected themeBg.s = ColorToCssHex(themeBackgroundColor)
    Protected deferReady.s = "false"
    ; Who un-hides the body. Normally the page does it the moment the DOM is
    ; parsed; a deferred-ready window leaves it to the host, which adds the
    ; class one frame after the window is on screen (SetBodyFadeIn) so the fade
    ; is not spent behind a window nobody can see yet.
    Protected markBodyReadyJs.s = "setTimeout(()=>{document.body.classList.add('pbjs-document-ready');},0);"
    If *JSWindow\DeferContentReady
      deferReady = "true"
      markBodyReadyJs = ""
    EndIf
    Debug WindowWidth(window)
    If *JSWindow\Visible
      
      
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        fadeInTime = 310 
      CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
        fadeInTime = 510
      CompilerElse
        fadeInTime = 150 
        
      CompilerEndIf
    Else
      fadeInTime = 0
    EndIf 
    ; Two things below are worth knowing before reading the wall of string
    ; concatenation:
    ;
    ; • window.pbjsContentReady() is the single entry point for "this page has
    ;   content to show". By default it fires from DOMContentLoaded, exactly as
    ;   this script always did. A page that sets window.pbjsDeferContentReady
    ;   owns the call instead and makes it once it has actually painted; pbjs
    ;   neither knows nor cares which framework decides that — it only honours
    ;   the flag, and keeps a timer so the handshake cannot be lost.
    ;
    ; • The `else` branch of the readyState test runs when the script is
    ;   replayed into a live document (dev reload, web-mode re-attach). The page
    ;   is already up there, so deferral would only strand the handshake until
    ;   that fallback timer — it reports ready immediately instead.
    *JSWindow\StartupJS = ""+
                          "if(!window.__pbjsAdded){" +
                          "" + 
                          " window.pbjsUpdateScale =  function(width, height) {" +
                          "   document.documentElement.style.setProperty('--container-width', width + 'px');" +
                          "   document.documentElement.style.setProperty('--container-height', height + 'px')" +
                          " };"+
                          ""+    
                          " window.pbjs = (window.pbjs || {});" +
                          " window.pbjs.darkMode = " + Str(OsTheme::IsDarkModeActive()) + ";" +
                          " window.pbjsDeferContentReady = " + deferReady + ";" +
                          ""+
                          " window.pbjsDocumentReady = function () {" +
                          "  " + markBodyReadyJs +
                          "  const callReady = () => {" +
                          "    if(window.callbackReadyState) {" +
                          "      try { " +
                          "        window.callbackReadyState(" + Str(window) + "," + Str(webViewGadget) + ").catch(e => console.error('ReadyState Error:', e));" + 
                          "      } catch(e) { console.error('ReadyState Call Error:', e); }" +
                          "    } " +
                          "    else setTimeout(callReady, 50);" +
                          "  };" +
                          "  callReady();" +
                          " };"+
                          ""+
                          " window.__pbjsContentReadySent = false;" +
                          " window.pbjsContentReady = function () {" +
                          "  if (window.__pbjsContentReadySent) return;" +
                          "  window.__pbjsContentReadySent = true;" +
                          "  window.pbjsDocumentReady();" +
                          " };" +
                          ""+
                          "(function (){"+
                          ""+
                          " window.pbjsUpdateScale(" + Str(width) + "," + Str(height) + ");"+
                          ""+
                          " const style=document.createElement('style');" + 
                          " style.id='pbjs-dynamic-style';" + 
                          "" + 
                          " style.textContent='html, body {" + 
                          "   width: var(--container-width);" + 
                          "   height: var(--container-height);" + 
                          "   min-width: 0!important;" + 
                          "   min-height: 0!important;" + 
                          "   max-width: var(--container-width);" + 
                          "   max-height: var(--container-height);" + 
                          " }" +
                          "" +
                          " html {" +
                          "   background: " + themeBg + ";" +
                          " }" +
                          "" +
                          " body {" +
                          "   opacity: 0;" +
                          " }" +
                          "" + 
                          " body.pbjs-document-ready {" + 
                          "   opacity: 1;" + 
                          "   transition: opacity "+fadeInTime+"ms ease-out" + 
                          " }';" + 
                          "" + 
                          " document.head.appendChild(style);" + 
                          "" +
                          " if (document.readyState === 'loading') {" +
                          "   document.addEventListener('DOMContentLoaded', function() {" +
                          "     if (window.pbjsDeferContentReady) {" +
                          "       setTimeout(window.pbjsContentReady, " + Str(#PBJS_DeferredReadyFallbackMs) + ");" +
                          "     } else {" +
                          "       window.pbjsContentReady();" +
                          "     }" +
                          "   });" +
                          " } else {" +
                          "   window.pbjsContentReady();"+
                          " }" +
                          ""+
                          ""+
                          " window.__pbjsAdded=true;" + 
                          "})();"+
                          "}" 
  EndProcedure
  
  Procedure.s WithPbjsBasicScript(html.s,*JSWindow.JSWindow)
    Protected result.s, bodyPos.i, bodyEndPos.i
    
    result = html
    
    PreparePbjsBasicScript(*JSWindow)
    
    Debug "ÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖÖ"
    
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + "<script>" +*JSWindow\StartupJS + "</script>"+ Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = *JSWindow\StartupJS + result
    EndIf

    ProcedureReturn result
  EndProcedure

  ; Inject an opaque app-supplied script before page content. Same insertion
  ; mechanism as WithPbjsBasicScript (classic <script> right after <body> open),
  ; so it runs before React's deferred module bundle. pbjs treats js as opaque.
  Procedure.s WithPreRenderScript(html.s, js.s)
    If js = ""
      ProcedureReturn html
    EndIf
    Protected result.s = html
    Protected bodyPos.i, bodyEndPos.i
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + "<script>" + js + "</script>" + Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = "<script>" + js + "</script>" + result
    EndIf
    ProcedureReturn result
  EndProcedure

  ; Public: store opaque pre-render JS on a window. No interpretation.
  Procedure SetPreRenderJS(*Window.AppWindow, js.s)
    If *Window And IsWindow(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      If *JSWindow
        *JSWindow\PreRenderJS = js
      EndIf
    EndIf
  EndProcedure

  ; Public: hand the content-ready decision to the page (see the declaration).
  Procedure SetDeferContentReady(*Window.AppWindow, defer.b = #True)
    If *Window And IsWindow(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      If *JSWindow
        *JSWindow\DeferContentReady = defer
      EndIf
    EndIf
  EndProcedure



  ; Off-main UTF-8 decode of the embedded single-file HTML (megabytes — that
  ; is why it is threaded at all). The thread touches only *Args: the source
  ; range is resolved by the main-thread spawner below, and the decoded string
  ; rides back as the #Event_Loaded_Html payload, where the handler copies it
  ; into JSWindows() and frees *Args. The thread itself never reads the map.
  ; (If the window dies before the event is dispatched the args leak — a close
  ; within the few ms of decoding; accepted over sharing map state with a
  ; thread.)
  Structure LoadHtmlArgs
    Window.i
    *HtmlStart
    *HtmlEnd
    Html.s
  EndStructure

  Procedure LoadHtml(*Args.LoadHtmlArgs)
    *Args\Html = PeekS(*Args\HtmlStart, *Args\HtmlEnd - *Args\HtmlStart, #PB_UTF8|#PB_ByteLength)
    PostEvent(#CustomWindowEvent, *Args\Window, 0, #Event_Loaded_Html, *Args)
  EndProcedure

  ; Decoded embedded HTML, keyed by its source range. Every window built from
  ; the same template decodes byte-identical bytes, so a pool of N spares paid
  ; for N decodes of the same multi-megabyte string.
  ;
  ; MAIN THREAD ONLY — read by StartLoadHtml, written by the #Event_Loaded_Html
  ; handler, both of which run there. The worker thread still never touches a
  ; map, which is the invariant the whole threading scheme rests on (PB maps
  ; share one current-element pointer, and a bare read inserts).
  Global NewMap DecodedHtmlCache.s()

  Procedure.s HtmlCacheKey(*htmlStart, *htmlEnd)
    ProcedureReturn Str(*htmlStart) + ":" + Str(*htmlEnd)
  EndProcedure

  ; Main-thread spawner: resolves the html source range while JSWindows() is
  ; safe to read.
  Procedure StartLoadHtml(*JSWindow.JSWindow)
    Protected *Args.LoadHtmlArgs = AllocateStructure(LoadHtmlArgs)
    *Args\Window    = *JSWindow\Window
    *Args\HtmlStart = *JSWindow\HtmlStart
    *Args\HtmlEnd   = *JSWindow\HtmlEnd

    ; Cache hit: skip both the decode and the thread. The event still carries
    ; the payload, so the handler downstream is identical either way.
    Protected key.s = HtmlCacheKey(*Args\HtmlStart, *Args\HtmlEnd)
    If FindMapElement(DecodedHtmlCache(), key)
      *Args\Html = DecodedHtmlCache()
      PostEvent(#CustomWindowEvent, *Args\Window, 0, #Event_Loaded_Html, *Args)
      ProcedureReturn
    EndIf

    If CreateThread(@LoadHtml(), *Args) = 0
      FreeStructure(*Args)
    EndIf
  EndProcedure

  ; Takes a Sink handle (== the gadget for real windows, negative for headless)
  ; so the same nine bindings reach a browser tab via the proxy in web mode.
  Procedure BindWebviewEvents(sink)
    Sink::Bind(sink, "callbackReadyState", @JSReadyState())
    Sink::Bind(sink, "pbjsNativeGetWindow", @JSGetWindow())
    Sink::Bind(sink, "pbjsNativeOpenWindow", @JSOpenWindow())
    Sink::Bind(sink, "pbjsNativeOpenInstance", @JSOpenInstance())
    Sink::Bind(sink, "pbjsNativeHideWindow", @JSHideWindow())
    Sink::Bind(sink, "pbjsNativeCloseWindow", @JSCloseWindow())
    Sink::Bind(sink, "pbjsNativeIsWindowOpen", @JSIsWindowOpen())
    Sink::Bind(sink, "pbjsNativeSetWindowTitle", @JSSetWindowTitle())
    Sink::Bind(sink, "pbjsNativeFocusWindow", @JSFocusWindow())
    Sink::Bind(sink, "pbjsNativeStartWindowDrag", @JSStartWindowDrag())
    Sink::Bind(sink, "pbjsNativeSetWindowState", @JSSetWindowState())
    Sink::Bind(sink, "pbjsNativeGetWindowMetrics", @JSGetWindowMetrics())
    ; Cross-window drag & drop: the pbjsNativeDnd* binds live in DndService
    ; itself (PB's @ operator cannot take module-qualified procedure
    ; addresses, so the module binds its own procs; declares come from
    ; DndServiceDeclare.pb ahead of this file).
    DndService::BindNatives(sink)
  EndProcedure
  
  
  
  Procedure.i CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, *Parent.AppWindow = 0, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0, debugUrl.s="", webWindow.b = #False)

    ; WindowManager polls the desktop bounding box but cannot call into this
    ; module (it is included first), so the responses are registered from here.
    ; Idempotent — each handler is a single global, not a list.
    SetMaxSizeChangedHandler(@HandleMaxDesktopSizeChanged())
    SetManagedWindowRemovingHandler(@HandleManagedWindowRemoving())

    Protected parentWindowID = 0
    If *Parent And IsWindow(*Parent\Window)
      parentWindowID = WindowID(*Parent\Window)
    EndIf

    window = OpenWindow(#PB_Any,x,y,w,h,title.s,flags| #PB_Window_Invisible,parentWindowID)

    If window
      ; Headless (web-mode) window: real invisible PB window — all identity /
      ; geometry / close plumbing keeps working — but NO WebViewGadget; the
      ; page runs in a browser tab and traffic routes through the Sink hooks.
      Protected webViewGadget = 0
      Protected sink.i
      If webWindow
        sink = Sink::RegisterHeadless(windowName)
      Else
        ; Devtools are a build decision, not a default — this page holds the
        ; full native binding set. #PBJS_EnableDevTools (pbjsConfig.pb) follows
        ; dev mode unless the host opts a release build in deliberately.
        CompilerIf #PBJS_EnableDevTools
          webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight, #PB_WebView_Debug)
        CompilerElse
          webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight)
        CompilerEndIf
        sink = webViewGadget
      EndIf

      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        If Not webWindow
          CocoaMessage(0, GadgetID(webViewGadget), "setBorderType:", 0)
          ; Before the first web-process frame the webview has nothing to show —
          ; let the themed window colour show through instead of WebKit's white.
          MacClearWebViewBackdrop(webViewGadget)
        EndIf
        ; Disable window show/hide animation (NSWindowAnimationBehaviorNone = 2).
        ; Without this, every makeKeyAndOrderFront: call adds ~150-200ms of zoom animation.
        CocoaMessage(0, WindowID(window), "setAnimationBehavior:", 2)

        ; Full-size content view: grow the content view over the titlebar so the
        ; WebViewGadget's 0,0 origin lands at the window FRAME origin and the page
        ; owns the whole surface. The traffic lights stay as floating AppKit views
        ; on top; everything else in the strip belongs to the WKWebView (verified
        ; by hit-testing the NSThemeFrame — the strip resolves to a view whose
        ; ancestor is the WKWebView, so clicks reach the page). The page draws its
        ; own title bar via DefaultWindowComponent and forwards caption drags
        ; through JSStartWindowDrag below.
        If Not webWindow
          #NSWindowStyleMaskFullSizeContentView = 32768   ; 1 << 15
          Protected nsWin.i = WindowID(window)
          CocoaMessage(0, nsWin, "setStyleMask:",
                       CocoaMessage(0, nsWin, "styleMask") | #NSWindowStyleMaskFullSizeContentView)
          CocoaMessage(0, nsWin, "setTitlebarAppearsTransparent:", #True)
          CocoaMessage(0, nsWin, "setTitleVisibility:", 1)   ; NSWindowTitleHidden
        EndIf

        ; Re-apply the requested origin. OpenWindow alone gets it wrong twice on
        ; macOS, and both errors are invisible until a window is restored from
        ; saved geometry:
        ;
        ;   1. FullSizeContentView above absorbs the titlebar into the content
        ;      view, so AppKit shrinks the frame by its height while keeping the
        ;      bottom-left origin — the top edge drops 32px. Save that on close
        ;      and the window walks down the screen, 32px per launch. (Measured:
        ;      OpenWindow y=300 -> WindowY 300, then 332 right after the patch.)
        ;
        ;   2. AppKit's constrainFrameRect:toScreen: pulls a frame that lands on
        ;      a SECONDARY display back onto the main screen at creation time —
        ;      even for an invisible window — so a window saved on an external
        ;      monitor always reopens on the primary one. (Measured on a
        ;      3-display Mac: OpenWindow at 1662,52 -> WindowX/Y 542,52.)
        ;
        ; ResizeWindow has neither problem: it honours the exact coordinates,
        ; negative ones included, while the window is still invisible.
        ; Centered windows are left alone — they asked for a computed position,
        ; not the x/y passed in.
        If Not (flags & (#PB_Window_ScreenCentered | #PB_Window_WindowCentered))
          ResizeWindow(window, x, y, #PB_Ignore, #PB_Ignore)
        EndIf
      CompilerEndIf

      *Window.AppWindow = AddManagedWindow(title, window, @HandleEvent(), @HideJSWindow() , @CloseJSWindow())

      Protected hWnd = WindowID(window)

      SetWindowColor(window, themeBackgroundColor)

      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        SetWindowLongPtr_(WindowID(window), #GWL_STYLE, GetWindowLongPtr_(WindowID(window), #GWL_STYLE) | #WS_CLIPCHILDREN)

        ; Frameless: drop WS_CAPTION so the client area starts at the top of the
        ; frame and the page draws the title bar (the macOS counterpart is
        ; NSWindowStyleMaskFullSizeContentView above).
        ;
        ; WS_THICKFRAME is kept deliberately: Windows then still owns resizing,
        ; so the resize borders, Aero Snap and the snap-assist layouts keep
        ; working without a WM_NCHITTEST implementation — which could not work
        ; here anyway, because the WebView2 child HWND covers the client area and
        ; receives the mouse before the parent ever sees a hit-test.
        ; WS_SYSMENU/MINIMIZEBOX/MAXIMIZEBOX keep the taskbar entry, Win+Arrow
        ; snapping and the minimize/restore animations intact.
        If Not webWindow
          Protected winStyle.i = GetWindowLongPtr_(hWnd, #GWL_STYLE)
          SetWindowLongPtr_(hWnd, #GWL_STYLE,
                            (winStyle & ~#WS_CAPTION) | #WS_THICKFRAME |
                            #WS_SYSMENU | #WS_MINIMIZEBOX | #WS_MAXIMIZEBOX)
          SetWindowPos_(hWnd, 0, 0, 0, 0, 0,
                        #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOZORDER | #SWP_FRAMECHANGED)
        EndIf

        ApplyThemeToWinHandle(hWnd)
        SetWindowCallback(@WindowCallback(),window, #PB_Window_NoChildEvents)
      CompilerEndIf

      CompilerIf #PB_Compiler_OS = #PB_OS_Linux
        ; Frameless titlebar: replace server-side titlebar with an empty 0-height GtkBox.
        ; Removes the OS titlebar box so WebView content starts at (0,0), while
        ; preserving GTK window borders, resize grips, and hover cursor indicators (↔, ↕, ⤢).
        If Not webWindow
          Protected *emptyTitlebar = gtk_box_new(0, 0)
          gtk_window_set_titlebar(hWnd, *emptyTitlebar)
        EndIf

        ; Apply GTK CSS background color to window container to match themeBackgroundColor (dark/light)
        ; so no white gaps/flashes appear during live window resizing.
        Protected *winCssProvider = gtk_css_provider_new()
        If *winCssProvider
          Protected winBgHex.s = ColorToCssHex(themeBackgroundColor)
          Protected winCss.s = "window, widget, grid, box { background-color: " + winBgHex + "; }"
          Protected *utf8WinCss = UTF8(winCss)
          If *utf8WinCss
            gtk_css_provider_load_from_data(*winCssProvider, *utf8WinCss, -1, 0)
            Protected *winStyleContext = gtk_widget_get_style_context(hWnd)
            If *winStyleContext
              gtk_style_context_add_provider(*winStyleContext, *winCssProvider, 600)
            EndIf
            FreeMemory(*utf8WinCss)
          EndIf
          g_object_unref(*winCssProvider)
        EndIf
      CompilerEndIf

      CompilerIf Not #PBJS_DevMode
        If Not webWindow
          CompilerIf #PB_Compiler_OS = #PB_OS_Windows Or #PB_Compiler_OS = #PB_OS_Linux
            ResizeGadget(webViewGadget,-1000000000,1000000000,#PB_Ignore,#PB_Ignore)
          CompilerElse
            HideGadget(webViewGadget,#True)
          CompilerEndIf
        EndIf
      CompilerEndIf

      BindWebviewEvents(sink)

      *JSWindow.JSWindow = JSWindows(Str(window))

      *JSWindow\Window = window
      *JSWindow\Name = windowName
      *JSWindow\Visible = #False
      *JSWindow\Parent = *Parent
      *JSWindow\Ready = #False
      *JSWindow\HtmlStart = *htmlStart
      *JSWindow\HtmlEnd = *htmlStop
      *JSWindow\WindowReadyProc = *WindowReadyCallback
      *JSWindow\ResizeProc = *ResizeCallback
      *JSWindow\CloseBehaviour = CloseBehaviour
      *JSWindow\WebViewGadget = webViewGadget
      *JSWindow\Sink = sink
      *JSWindow\Headless = webWindow

      WindowsByName(windowName) = window
      JSBridge::InitializeBridge(windowName, window, sink)

      ; Register for live resize notifications on macOS (pointless for a
      ; never-shown headless window — plan C12)
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        If Not webWindow
          MacOSRegisterResizeNotifications(*Window)
        EndIf
      CompilerEndIf

      ; Headless: the page is served by Vite/the browser, never from the
      ; embedded HTML — skip the loader thread entirely (plan C7).
      If Not webWindow
        StartLoadHtml(*JSWindow)
      EndIf
      PbjsStartupTraceMark("webview window created: " + windowName)

      CompilerIf  #PBJS_DevMode; remote debugging
        PreparePbjsBasicScript(*JSWindow.JSWindow)


        If debugUrl <> "" And Not webWindow
          SetGadgetText(webViewGadget, debugUrl)
        EndIf
      CompilerEndIf

      ProcedureReturn *Window
    EndIf
    ProcedureReturn -1
  EndProcedure
  
  
  
  
  
  
  
  Procedure OpenJSWindow(*Window.AppWindow )
    Protected manualOpen
    Protected startTime = ElapsedMilliseconds()
    Debug "[OpenJSWindow] START at " + Str(startTime)
    If IsWindow(*Window\Window)
      *JSWindow.JSWindow = JSWindows(Str(*Window\Window))

      ; Headless: mark open ("virtually visible" — the browser tab is the
      ; view) but never show the PB window. OpenManagedWindow(manualOpen=#True)
      ; sets AppWindow\Open without any show call, which keeps the event loop
      ; alive (WindowManager.pb:154). No ForceContentVisible either — content
      ; readiness comes from the attach-driven callbackReadyState handshake.
      If *JSWindow\Headless
        *JSWindow\Open = #True
        *JSWindow\Visible = #True
        *JSWindow\OpenTime = ElapsedMilliseconds()
        OpenManagedWindow(*Window, #True)
        Debug "[OpenJSWindow] headless open: " + *JSWindow\Name
        ProcedureReturn
      EndIf

      Debug "[OpenJSWindow] *JSWindow\Visible = " + Str(*JSWindow\Visible) + ", *JSWindow\Ready = " + Str(*JSWindow\Ready)
      If *JSWindow\Visible
        manualOpen = #False
        Debug "[OpenJSWindow] Taking FAST path (manualOpen = #False)"
      Else
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          ; For cold/mid-prepare windows on Mac: do NOT call HideWindow or makeKeyAndOrderFront
          ; yet. The window is off-screen at alpha=0 (PrepareJSWindow state). Calling
          ; makeKeyAndOrderFront on an unready WKWebView triggers expensive compositor/display-
          ; server work that blocks for seconds. Let Event_Prepare_Complete handle the first
          ; show once content is ready and the window is in its correct state.
          manualOpen = #True
          Debug "[OpenJSWindow] Taking SLOW path (manualOpen = #True, Mac unready)"
        CompilerElse
          manualOpen = #False
          Debug "[OpenJSWindow] Taking path (manualOpen = #False, non-Mac)"
        CompilerEndIf
      EndIf
      *JSWindow\Open = #True
      *JSWindow\Visible = Bool(Not manualOpen)
      *JSWindow\OpenTime = ElapsedMilliseconds()
      Debug "[OpenJSWindow] Calling OpenManagedWindow at " + Str(ElapsedMilliseconds() - startTime) + "ms"
      OpenManagedWindow(*Window,manualOpen)
      Debug "[OpenJSWindow] OpenManagedWindow returned at " + Str(ElapsedMilliseconds() - startTime) + "ms"
      If Not *JSWindow\Visible
        Debug "[OpenJSWindow] Starting ForceContentVisible watchdog (this adds 600ms delay!)"
        ForceContentVisible(*Window\Window)
      Else
        Debug "[OpenJSWindow] Skipping ForceContentVisible (already visible)"
        ; Mac: HideWindow() shows the window but does not activate it or raise it
        ; above other windows. Call makeKeyAndOrderFront: explicitly so the first
        ; click brings the window to front without needing a second click.
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          Protected openNsApp = CocoaMessage(0, 0, "NSApplication sharedApplication")
          CocoaMessage(0, openNsApp, "activateIgnoringOtherApps:", #True)
          CocoaMessage(0, WindowID(*Window\Window), "makeKeyAndOrderFront:", #Null)
        CompilerEndIf
      EndIf
    EndIf 
    Debug "[OpenJSWindow] END at " + Str(ElapsedMilliseconds() - startTime) + "ms"
  EndProcedure
  
  Procedure PrepareJSWindow(*Window.AppWindow)
    Debug "[PrepareJSWindow] START (non-blocking)"
    If IsWindow(*Window\Window)
      Protected WinID = WindowID(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      Protected windowHandle = *Window\Window

      ; Headless spares need no pre-warm theatrics (cloak/alpha/off-screen are
      ; meaningless for a never-shown window — plan C15). Mark claimable.
      If *JSWindow\Headless
        *JSWindow\Visible = #True
        ProcedureReturn
      EndIf
      
      ; Save original position
      Protected originalX = WindowX(*Window\Window)
      Protected originalY = WindowY(*Window\Window)
      *JSWindow\PrepareOriginalX = originalX
      *JSWindow\PrepareOriginalY = originalY
      
      Protected minValue = -10000 ; Off-screen position
      
      Debug "[PrepareJSWindow] Initial state: Visible=" + Str(*JSWindow\Visible) + ", Ready=" + Str(*JSWindow\Ready)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        ; FIRST: Set alpha to 0 before ANY showing to prevent flash
        Debug "[PrepareJSWindow] Mac: Setting alpha to 0, moving off-screen, orderBack"
        Protected alpha.d = 0.0
        CocoaMessage(0, WinID, "setAlphaValue:@", @alpha)
        
        ; Move window off-screen as extra safety
        ResizeWindow(*Window\Window, minValue, minValue, #PB_Ignore, #PB_Ignore)
        
        ; Now show window behind others (it's invisible because alpha=0)
        CocoaMessage(0, WinID, "orderBack:", #Null)
        
      CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
        Debug "[PrepareJSWindow] Win: cloak + toolwindow + alpha 0, off-screen, show no-activate"
        ; FIRST: DWM-cloak before the window is ever shown — zero pixels
        ; presented (frame/shadow included), taskbar/Alt-Tab filtered, while
        ; WebView2 keeps initializing. The layered alpha-0 + off-screen moves
        ; below stay as fallback for systems where the cloak call fails.
        SetWindowCloak(WinID, #True)
        ; WS_EX_TOOLWINDOW: belt & braces vs taskbar/Alt-Tab where cloak
        ; filtering misbehaves. Removed again at Event_Prepare_Complete.
        Protected currentStyle = GetWindowLongPtr_(WinID, #GWL_EXSTYLE)
        SetWindowLongPtr_(WinID, #GWL_EXSTYLE, currentStyle | #WS_EX_LAYERED | #WS_EX_TOOLWINDOW)
        SetLayeredWindowAttributes_(WinID, 0, 0, #LWA_ALPHA)  ; Alpha 0 = invisible

        ; Move off-screen
        ResizeWindow(*Window\Window, minValue, minValue, #PB_Ignore, #PB_Ignore)

        ; Now show window WITHOUT activating it, so the main window (or, on
        ; pool refill, the just-claimed instance) keeps focus and an active
        ; caption.
        HideWindow(*Window\Window, #False, #PB_Window_NoActivate)
        
      CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
        ; FIRST: Set opacity to 0 before ANY showing to prevent flash
        Debug "[PrepareJSWindow] Linux: Setting opacity to 0, moving off-screen, showing"
        Protected *GtkWidget = WinID
        If *GtkWidget
          ; Imported near gtk_window_begin_move_drag above, NOT the built-in
          ; gtk_widget_set_opacity_() — see that comment. Pairs with the
          ; restore to 1.0 in the reveal path; changing one without the other
          ; leaves every pre-warmed window invisible for good.
          gtk_widget_set_opacity(*GtkWidget, 0.0)
        EndIf
        
        ; Move off-screen
        ResizeWindow(*Window\Window, minValue, minValue, #PB_Ignore, #PB_Ignore)
        
        ; Now show window (it's invisible because opacity=0)
        HideWindow(*Window\Window, #False)
      CompilerEndIf
      
      ; Prepare completion is event-driven on the main thread — the old
      ; PrepareJSWindowThread polled *JSWindow\Ready through a JSWindows()
      ; lookup from a worker thread. Now JSReadyState posts
      ; #Event_Prepare_Complete the moment this page reports ready, and a
      ; pure sleep-and-post timer posts the same event as a timeout failsafe;
      ; the PrepareWaiting latch in the handler makes whichever fires second
      ; a no-op.
      *JSWindow\PrepareWaiting = #True
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        ; Uncloak ~3 frames after the cloaked no-activate show: by then the
        ; DWM present race at ShowWindow has settled, but Chromium's occlusion
        ; tracker treats cloaked windows as occluded — staying cloaked for the
        ; whole prepare would pause WebView2 rendering and defer the first
        ; contentful paint to reveal time, defeating the pre-warm. After the
        ; uncloak the window is still invisible (alpha 0, off-screen,
        ; WS_EX_TOOLWINDOW) yet renders warm pixels. Event_Prepare_Complete's
        ; own uncloak then becomes a harmless no-op.
        PostEventAfterDelay(windowHandle, 48, #Event_Prepare_Uncloak)
        PostEventAfterDelay(windowHandle, 48 + #PBJS_PrepareReadyTimeoutMs, #Event_Prepare_Complete)
      CompilerElse
        PostEventAfterDelay(windowHandle, #PBJS_PrepareReadyTimeoutMs, #Event_Prepare_Complete)
      CompilerEndIf

      Debug "[PrepareJSWindow] Prepare timers started, returning immediately"
    EndIf
  EndProcedure


  ; ============================================================================
  ;- TEMPLATES & INSTANCES (multi-instance window support)
  ; ============================================================================
  ;
  ; A template is a metadata record (no PB window of its own) describing how
  ; to build instances. Real instances are JSWindow records with unique
  ; runtime names like "<templateName>-<seq>". OpenInstance dedupes by an
  ; opaque caller-supplied instanceKey; calling it twice for the same key
  ; just focuses the existing window. A pool of pre-warmed spares keeps
  ; first-click latency low.
  ;
  ; JSWindow stays domain-agnostic: templateName / instanceKey / paramsJson
  ; are all opaque strings as far as this module is concerned.

  Procedure FocusInstance(*Window.AppWindow)
    If Not (*Window And IsWindow(*Window\Window))
      ProcedureReturn
    EndIf
    ; Headless: "focus" means the browser tab, not the invisible PB window.
    Protected *FocusJS.JSWindow = JSWindows(Str(*Window\Window))
    If *FocusJS And *FocusJS\Headless
      Sink::WinCmd(*FocusJS\Sink, "focus", "")
      ProcedureReturn
    EndIf
    HideWindow(*Window\Window, #False)
    CompilerSelect #PB_Compiler_OS
      CompilerCase #PB_OS_MacOS
        Protected nsApp = CocoaMessage(0, 0, "NSApplication sharedApplication")
        CocoaMessage(0, nsApp, "activateIgnoringOtherApps:", #True)
        CocoaMessage(0, WindowID(*Window\Window), "makeKeyAndOrderFront:", #Null)
      CompilerCase #PB_OS_Windows
        Protected hwnd = WindowID(*Window\Window)
        If IsIconic_(hwnd)
          ShowWindow_(hwnd, #SW_RESTORE)
        EndIf
        ShowWindow_(hwnd, 9)        ; SW_SHOWNORMAL
        SetForegroundWindow_(hwnd)
      CompilerDefault
        SetActiveWindow(*Window\Window)
    CompilerEndSelect
  EndProcedure


  Procedure.i FindTemplate(templateName.s)
    If FindMapElement(JSTemplates(), templateName)
      ProcedureReturn @JSTemplates()
    EndIf
    ProcedureReturn 0
  EndProcedure


  Procedure.i RegisterTemplate(templateName.s, x, y, w, h, title.s, flags, *htmlStart, *htmlStop, *Parent.AppWindow = 0, *WindowReadyCallback = 0, *ResizeCallback.ResizeCallback = 0, debugUrl.s = "", poolTargetSize = 1, webMode.b = #False)
    AddMapElement(JSTemplates(), templateName)
    Protected *T.JSWindowTemplate = @JSTemplates()
    *T\Name = templateName
    *T\HtmlStart = *htmlStart
    *T\HtmlEnd = *htmlStop
    *T\X = x
    *T\Y = y
    *T\W = w
    *T\H = h
    *T\Title = title
    *T\Flags = flags
    *T\Parent = *Parent
    *T\WindowReadyCallback = *WindowReadyCallback
    *T\ResizeCallback = *ResizeCallback
    *T\DebugUrl = debugUrl
    *T\PoolTargetSize = poolTargetSize
    *T\NextSeq = 1
    *T\WebMode = webMode
    Debug "[RegisterTemplate] Registered '" + templateName + "' poolTargetSize=" + Str(poolTargetSize) + " webMode=" + Str(webMode)
    ProcedureReturn *T
  EndProcedure


  Procedure.i CreateAndPrepareSpare(*T.JSWindowTemplate)
    If Not *T : ProcedureReturn 0 : EndIf

    Protected instanceName.s = *T\Name + "-" + Str(*T\NextSeq)
    *T\NextSeq + 1

    Debug "[CreateAndPrepareSpare] Creating '" + instanceName + "'"

    Protected *Window.AppWindow = CreateJSWindow(instanceName, *T\X, *T\Y, *T\W, *T\H, *T\Title, *T\Flags, *T\HtmlStart, *T\HtmlEnd, *T\Parent, #JSWindow_Behaviour_CloseWindow, *T\WindowReadyCallback, *T\ResizeCallback, *T\DebugUrl, *T\WebMode)

    If *Window = 0 Or *Window = -1
      Debug "[CreateAndPrepareSpare] CreateJSWindow failed for '" + instanceName + "'"
      ProcedureReturn 0
    EndIf

    Protected *JS.JSWindow = JSWindows(Str(*Window\Window))
    If *JS
      *JS\OwningTemplate  = *T
      *JS\IsPoolSpare     = #True
      *JS\InstanceKey     = ""
      *JS\NeedsReload     = #False  ; freshly prepared content
      *JS\ReloadOnRecycle = #True   ; conservative default until a caller sets it
    EndIf

    AddElement(*T\PoolHandles())
    *T\PoolHandles() = *Window\Window

    PrepareJSWindow(*Window)
    ProcedureReturn *Window\Window
  EndProcedure


  Procedure RefillPoolAsync(*Template.JSWindowTemplate)
    If Not *Template : ProcedureReturn : EndIf
    Protected need = *Template\PoolTargetSize - ListSize(*Template\PoolHandles())
    If need <= 0 : ProcedureReturn : EndIf

    LockMutex(PoolRefillMutex)
    While need > 0
      AddElement(PoolRefillQueue())
      PoolRefillQueue() = *Template
      need - 1
    Wend
    UnlockMutex(PoolRefillMutex)

    ; Wake the main loop. 4-arg PostEvent — matches the existing
    ; #Event_Loaded_Html / #Event_Content_Ready / #Event_Prepare_Complete shape.
    PostEvent(#CustomWindowEvent, 0, 0, #Event_Pool_Refill)
  EndProcedure


  Procedure HandlePoolRefillEvent(Event.i)
    ; Dispatched once per main-loop tick from main.pb's HandleMainEvent,
    ; mirroring how Ptym::PtymHandleEvent(Event) is wired up.
    If Event <> #CustomWindowEvent : ProcedureReturn : EndIf
    If EventType() <> #Event_Pool_Refill : ProcedureReturn : EndIf
    If AppClosing : ProcedureReturn : EndIf

    LockMutex(PoolRefillMutex)
    Protected *T.JSWindowTemplate = 0
    If ListSize(PoolRefillQueue()) > 0
      FirstElement(PoolRefillQueue())
      *T = PoolRefillQueue()
      DeleteElement(PoolRefillQueue())
    EndIf
    Protected remaining = ListSize(PoolRefillQueue())
    UnlockMutex(PoolRefillMutex)

    If *T And ListSize(*T\PoolHandles()) < *T\PoolTargetSize
      CreateAndPrepareSpare(*T)
    EndIf

    ; Keep draining. RefillPoolAsync enqueues one entry per missing spare but
    ; posts a SINGLE event, and this handler consumes exactly one entry — so
    ; with poolTargetSize > 1 the rest sat in the queue until some unrelated
    ; future refill happened to post again. The knob was advertised and did
    ; nothing past 1.
    ;
    ; Re-posting instead of looping here is deliberate: one spare per loop tick
    ; preserves the creation stagger, which is what keeps warming the pool from
    ; blocking the UI thread in a burst. The queue strictly shrinks (the entry
    ; is always removed above), so this terminates.
    If remaining > 0
      PostEvent(#CustomWindowEvent, 0, 0, #Event_Pool_Refill)
    EndIf
  EndProcedure


  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
  Procedure HandleDeferredCloseEvent(Event.i)
    ; Legacy drain path. Window close now goes through ScheduleGCDClose (GCD main
    ; queue), so this list is normally empty; kept as a safety drain in case any
    ; handle is ever enqueued here.
    If Event <> #CustomWindowEvent : ProcedureReturn : EndIf
    If EventType() <> #Event_Deferred_Close : ProcedureReturn : EndIf
    While ListSize(DeferredCloseHandles()) > 0
      FirstElement(DeferredCloseHandles())
      Protected handle.i = DeferredCloseHandles()
      DeleteElement(DeferredCloseHandles())
      If IsWindow(handle)
        CloseWindow(handle)
      EndIf
    Wend
  EndProcedure

  Procedure HandleDeferredReleaseEvent(Event.i)
    ; Retired: the retain/release scheme it served was replaced by GCD-ordered
    ; close (ScheduleGCDClose). Kept as a no-op so HandleMainEvent wiring stays valid.
  EndProcedure
  CompilerElse
  Procedure HandleDeferredCloseEvent(Event.i)
    ; No-op on non-macOS: CloseWindow is called synchronously there.
  EndProcedure
  Procedure HandleDeferredReleaseEvent(Event.i)
  EndProcedure
  CompilerEndIf


  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
    ; ---------------------------------------------------------------------------
    ; GCD-ordered window close (macOS).
    ;
    ; PureBasic's WebViewGadget is built on the webview.h C++ library. When JS
    ; invokes a native binding, webview enqueues a `resolve` block onto the main
    ; GCD queue (libdispatch) to deliver the result. The close handshake itself
    ; triggers such a binding (system:close-window), so a `resolve` block that
    ; captures the C++ engine `this` is in flight at close time.
    ;
    ; If we destroy the window (and thus the webview engine) before that block
    ; runs, the next run-loop iteration drains the queue, the block fires, and it
    ; dereferences the freed engine -> EXC_BAD_ACCESS in
    ; webview::detail::engine_base::resolve (confirmed via symbolicated crash
    ; report). Retaining the WKWebView/NSWindow does NOT help -- the dangling
    ; pointer is the webview.h engine, a layer below Apple's objects.
    ;
    ; Fix: enqueue CloseWindow onto the SAME main GCD queue via dispatch_async_f.
    ; GCD is strict FIFO, so the already-queued `resolve` block runs first (engine
    ; alive), then our block destroys the window. No block is left referencing a
    ; freed engine. This also runs CloseWindow at the top of a clean run-loop
    ; iteration (not nested in WaitWindowEvent's call stack).
    ;
    ; dispatch_async_f schedules a C callback on a GCD queue. _dispatch_main_q is
    ; the main-queue object; its ADDRESS is the queue handle (what the inline
    ; dispatch_get_main_queue() macro returns).
    ; Import only the function. PureBasic's ImportC parameter list does not take
    ; type suffixes — all args are integer/pointer-width.
    ImportC ""
      dispatch_async_f(gcdQueue, gcdContext, gcdWork)
    EndImport

    Procedure GCDCloseCallback(handle.i)
      ; Runs on the main thread (GCD main queue). `handle` is the PB window id,
      ; passed through dispatch_async_f's context slot.
      If IsWindow(handle)
        Debug "[GCDCloseCallback] CloseWindow handle=" + Str(handle)
        CloseWindow(handle)
      EndIf
    EndProcedure

    Procedure ScheduleGCDClose(handle.i)
      Protected cb.i = @GCDCloseCallback()
      ; The main-queue handle is the ADDRESS of libdispatch's _dispatch_main_q
      ; symbol (what the dispatch_get_main_queue() macro returns). Resolve it via
      ; inline C in the C backend; declare the extern so the C compiler accepts it.
      Protected q.i = 0
      ! extern char _dispatch_main_q[];
      ! v_q = (long)&_dispatch_main_q;
      If q And cb
        dispatch_async_f(q, handle, cb)
      Else
        ; Fallback: should never happen, but don't leak the window.
        If IsWindow(handle) : CloseWindow(handle) : EndIf
      EndIf
    EndProcedure
  CompilerEndIf


  Procedure.i OpenInstance(templateName.s, instanceKey.s, paramsJson.s, reloadOnReuse.b = #False, callerWindowName.s = "", atScreenX.i = #JSWindow_NoPosition, atScreenY.i = #JSWindow_NoPosition)
    If Not FindMapElement(JSTemplates(), templateName)
      Debug "[OpenInstance] Unknown template: " + templateName
      ProcedureReturn 0
    EndIf
    Protected *T.JSWindowTemplate = @JSTemplates()

    ; --- 1. Dedupe by caller-supplied opaque key. Empty key disables dedupe. ---
    Protected lookupKey.s = templateName + ":" + instanceKey
    If instanceKey <> "" And FindMapElement(TemplateInstances(), lookupKey)
      Protected existingHandle.i = TemplateInstances()
      If IsWindow(existingHandle) And FindMapElement(JSWindows(), Str(existingHandle))
        Protected *Existing.AppWindow = GetManagedWindowFromWindowHandle(WindowID(existingHandle))
        If *Existing
          Debug "[OpenInstance] Re-focus existing instance for key '" + instanceKey + "'"
          If paramsJson <> ""
            JSBridge::SendParameters(@JSWindows(), paramsJson)
          EndIf
          FocusInstance(*Existing)
          ProcedureReturn existingHandle
        EndIf
      EndIf
      ; Stale entry — drop it and fall through to open a new window.
      Debug "[OpenInstance] Stale TemplateInstances entry for '" + lookupKey + "', dropping"
      DeleteMapElement(TemplateInstances(), lookupKey)
    EndIf

    ; --- 2. Try to take a Ready spare from the pool. ---
    Protected *Window.AppWindow = 0
    Protected handle.i
    ForEach *T\PoolHandles()
      handle = *T\PoolHandles()
      If FindMapElement(JSWindows(), Str(handle)) And JSWindows()\Ready And JSWindows()\Visible
        ; reloadOnReuse=True  → only claim spares with NeedsReload=False (fresh / already reloaded)
        ; reloadOnReuse=False → accept any Ready+Visible spare, including recycled-no-reload ones
        If reloadOnReuse = #False Or JSWindows()\NeedsReload = #False
          *Window = GetManagedWindowFromWindowHandle(WindowID(handle))
          DeleteElement(*T\PoolHandles())
          Debug "[OpenInstance] Claimed spare handle=" + Str(handle) + " NeedsReload=" + Str(JSWindows()\NeedsReload) + " reloadOnReuse=" + Str(reloadOnReuse)
          Break
        EndIf
      EndIf
    Next

    ; --- 3. Cold path: pool empty or no Ready spare. ---
    If *Window = 0
      Debug "[OpenInstance] Cold path — creating spare synchronously"
      Protected createdHandle.i = CreateAndPrepareSpare(*T)
      If createdHandle = 0 : ProcedureReturn 0 : EndIf
      *Window = GetManagedWindowFromWindowHandle(WindowID(createdHandle))
      ; Remove from pool list — we're using it directly.
      ForEach *T\PoolHandles()
        If *T\PoolHandles() = createdHandle
          DeleteElement(*T\PoolHandles())
          Break
        EndIf
      Next
    EndIf

    If *Window = 0 : ProcedureReturn 0 : EndIf

    ; --- 4. Claim and open. ---
    Protected *JS.JSWindow = JSWindows(Str(*Window\Window))
    If *JS
      *JS\IsPoolSpare     = #False
      *JS\InstanceKey     = instanceKey
      *JS\ReloadOnRecycle = reloadOnReuse  ; store preference for use at close/recycle time
    EndIf
    If instanceKey <> ""
      TemplateInstances(lookupKey) = *Window\Window
    EndIf

    If paramsJson <> "" And *JS
      JSBridge::SendParameters(*JS, paramsJson)
    EndIf

    ; --- Smart cascade: position the new instance before it becomes visible
    ;     so there is no flicker. Base preference:
    ;       1. The most recently opened sibling instance of this template —
    ;          instances must never stack at the exact same x,y (always on,
    ;          no smartPosition opt-in needed).
    ;       2. The caller window (smartPosition opt-in via callerWindowName).
    ;     No usable base -> keep the default (template) position. ---
    Protected cascadeBaseX.i, cascadeBaseY.i
    Protected hasCascadeBase.b = #False

    ; Explicit drop-point placement (cross-window DnD "new window at the
    ; cursor"): overrides both cascade bases and skips the +10 offset — the
    ; caller already chose the exact spot. Still monitor-clamped below.
    Protected explicitPos.b = #False
    If atScreenX <> #JSWindow_NoPosition And atScreenY <> #JSWindow_NoPosition
      explicitPos = #True
      cascadeBaseX = atScreenX
      cascadeBaseY = atScreenY
      hasCascadeBase = #True
    EndIf

    Protected siblingHandle.i = 0
    Protected siblingOpenTime.i = -1
    Protected candHandle.i
    Protected instPrefix.s = *T\Name + ":"
    ForEach TemplateInstances()
      If Left(MapKey(TemplateInstances()), Len(instPrefix)) = instPrefix
        candHandle = TemplateInstances()
        If candHandle <> *Window\Window And IsWindow(candHandle) And FindMapElement(JSWindows(), Str(candHandle))
          ; Minimized windows report bogus positions (-32000 on Windows).
          If JSWindows()\Open And GetWindowState(candHandle) <> #PB_Window_Minimize And JSWindows()\OpenTime > siblingOpenTime
            siblingOpenTime = JSWindows()\OpenTime
            siblingHandle = candHandle
          EndIf
        EndIf
      EndIf
    Next
    If siblingHandle And Not explicitPos
      If JSWindows(Str(siblingHandle))\HasCascadePosition And WindowX(siblingHandle) < -5000
        ; Sibling is still parked off-screen (claimed mid-prepare): its real
        ; target position is the stored cascade target, not the parking spot.
        cascadeBaseX = JSWindows(Str(siblingHandle))\CascadeX
        cascadeBaseY = JSWindows(Str(siblingHandle))\CascadeY
      Else
        cascadeBaseX = WindowX(siblingHandle)
        cascadeBaseY = WindowY(siblingHandle)
      EndIf
      hasCascadeBase = #True
      Debug "[OpenInstance] Cascade base: sibling '" + JSWindows(Str(siblingHandle))\Name + "' at " + Str(cascadeBaseX) + "," + Str(cascadeBaseY)
    EndIf

    If Not hasCascadeBase And callerWindowName <> ""
      Protected callerHandle.i = 0
      ForEach JSWindows()
        If JSWindows()\Name = callerWindowName
          callerHandle = Val(MapKey(JSWindows()))
          Break
        EndIf
      Next
      If callerHandle <> 0 And IsWindow(callerHandle)
        cascadeBaseX = WindowX(callerHandle)
        cascadeBaseY = WindowY(callerHandle)
        hasCascadeBase = #True
      EndIf
    EndIf

    If hasCascadeBase
      Protected offsetPx.i = Round(10.0 * WindowManager::DPI_Scale, #PB_Round_Nearest)
      If explicitPos
        offsetPx = 0
      EndIf
      Protected newX.i     = cascadeBaseX + offsetPx
      Protected newY.i     = cascadeBaseY + offsetPx
      Protected newWinW.i  = WindowWidth(*Window\Window)
      Protected newWinH.i  = WindowHeight(*Window\Window)
      Protected desktopCount.i = ExamineDesktops()
      Protected di.i
      Protected monitorFound.b = #False
      For di = 0 To desktopCount - 1
        If cascadeBaseX >= DesktopX(di) And cascadeBaseX < DesktopX(di) + DesktopWidth(di) And
           cascadeBaseY >= DesktopY(di) And cascadeBaseY < DesktopY(di) + DesktopHeight(di)
          monitorFound = #True
          If newX + newWinW > DesktopX(di) + DesktopWidth(di)
            newX = DesktopX(di) + DesktopWidth(di) - newWinW
          EndIf
          If newY + newWinH > DesktopY(di) + DesktopHeight(di)
            newY = DesktopY(di) + DesktopHeight(di) - newWinH
          EndIf
          If newX < DesktopX(di) : newX = DesktopX(di) : EndIf
          If newY < DesktopY(di) : newY = DesktopY(di) : EndIf
          Break
        EndIf
      Next
      ; A base outside every monitor would cascade the window off-screen —
      ; keep the default position instead.
      If monitorFound
        ResizeWindow(*Window\Window, newX, newY, #PB_Ignore, #PB_Ignore)
        ; Persist so Event_Prepare_Complete restores here, not to PrepareOriginalX/Y.
        JSWindows(Str(*Window\Window))\HasCascadePosition = #True
        JSWindows(Str(*Window\Window))\CascadeX = newX
        JSWindows(Str(*Window\Window))\CascadeY = newY
      EndIf
    EndIf

    OpenJSWindow(*Window)

    ; --- 5. Refill in the background. ---
    RefillPoolAsync(*T)

    ProcedureReturn *Window\Window
  EndProcedure


  Procedure JSOpenInstance(JsonParameters.s)
    Dim Parameters.s(0)
    Debug "JSOpenInstance CALLED with: " + JsonParameters

    If ParseJSON(0, JsonParameters) = 0
      ProcedureReturn UTF8(~"{\"error\":\"ParseJSON failed\"}")
    EndIf
    ExtractJSONArray(JSONValue(0), Parameters())

    Protected templateName.s = ""
    Protected instanceKey.s = ""
    Protected paramsJson.s = ""
    Protected reloadOnReuse.b = #False
    If ArraySize(Parameters()) >= 0 : templateName = Parameters(0) : EndIf
    If ArraySize(Parameters()) >= 1 : instanceKey = Parameters(1) : EndIf
    If ArraySize(Parameters()) >= 2 : paramsJson = Parameters(2) : EndIf
    If ArraySize(Parameters()) >= 3
      If Parameters(3) = "1" : reloadOnReuse = #True : EndIf
    EndIf

    Protected callerWindowName.s = ""
    If ArraySize(Parameters()) >= 4 : callerWindowName = Parameters(4) : EndIf

    ; Optional explicit position (DnD drop-point placement); "" = unset.
    Protected atScreenX.i = #JSWindow_NoPosition
    Protected atScreenY.i = #JSWindow_NoPosition
    If ArraySize(Parameters()) >= 5 And Parameters(5) <> ""
      atScreenX = Val(Parameters(5))
    EndIf
    If ArraySize(Parameters()) >= 6 And Parameters(6) <> ""
      atScreenY = Val(Parameters(6))
    EndIf

    Protected handle.i = OpenInstance(templateName, instanceKey, paramsJson, reloadOnReuse, callerWindowName, atScreenX, atScreenY)
    If handle = 0
      ProcedureReturn UTF8(~"{\"error\":\"OpenInstance failed\"}")
    EndIf

    Protected resultName.s = ""
    If FindMapElement(JSWindows(), Str(handle))
      resultName = JSWindows()\Name
    EndIf
    ProcedureReturn UTF8(~"{\"success\":true,\"name\":\"" + resultName + ~"\",\"id\":" + Str(handle) + "}")
  EndProcedure


  Procedure HideJSWindow(*Window.AppWindow, FromManagedWindow)
    If IsWindow(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))

      HideWindow(*Window\Window,#True)
      
      If *Window\Open
        If *JSWindow\Parent
          If IsWindow(*JSWindow\Parent\Window)
            SetActiveWindow(*JSWindow\Parent\Window)
          EndIf
        EndIf
      EndIf 
      
      If Not FromManagedWindow
        HideManagedWindow(*Window)
      EndIf
      
    EndIf 
  EndProcedure
  
  
  ; Register a generic close observer, invoked as (*Window, *JSWindow) just
  ; before a window's webview is torn down (see CloseJSWindow). Domain-agnostic.
  Procedure RegisterWindowClosingObserver(*callback)
    If *callback
      AddElement(WindowClosingObservers())
      WindowClosingObservers() = *callback
    EndIf
  EndProcedure

  Procedure CloseJSWindow(*Window.AppWindow)
    Protected *JSWindow.JSWindow
    ; Capture template/instanceKey/parent BEFORE the JSWindows() entry is deleted.
    Protected *T.JSWindowTemplate = 0
    Protected instanceKey.s = ""
    Protected *Parent.AppWindow = 0
    Protected lookupKey.s = ""
    If *Window <> 0 And IsWindow(*Window\Window)
      *JSWindow = JSWindows(Str(*Window\Window))
      If *JSWindow
        *T          = *JSWindow\OwningTemplate
        instanceKey = *JSWindow\InstanceKey
        *Parent     = *JSWindow\Parent  ; capture before DeleteMapElement frees *JSWindow
      EndIf

      ; ---- RECYCLE PATH: active template instance → hide and return to pool ----
      ; Instead of tearing the window down, recycle it as a warm pool spare.
      ; This mirrors terminal-window behaviour: WebView content stays loaded and
      ; Visible stays True, so the next OpenInstance claim is instant — no WKWebView
      ; reload or ForceContentVisible delay.
      ; Not while quitting: recycling skips the WebView teardown below, and the
      ; app-exit cleanup then frees a WKWebView that still has script-message
      ; handlers attached — the ObjC abort this teardown exists to prevent.
      If *T And instanceKey <> "" And Not AppClosing
        If *JSWindow
          If *JSWindow\ReloadOnRecycle
            ; Reload path: page will be replaced — no need to blank body first.
            ; Reset state so pool check blocks callers until reload finishes.
            *JSWindow\Ready = #False
            *JSWindow\Visible = #False
            *JSWindow\NeedsReload = #False  ; cleared again by JSReadyState after reload completes
            CompilerIf #PBJS_DevMode
              Sink::Exec(*JSWindow\Sink, "window.location.reload();")
            CompilerElse
              If *JSWindow\Headless
                Sink::Exec(*JSWindow\Sink, "window.location.reload();")
              Else
                StartLoadHtml(*JSWindow)
              EndIf
            CompilerEndIf
          Else
            ; Fast recycle (no reload): blank body so next user doesn't see stale content.
            ; SendParameters re-adds 'pbjs-document-ready' via rAF when the instance is next claimed.
            *JSWindow\NeedsReload = #True
            Sink::Exec(*JSWindow\Sink, "document.body.classList.remove('pbjs-document-ready');")
            ; Visible stays #True: WebView is live and ready for instant reuse.
          EndIf
          *JSWindow\IsPoolSpare = #True
          *JSWindow\InstanceKey = ""
          *JSWindow\Open = #False
        EndIf
        HideWindow(*Window\Window, #True)
        *Window\Open = #False
        ; Do NOT set Closed=True — CleanupManagedWindows will close it at app exit.
        lookupKey = *T\Name + ":" + instanceKey
        If FindMapElement(TemplateInstances(), lookupKey)
          DeleteMapElement(TemplateInstances(), lookupKey)
        EndIf
        AddElement(*T\PoolHandles())
        *T\PoolHandles() = *Window\Window
        Debug "[CloseJSWindow] Recycled '" + instanceKey + "' → pool (size=" + Str(ListSize(*T\PoolHandles())) + ")"
        If *Parent And IsWindow(*Parent\Window)
          SetActiveWindow(*Parent\Window)
        EndIf
        ProcedureReturn
      EndIf
      ; ---- END RECYCLE PATH ----

      If Not *Window\Closed
        CloseManagedWindow(*Window)
        ; CloseManagedWindow calls CloseProc = CloseJSWindow recursively (with
        ; *Window\Closed already True). That inner call runs all cleanup below with
        ; a valid *JSWindow pointer and defers CloseWindow. By the time we return
        ; here, the JSWindows map entry is gone and *JSWindow is dangling — bail out
        ; so the outer call doesn't re-execute cleanup with a stale pointer.
        If Not FindMapElement(JSWindows(), Str(*Window\Window))
          ProcedureReturn
        EndIf
      EndIf

      ; Notify close observers while *JSWindow and its webview gadget are still
      ; valid (runs once, in the cleanup path — the outer call returned above).
      ; Generic hook: pbjs doesn't know or care what observers do.
      If *JSWindow
        ; Tell peers this window is gone so they reject in-flight requests to it
        ; now (orphan-reject) and evict it from their readiness cache. (§6.5)
        JSBridge::NotifyWindowEvent(*JSWindow\Name, "closed")
        ForEach WindowClosingObservers()
          CallFunctionFast(WindowClosingObservers(), *Window, *JSWindow)
        Next
        ; Headless: tell the browser tab, then release the sink handle.
        If *JSWindow\Headless
          Sink::WinCmd(*JSWindow\Sink, "close", "")
          Sink::ReleaseHeadless(*JSWindow\Sink)
        EndIf
      EndIf
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        MacOSUnregisterResizeNotifications(*Window)
        ; Stop the WebView and remove all script message handlers before deferring
        ; CloseWindow. Pending WKScriptMessage deliveries from the web content
        ; process arrive via the Cocoa run loop — if the webview is already freed
        ; when they land, the next WaitWindowEvent crashes with an invalid memory
        ; access. Removing the handlers makes those deliveries silent no-ops.
        ; GadgetID returns a container NSView, not the WKWebView itself — search
        ; subviews for the actual WKWebView.
        If *JSWindow And IsGadget(*JSWindow\WebViewGadget)
          Protected macGadgetView.i = GadgetID(*JSWindow\WebViewGadget)
          Protected macWKClass.i = objc_getClass_("WKWebView")
          Protected macWv.i = 0
          ; Search up to 3 levels deep — GadgetID returns a container NSView, not
          ; WKWebView itself. Depth varies across PureBasic versions/macOS versions.
          If macGadgetView And macWKClass
            Protected macSearchQueue.i = CocoaMessage(0, 0, "NSMutableArray array")
            CocoaMessage(0, macSearchQueue, "addObject:", macGadgetView)
            Protected macSearchDepth.i = 0
            While macWv = 0 And CocoaMessage(0, macSearchQueue, "count") > 0 And macSearchDepth < 3
              Protected macNextLevel.i = CocoaMessage(0, 0, "NSMutableArray array")
              Protected macQLvlCount.i = CocoaMessage(0, macSearchQueue, "count")
              Protected macQIdx.i
              For macQIdx = 0 To macQLvlCount - 1
                Protected macQView.i = CocoaMessage(0, macSearchQueue, "objectAtIndex:", macQIdx)
                If CocoaMessage(0, macQView, "isKindOfClass:", macWKClass)
                  macWv = macQView
                  Break
                EndIf
                Protected macQSubs.i = CocoaMessage(0, macQView, "subviews")
                CocoaMessage(0, macNextLevel, "addObjectsFromArray:", macQSubs)
              Next
              macSearchQueue = macNextLevel
              macSearchDepth + 1
            Wend
          EndIf
          Debug "[CloseJSWindow] macWv=" + Str(macWv)
          If macWv
            CocoaMessage(0, macWv, "stopLoading")
            ; Nil the delegates so the WKWebView won't call into PureBasic's
            ; delegate objects after CloseWindow frees them. These are weak
            ; properties — nil-ing does NOT extend any object's lifetime.
            CocoaMessage(0, macWv, "setNavigationDelegate:", 0)
            CocoaMessage(0, macWv, "setUIDelegate:", 0)
            Protected macUcc.i = CocoaMessage(0, CocoaMessage(0, macWv, "configuration"), "userContentController")
            If macUcc : CocoaMessage(0, macUcc, "removeAllScriptMessageHandlers") : EndIf
          EndIf
          ; NOTE: do NOT retain the WKWebView/NSWindow past CloseWindow. Doing so
          ; kept a half-torn-down object alive that the run loop then touched,
          ; turning an occasional crash into a deterministic one. Letting them
          ; deallocate naturally during CloseWindow is strictly better here.
        EndIf
      CompilerEndIf
      If IsWindow(*Window\Window)
        ; Name→handle map: same aliasing hazard as the native-handle map. PB
        ; reuses window NUMBERS, so a stale name entry can resolve to a
        ; different, live window and route another page's messages into it.
        If *JSWindow And FindMapElement(WindowsByName(), *JSWindow\Name)
          DeleteMapElement(WindowsByName(), *JSWindow\Name)
        EndIf
        DeleteMapElement(JSWindows(), Str(*Window\Window))
        ; The one place that knows this is a real teardown and not a recycle —
        ; the recycle path returned long before here. Marks the AppWindow for
        ; removal; WindowManager frees it from the event loop.
        ForgetManagedWindow(*Window)
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          ; Enqueue CloseWindow on the main GCD queue so it runs AFTER any
          ; in-flight webview.h `resolve` block (FIFO ordering). See the comment
          ; on ScheduleGCDClose above for the full rationale. This also avoids
          ; calling CloseWindow from inside WaitWindowEvent's call stack.
          ScheduleGCDClose(*Window\Window)
        CompilerElse
          CloseWindow(*Window\Window)
        CompilerEndIf
      EndIf

      If *Parent And IsWindow(*Parent\Window)
        SetActiveWindow(*Parent\Window)
      EndIf
    EndIf

    ; Multi-instance cleanup: drop the dedupe entry and refill the pool.
    ; (Only reached for pool spares and non-template windows — active instances
    ;  return early via the recycle path above.)
    If *T
      If instanceKey <> ""
        lookupKey = *T\Name + ":" + instanceKey
        If FindMapElement(TemplateInstances(), lookupKey)
          DeleteMapElement(TemplateInstances(), lookupKey)
        EndIf
      EndIf

      ; Drop this window from the pool list if it was a spare. Without this the
      ; handle of a DESTROYED spare stays in PoolHandles() forever, and since
      ; RefillPoolAsync sizes the shortfall as
      ;   need = PoolTargetSize - ListSize(PoolHandles())
      ; the stale entry makes an empty pool look full: need <= 0, no refill,
      ; ever. OpenInstance's claim loop skips the dead handle safely, so the
      ; symptom is not a crash — it is a pool that quietly stops warming and
      ; every open falling back to the slow cold path.
      ForEach *T\PoolHandles()
        If *T\PoolHandles() = *Window\Window
          Debug "[CloseJSWindow] Pruned destroyed spare " + Str(*Window\Window) + " from pool"
          DeleteElement(*T\PoolHandles())
          Break
        EndIf
      Next

      RefillPoolAsync(*T)
    EndIf
  EndProcedure
  
  
  Procedure ResizeJSWindow(*Window.AppWindow, x, y, w, h)
    If IsWindow(*Window\Window)
      ResizeWindow( *Window\Window,x, y, w, h)
    EndIf 
  EndProcedure
  
  
  ; ============================================================================
  ; APP CLOSE HANDLING
  ; ============================================================================
  
  Procedure ResetCloseChecks(Scope)
     Debug "[RESET_CLOSE_CHECKS] ENTER. Scope=" + Str(Scope)
     Protected LoopCount = 0
     ForEach JSWindows()
       LoopCount + 1
       If LoopCount > 100
         Debug "[RESET_CLOSE_CHECKS] FOREACH LOOP > 100, breaking!"
         Break
       EndIf
       ; Skip empty key entries
       If MapKey(JSWindows()) = "" : Continue : EndIf
       Protected InScope = #False 
       Debug "[RESET_CLOSE_CHECKS] Checking window: " + JSWindows()\Name
       
       If Scope = -1
         InScope = #True 
       ElseIf IsWindow(JSWindows()\Window)
         If JSWindows()\Window = Scope 
           InScope = #True 
         Else 
            ; Check ancestry
            Protected *Current.AppWindow = JSWindows()\Parent
            Protected AncestryDepth = 0
            While *Current
              AncestryDepth + 1
              If AncestryDepth > 100
                Debug "[RESET_CLOSE_CHECKS] ANCESTRY LOOP > 100, breaking!"
                Break
              EndIf
              Debug "[RESET_CLOSE_CHECKS] Ancestry depth " + Str(AncestryDepth) + ": Window=" + Str(*Current\Window)
              If *Current\Window = Scope 
                 InScope = #True 
                 Break 
              EndIf 
              ; Move up - save/restore map position to preserve ForEach iterator
                If IsWindow(*Current\Window)
                   PushMapPosition(JSWindows())
                   If FindMapElement(JSWindows(), Str(*Current\Window))
                     Protected *ParentRef.AppWindow = JSWindows()\Parent 
                     PopMapPosition(JSWindows())
                     *Current = *ParentRef
                   Else
                     PopMapPosition(JSWindows())
                     Break 
                   EndIf 
                Else
                 Break 
               EndIf 
            Wend 
         EndIf 
       EndIf 
       
       If InScope
         Debug "[RESET_CLOSE_CHECKS] InScope=True, resetting BypassCloseCheck"
         JSWindows()\BypassCloseCheck = #False 
       EndIf 
     Next 
     Debug "[RESET_CLOSE_CHECKS] EXIT"
  EndProcedure

  Procedure CancelClose(Reason.s="")
     Debug "CANCEL CLOSE: " + Reason
     ResetCloseChecks(ClosingScope)
     ClosingScope = 0
     CloseWatchdogArmedAt = 0
  EndProcedure

  Procedure CheckCloseProgress()
    Debug "[CHECK_CLOSE_PROGRESS] ENTER. ClosingScope=" + Str(ClosingScope)
    If ClosingScope = 0
      ProcedureReturn 
    EndIf 
    
    Protected AllReady = #True 
    
    ForEach JSWindows()
       Protected InScope = #False 
       If MapKey(JSWindows()) = "" : Continue : EndIf 
       Debug "[CHECK_CLOSE_PROGRESS] Checking window: " + JSWindows()\Name + " (ID=" + Str(JSWindows()\Window) + ")"
       
       If ClosingScope = -1
         InScope = #True 
       ElseIf IsWindow(JSWindows()\Window)
         If JSWindows()\Window = ClosingScope
           InScope = #True 
         Else 
            ; Check ancestry
            Protected *Current.AppWindow = JSWindows()\Parent
            Protected AncestryDepth = 0
            While *Current
              AncestryDepth + 1
              If AncestryDepth > 100
                Debug "[CHECK_CLOSE_PROGRESS] INFINITE LOOP DETECTED at depth 100!"
                Break
              EndIf
              Debug "[CHECK_CLOSE_PROGRESS] Ancestry depth " + Str(AncestryDepth) + ": Window=" + Str(*Current\Window)
               If *Current\Window = ClosingScope
                  InScope = #True 
                  Break 
               EndIf 
               ; Move up - save/restore map position to preserve ForEach iterator
               If IsWindow(*Current\Window)
                  PushMapPosition(JSWindows())
                  If FindMapElement(JSWindows(), Str(*Current\Window))
                    Protected *ParentRef.AppWindow = JSWindows()\Parent 
                    PopMapPosition(JSWindows())
                    *Current = *ParentRef
                  Else
                    PopMapPosition(JSWindows())
                    Break 
                  EndIf 
               Else
                 Break 
               EndIf 
             Wend 
         EndIf 
       EndIf 
       
       If InScope
          Debug "[CHECK_CLOSE_PROGRESS] InScope=True. Visible=" + Str(JSWindows()\Visible) + " BypassCloseCheck=" + Str(JSWindows()\BypassCloseCheck)

          Protected *AppWin.AppWindow = 0
          If IsWindow(JSWindows()\Window)
             *AppWin = GetManagedWindowFromWindowHandle(WindowID(JSWindows()\Window))
          EndIf
          
          If *AppWin And *AppWin\Open And JSWindows()\Visible And Not JSWindows()\BypassCloseCheck
             AllReady = #False 
             Debug "[CHECK_CLOSE_PROGRESS] AllReady=False, breaking"
             Break 
          EndIf 
       EndIf
    Next 
    Debug "[CHECK_CLOSE_PROGRESS] Loop finished. AllReady=" + Str(AllReady) 
    
    If AllReady
      If ClosingScope = -1
        End 
      Else
        Protected *RootJS.JSWindow = JSWindows(Str(ClosingScope))
        If *RootJS
           *RootJS\BypassCloseCheck = #True
           PostEvent(#PB_Event_CloseWindow, ClosingScope, 0)
        EndIf
        ClosingScope = 0
        CloseWatchdogArmedAt = 0
      EndIf
    EndIf

  EndProcedure

  ; ---------------------------------------------------------------------------
  ;- Close-veto watchdog
  ; ---------------------------------------------------------------------------
  ; RequestClose sends a close check to every in-scope window and sets the
  ; single global ClosingScope. Progress happens ONLY when a reply arrives
  ; (HandleReply → CheckCloseProgress). So a window that never replies — a hung
  ; page, a handler stuck on a promise that never settles — leaves ClosingScope
  ; set forever, and because RequestClose returns 0 while a scope is pending,
  ; EVERY later close click on EVERY window is silently consumed. The app
  ; becomes unquittable with no error anywhere the user can see.
  ;
  ; The watchdog ends that state, and it ends it as DECLINED: an unanswered
  ; check is not consent. The window stays open; the scope is cleared so the
  ; close path works again, and the next close click starts a fresh round (which
  ; will also time out while the page stays hung — by design). There is
  ; deliberately NO "click again to force it" escape hatch: a page that has not
  ; answered may be mid-save, and pbjs will not throw that away on a guess. A
  ; genuinely wedged app is the OS's problem to kill, not this module's.
  ;
  ; No timer object and no generation counter: the arm TIME is the generation.
  ; A stale post from a completed round finds either ClosingScope = 0, or a
  ; newer round whose elapsed time has not run out yet — and no-ops either way.
  Global CloseWatchdogArmedAt.q = 0

  Procedure ArmCloseWatchdog(Scope)
    CloseWatchdogArmedAt = ElapsedMilliseconds()

    ; The post needs some live window to be delivered to; the handler acts on
    ; the global scope, not on that window. Prefer the scope window itself,
    ; fall back to any open one (Scope = -1 is the whole app).
    Protected deliverTo.i = 0
    If Scope > 0 And IsWindow(Scope)
      deliverTo = Scope
    Else
      ForEach JSWindows()
        If MapKey(JSWindows()) = "" : Continue : EndIf
        If IsWindow(JSWindows()\Window) And JSWindows()\Visible
          deliverTo = JSWindows()\Window
          Break
        EndIf
      Next
    EndIf

    If deliverTo
      PostEventAfterDelay(deliverTo, #PBJS_CloseCheckTimeoutMs, #Event_Close_Watchdog)
    Else
      ; Nothing left to deliver to — nothing can reply either, so the scope
      ; would never clear. Drop it now rather than arming a timer into the void.
      Debug "[CLOSE_WATCHDOG] no live window to arm on; clearing scope"
      CancelClose("no window available to answer the close check")
    EndIf
  EndProcedure

  Procedure CheckCloseWatchdog()
    If ClosingScope = 0
      ProcedureReturn   ; round already finished
    EndIf
    If CloseWatchdogArmedAt = 0
      ProcedureReturn
    EndIf
    ; A newer round re-armed after this post was scheduled: its own watchdog is
    ; still pending and owns the deadline.
    If ElapsedMilliseconds() - CloseWatchdogArmedAt < #PBJS_CloseCheckTimeoutMs
      ProcedureReturn
    EndIf

    Debug "[CLOSE_WATCHDOG] no reply within " + Str(#PBJS_CloseCheckTimeoutMs) +
          "ms for scope " + Str(ClosingScope) + " — treating as declined"
    CloseWatchdogArmedAt = 0
    CancelClose("close check timed out after " + Str(#PBJS_CloseCheckTimeoutMs) + "ms")
  EndProcedure

  Procedure RequestClose(Scope)
    Debug "[REQUEST_CLOSE] ENTER. Scope=" + Str(Scope) + " ClosingScope=" + Str(ClosingScope)

    If ClosingScope <> 0
       ProcedureReturn 0
    EndIf

    ClosingScope = Scope
    
    Protected CheckStarted = #False 
    
    ForEach JSWindows()
      Protected *AppWin.AppWindow = 0
      If IsWindow(JSWindows()\Window)
         *AppWin = GetManagedWindowFromWindowHandle(WindowID(JSWindows()\Window))
      EndIf
      
      If *AppWin And *AppWin\Open And JSWindows()\Visible 
        
         Protected InScope = #False 
         
         If ClosingScope = -1
           InScope = #True 
         Else
           If JSWindows()\Window = Scope 
             InScope = #True 
           Else 
              ; Check ancestry
              Protected *Current.AppWindow = JSWindows()\Parent
              While *Current
                If *Current\Window = Scope 
                   InScope = #True 
                   Break 
                EndIf
                If IsWindow(*Current\Window)
                     ; Save/restore map position to preserve ForEach iterator
                     PushMapPosition(JSWindows())
                     If FindMapElement(JSWindows(), Str(*Current\Window))
                       Protected *ParentRef.AppWindow = JSWindows()\Parent 
                       PopMapPosition(JSWindows())
                       *Current = *ParentRef
                     Else
                       PopMapPosition(JSWindows())
                       Break 
                     EndIf 
                  Else
                   Break 
                 EndIf 
               Wend 
           EndIf 
         EndIf 
         
         If InScope
           If Not JSWindows()\BypassCloseCheck
             JSBridge::SendCloseCheck(@JSWindows())
             CheckStarted = #True 
           EndIf 
         EndIf 
      EndIf 
    Next 
    
    If Not CheckStarted
      ; No window was asked anything, so no reply can ever arrive — and it is
      ; CheckCloseProgress/CancelClose, both reply-driven, that clear the scope.
      ; Leaving it set here (what this did before) wedges every later close for
      ; the rest of the run, by the same mechanism as an unanswered check but
      ; without even a check outstanding. Nothing is pending: drop it now.
      ClosingScope = 0
      CloseWatchdogArmedAt = 0
      ProcedureReturn #True
    EndIf

    ; Checks are in flight. From here the ONLY things that can clear
    ; ClosingScope are a reply (CheckCloseProgress / CancelClose) and this.
    ArmCloseWatchdog(Scope)
    ProcedureReturn #False

  EndProcedure
  
  CompilerIf #PBJS_DevMode
    
    Global DEBUGMODEoldLocation.s
    Global DEBUGMODEinjectStartupOnce = #False 
    
    Procedure CallbackLocation(jsonParameters.s)
      Dim Parameters.s(0)
      ParseJSON(0, jsonParameters)
      ExtractJSONArray(JSONValue(0), Parameters())
      
      window.s = Parameters(0)
      location.s = Parameters(1)

      ; Page-supplied key — don't let an unknown/closed id auto-create a ghost
      ; JSWindows() element (map () access inserts missing keys).
      If Not FindMapElement(JSWindows(), window)
        ProcedureReturn UTF8(~"")
      EndIf

      If JSWindows(window)\LastLocation <> "" And JSWindows(window)\LastLocation <> location
        DEBUGMODEinjectStartupOnce = #True 
        JSWindows(window)\Ready = #False 
        
        
        ; CRITICAL FIX: Do NOT restart the global PTY manager just because one window reloaded/changed URL.
        ; This was causing all shells to die when MainWindow updated its URL parameters.
        ; Ptym::IsStarted = #False
        
        
      EndIf 
      
      JSWindows(window)\LastLocation = location
      ProcedureReturn UTF8(~"")
    EndProcedure 
    
    Global DEBUGMODEcheckTime
    
    Global DEBUGMODEcheckTime
    Global DEBUGMODEexecuteLocationScriptTime
    
    
  CompilerEndIf
  
  
  Procedure HideChildWindows(*ParentWindow.AppWindow)
     ForEach JSWindows()
       If JSWindows()\Parent = *ParentWindow
         If IsWindow(JSWindows()\Window)
           Protected *ChildAppWindow.AppWindow = WindowManager::GetManagedWindowFromWindowHandle(WindowID(JSWindows()\Window))
           If *ChildAppWindow
             HideChildWindows(*ChildAppWindow)
             WindowManager::HideManagedWindow(*ChildAppWindow)
             JSWindows()\Visible = #False 
           EndIf 
         EndIf 
       EndIf 
     Next 
  EndProcedure

  Procedure.i HandleEvent(*Window.AppWindow,Event.i, Gadget.i, Type.i)
    
    
    *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
    
    CompilerIf #PBJS_DevMode
      ; Headless windows are bootstrapped attach-driven (HandleHeadlessAttach),
      ; not by this event-driven retry loop; the location poll is equally
      ; meaningless for a browser tab (reload detection = proxy re-attach).
      ; Gate BOTH blocks (plan C6).
      If Not *JSWindow\Headless
        webViewGadget = *JSWindow\WebViewGadget
        If (Not *JSWindow\Ready Or DEBUGMODEinjectStartupOnce) And ElapsedMilliseconds() - DEBUGMODEcheckTime > 300
          DEBUGMODEinjectStartupOnce = #False
          BindWebviewEvents(webViewGadget)
          DEBUGMODEcheckTime =  ElapsedMilliseconds()
          WebViewExecuteScript(webViewGadget, "window.__pbjsAdded = false;")
          WebViewExecuteScript(webViewGadget, *JSWindow\PreRenderJS)
          WebViewExecuteScript(webViewGadget, *JSWindow\StartupJS)
          WebViewExecuteScript(webViewGadget, *JSWindow\WindowJS )
          WebViewExecuteScript(webViewGadget, JSBridge::GetStartUpJS(*JSWindow\Name))
        EndIf


        If  ElapsedMilliseconds() - DEBUGMODEexecuteLocationScriptTime > 500
          DEBUGMODEexecuteLocationScriptTime = ElapsedMilliseconds()
          BindWebViewCallback(webViewGadget, "callbackLocation", @CallbackLocation())
          WebViewExecuteScript(webViewGadget, ~"callbackLocation('"+Str(*Window\Window)+"', '"+ ~"'+document.location.href+'" +~"');")

          w = WindowWidth(*JSWindow\Window)
          h = WindowHeight(*JSWindow\Window)
          UpdateWebViewScale(*JSWindow, w, h)
        EndIf
      EndIf
    CompilerEndIf
    
    
    Protected closeWindow = #False
    Select Event
      Case #PB_Event_CloseWindow
        closeWindow = #True
      Case #PB_Event_Gadget
        Select Gadget
        EndSelect
        
      Case #PB_Event_SizeWindow
        
        w = WindowWidth(*JSWindow\Window)
        h = WindowHeight(*JSWindow\Window)
        UpdateWebViewScale(*JSWindow, w, h) 
        
        
        
      Case  #CustomWindowEvent
        Select Type.i 
            
          Case #Event_Loaded_Html
            ; The decoded HTML arrives as the event payload (LoadHtml threads
            ; only over its own args, never the map). Copy + free
            ; unconditionally — outside the release gate below — so debug
            ; builds don't leak the args either.
            Protected *LoadArgs.LoadHtmlArgs = EventData()
            If *LoadArgs
              *JSWindow\Html = *LoadArgs\Html
              ; Populate the decode cache here, on the main thread, so the next
              ; window built from this same embedded range skips the decode
              ; entirely (StartLoadHtml). Costs one extra copy of a string the
              ; process is holding anyway; saves a full multi-MB UTF-8 decode
              ; per pool spare.
              Protected htmlKey.s = HtmlCacheKey(*LoadArgs\HtmlStart, *LoadArgs\HtmlEnd)
              If *LoadArgs\Html <> "" And Not FindMapElement(DecodedHtmlCache(), htmlKey)
                DecodedHtmlCache(htmlKey) = *LoadArgs\Html
              EndIf
              FreeStructure(*LoadArgs)
            EndIf
            CompilerIf Not #PBJS_DevMode
              ; Headless: no gadget, page comes from the browser (plan C7).
              ; (LoadHtml is never started for headless windows; belt & braces.)
              If Not *JSWindow\Headless
                webViewGadget = *JSWindow\WebViewGadget

                html.s =  JSBridge::WithBridgeScript(*JSWindow\Html, *JSWindow\Name)
                html.s =  WithPbjsBasicScript(html, *JSWindow)
                ; Opaque app pre-render script: inserted last ⇒ closest to <body>
                ; ⇒ runs first, before React's deferred module bundle.
                html.s =  WithPreRenderScript(html, *JSWindow\PreRenderJS)



                SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
                *JSWindow\LoadedCode = #True
                PbjsStartupTraceMark("html + bridge script set on webview: " + *JSWindow\Name)
              EndIf
            CompilerEndIf
          Case #Event_Content_Ready

            ; Headless: no gadget to unhide, no window to show/maximize — but
            ; the semantic milestone is identical: mark visible, fade-in style,
            ; and fire WindowReadyProc (→ WindowLoaded: ptym/FS/settings
            ; bridges attach through the Sink). Plan §5.4-4.
            If *JSWindow\Headless
              Debug " #Event_Content_Ready (headless) "+*JSWindow\Name
              *JSWindow\Visible = #True
              PbjsStartupTraceMark("headless content ready: " + *JSWindow\Name)
              SetBodyFadeIn(*JSWindow)
              If *JSWindow\Ready
                If *JSWindow\WindowReadyProc
                  CallFunctionFast(*JSWindow\WindowReadyProc, *Window , *JSWindow)
                EndIf
              EndIf
              ProcedureReturn #True
            EndIf

            ; macOS first-show site (Win/Linux consume the flag in
            ; OpenManagedWindow): maximize while still hidden so the
            ; HideWindow(#False) below reveals the window already maximized —
            ; no normal-size flash — and UpdateWebViewScale sees the maximized
            ; dimensions. The state guard matters: Cocoa zoom: is a toggle.
            If *Window\OpenMaximized And *JSWindow\Open And Not *JSWindow\Visible
              *Window\OpenMaximized = #False
              If GetWindowState(*JSWindow\Window) <> #PB_Window_Maximize
                SetWindowState(*JSWindow\Window, #PB_Window_Maximize)
              EndIf
            EndIf

            webViewGadget = *JSWindow\WebViewGadget
            w = WindowWidth(*JSWindow\Window)
            h = WindowHeight(*JSWindow\Window)

            UpdateWebViewScale(*JSWindow, w, h)

            CompilerIf #PB_Compiler_OS = #PB_OS_Windows Or #PB_Compiler_OS = #PB_OS_Linux
              ResizeGadget(webViewGadget,0,0,#PB_Ignore,#PB_Ignore)
            CompilerEndIf
            CompilerIf #PB_Compiler_OS = #PB_OS_Windows
              ;UpdateWindow_(WindowID(*JSWindow\Window))
              RedrawWindow_(GadgetID(*JSWindow\WebViewGadget), #Null, #Null, #RDW_UPDATENOW  )
              RedrawWindow_(WindowID(*JSWindow\Window), #Null, #Null, #RDW_UPDATENOW | #RDW_ALLCHILDREN )
            CompilerEndIf

            Debug " #Event_Content_Ready "+*JSWindow\Name

            HideGadget(webViewGadget,#False)

            If *JSWindow\Open And Not *JSWindow\Visible
              ; First reveal. On mac it fades up from transparent, which is what
              ; covers WebKit's first rendering pass — see MacRevealWindow.
              CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
                MacRevealWindow(*JSWindow)
              CompilerElse
                HideWindow(*JSWindow\Window, #False)
              CompilerEndIf
            EndIf
            *JSWindow\Visible = #True
            PbjsStartupTraceMark("window shown (content ready): " + *JSWindow\Name)

            SetBodyFadeIn(*JSWindow)

            If *JSWindow\Ready
              If *JSWindow\WindowReadyProc
                CallFunctionFast(*JSWindow\WindowReadyProc, *Window , *JSWindow)
              EndIf
            EndIf
            
          Case #Event_Prepare_Uncloak
            ; Posted by PrepareJSWindow's uncloak timer ~3 frames after the
            ; cloaked no-activate show (Windows only). The window stays invisible via
            ; alpha-0 + off-screen + WS_EX_TOOLWINDOW, but without the cloak
            ; Chromium no longer considers it occluded, so WebView2 renders
            ; the page during prepare — that render IS the pre-warm.
            CompilerIf #PB_Compiler_OS = #PB_OS_Windows
              Debug "[Event_Prepare_Uncloak] " + *JSWindow\Name
              SetWindowCloak(WindowID(*JSWindow\Window), #False)
            CompilerEndIf

          Case #Event_Show_WebView
            ; Posted by ShowGadgetThread after a fullscreen transition
            ; (macOS only). The un-hide must run here on the main thread —
            ; HideGadget from the worker thread trips AppKit's drag-region
            ; main-thread assert and aborts. Gadget re-resolved now, not at
            ; post time: the window may have closed during the 200 ms wait.
            CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
              If Not *JSWindow\Headless
                webViewGadget = *JSWindow\WebViewGadget
                If IsGadget(webViewGadget)
                  HideGadget(webViewGadget, #False)
                EndIf
              EndIf
            CompilerEndIf

          Case #Event_Force_Content_Visible
            ; Reveal watchdog fired (ForceContentVisible's timer). The page
            ; may have reported ready during the sleep — that check runs HERE
            ; on the main thread, not in the timer thread; if it hasn't,
            ; fall through to the normal reveal path.
            If Not *JSWindow\Ready
              PostEvent(#CustomWindowEvent, *Window\Window, 0, #Event_Content_Ready)
            EndIf

          Case #Event_Close_Watchdog
            ; A close check went unanswered. Acts on the global close scope,
            ; not on this window — this window is only the delivery vehicle
            ; the post needed. See CheckCloseWatchdog.
            CheckCloseWatchdog()

          Case #Event_Prepare_Complete
            ; Posted by JSReadyState (page ready) or by the prepare timeout
            ; timer — first one wins; the latch makes the second a no-op and
            ; absorbs a stale timer post landing on a recycled window number.
            If Not *JSWindow\PrepareWaiting
              ProcedureReturn #True
            EndIf
            *JSWindow\PrepareWaiting = #False
            ; Claimable-marker (OpenInstance requires Ready And Visible; also
            ; lets OpenJSWindow skip the reveal watchdog). Was the prepare
            ; thread's off-main write; now it flips here on the main thread.
            *JSWindow\Visible = #True
            Debug "[Event_Prepare_Complete] Hiding and restoring position for " + *JSWindow\Name

            Protected PrepWinID = WindowID(*JSWindow\Window)

            ; Race guard: if OpenInstance claimed this spare before the event was
            ; processed, IsPoolSpare is already #False and the window is open.
            ; In that case skip orderOut (the window should stay visible) but still
            ; restore alpha and position — they were left in the "hiding" state
            ; (alpha 0, off-screen) when the spare was created.
            Protected claimedAndOpen.b = #False
            If Not *JSWindow\IsPoolSpare And *JSWindow\Open
              claimedAndOpen = #True
            EndIf

            CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
              If Not claimedAndOpen
                ; Use Cocoa to hide - orderOut removes from screen without affecting PB state
                CocoaMessage(0, PrepWinID, "orderOut:", #Null)
              EndIf
              ; Restore alpha to 1.0
              Protected restoreAlpha.d = 1.0
              CocoaMessage(0, PrepWinID, "setAlphaValue:@", @restoreAlpha)
            CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
              ; Hide FIRST (unconditionally — in the claimed race the window is
              ; still cloaked-invisible, so this hide cannot flicker), then
              ; strip every prepare-time invisibility measure while nothing can
              ; be presented. Uncloak LAST among the restores so any paint
              ; triggered by the style change is still guarded. The claimed
              ; race is re-shown below, after the position restore.
              HideWindow(*JSWindow\Window, #True)
              Protected prepStyle = GetWindowLongPtr_(PrepWinID, #GWL_EXSTYLE)
              SetWindowLongPtr_(PrepWinID, #GWL_EXSTYLE, prepStyle & ~#WS_EX_TOOLWINDOW)
              SetLayeredWindowAttributes_(PrepWinID, 0, 255, #LWA_ALPHA)
              SetWindowCloak(PrepWinID, #False)
            CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
              If Not claimedAndOpen
                HideWindow(*JSWindow\Window, #True)
              EndIf
              ; The other half of the pair: undoes the opacity 0 set in
              ; PrepareJSWindow. Imported, not the built-in — see the ImportC
              ; block near gtk_window_begin_move_drag.
              gtk_widget_set_opacity(PrepWinID, 1.0)
            CompilerEndIf

            ; Restore position — use cascade target if OpenInstance set one, otherwise
            ; the pre-prepare origin (the window was moved off-screen during preparation).
            If *JSWindow\HasCascadePosition
              ResizeWindow(*JSWindow\Window, *JSWindow\CascadeX, *JSWindow\CascadeY, #PB_Ignore, #PB_Ignore)
            Else
              ResizeWindow(*JSWindow\Window, *JSWindow\PrepareOriginalX, *JSWindow\PrepareOriginalY, #PB_Ignore, #PB_Ignore)
            EndIf

            ; If the race fired (window was opened while still being prepared),
            ; now that alpha and position are correct, raise the window to front.
            If claimedAndOpen
              Debug "[Event_Prepare_Complete] Race: window was claimed mid-prepare — raising to front"
              CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
                Protected raceNsApp = CocoaMessage(0, 0, "NSApplication sharedApplication")
                CocoaMessage(0, raceNsApp, "activateIgnoringOtherApps:", #True)
                CocoaMessage(0, PrepWinID, "makeKeyAndOrderFront:", #Null)
              CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
                ; Re-show after the WS_EX_TOOLWINDOW strip happened while
                ; hidden — the shell re-evaluates taskbar presence on this
                ; hidden->shown transition, so the button (re)appears. The
                ; window is uncloaked, alpha 255 and at its final position:
                ; it appears fully formed.
                HideWindow(*JSWindow\Window, #False)
                SetForegroundWindow_(PrepWinID)
              CompilerEndIf
            EndIf

            Debug "[Event_Prepare_Complete] Done for " + *JSWindow\Name
            
        EndSelect 
        
    EndSelect
    
    If closeWindow
      Debug "[JSWindow] HandleEvent CLOSE: window='" + *JSWindow\Name + "' BypassCloseCheck=" + Str(*JSWindow\BypassCloseCheck) + " Behaviour=" + Str(*JSWindow\CloseBehaviour) + " Open=" + Str(*Window\Open)

      ; --- INTERCEPT CLOSE ---
      If Not *JSWindow\BypassCloseCheck
        Debug "Check needed"
        If RequestClose(*JSWindow\Window)
           ; If returns true, no checks were needed (e.g. not visible or already bypassed? wait logic says if Request returns True it means we can proceed immediately?)
           ; RequestClose will send checks and return False if checks are PENDING.
           ; If it returns True, it means either no windows in scope or all already bypassed?
           ; Actually, RequestClose sets ClosingScope. If it returns True, it means nothing to check.
           ; But we should double check if we can close.
           ; If RequestClose returns True, it means "Go ahead". But for normal close we usually consume the event.
           
           ; If this is a distinct event, let's allow it to fall through?
           ; Wait, if RequestClose(ID) returns True, it means no children blocked us (or no children exist to check).
           ; So we can proceed.
        Else
           ProcedureReturn #True ; Consume event, wait for reply
        EndIf 
      EndIf
      ; -----------------------
      
      If *JSWindow\CloseBehaviour = #JSWindow_Behaviour_CloseWindow
        Debug "CLOSE"
        CloseManagedWindow(*Window)
      Else
        Debug "HIDE"
        HideChildWindows(*Window)
        HideManagedWindow(*Window)
      EndIf 
    EndIf    
    
    ProcedureReturn #True
  EndProcedure
  
  
  
  
  
  
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    
    Procedure WindowCallback(hWnd, uMsg, WParam, LParam) 
      Protected w, h
      
      *Window.AppWindow =  GetManagedWindowFromWindowHandle(hWnd)
      
      If *Window = 0
        ProcedureReturn #PB_ProcessPureBasicEvents 
      EndIf 
      
      Select uMsg

        Case #WM_SIZE , #WM_SIZING
          w = WindowWidth(*Window\Window)
          h = WindowHeight(*Window\Window)
          UpdateWebViewScale(JSWindows(Str(*Window\Window)), w, h)
          ; Live-drain subscribers (e.g. PTY output) on every size step so terminal
          ; content tracks the drag instead of flooding in on mouse-up. This proc
          ; is invoked by Windows directly during the modal loop, so the hook runs
          ; even though PB's own event loop is suspended.
          If ResizeDrainHook : CallFunctionFast(ResizeDrainHook) : EndIf
          ProcedureReturn #True

        Case $0231 ; WM_ENTERSIZEMOVE — modal loop begins
          Debug "[JSWIN-CB] WM_ENTERSIZEMOVE hwnd=" + Str(hWnd) + " t=" + Str(ElapsedMilliseconds())
          ; Cover the held-still case (no WM_SIZE): WM_TIMER is the only message
          ; this proc receives during an otherwise idle modal loop.
          SetTimer_(hWnd, #JSWIN_RESIZE_DRAIN_TIMER, #JSWIN_RESIZE_DRAIN_INTERVAL, #Null)

        Case #WM_TIMER
          If WParam = #JSWIN_RESIZE_DRAIN_TIMER And ResizeDrainHook
            CallFunctionFast(ResizeDrainHook)
          EndIf

        Case $0232 ; WM_EXITSIZEMOVE — modal loop ends
          Debug "[JSWIN-CB] WM_EXITSIZEMOVE hwnd=" + Str(hWnd) + " t=" + Str(ElapsedMilliseconds())
          KillTimer_(hWnd, #JSWIN_RESIZE_DRAIN_TIMER)
          If ResizeDrainHook : CallFunctionFast(ResizeDrainHook) : EndIf

      EndSelect

      ProcedureReturn #PB_ProcessPureBasicEvents
    EndProcedure
  CompilerEndIf
  
  
  ; Last resort: reveal a window whose page never reported content-ready. Runs
  ; on the MAIN thread (called from OpenJSWindow): the deadline is read here —
  ; a deferred-ready page is expected to take longer, and firing at the
  ; default 600 ms would show the blank frame the deferral was introduced to
  ; prevent — and only the sleep is threaded. The post-sleep "did the page
  ; report ready meanwhile?" check lives in the #Event_Force_Content_Visible
  ; handler, so no worker thread ever reads JSWindows().
  Procedure ForceContentVisible(window)
    Protected deadline = #PBJS_RevealWatchdogMs
    If FindMapElement(JSWindows(), Str(window))
      If JSWindows()\DeferContentReady
        deadline = #PBJS_DeferredRevealWatchdogMs
      EndIf
    EndIf

    PostEventAfterDelay(window, deadline, #Event_Force_Content_Visible)
  EndProcedure


  ; ===========================================================================
  ;- HEADLESS (WEB-MODE) ATTACH / DETACH
  ; ===========================================================================
  ; A browser tab (re)connected for a headless window. Replays the EXACT
  ; dev-reload bootstrap this module already uses for Vite-served pages (the
  ; #PBJS_DevMode retry block above): binds first, then __pbjsAdded reset,
  ; PreRenderJS (window.startupSettings), StartupJS (pbjsDocumentReady →
  ; callbackReadyState), WindowJS, and the pbjs bridge script. Everything
  ; after that — JSReadyState → Ready → FlushPendingMessages → Content_Ready →
  ; WindowLoaded — is the untouched existing handshake.
  Procedure HandleHeadlessAttach(windowName.s)
    If Not FindMapElement(WindowsByName(), windowName)
      Debug "[JSWindow] HandleHeadlessAttach: unknown window '" + windowName + "'"
      ProcedureReturn
    EndIf
    Protected window.i = WindowsByName()
    Protected *JSWindow.JSWindow = JSWindows(Str(window))
    If *JSWindow = 0 Or Not *JSWindow\Headless
      Debug "[JSWindow] HandleHeadlessAttach: '" + windowName + "' is not headless"
      ProcedureReturn
    EndIf

    ; Re-attach (tab reload / takeover): same semantics as a dev-mode page
    ; reload — reset readiness and orphan-reject peers' in-flight requests.
    If *JSWindow\Ready
      Debug "[JSWindow] HandleHeadlessAttach: re-attach for '" + windowName + "' — resetting Ready"
      *JSWindow\Ready = #False
      JSBridge::NotifyWindowEvent(windowName, "reloaded")
    EndIf

    ; 1. Shims first, so StartupJS's callbackReadyState poll finds its target.
    Sink::ReplayBinds(windowName)

    ; 2..5. The dev-reload injection sequence, byte-identical script content.
    Sink::Exec(*JSWindow\Sink, "window.__pbjsAdded = false;")
    Sink::Exec(*JSWindow\Sink, *JSWindow\PreRenderJS)
    PreparePbjsBasicScript(*JSWindow)
    Sink::Exec(*JSWindow\Sink, *JSWindow\StartupJS)
    Sink::Exec(*JSWindow\Sink, *JSWindow\WindowJS)
    Sink::Exec(*JSWindow\Sink, JSBridge::GetStartUpJS(windowName))

    Debug "[JSWindow] HandleHeadlessAttach: bootstrap sent to '" + windowName + "'"
  EndProcedure

  ; Tab closed / WS dropped: NOT a window close (terminals keep running,
  ; ownership stays — plan C11). Ready=#False makes the bridge buffer messages
  ; via the existing QueuePending path until the next attach replays them;
  ; peers orphan-reject their in-flight requests instead of waiting 30 s.
  Procedure HandleHeadlessDetach(windowName.s)
    If Not FindMapElement(WindowsByName(), windowName)
      ProcedureReturn
    EndIf
    Protected window.i = WindowsByName()
    Protected *JSWindow.JSWindow = JSWindows(Str(window))
    If *JSWindow And *JSWindow\Headless And *JSWindow\Ready
      *JSWindow\Ready = #False
      JSBridge::NotifyWindowEvent(windowName, "reloaded")
      Debug "[JSWindow] HandleHeadlessDetach: '" + windowName + "' marked not-ready"
    EndIf
  EndProcedure

EndModule
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 3058
; FirstLine = 97
; Folding = ----------
; EnableXP
; DPIAware