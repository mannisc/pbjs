
; =============================================================================
;- WINDOW MANAGER MODULE
; =============================================================================

DeclareModule WindowManager
  
  Prototype.i HandleMainEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i MaxSizeChangedEvent(*Window, widht, height)
  Prototype.i ProtoHideWindow(*Window)
  Prototype.i ProtoOpenWindow(*Window)
  Prototype.i ProtoHandleEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i ProtoCloseWindow(Window.i)
  Prototype.i ProtoCleanupWindow()

  Prototype.i ShouldKeepRunning()
  Prototype.i HandleNetworkEvent(netEvent.i, netClient.i)

  Structure AppWindow
    Title.s
    Window.i
    *HandleProc.ProtoHandleEvent
    *MaxSizeChangedProc.MaxSizeChangedEvent
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
  Declare CloseManagedWindow(*Window.AppWindow)
  Declare RunEventLoop(*HandleMainEvent.HandleMainEvent, *HandleNetworkEvent.HandleNetworkEvent = 0, *ShouldKeepRunning.ShouldKeepRunning = 0)
  Declare CleanupManagedWindows()
  Declare CloseManagedWindows()
  Declare GetManagedWindowFromWindowHandle(hWnd)
  Declare WindowMaxSizeChanged()
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
    ManagedWindowsHandles(Str(WindowID(window)))\Window = @ManagedWindows()
    
    If Not TimerAdded
      TimerAdded = #True
      AddWindowTimer(window, #Timer_CheckDesktop, 500)
    EndIf 
    
    ProcedureReturn @ManagedWindows()
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
              ; Now paint while it's "visible" (but off-screen)
              Protected rect.RECT
              Protected hdc = GetDC_(hWnd)
              GetClientRect_(hWnd, @rect)
              FillRect_(hdc, @rect, brush)
              ReleaseDC_(hWnd, hdc)
              UpdateWindow_(hWnd)
              RedrawWindow_(hWnd, #Null, #Null, #RDW_UPDATENOW | #RDW_ERASE | #RDW_INVALIDATE | #RDW_ALLCHILDREN)
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
      CloseManagedWindow(@ManagedWindows())
    Next
  EndProcedure
  
  
  
  Procedure CleanupManagedWindows()
    NewList Windows()
    ForEach ManagedWindows()
      If ManagedWindows()\Open
        AddElement(Windows())
        Windows() = ManagedWindows()\Window

        If ManagedWindows()\CloseProc
          CallFunctionFast(ManagedWindows()\CloseProc, ManagedWindows()\Window)
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
      ForEach ManagedWindows()
        If ManagedWindows()\HandleProc

          If Event = #CustomWindowEvent Or ManagedWindows()\Open
            If EventWindow = ManagedWindows()\Window And
               KeepWindow = CallFunctionFast(ManagedWindows()\HandleProc, @ManagedWindows(), Event,EventGadget,EventType)
              If Event = #PB_Event_CloseWindow
                Debug "[WM] HandleWindowEvent: dispatched close to '" + ManagedWindows()\Title + "' KeepWindow=" + Str(KeepWindow)
              EndIf
              If Not KeepWindow
                Debug "[WM] HandleWindowEvent: DeleteElement for '" + ManagedWindows()\Title + "'"
                DeleteElement(ManagedWindows())
                Break
              EndIf
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
      If Not OpenedWindowExists
        ForEach ManagedWindows()
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
  
  
  Procedure WindowMaxSizeChanged()
    ForEach ManagedWindows()
      If ManagedWindows()\Window And ManagedWindows()\MaxSizeChangedProc
        CallFunctionFast(ManagedWindows()\MaxSizeChangedProc)
      EndIf
    Next 
  EndProcedure 
EndModule

; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 4
; Folding = ---
; EnableXP
; DPIAware