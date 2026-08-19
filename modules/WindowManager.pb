
; =============================================================================
;- WINDOW MANAGER MODULE
; =============================================================================

DeclareModule WindowManager
  
  Prototype.i HandleMainEvent(Event.i, Window.i, Gadget.i, Type.i)
  ; Fired once (not per window) when the desktop bounding box GROWS — a display
  ; was attached, or the laptop was docked into a larger one. The webview
  ; gadgets are created at the startup maximum and must be re-sized to the new
  ; one, which is JSWindow's business, not this module's; JSWindow registers
  ; through SetMaxSizeChangedHandler below.
  ;
  ; This replaced a per-window *MaxSizeChangedProc field that NOTHING ever
  ; assigned — the poll detected the change and handed it to a null pointer, so
  ; docking into a bigger display left every webview smaller than its window
  ; could grow (a maximized window showed a bare stripe down the right/bottom).
  Prototype.i MaxSizeChangedHandler(width, height)
  Prototype.i ProtoHideWindow(*Window)
  Prototype.i ProtoOpenWindow(*Window)
  Prototype.i ProtoHandleEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i ProtoCloseWindow(Window.i)
  Prototype.i ProtoCleanupWindow()

  Prototype.i ShouldKeepRunning()
  Prototype.i HandleNetworkEvent(netEvent.i, netClient.i)

  ; Called just BEFORE a managed window's list element is physically freed, with
  ; the AppWindow pointer about to become invalid. Anything holding that pointer
  ; must drop it here — JSWindow registers a handler to null out its
  ; JSWindows()\Parent and JSTemplates()\Parent references.
  ;
  ; This hook is what makes removal safe at all. Until now the list never
  ; actually shrank (the DeleteElement guarding it was unreachable — see
  ; HandleWindowEvent), so raw AppWindow pointers stayed valid by accident.
  Prototype.i ManagedWindowRemoving(*Window)

  ; Re-check the OS theme (roadmap 2.4). A hook rather than a direct call into
  ; OsTheme, and NOT for tidiness:
  ;
  ; a host may include WindowManager.pb before pbjs.pb so its own modules can
  ; use it — README §2.1 documents exactly that, and Vynce does it — which puts
  ; this module in scope BEFORE OsTheme, whose include lives inside pbjs.pb.
  ; Reaching into OsTheme from here compiles fine standalone and fails in the
  ; host with "Module not found". JSWindow sees both and registers the response,
  ; the same way it already does for MaxSizeChangedHandler.
  Prototype.i ThemeRecheckHandler()

  Structure AppWindow
    Title.s
    Window.i
    ; Native handle, captured at AddManagedWindow time. WindowID() is
    ; unrecoverable once the window is closed, so the key needed to remove this
    ; window's ManagedWindowsHandles() entry has to be kept here — reading it at
    ; removal time is what made the old cleanup impossible.
    Hwnd.i
    ; Marked by ForgetManagedWindow, freed by SweepRemovedWindows. Removal is
    ; deferred because callers are almost always inside a ForEach over this very
    ; list (HandleWindowEvent → HandleEvent → CloseJSWindow).
    PendingRemoval.b
    *HandleProc.ProtoHandleEvent
    *HideProc.ProtoHideWindow
    *CloseProc.ProtoCloseWindow
    *CleanupProc.ProtoCleanupWindow
    UserData.i
    Open.b
    Closed.b
    WasOpen.b
    OpenMaximized.b  ; one-shot: first show of this window happens maximized; the
                     ; window's creation x/y/w/h remain the OS restore bounds
  EndStructure
  
  Declare InitWindowManager()
  Declare AddManagedWindow(Title.s, window, *HandleProc,*HideProc = 0, *CloseProc = 0, *CleanupProc = 0)
  Declare OpenManagedWindow(*Window.AppWindow,manualOpen=#False)
  Declare HideManagedWindow(*Window.AppWindow)
  Declare HideAllManagedWindows()
  Declare CloseManagedWindow(*Window.AppWindow)
  Declare RunEventLoop(*HandleMainEvent.HandleMainEvent, *HandleNetworkEvent.HandleNetworkEvent = 0, *ShouldKeepRunning.ShouldKeepRunning = 0)
  Declare CleanupManagedWindows()
  Declare CloseManagedWindows()
  Declare GetManagedWindowFromWindowHandle(hWnd)
  ; Drop a window from the registries. Call this ONLY when the window is really
  ; destroyed — never for a window that is merely hidden, and in particular
  ; never for a pool spare or a recycled template instance, which are hidden and
  ; reused and must keep both their registry entries. JSWindow calls it from the
  ; teardown branch of CloseJSWindow, past the recycle early-return.
  Declare ForgetManagedWindow(*Window.AppWindow)
  Declare SetManagedWindowRemovingHandler(*proc)
  Declare SweepRemovedWindows()
  Declare WindowMaxSizeChanged()
  ; Install the desktop-grew handler (see Prototype MaxSizeChangedHandler).
  ; One handler for the whole app; JSWindow registers itself.
  Declare SetMaxSizeChangedHandler(*proc)
  ; Install the theme re-check (see Prototype ThemeRecheckHandler).
  Declare SetThemeRecheckHandler(*proc)
  Declare UpdateMaxDesktopSize()
  ; Everything the periodic tick does — re-read the desktop bounding box, and
  ; (macOS/Windows) re-check the OS theme. Exported because the Windows display
  ; watcher has to live in JSWindow::WindowCallback: WM_DISPLAYCHANGE needs a
  ; window procedure and there is only one SetWindowCallback slot per window.
  Declare ServiceTick()
  Declare HandleWindowEvent(Event, EventWindow, EventGadget,EventType)

  ; --- Delayed events (roadmap 2.5) -----------------------------------------
  ; Post `eventType` as a #CustomWindowEvent to `window` after `delayMs`.
  ;
  ; This used to spawn a THREAD PER CALL whose entire job was to sleep and then
  ; PostEvent — two to four of them per window prepare/open. Now it is one entry
  ; in a main-thread deadline list that RunEventLoop services, and the wait it
  ; is about to do is shortened to the nearest deadline. No threads, and — the
  ; actual point — the entries are CANCELLABLE, so a timer can no longer outlive
  ; its window and land on a recycled window number.
  ;
  ; ⚠ MAIN THREAD ONLY. The old spawner was too (it resolved everything into
  ; *Args before the thread started); this is now load-bearing rather than
  ; incidental, because the list itself is unsynchronised.
  Declare PostEventAfterDelay(window, delayMs, eventType)
  ; Drop every pending delayed event for a window. Called from
  ; ForgetManagedWindow, which is what makes "cancelled when its window closes"
  ; true rather than aspirational.
  Declare CancelDelayedEvents(window)
  ; Drop only the pending events of one kind for a window — for a re-arm, where
  ; the previous round's timer must not also fire.
  Declare CancelDelayedEvent(window, eventType)
  Declare.i PendingDelayedEventCount()
  ; Fire everything due; answer how many ms until the next one (0 = none
  ; pending). RunEventLoop calls this; exposed for the test harness.
  Declare.i ServiceDelayedEvents()

  ; --- Idle behaviour (roadmap 2.2) -----------------------------------------
  ; How long RunEventLoop may sleep when nothing else bounds the wait.
  ;
  ; 0 means "block until an event arrives" — the ideal, and NOT the default,
  ; because ShouldKeepRunning is a host callback that has always been polled
  ; every tick and real hosts put deadline checks in it (Vynce's quit path times
  ; out an unresponsive renderer there). Blocking would stop calling it, and the
  ; app would hang at quit instead of timing out. So: 250 ms by default when a
  ; ShouldKeepRunning hook is registered, and set this to 0 once you have
  ; checked that yours is purely reactive.
  ;
  ; With no ShouldKeepRunning and no network hook, nothing in the loop is polled
  ; and it blocks regardless of this value.
  Declare SetIdleTimeout(ms)
  ; How often NetworkServerEvent() is polled when a network hook is registered.
  Declare SetNetworkPollInterval(ms)
  
  Global DesktopCount = ExamineDesktops()
  Global DPI_Scale
  Global MaxDesktopWidth = 0
  Global MaxDesktopHeight = 0 
  Global TimerAdded = #False 
  
  Enumeration #PB_Event_FirstCustomValue
    #CustomWindowEvent
  EndEnumeration
EndDeclareModule

Module WindowManager
  
  
  
  ; The service tick. Was a 500 ms poll that existed only to call
  ; ExamineDesktops(); roadmap 2.3 made the monitor-topology change event-driven
  ; (see InitPlatformWatchers), so this is now the BELT-AND-BRACES path, not the
  ; primary one — hence 5 s rather than 0.5. It is deliberately kept rather than
  ; deleted: the native subscriptions are per-OS and only one of the three could
  ; be tested where this was written, and a topology change that the OS hook
  ; misses would otherwise be invisible forever.
  ;
  ; It carries the theme re-check too (roadmap 2.4) on the platforms where
  ; detection is cheap. See ServiceTick.
  #Timer_CheckDesktop = 1
  #ServiceTickIntervalMs = 5000
  
  Structure HandleInfo
    *Window
  EndStructure 
  
  
  Global OSVersion = OSVersion()

  ; Set via SetMaxSizeChangedHandler; called by WindowMaxSizeChanged.
  Global MaxSizeChangedProc.MaxSizeChangedHandler = 0

  ; Set via SetThemeRecheckHandler; called by ServiceTick and the per-OS theme
  ; watchers. See the Prototype for why this cannot be a direct call.
  Global ThemeRecheckProc.ThemeRecheckHandler = 0

  ; Set via SetManagedWindowRemovingHandler; called by SweepRemovedWindows.
  Global ManagedWindowRemovingProc.ManagedWindowRemoving = 0
  ; Non-zero only while removals are outstanding, so the per-tick sweep is a
  ; single integer test in the overwhelmingly common case.
  Global PendingRemovalCount = 0
  ; Which PB window currently carries #Timer_CheckDesktop. The timer belongs to
  ; a window, so it dies with it — if that window is the one being removed, the
  ; desktop poll has to be re-homed or it stops silently (and with it the
  ; monitor-topology response).
  Global TimerWindow = 0
  ; Set when the window carrying #Timer_CheckDesktop is removed; consumed by
  ; SweepRemovedWindows, which re-arms the timer on a surviving window.
  Global TimerNeedsRehome = #False

  ; ---------------------------------------------------------------------------
  ;- Delayed events — one main-thread deadline list  (roadmap 2.5)
  ; ---------------------------------------------------------------------------
  ; Replaces JSWindow's thread-per-delay. See the note on PostEventAfterDelay in
  ; the DeclareModule for why cancellation is the point rather than the thread
  ; count.
  Structure DelayedEvent
    Window.i
    EventType.i
    DueAt.q
  EndStructure
  Global NewList DelayedEvents.DelayedEvent()

  ; How long the loop may sleep with nothing else bounding it. See SetIdleTimeout.
  Global IdleTimeoutMs = 250
  Global NetworkPollMs = 100

  Procedure SetIdleTimeout(ms)
    If ms < 0 : ms = 0 : EndIf
    IdleTimeoutMs = ms
  EndProcedure

  Procedure SetNetworkPollInterval(ms)
    If ms < 1 : ms = 1 : EndIf
    NetworkPollMs = ms
  EndProcedure

  Procedure PostEventAfterDelay(window, delayMs, eventType)
    If delayMs < 0 : delayMs = 0 : EndIf
    LastElement(DelayedEvents())
    AddElement(DelayedEvents())
    DelayedEvents()\Window    = window
    DelayedEvents()\EventType = eventType
    DelayedEvents()\DueAt     = ElapsedMilliseconds() + delayMs
  EndProcedure

  Procedure CancelDelayedEvents(window)
    ; Index-walked for the same reason SweepRemovedWindows is: PureBasic's
    ; DeleteElement leaves the current-element pointer somewhere version-
    ; dependent, and this must not depend on which.
    Protected i = 0
    While i < ListSize(DelayedEvents())
      SelectElement(DelayedEvents(), i)
      If DelayedEvents()\Window = window
        DeleteElement(DelayedEvents())
      Else
        i + 1
      EndIf
    Wend
  EndProcedure

  Procedure CancelDelayedEvent(window, eventType)
    Protected i = 0
    While i < ListSize(DelayedEvents())
      SelectElement(DelayedEvents(), i)
      If DelayedEvents()\Window = window And DelayedEvents()\EventType = eventType
        DeleteElement(DelayedEvents())
      Else
        i + 1
      EndIf
    Wend
  EndProcedure

  Procedure.i PendingDelayedEventCount()
    ProcedureReturn ListSize(DelayedEvents())
  EndProcedure

  Procedure.i ServiceDelayedEvents()
    If ListSize(DelayedEvents()) = 0
      ProcedureReturn 0
    EndIf

    Protected now.q = ElapsedMilliseconds()
    Protected nextIn.q = -1
    Protected remaining.q
    Protected w.i, t.i
    Protected i = 0

    While i < ListSize(DelayedEvents())
      SelectElement(DelayedEvents(), i)
      If DelayedEvents()\DueAt <= now
        w = DelayedEvents()\Window
        t = DelayedEvents()\EventType
        ; Remove BEFORE posting: the handler for this event may itself schedule
        ; another one, and it must not be looking at an entry that is about to
        ; be deleted underneath it.
        DeleteElement(DelayedEvents())
        If IsWindow(w)
          PostEvent(#CustomWindowEvent, w, 0, t)
        EndIf
      Else
        remaining = DelayedEvents()\DueAt - now
        If nextIn < 0 Or remaining < nextIn
          nextIn = remaining
        EndIf
        i + 1
      EndIf
    Wend

    If nextIn < 0
      ProcedureReturn 0
    EndIf
    ; Never answer 0 for "there is one pending" — 0 is the caller's signal to
    ; sleep without a deadline.
    If nextIn < 1
      nextIn = 1
    EndIf
    ProcedureReturn nextIn
  EndProcedure


  Declare InitPlatformWatchers()
  Declare ServiceTick()
  Declare RecheckTheme()

  Procedure InitWindowManager()
    Global NewMap ManagedWindowsHandles.HandleInfo()
    Global NewList ManagedWindows.AppWindow()
    UpdateMaxDesktopSize()
    InitPlatformWatchers()
  EndProcedure 
  
  
  Procedure.i AddManagedWindow(Title.s, window, *HandleProc,*HideProc = 0, *CloseProc = 0, *CleanupProc = 0)
    AddElement(ManagedWindows())
    ManagedWindows()\Title = Title
    ManagedWindows()\Window = window
    ManagedWindows()\HandleProc = *HandleProc
    ManagedWindows()\HideProc = *HideProc
    ManagedWindows()\CloseProc = *CloseProc
    ManagedWindows()\CleanupProc = *CleanupProc
    ManagedWindows()\Hwnd = WindowID(window)
    ManagedWindows()\PendingRemoval = #False
    ManagedWindowsHandles(Str(ManagedWindows()\Hwnd))\Window = @ManagedWindows()

    If Not TimerAdded
      TimerAdded = #True
      TimerWindow = window
      AddWindowTimer(window, #Timer_CheckDesktop, #ServiceTickIntervalMs)
    EndIf

    ProcedureReturn @ManagedWindows()
  EndProcedure

  Procedure SetManagedWindowRemovingHandler(*proc)
    ManagedWindowRemovingProc = *proc
  EndProcedure

  ; Take a destroyed window out of the registries.
  ;
  ; ⚠ Destroyed, not hidden. A pool spare and a recycled template instance are
  ; both hidden-but-alive and are re-shown later by OpenInstance; calling this
  ; for one of those would strip the handle-map entry that routes its native
  ; events and leave the pool holding a window the manager no longer knows.
  ; CloseJSWindow's recycle path returns before the teardown that calls this.
  Procedure ForgetManagedWindow(*Window.AppWindow)
    If *Window = 0 Or *Window\PendingRemoval
      ProcedureReturn
    EndIf

    ; Keyed by the handle captured at Add time: WindowID() cannot be read back
    ; once the window is gone, and this map is the one that actually bites —
    ; the OS recycles native handles, so a stale entry lets a NEW window alias a
    ; dead AppWindow and route its events into freed memory.
    If *Window\Hwnd And FindMapElement(ManagedWindowsHandles(), Str(*Window\Hwnd))
      DeleteMapElement(ManagedWindowsHandles(), Str(*Window\Hwnd))
    EndIf

    ; The desktop poll lives on ONE window (whichever was added first), so it
    ; dies with that window and nothing reports a timer that stopped. Only flag
    ; it here — re-homing has to look at the list, and every caller of this
    ; procedure is already inside a ForEach over it. PureBasic lists have a
    ; single current-element pointer, so a nested walk would derail the outer
    ; loop. SweepRemovedWindows does the re-home, outside any iteration and
    ; after the dead entries are actually gone.
    If TimerAdded And TimerWindow = *Window\Window
      TimerWindow = 0
      TimerNeedsRehome = #True
    EndIf

    ; 2.5: the window is going away, so nothing may still be scheduled to post
    ; at it. This is what "cancellable when their window closes" means — and
    ; what removes the reason the latches (PrepareWaiting) had to exist: a stale
    ; post can no longer land on a recycled window number, because it no longer
    ; exists to land.
    CancelDelayedEvents(*Window\Window)

    *Window\PendingRemoval = #True
    PendingRemovalCount + 1
  EndProcedure

  ; Physically free everything ForgetManagedWindow marked. Runs from the event
  ; loop, i.e. outside any ForEach over ManagedWindows() — which is the whole
  ; reason removal is two-phase.
  Procedure SweepRemovedWindows()
    If PendingRemovalCount = 0
      ProcedureReturn
    EndIf

    ; Index-walked rather than ForEach: PureBasic's DeleteElement leaves the
    ; current-element pointer somewhere version-dependent, and this loop must
    ; not depend on which.
    Protected i = 0
    While i < ListSize(ManagedWindows())
      SelectElement(ManagedWindows(), i)
      If ManagedWindows()\PendingRemoval
        ; Last chance for anyone holding this pointer to drop it — after
        ; DeleteElement it is freed memory (JSWindow\Parent, JSTemplates\Parent).
        If ManagedWindowRemovingProc
          ManagedWindowRemovingProc(@ManagedWindows())
        EndIf
        Debug "[WM] SweepRemovedWindows: freeing '" + ManagedWindows()\Title + "'"
        DeleteElement(ManagedWindows())
      Else
        i + 1
      EndIf
    Wend

    PendingRemovalCount = 0

    ; Re-arm the desktop poll on a survivor. Safe here and nowhere else: the
    ; dead records are gone, so this cannot pick a window that is about to be
    ; freed, and nothing is iterating the list.
    If TimerNeedsRehome
      TimerNeedsRehome = #False
      ForEach ManagedWindows()
        If IsWindow(ManagedWindows()\Window)
          TimerWindow = ManagedWindows()\Window
          AddWindowTimer(TimerWindow, #Timer_CheckDesktop, #ServiceTickIntervalMs)
          Break
        EndIf
      Next
      If TimerWindow = 0
        ; No window left to host it; the next AddManagedWindow re-arms.
        TimerAdded = #False
      EndIf
    EndIf
  EndProcedure
  
  Procedure OpenManagedWindow(*Window.AppWindow,manualOpen=#False)
    Debug "OPEN MANAGED WINDOW"
    
    If Not *Window\Open
      If IsWindow(*Window\Window)
        If Not manualOpen
          
          CompilerIf #PB_Compiler_OS = #PB_OS_Windows

            If *Window\OpenMaximized
              ; First show happens maximized: SW_SHOWMAXIMIZED on the (still
              ; invisible) window makes Windows record the creation x/y/w/h as
              ; rcNormalPosition, so the restore button returns to them. The
              ; Win11 off-screen paint trick below is skipped — its
              ; SetWindowPos(#SWP_NOSIZE) dance would corrupt maximized placement.
              *Window\OpenMaximized = #False
              *Window\WasOpen = #True
              ShowWindow_(WindowID(*Window\Window), #SW_SHOWMAXIMIZED)
            ElseIf *Window\WasOpen Or (OSVersion <> #PB_OS_Windows_11 And osVersion <> #PB_OS_Windows_Future)
              HideWindow(*Window\Window, #False)
            Else
              *Window\WasOpen = #True
              ; Basically just ShowWindow with fix to draw immiditaly correctly on fadeIn
              Protected hWnd = WindowID(*Window\Window)
              Protected winRect.RECT
              GetWindowRect_(hWnd, @winRect)

              ; Show window instantly (no animation) by positioning it off-screen
              Protected minValue = -1000000000 ;lowest min value possible
              SetWindowPos_(hWnd, 0, minValue, minValue, 0, 0, #SWP_NOSIZE | #SWP_NOZORDER | #SWP_SHOWWINDOW | #SWP_NOACTIVATE)
              ; Force a paint while the window is "visible" but off-screen.
              ;
              ; A GetDC/GetClientRect/FillRect/ReleaseDC block used to sit here.
              ; It was dead code: the brush it filled with was never assigned, so
              ; FillRect got a NULL HBRUSH and drew nothing. The two Redraw calls
              ; below are what actually paints, and they always were.
              UpdateWindow_(hWnd)
              RedrawWindow_(hWnd, #Null, #Null, #RDW_UPDATENOW | #RDW_ERASE | #RDW_INVALIDATE | #RDW_ALLCHILDREN)
              ; ⚠ Blocks the main thread for two frames. It buys the compositor
              ; time to present the off-screen paint before the move below, and
              ; it is the reason this path looks flash-free on Win11.
              ;
              ; STILL BLOCKING after 2.5, deliberately. The scheduler now exists
              ; and could carry it, but replacing it is not a swap: the second
              ; SetWindowPos_ would move into an event handler, so
              ; OpenManagedWindow would return with the window still parked at
              ; -1e9 and every caller that assumes it is placed on return would
              ; be wrong. That needs winRect parked on AppWindow, a new event
              ; type, a handler in JSWindow, and a Win11 machine to confirm the
              ; result still looks flash-free. Two of those three are cheap; the
              ; third is the one that matters, and it is not available here.
              Delay(32) ; 16 -  frame at 60fps
                        ; NOW move to correct position WITH animation
              SetWindowPos_(hWnd, 0, winRect\left, winRect\top, 0, 0, #SWP_NOSIZE | #SWP_NOZORDER | #SWP_SHOWWINDOW)
            EndIf
          CompilerElse

            If *Window\OpenMaximized
              ; Maximize while still hidden (gtk_window_maximize is legal pre-map;
              ; Cocoa zoom on an unordered window just sets the frame) so the
              ; window appears maximized with no normal-size flash.
              *Window\OpenMaximized = #False
              If GetWindowState(*Window\Window) <> #PB_Window_Maximize
                SetWindowState(*Window\Window, #PB_Window_Maximize)
              EndIf
            EndIf
            HideWindow(*Window\Window, #False)
          CompilerEndIf
        EndIf 
        *Window\Open = #True
        Debug *Window
        ProcedureReturn 1
      EndIf 
    EndIf
    ProcedureReturn 0
  EndProcedure
  
  Procedure HideManagedWindow(*Window.AppWindow)
    Debug "[WM] HideManagedWindow: title='" + *Window\Title + "' Open=" + Str(*Window\Open)
    If *Window\Window
      If *Window\HideProc
        CallFunctionFast(*Window\HideProc, *Window, #True )
        *Window\Open = #False

      EndIf
    EndIf
  EndProcedure

  ; App shutdown hides every live managed window in one native event turn, so
  ; the app disappears at once instead of window by window. Deliberately NOT a
  ; close: WebViews stay alive for a final JS acknowledgement. The caller must
  ; still run CloseManagedWindows() afterwards — hiding skips the per-window
  ; CloseProc that tears the WebView down.
  Procedure HideAllManagedWindows()
    ForEach ManagedWindows()
      If ManagedWindows()\PendingRemoval : Continue : EndIf
      If ManagedWindows()\Open
        HideManagedWindow(@ManagedWindows())
        ; A managed window without a HideProc would otherwise stay Open and
        ; keep the event loop (and the visible window) alive.
        If ManagedWindows()\Open And ManagedWindows()\Window
          HideWindow(ManagedWindows()\Window, #True)
          ManagedWindows()\Open = #False
        EndIf
      EndIf
    Next
  EndProcedure


  ; ⚠ Deliberately does NOT deregister the window, even though the name suggests
  ; it might. CloseProc is free to decide this "close" is really a RECYCLE:
  ; JSWindow's CloseJSWindow hides a template instance and hands it back to the
  ; pool, returning a live window that must keep both registry entries and will
  ; be re-shown by a later OpenInstance. Only the code that truly tears a window
  ; down knows the difference, so it calls ForgetManagedWindow itself.
  Procedure CloseManagedWindow(*Window.AppWindow)
    Debug "[WM] CloseManagedWindow: title='" + *Window\Title + "' Open=" + Str(*Window\Open)
    If *Window\Window
      *Window\Open = #False
      *Window\Closed = #True
      If *Window\CloseProc
        CallFunctionFast(*Window\CloseProc, *Window)
      EndIf
    EndIf
  EndProcedure
  
  Procedure CloseManagedWindows()
    ForEach ManagedWindows()
      If ManagedWindows()\PendingRemoval : Continue : EndIf
      CloseManagedWindow(@ManagedWindows())
    Next
  EndProcedure
  
  
  
  Procedure CleanupManagedWindows()
    NewList Windows()
    ForEach ManagedWindows()
      ; Already torn down and awaiting the sweep — its PB window is gone.
      If ManagedWindows()\PendingRemoval : Continue : EndIf
      If ManagedWindows()\Open
        AddElement(Windows())
        Windows() = ManagedWindows()\Window

        If ManagedWindows()\CloseProc
          CallFunctionFast(ManagedWindows()\CloseProc, @ManagedWindows())
        EndIf
      ElseIf Not ManagedWindows()\Closed
        ; Window was hidden (not destroyed) — add for explicit CloseWindow() to free WebViewGadget/WKWebView
        AddElement(Windows())
        Windows() = ManagedWindows()\Window
      Else
        ; Closed=True but window handle still valid: macOS deferred-close path hides instead
        ; of calling CloseWindow() during the event loop. Destroy it now (we're outside the loop).
        If IsWindow(ManagedWindows()\Window)
          AddElement(Windows())
          Windows() = ManagedWindows()\Window
        EndIf
      EndIf
      If ManagedWindows()\CleanupProc
        CallFunctionFast( ManagedWindows()\CleanupProc)
      EndIf
    Next
    
    endTime = ElapsedMilliseconds()
    Repeat
      Delay(10)
      ForEach Windows()
        If IsWindow(Windows())
          CloseWindow(Windows())
        EndIf
      Next
      windowExists = #False
      ForEach Windows()
        If IsWindow(Windows())
          windowExists = #True
          Break
        EndIf
      Next
      If windowExists
        WindowEvent()
      EndIf
    Until Not windowExists Or ElapsedMilliseconds()-endTime > 250
    
    
  EndProcedure
  
  ; Everything the periodic tick does. Also called directly by the per-OS
  ; watchers (InitPlatformWatchers), so the response is written once.
  Procedure ServiceTick()
    If UpdateMaxDesktopSize()
      WindowMaxSizeChanged()
    EndIf

    ; Theme re-check (roadmap 2.4) — only where detecting costs nothing.
    ;
    ; macOS reads NSApp.effectiveAppearance and Windows reads one registry
    ; value: both are in-process and cheap enough to do every 5 s. LINUX IS
    ; DELIBERATELY EXCLUDED — detection there shells out to gsettings twice and
    ; gdbus once in the worst case, and a fork every 5 s would be far worse than
    ; the problem 2.4 set out to fix. Linux gets the GTK signal instead, and if
    ; that does not fire the theme simply stays as detected at init, which is
    ; exactly today's behaviour.
    CompilerIf #PB_Compiler_OS <> #PB_OS_Linux
      RecheckTheme()
    CompilerEndIf
  EndProcedure

  ; ---------------------------------------------------------------------------
  ;- Per-OS watchers  (roadmap 2.3 display topology, 2.4 theme)
  ; ---------------------------------------------------------------------------
  ; What replaced the twice-a-second ExamineDesktops() poll, and what makes a
  ; mid-run OS theme flip visible at all — the bridge has shipped
  ; updateDarkMode() since the beginning with nothing on the native side ever
  ; calling it.
  ;
  ; Registered once, app-wide, from InitWindowManager. Every one of them is
  ; best-effort: if a lookup fails the watcher is simply not installed, and the
  ; 5 s service tick still covers topology everywhere and theme on
  ; macOS/Windows. Nothing here can leave the app worse off than the poll alone.
  ;
  ; Windows is NOT here — WM_DISPLAYCHANGE and WM_SETTINGCHANGE need a window
  ; procedure, there is exactly one SetWindowCallback slot per window, and
  ; JSWindow already owns it. Those two cases live in JSWindow::WindowCallback.

  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS

    ; Both are (id self, SEL _cmd, id notification) -> void, i.e. "v@:@".
    ProcedureC MacScreenParametersChanged(obj, sel, notification)
      ServiceTick()
    EndProcedure

    ProcedureC MacThemeChanged(obj, sel, notification)
      RecheckTheme()
    EndProcedure

    Procedure InitPlatformWatchers()
      Protected observerClass, observer, center

      ; Same allocate-or-fetch shape as JSWindow's resize observer: the class
      ; name is process-global, so a second registration must reuse the first.
      observerClass = objc_allocateClassPair_(objc_getClass_("NSObject"), "PBJSAppWatcher", 0)
      If observerClass
        class_addMethod_(observerClass, sel_registerName_("screenParametersChanged:"),
                         @MacScreenParametersChanged(), "v@:@")
        class_addMethod_(observerClass, sel_registerName_("themeChanged:"),
                         @MacThemeChanged(), "v@:@")
        objc_registerClassPair_(observerClass)
      Else
        observerClass = objc_getClass_("PBJSAppWatcher")
      EndIf
      If observerClass = 0
        ProcedureReturn
      EndIf

      observer = CocoaMessage(0, CocoaMessage(0, observerClass, "alloc"), "init")
      If observer = 0
        ProcedureReturn
      EndIf

      ; Display topology. NSApplication posts this to the DEFAULT centre
      ; whenever a screen is attached, removed, or its resolution changes.
      center = CocoaMessage(0, 0, "NSNotificationCenter defaultCenter")
      If center
        CocoaMessage(0, center,
                     "addObserver:", observer,
                     "selector:", sel_registerName_("screenParametersChanged:"),
                     "name:$", @"NSApplicationDidChangeScreenParametersNotification",
                     "object:", 0)
      EndIf

      ; Theme. This one is DISTRIBUTED, not the default centre — the flip
      ; happens in another process and is broadcast system-wide.
      ;
      ; ⚠ It can be delivered a beat before NSApp.effectiveAppearance has
      ; caught up, in which case this refresh reads the old value and does
      ; nothing. The 5 s service tick is what corrects that, which is one of
      ; the reasons it was kept rather than deleted.
      center = CocoaMessage(0, 0, "NSDistributedNotificationCenter defaultCenter")
      If center
        CocoaMessage(0, center,
                     "addObserver:", observer,
                     "selector:", sel_registerName_("themeChanged:"),
                     "name:$", @"AppleInterfaceThemeChangedNotification",
                     "object:", 0)
      EndIf
    EndProcedure

  CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux

    ; Imported rather than used through PureBasic's gtk_*_() built-ins, for the
    ; reason spelled out at length next to gtk_widget_set_opacity in
    ; JSWindow.pb: which built-ins a given PureBasic build declares varies, and
    ; ImportC does not depend on that.
    ImportC ""
      gtk_settings_get_default()
      gdk_screen_get_default()
      g_signal_connect_data(*instance, detailed_signal.p-utf8, *c_handler, *data, *destroy_data, flags.i)
    EndImport

    ProcedureC GtkMonitorsChanged(*screen, *data)
      ServiceTick()
    EndProcedure

    ProcedureC GtkThemeChanged(*settings, *pspec, *data)
      RecheckTheme()
    EndProcedure

    Procedure InitPlatformWatchers()
      Protected *screen, *settings

      *screen = gdk_screen_get_default()
      If *screen
        g_signal_connect_data(*screen, "monitors-changed", @GtkMonitorsChanged(), 0, 0, 0)
      EndIf

      ; The theme half. Linux is the platform where detection is expensive —
      ; up to three subprocesses — so this signal is the ONLY thing that
      ; re-checks it; ServiceTick deliberately skips Linux. If the signal never
      ; fires the theme stays as detected at init, which is what happened
      ; before 2.4 anyway.
      *settings = gtk_settings_get_default()
      If *settings
        g_signal_connect_data(*settings, "notify::gtk-application-prefer-dark-theme",
                              @GtkThemeChanged(), 0, 0, 0)
        g_signal_connect_data(*settings, "notify::gtk-theme-name",
                              @GtkThemeChanged(), 0, 0, 0)
      EndIf
    EndProcedure

  CompilerElse

    ; Windows: see JSWindow::WindowCallback (WM_DISPLAYCHANGE / WM_SETTINGCHANGE).
    Procedure InitPlatformWatchers()
    EndProcedure

  CompilerEndIf

  Procedure HandleWindowEvent(Event, EventWindow, EventGadget,EventType)
    If Event <> 0
      If Event = #PB_Event_Timer And EventTimer() = #Timer_CheckDesktop
        ServiceTick()
      EndIf
      If Event = #PB_Event_CloseWindow
        Debug "[WM] HandleWindowEvent: CLOSE for EventWindow=" + Str(EventWindow)
      EndIf
      Protected KeepWindow.i
      ForEach ManagedWindows()
        If ManagedWindows()\PendingRemoval : Continue : EndIf
        If ManagedWindows()\HandleProc

          ; #CustomWindowEvent reaches even a non-Open window on purpose: that is
          ; how a pool spare still receives #Event_Prepare_Complete and friends
          ; while it sits hidden and unclaimed.
          If Event = #CustomWindowEvent Or ManagedWindows()\Open
            If EventWindow = ManagedWindows()\Window
              ; This used to read `... And KeepWindow = CallFunctionFast(...)`,
              ; which in PureBasic is a COMPARISON, not an assignment. KeepWindow
              ; was always 0 there, so the test was `0 = <handler result>`; every
              ; handler returns #True, so the body below — including the removal
              ; — was unreachable. Written honestly it is a call, then a test.
              KeepWindow = CallFunctionFast(ManagedWindows()\HandleProc, @ManagedWindows(), Event, EventGadget, EventType)
              If Event = #PB_Event_CloseWindow
                Debug "[WM] HandleWindowEvent: dispatched close to '" + ManagedWindows()\Title + "' KeepWindow=" + Str(KeepWindow)
              EndIf
              If Not KeepWindow
                ; Deregister rather than DeleteElement here: we are inside the
                ; ForEach, and the handle map has to go with the list entry.
                Debug "[WM] HandleWindowEvent: forgetting '" + ManagedWindows()\Title + "'"
                ForgetManagedWindow(@ManagedWindows())
              EndIf
              Break
            EndIf
          EndIf
        EndIf
      Next

    EndIf
  EndProcedure

  ; How long the loop may sleep before it must look around again, ignoring any
  ; scheduled delayed event (RunEventLoop folds that in separately).
  ; 0 = nothing here is polled, sleep until an event arrives.
  Procedure.i IdleWaitMs(*HandleNetworkEvent, *ShouldKeepRunning)
    ; NetworkServerEvent() generates no window event, so it can only be found by
    ; looking. This is the one genuine poll left.
    If *HandleNetworkEvent <> 0
      ProcedureReturn NetworkPollMs
    EndIf
    ; ShouldKeepRunning is a host callback that has been called every tick since
    ; this loop existed, and hosts put deadline checks in it. Keep calling it on
    ; a cadence unless the host has said it is safe not to. See SetIdleTimeout.
    If *ShouldKeepRunning <> 0
      ProcedureReturn IdleTimeoutMs
    EndIf
    ProcedureReturn 0
  EndProcedure

  Procedure RunEventLoop(*HandleMainEvent.HandleMainEvent, *HandleNetworkEvent.HandleNetworkEvent = 0, *ShouldKeepRunning.ShouldKeepRunning = 0)
    Protected Event.i
    Protected EventWindow.i
    Protected EventGadget.i
    Protected KeepRunning.i = #True
    Protected KeepWindow.i
    Protected OpenedWindowExists.i
    Protected netEvent.i
    Protected netClient.i
    Protected waitMs.i
    Protected nextDelayed.i
    While KeepRunning
      ; Fire anything whose deadline has passed, and learn how long until the
      ; next one. Both happen before the wait so the wait can be shortened to it.
      nextDelayed = ServiceDelayedEvents()

      waitMs = IdleWaitMs(*HandleNetworkEvent, *ShouldKeepRunning)
      If nextDelayed > 0 And (waitMs <= 0 Or nextDelayed < waitMs)
        waitMs = nextDelayed
      EndIf

      If waitMs > 0
        Event = WaitWindowEvent(waitMs)
      ElseIf ListSize(ManagedWindows()) > 0
        ; Nothing is polled and there is a window to receive events on: sleep
        ; until one arrives. This is the idle case that used to wake ~60x/s
        ; forever. PostEvent and window timers both wake a blocked
        ; WaitWindowEvent, so the close watchdog, the pool refill and the
        ; service tick all still arrive.
        Event = WaitWindowEvent()
      Else
        ; No managed window left. WaitWindowEvent() with nothing to wait on is
        ; not a defined place to block, and the exit test below is the only
        ; thing that can end the loop now — so take a short turn instead.
        Event = WaitWindowEvent(50)
      EndIf

      ; Drain the network queue rather than taking one event per wake: at a
      ; 100 ms poll a burst would otherwise serialise at 10 events/second.
      If *HandleNetworkEvent <> 0
        netEvent = NetworkServerEvent()
        While netEvent <> 0
          netClient = EventClient()
          CallFunctionFast(*HandleNetworkEvent, netEvent, netClient)
          netEvent = NetworkServerEvent()
        Wend
      EndIf

      If Event <> 0
        EventWindow = EventWindow()
        EventGadget = EventGadget()
        EventType = EventType()
        If *HandleMainEvent = 0 Or *HandleMainEvent( Event, EventWindow, EventGadget, EventType) = 0
          HandleWindowEvent(Event, EventWindow, EventGadget,EventType)   
        EndIf 
      EndIf 
      OpenedWindowExists = #False
      
      If *ShouldKeepRunning <> 0
        OpenedWindowExists = CallFunctionFast(*ShouldKeepRunning) 
      EndIf 
      ; Free anything deregistered during this tick's dispatch. Must happen
      ; here: every caller of ForgetManagedWindow is itself inside a ForEach
      ; over ManagedWindows(), so the actual DeleteElement cannot run there.
      SweepRemovedWindows()

      If Not OpenedWindowExists
        ForEach ManagedWindows()
          If ManagedWindows()\PendingRemoval : Continue : EndIf
          If ManagedWindows()\Open
            OpenedWindowExists = #True
            Break
          EndIf
        Next 
        If Not OpenedWindowExists Or ListSize(ManagedWindows()) = 0
          Debug "[WM] RunEventLoop EXIT: OpenedWindowExists=" + Str(OpenedWindowExists) + " ListSize=" + Str(ListSize(ManagedWindows()))
          ForEach ManagedWindows()
            Debug "[WM]   window='" + ManagedWindows()\Title + "' Open=" + Str(ManagedWindows()\Open) + " Closed=" + Str(ManagedWindows()\Closed)
          Next
          KeepRunning = #False
        EndIf
      EndIf 
      
      
    Wend
    
  EndProcedure
  
  
  
  Procedure GetManagedWindowFromWindowHandle(hWnd)
    If FindMapElement(ManagedWindowsHandles(),Str(hwnd))
      ProcedureReturn ManagedWindowsHandles(Str(hwnd))\Window
    EndIf 
    ProcedureReturn 0
  EndProcedure 
  
  ; Find the largest desktop dimensions
  Procedure UpdateMaxDesktopSize()
    Protected newMaxWidth = 0
    Protected newMaxHeight = 0
    Protected DesktopCount = ExamineDesktops()
    
    For i = 0 To DesktopCount - 1
      If DesktopWidth(i) > newMaxWidth
        newMaxWidth = DesktopWidth(i)
      EndIf
      If DesktopHeight(i) > newMaxHeight
        newMaxHeight = DesktopHeight(i)
      EndIf
    Next
    
    ; Check if size changed
    If newMaxWidth <> MaxDesktopWidth Or newMaxHeight <> MaxDesktopHeight
      MaxDesktopWidth = newMaxWidth
      MaxDesktopHeight = newMaxHeight
      ProcedureReturn #True
    EndIf
    
    ProcedureReturn #False
  EndProcedure
  
  
  Procedure SetMaxSizeChangedHandler(*proc)
    MaxSizeChangedProc = *proc
  EndProcedure

  Procedure SetThemeRecheckHandler(*proc)
    ThemeRecheckProc = *proc
  EndProcedure

  Procedure RecheckTheme()
    If ThemeRecheckProc
      ThemeRecheckProc()
    EndIf
  EndProcedure

  Procedure WindowMaxSizeChanged()
    If MaxSizeChangedProc
      CallFunctionFast(MaxSizeChangedProc, MaxDesktopWidth, MaxDesktopHeight)
    EndIf
  EndProcedure
EndModule

; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 4
; Folding = ---
; EnableXP
; DPIAware
