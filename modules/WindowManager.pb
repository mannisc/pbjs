
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
  Declare UpdateMaxDesktopSize()
  Declare HandleWindowEvent(Event, EventWindow, EventGadget,EventType)
  
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
  
  
  
  #Timer_CheckDesktop = 1
  
  Structure HandleInfo
    *Window
  EndStructure 
  
  
  Global OSVersion = OSVersion()

  ; Set via SetMaxSizeChangedHandler; called by WindowMaxSizeChanged.
  Global MaxSizeChangedProc.MaxSizeChangedHandler = 0

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


  Procedure InitWindowManager()
    Global NewMap ManagedWindowsHandles.HandleInfo()
    Global NewList ManagedWindows.AppWindow()
    UpdateMaxDesktopSize()
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
      AddWindowTimer(window, #Timer_CheckDesktop, 500)
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
          AddWindowTimer(TimerWindow, #Timer_CheckDesktop, 500)
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
              ; it is the reason this path looks flash-free on Win11. Left as-is
              ; deliberately: it is a timing value on a platform not available
              ; here, so changing it would be a guess dressed as a cleanup.
              ; Revisit with 2.5 (the scheduler), which can replace the block
              ; with a deferred event instead of shortening it.
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
  
  Procedure HandleWindowEvent(Event, EventWindow, EventGadget,EventType)
    If Event <> 0
      If Event = #PB_Event_Timer And EventTimer() = #Timer_CheckDesktop
        If UpdateMaxDesktopSize()
          WindowMaxSizeChanged()
        EndIf
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

  Procedure RunEventLoop(*HandleMainEvent.HandleMainEvent, *HandleNetworkEvent.HandleNetworkEvent = 0, *ShouldKeepRunning.ShouldKeepRunning = 0)
    Protected Event.i
    Protected EventWindow.i
    Protected EventGadget.i
    Protected KeepRunning.i = #True
    Protected KeepWindow.i
    Protected OpenedWindowExists.i
    Protected netEvent.i
    Protected netClient.i
    While KeepRunning
      Event = WaitWindowEvent(16)

      ; Dispatch network events — see Execute::HandleNetworkEvent in main.pb
      netEvent = NetworkServerEvent()
      If netEvent <> 0
        netClient = EventClient()
        If *HandleNetworkEvent <> 0
          CallFunctionFast(*HandleNetworkEvent, netEvent, netClient)
        EndIf
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
