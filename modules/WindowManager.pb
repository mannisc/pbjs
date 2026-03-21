
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
            
            If  *Window\WasOpen Or (OSVersion <> #PB_OS_Windows_11 And osVersion <> #PB_OS_Windows_Future)
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
    Debug "HideManagedWindow"
    If *Window\Window
      If *Window\HideProc
        CallFunctionFast(*Window\HideProc, *Window, #True )
        *Window\Open = #False    
        
      EndIf
    EndIf
  EndProcedure
  
  
  Procedure CloseManagedWindow(*Window.AppWindow)
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
      ForEach ManagedWindows()
        If ManagedWindows()\HandleProc
          
          If Event = #CustomWindowEvent Or ManagedWindows()\Open     
            If EventWindow = ManagedWindows()\Window And 
               KeepWindow = CallFunctionFast(ManagedWindows()\HandleProc, @ManagedWindows(), Event,EventGadget,EventType)
              If Not KeepWindow
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