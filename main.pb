
; =============================================================================
;- WINDOW MANAGER MODULE
; =============================================================================

DeclareModule WindowManager
  
  Prototype.i HandleMainEvent(Event.i, Window.i, Gadget.i)
  Prototype.i MaxSizeChangedEvent(*Window, widht, height)
  Prototype.i ProtoOpenWindow(*Window)
  Prototype.i ProtoHandleEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i ProtoCloseWindow(Window.i)
  Prototype.i ProtoCleanupWindow()
  
  Structure AppWindow
    Title.s
    Window.i
    WebViewGadget.i
    *HandleProc.ProtoHandleEvent
    *MaxSizeChangedProc.MaxSizeChangedEvent
    *CloseProc.ProtoCloseWindow
    *CleanupProc.ProtoCleanupWindow
    UserData.i
    Open.b
  EndStructure
  
  Declare  Init()
  Declare.i AddManagedWindow(Title.s, *Gadgets, *CreateProc, *HandleProc, *RemoveProc, *CleanupProc = 0)
  Declare OpenManagedWindow(*Window.AppWindow)
  Declare CloseManagedWindow(*Window.AppWindow)
  Declare RunEventLoop(*HandleMainEvent.HandleMainEvent)
  Declare CleanupManagedWindows()
  Declare GetManagedWindowFromWindowHandle(hWnd)
  Declare WindowMaxSizeChanged()
  Declare UpdateMaxDesktopSize()
  
  Global DesktopCount = ExamineDesktops()
  Global DPI_Scale
  Global MaxDesktopWidth = 0
  Global MaxDesktopHeight = 0 
  Global TimerAdded = #False 
EndDeclareModule

Module WindowManager
  
  
  #Timer_CheckDesktop = 1
  
  Structure HandleInfo
    *Window
  EndStructure 
  
  
  Procedure Init()
    Global NewMap ManagedWindowsHandles.HandleInfo()
    Global NewList ManagedWindows.AppWindow()
    UpdateMaxDesktopSize()
  EndProcedure 
  
  
  Procedure.i AddManagedWindow(Title.s, window,webViewGadget, *HandleProc, *CloseProc, *CleanupProc = 0)
    AddElement(ManagedWindows())
    ManagedWindows()\Title = Title
    ManagedWindows()\Window = window
    ManagedWindows()\WebViewGadget = webViewGadget
    ManagedWindows()\HandleProc = *HandleProc
    ManagedWindows()\CloseProc = *CloseProc
    ManagedWindows()\CleanupProc = *CleanupProc
    ManagedWindowsHandles(Str(WindowID(window)))\Window = @ManagedWindows()
    
    If Not TimerAdded
      TimerAdded = #True
      AddWindowTimer(window, #Timer_CheckDesktop, 500)
    EndIf 
    
    ProcedureReturn @ManagedWindows()
    
    
  EndProcedure
  
  
  
  
  Procedure OpenManagedWindow(*Window.AppWindow)
    If Not *Window\Open
      If *Window\Window <> -1
        *Window\Open = #True
        ProcedureReturn 1
      EndIf
    EndIf
    
    ProcedureReturn 0
  EndProcedure
  
  Procedure CloseManagedWindow(*Window.AppWindow)
    If *Window\Window
      If *Window\CloseProc
        CallFunctionFast(*Window\CloseProc, *Window)
      EndIf
      *Window\Open = #False     
    EndIf
  EndProcedure
  
  
  Procedure CleanupManagedWindows()
    ForEach ManagedWindows()
      If  ManagedWindows()\Window And ManagedWindows()\CleanupProc
        CallFunctionFast( ManagedWindows()\CleanupProc)
      EndIf
    Next
  EndProcedure
  
  Procedure RunEventLoop(*HandleMainEvent.HandleMainEvent)
    Protected Event.i
    Protected EventWindow.i
    Protected EventGadget.i
    Protected KeepRunning.i = #True
    Protected KeepWindow.i
    Protected OpenedWindowExists.i
    
    
    While KeepRunning
      Event = WaitWindowEvent()
      If Event <> 0
        
        If Event = #PB_Event_Timer And EventTimer() = #Timer_CheckDesktop
          If UpdateMaxDesktopSize()
            WindowMaxSizeChanged()
          EndIf
        EndIf
        
        
        
        EventWindow = EventWindow()
        If *HandleMainEvent( Event, EventWindow, EventGadget) = 0
          ForEach ManagedWindows()
            If ManagedWindows()\Open 
              If EventWindow = ManagedWindows()\Window And  ManagedWindows()\HandleProc
                KeepWindow = CallFunctionFast(ManagedWindows()\HandleProc, @ManagedWindows(), Event,EventGadget(),EventType())
                If Not KeepWindow
                  DeleteElement(ManagedWindows())
                  Break
                EndIf
              EndIf
            EndIf
          Next
        EndIf 
      EndIf 
      OpenedWindowExists = #False
      ForEach ManagedWindows()
        If ManagedWindows()\Open
          OpenedWindowExists = #True
          Break
        EndIf
      Next
      
      If Not OpenedWindowExists Or ListSize(ManagedWindows()) = 0
        KeepRunning = #False
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

; =============================================================================
;- EDIT MONITOR DIALOG MODULE
; =============================================================================

DeclareModule JSWindow
  UseModule WindowManager
  Declare CreateJSWindow(x,y,w,h,title.s,flags,html.s="",js.s="")
  Declare OpenJSWindow(*Window.AppWindow)    
EndDeclareModule

Module JSWindow


  Declare RegisterWebViewScale(gadget)
  Declare UpdateWebViewScale(gadget, width, height)
  Declare WindowCallback(hWnd, uMsg, WParam, LParam)
  
  Declare HandleEvent(*Window,Event.i, Gadget.i, Type.i)
  Declare RemoveWindow(*Window)
  
  
  Procedure RegisterSync(webViewGadget)
   
    
    WebViewExecuteScript(webViewGadget, "")
  EndProcedure
  
  
  Procedure.i CreateJSWindow(x,y,w,h,title.s,flags,html.s="",js.s="")
    
    ; HTML with direct width/height control
    html.s = ""+
            "<html><head><meta charset='utf-8'>" +
            "<style>" +
            "html, body { margin:0; padding:0; overflow:hidden; font-family:Arial; }" +
            "body { background-color: #1E90FF; }" +    
            ":root {"+
            "   --container-width: 600px;"+
            "   --container-height: 400px;"+
            "}"+
            "#container {" +
            "   position:absolute;" +
            "   top:0;" +
            "   left:0;" +
            "   width: var(--container-width);"+
            "   height: var(--container-height);"+
            "}"+
            "ul { list-style: none; padding:0; margin:0; height:100%; display:flex; flex-direction:column; }" +
            "li { flex:1; display:flex; align-items:center; justify-content:center; color:white; font-weight:bold; font-size: 24px; }" +
            "li:nth-child(1) { background-color: #FF6B6B; }" +
            "li:nth-child(2) { background-color: #4ECDC4; }" +
            "li:nth-child(3) { background-color: #45B7D1; }" +
            "li:nth-child(4) { background-color: #FFA07A; }" +
            "</style></head>" +
            "<body>" +
            "<div id='container'>" +
            "<ul>" +
            "<li>Item A</li>" +
            "<li>Item B</li>" +
            "<li>Item C</li>" +
            "<li>Item D</li>" +
            "</ul>" +
            "</div>" +
            "</body></html>"
    
    
    window = OpenWindow(#PB_Any,x,y,w,h,title.s,flags)
    If window
      SetWindowCallback(@WindowCallback(),window,#PB_Window_NoChildEvents)
      
      webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight,#PB_WebView_Debug)
      
      RegisterSync(webViewGadget)
      
      SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
      
      WebViewExecuteScript(webViewGadget, js)
      
      
      
      
      ; Add timer for desktop checking
      
      RegisterWebViewScale(webViewGadget)
      ; Set initial scale
      UpdateWebViewScale(webViewGadget, WindowWidth(window), WindowHeight(window))
      
      *Window = AddManagedWindow(title, window,webViewGadget, @HandleEvent(), @RemoveWindow())
      
      ProcedureReturn *Window
    EndIf 
    ProcedureReturn -1
  EndProcedure 
  
  
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
        UpdateWebViewScale(*Window\WebViewGadget, w, h)  
        ProcedureReturn #True
      Case #WM_PAINT
        ; During resize, use WM_PRINTCLIENT for faster painting
        Protected ps.PAINTSTRUCT
        hdc = BeginPaint_(hWnd, @ps)
        If hdc
          SendMessage_(hWnd, #WM_PRINTCLIENT, hdc, #PRF_CLIENT | #PRF_CHILDREN)
          EndPaint_(hWnd, @ps)
          ProcedureReturn 0
        EndIf
        
    EndSelect
    
    ProcedureReturn #PB_ProcessPureBasicEvents 
  EndProcedure 
  ; Fast resize procedure - sets width and height directly
  Procedure RegisterWebViewScale(gadget)
    Protected script.s = ""+
                         "function updateScale(width, height) {" +
                         "console.log('RESIZE',width,height);" +
                         "  document.documentElement.style.setProperty('--container-width', width + 'px');" +
                         "  document.documentElement.style.setProperty('--container-height', height + 'px')" +
                         "}"
    WebViewExecuteScript(gadget, script)
  EndProcedure
  
  Procedure UpdateWebViewScale(gadget, width, height)
    Protected script$ = "updateScale(" + Str(width) + "," + Str(height) + ");"
    Debug "RESIZE "+Str(width)+" "+Str(height)+" "+Str(ElapsedMilliseconds())+"  DPI "+Str(DPI_Scale)
    WebViewExecuteScript(gadget, script$)
  EndProcedure
  
  
  
  
  Procedure.i HandleEvent(*Window.AppWindow,Event.i, Gadget.i, Type.i)
    
    Protected closeWindow = #False
    
    Select Event
      Case #PB_Event_CloseWindow
        closeWindow = #True
        Debug "CLOSE!!!!!!!!!!!!!!!!!!!!"
      Case #PB_Event_Gadget
        Select Gadget
        EndSelect
    EndSelect
    
    If closeWindow
      CloseManagedWindow(*Window)
    EndIf    
    ProcedureReturn #True
  EndProcedure
  
  Procedure RemoveWindow(*Window.AppWindow)
    CloseWindow(*Window\Window)
  EndProcedure
  
  Procedure OpenJSWindow(*Window.AppWindow)    
    OpenManagedWindow(*Window)
  EndProcedure
  
  
EndModule




; =============================================================================
;- START APP 
; =============================================================================


DeclareModule Execute
  Declare StartApp()
EndDeclareModule
Module Execute
  
  
  Procedure.i HandleMainEvent( Event.i, Window.i, Gadget.i)
    Select Event
      Case #PB_Event_SysTray
      Case #PB_Event_Menu
      Case #PB_Event_Timer
    EndSelect
  EndProcedure 
  
  
  Procedure StartApp()
   UseModule WindowManager

    DPI_Scale = DesktopResolutionX()
    If DPI_Scale <= 0
      DPI_Scale = 1.0
    EndIf
    Debug "SET DPI"
    Debug DPI_Scale
    
    WindowManager::Init()
    
    
    *Window = JSWindow::CreateJSWindow(0, 0, 600, 400, "WebView List Example", 
                                       #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                       #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget)
    
    JSWindow::OpenJSWindow(*Window)
    
    
    *Window2 = JSWindow::CreateJSWindow(100, 100, 600, 400, "WebView List Example", 
                                       #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                       #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget)
    JSWindow::OpenJSWindow(*Window2)
    
    
    WindowManager::RunEventLoop(@HandleMainEvent()) 
    
  EndProcedure
EndModule


; =============================================================================
;- BOOTSTRAP
; =============================================================================


Execute::StartApp()
WindowManager::CleanupManagedWindows()
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 228
; FirstLine = 221
; Folding = -----
; EnableXP
; DPIAware