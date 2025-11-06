

;=====================================================================
;-  Window Dark Mode Support
;=====================================================================
DeclareModule OsTheme
  Declare IsDarkModeActive()
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare ApplyThemeToWinHandle(hWnd)
  CompilerEndIf 
  Declare InitOsTheme()
  Global isDarkModeActiveCached
  
EndDeclareModule

Module OsTheme
  
  Global NewMap StaticControlThemeProcs()
  
  Procedure InitOsTheme()
    isDarkModeActiveCached = IsDarkModeActive()
  EndProcedure 
  
  Procedure IsDarkModeActive()
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      Protected key, result = 0, value.l, size = SizeOf(Long)
      If RegOpenKeyEx_(#HKEY_CURRENT_USER, "Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", 0, #KEY_READ, @key) = #ERROR_SUCCESS
        If RegQueryValueEx_(key, "AppsUseLightTheme", 0, 0, @value, @size) = #ERROR_SUCCESS
          result = Bool(value = 0)
        EndIf
        RegCloseKey_(key)
      EndIf
      ProcedureReturn result
    CompilerElse
      ProcedureReturn #False
    CompilerEndIf 
  EndProcedure
  
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    
    #DWMWA_USE_IMMERSIVE_DARK_MODE = 20
    Procedure DwmSetWindowAttributeDynamic(hwnd.i, dwAttribute.i, *pvAttribute, cbAttribute.i)
      Protected result = 0
      Protected hDll = OpenLibrary(#PB_Any, "dwmapi.dll")
      If hDll
        Protected *fn = GetFunction(hDll, "DwmSetWindowAttribute")
        If *fn
          result = CallFunctionFast(*fn, hwnd, dwAttribute, *pvAttribute, cbAttribute)
        EndIf
        CloseLibrary(hDll)
      EndIf
      ProcedureReturn result
    EndProcedure
    
    Procedure SetDarkTitleBar(hwnd.i, enable)
      Protected attrValue.i = Bool(enable)
      DwmSetWindowAttributeDynamic(hwnd, #DWMWA_USE_IMMERSIVE_DARK_MODE, @attrValue, SizeOf(Integer))
    EndProcedure
    
    
    
    Procedure SetWindowThemeDynamic(hwnd.i, subAppName.s)
      Protected hUxTheme = OpenLibrary(#PB_Any, "uxtheme.dll")
      If hUxTheme
        Protected *fn = GetFunction(hUxTheme, "SetWindowTheme")
        If *fn
          CallFunctionFast(*fn, hwnd, @subAppName, 0)
        EndIf
        CloseLibrary(hUxTheme)
      EndIf
    EndProcedure
    
    Procedure ApplyGadgetTheme(gadgetId)
      
      ; Only apply if dark mode active
      If isDarkModeActiveCached
        SetWindowThemeDynamic(gadgetId, "DarkMode_Explorer")
      Else
        SetWindowThemeDynamic(gadgetId, "Explorer")
      EndIf
      
      ; Force repaint
      SendMessage_(gadgetId, #WM_THEMECHANGED, 0, 0)
      InvalidateRect_(gadgetId, #Null, #True)
    EndProcedure
    
    
    Procedure StaticControlThemeProc(hwnd, msg, wParam, lParam)
      
      Protected oldProc = StaticControlThemeProcs(Str(hwnd))
      Protected fg, bg
      
      If isDarkModeActiveCached
        bg = RGB(10,10,10)
        fg = RGB(220, 220, 220)
      Else
        bg = RGB(255, 255, 255)
        fg = RGB(0, 0, 0)
      EndIf 
      Protected result
      Select msg
        Case #WM_SETTEXT
          ; Let Windows actually set the text first
          result = CallWindowProc_(oldProc, hwnd, msg, wParam, lParam)
          ; Now trigger repaint AFTER text changed
          InvalidateRect_(hwnd, #Null, #True)
          UpdateWindow_(hwnd) ; force immediate paint
          ProcedureReturn result
          
        Case #WM_PAINT
          Protected ps.PAINTSTRUCT
          Protected hdc = BeginPaint_(hwnd, @ps)
          Protected rect.RECT
          GetClientRect_(hwnd, @rect)
          
          ; Draw background
          Protected hBrush = CreateSolidBrush_(bg)
          FillRect_(hdc, @rect, hBrush)
          DeleteObject_(hBrush)
          
          ; Font + color
          Protected hFont = SendMessage_(hwnd, #WM_GETFONT, 0, 0)
          If hFont : SelectObject_(hdc, hFont) : EndIf
          SetBkMode_(hdc, #TRANSPARENT)
          SetTextColor_(hdc, fg)
          
          ; Get text
          Protected textLen = GetWindowTextLength_(hwnd)
          
          If textLen > 0
            Protected *text = AllocateMemory((textLen + 1) * SizeOf(Character))
            GetWindowText_(hwnd, *text, textLen + 1)
            
            ; Alignment + ellipsis setup
            Protected style = GetWindowLong_(hwnd, #GWL_STYLE)
            Protected format = #DT_VCENTER | #DT_SINGLELINE | #DT_END_ELLIPSIS | #DT_NOPREFIX | #DT_WORD_ELLIPSIS | #DT_MODIFYSTRING | #DT_LEFT
            
            If style & #SS_CENTER
              format | #DT_CENTER
            ElseIf style & #SS_RIGHT
              format | #DT_RIGHT
            EndIf
            
            ; Draw clipped text with ellipsis
            DrawText_(hdc, *text, -1, @rect, format)
            
            FreeMemory(*text)
          EndIf
          
          EndPaint_(hwnd, @ps)
          ProcedureReturn 0
          
          
          
        Case #WM_ERASEBKGND
          ProcedureReturn 1
      EndSelect
      
      ProcedureReturn CallWindowProc_(oldProc, hwnd, msg, wParam, lParam) ; sometimes stackoveflow, fix wip
    EndProcedure
    
    Global themeBackgroundColor.l
    Global themeForegroundColor.l
    
    ; Change the callback to use proper calling convention
    ProcedureC ApplyThemeToWindowChildren(hWnd, lParam)  ; Added CDLL
      Protected className.s = Space(256)
      
      Protected length = GetClassName_(hWnd, @className, 256)
      
      If length > 0
        className = LCase(PeekS(@className))
        
        Select className
            
            
          Case "button"; Applies to Button, CheckBox, Option gadgets
            
            style.l = GetWindowLong_(hWnd, #GWL_STYLE)
            
            If Not (((style & #BS_CHECKBOX) <> 0) Or ((style & #BS_AUTOCHECKBOX) <> 0)) ; Not Checkbox
              
              ApplyGadgetTheme(hWnd)
            EndIf
            ; Force repaint for checkboxes/options
            ;SendMessage_(hWnd, #WM_THEMECHANGED, 0, 0)
            InvalidateRect_(hWnd, #Null, #True)          
          Case "static"
            Protected textLength = GetWindowTextLength_(hWnd)
            If textLength = 0
              ProcedureReturn #True ; probably ImageGadget
            EndIf
            
            ; 1. Get old WndProc
            CompilerIf #PB_Compiler_Processor = #PB_Processor_x64
              Protected oldProc = GetWindowLongPtr_(hWnd, #GWLP_WNDPROC)
            CompilerElse
              Protected oldProc = GetWindowLong_(hWnd, #GWL_WNDPROC)
            CompilerEndIf
            If Not FindMapElement(StaticControlThemeProcs(),Str(hWnd))
              StaticControlThemeProcs(Str(hWnd)) = oldProc
            EndIf 
            CompilerIf #PB_Compiler_Processor = #PB_Processor_x64
              SetWindowLongPtr_(hWnd, #GWLP_WNDPROC, @StaticControlThemeProc())
            CompilerElse
              SetWindowLong_(hWnd, #GWL_WNDPROC, @StaticControlThemeProc())
            CompilerEndIf
            
        EndSelect
        
        
      EndIf
      
      InvalidateRect_(hWnd, #Null, #True)
      ProcedureReturn #True
    EndProcedure
    
    Procedure ApplyThemeToWinHandle(hWnd)
      Protected bg, fg
      If isDarkModeActiveCached
        bg = RGB(10,10,10)
        fg = RGB(220, 220, 220)
      Else
        bg = RGB(255, 255, 255)
        fg = RGB(0, 0, 0)
      EndIf 
      Debug "DARK MODE: "+Str(isDarkModeActiveCached)
      SetDarkTitleBar(hWnd, isDarkModeActiveCached)
      If isDarkModeActiveCached
        SetWindowThemeDynamic(hWnd, "DarkMode_Explorer")
      Else
        SetWindowThemeDynamic(hWnd, "Explorer")
      EndIf
      
      ;  EnumChildWindows_(hWnd, @ApplyThemeToWindowChildren(), 0)
    EndProcedure
  CompilerEndIf
  
  
  
EndModule 



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
    InjectTimer.i
  EndStructure
  
  Declare InitWindowManager()
  Declare.i AddManagedWindow(Title.s, *Gadgets, *CreateProc, *HandleProc, *RemoveProc, *CleanupProc = 0)
  Declare  OpenManagedWindow(*Window.AppWindow, showWindow=#True)
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
  
  
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Procedure ShowWindowWinHandle(hWnd)
      ShowWindow_(hWnd, #SW_SHOWNA)
      RedrawWindow_(hWnd, #Null, #Null, #RDW_UPDATENOW  )
    EndProcedure
  CompilerEndIf
  
  Procedure ShowWindowFadeIn(winID)
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      Protected hWnd = WindowID(winID)
      ShowWindowWinHandle(hWnd)
    CompilerElse
      HideWindow(winID, #False)
    CompilerEndIf
  EndProcedure
  
  
  Procedure InitWindowManager()
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
  
  Procedure OpenManagedWindow(*Window.AppWindow, showWindow=#True)
    If Not *Window\Open
      If *Window\Window <> -1
        If showWindow 
          ShowWindowFadeIn(*Window\Window)
        EndIf 
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
  Declare OpenJSWindow(*Window.AppWindow )       
EndDeclareModule

Module JSWindow
  UseModule OsTheme
  
  Declare RegisterWebViewScale(gadget)
  Declare UpdateWebViewScale(gadget, width, height)
  
  
  Declare HandleEvent(*Window,Event.i, Gadget.i, Type.i)
  Declare RemoveWindow(*Window)
  
  Declare RegisterSync(webViewGadget)
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare WindowCallback(hWnd, uMsg, WParam, LParam)
  CompilerEndIf
  
  Structure JSWindowState
    Visible.b
    Injected.b
    Ready.b
  EndStructure 
  
  Global NewMap JSWindows.JSWindowState()
  
  
  Procedure ShowWebViewGadgetThread(gadgetID)
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      duration = 150
      Protected hWnd = GadgetID(gadgetID)
      If hWnd = 0 : ProcedureReturn : EndIf
      Protected style = GetWindowLong_(hWnd, #GWL_EXSTYLE)
      SetWindowLong_(hWnd, #GWL_EXSTYLE, style | #WS_EX_LAYERED)
      HideGadget(gadgetID, #False)
      SetLayeredWindowAttributes_(hWnd, 0, 0, #LWA_ALPHA)
      Protected startTime = ElapsedMilliseconds()
      Protected endTime = startTime + duration
      Repeat
        Protected now = ElapsedMilliseconds()
        Protected alpha.f = (now - startTime) / (endTime - startTime)
        If alpha > 1 : alpha = 1 : EndIf
        SetLayeredWindowAttributes_(hWnd, 0, 255 * alpha, #LWA_ALPHA)
        Delay(10)
      Until now >= endTime
      SetLayeredWindowAttributes_(hWnd, 0, 255, #LWA_ALPHA)
      
    CompilerElse   
      HideGadget(gadgetID, #False)
    CompilerEndIf
  EndProcedure
  
  Procedure ShowWebView(window,gadgetID)
    If JSWindows(Str(window))\Visible = #False
      JSWindows(Str(window))\Visible = #True
      CreateThread(@ShowWebViewGadgetThread(),gadgetID)
    EndIf 
  EndProcedure
  
  Procedure CallbackReadyState(JsonParameters.s)
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    window = Parameters(0)
    JSWindows(Str(window))\Ready = #True
    CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
      *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
      If *Window\Open
        HideWindow(window,#False)
      EndIf 
    CompilerElse 
      If *Window\Open
        webViewGadget =  Parameters(1)
        ShowWebView(window,webViewGadget) ; Fade In -> on windows open window first, then load content
      Else
        HideGadget(webViewGadget,#False)
      EndIf 
    CompilerEndIf
    
    ProcedureReturn UTF8(~"")
  EndProcedure
  
  
  Procedure CallbackInjected(JsonParameters.s)
    ;MessageRequester("INJECTED","YES")
    
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    
    window = Parameters(0)
    
    Debug "INJECTED"
    Debug window
    Debug JSWindows(Str(window))\Injected
    
    JSWindows(Str(window))\Injected = #True
    
    ProcedureReturn UTF8(~"")
  EndProcedure
  
  ; Fast resize procedure - sets width and height directly
  Procedure RegisterWebViewScale(gadget)
    Protected script.s = ""+
                         "function pbjsUpdateScale(width, height) {" +
                         "console.log('RESIZE',width,height);" +
                         "  document.documentElement.style.setProperty('--container-width', width + 'px');" +
                         "  document.documentElement.style.setProperty('--container-height', height + 'px')" +
                         "}"
    WebViewExecuteScript(gadget, script)
  EndProcedure
  
  Procedure UpdateWebViewScale(gadget, width, height)
    Protected script$ = "pbjsUpdateScale(" + Str(width) + "," + Str(height) + ");"
    WebViewExecuteScript(gadget, script$)
  EndProcedure
  
  
  
  Procedure InjectStartJS(*Window.AppWindow)
    
    *Window\InjectTimer = ElapsedMilliseconds()
    
    window.i = *Window\Window
    webViewGadget.i = *Window\WebViewGadget
    
    
    RegisterWebViewScale(webViewGadget)
    UpdateWebViewScale(webViewGadget, WindowWidth(window), WindowHeight(window))
    
    startupJS.s = "" + 
                  "(function(){" + 
                  "if(!window.__pbjsStyleAdded){" + 
                  "" + 
                  "console.log('!!!!!!!INSERT');" + 
                  "const style=document.createElement('style');" + 
                  "style.id='pbjs-dynamic-style';" + 
                  "" + 
                  "style.textContent='body, html {" + 
                  "width: var(--container-width);" + 
                  "height: var(--container-height);" + 
                  "min-width: 0!important;" + 
                  "min-height: 0!important;" + 
                  "}';" + 
                  "" + 
                  "document.head.appendChild(style);" + 
                  "window.__pbjsStyleAdded=true;" + 
                  "}" + 
                  "})();" + 
                  "" + 
                  "document.addEventListener('DOMContentLoaded',function(){" + 
                  "callbackReadyState(" + Str(window) + "," + Str(webViewGadget) + ");" + 
                  "});" + 
                  "" + 
                  "setTimeout(function(){" + 
                  "callbackReadyState(" + Str(window) + "," + Str(webViewGadget) + ");" + 
                  "},0);"+
                  "callbackInjected(" + Str(window) + ");"
    
    
    WebViewExecuteScript(webViewGadget, startupJS)
    
  EndProcedure 
  
  
  
  
  Procedure.i CreateJSWindow(x,y,w,h,title.s,flags,html.s="",js.s="")
    
    window = OpenWindow(#PB_Any,x,y,w,h,title.s,flags | #PB_Window_Invisible)
    If window
      Protected hWnd = WindowID(window)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        SetWindowLongPtr_(WindowID(window), #GWL_STYLE, GetWindowLongPtr_(WindowID(window), #GWL_STYLE) | #WS_CLIPCHILDREN)
        ApplyThemeToWinHandle(hWnd)
        UpdateWindow_(hWnd)
        RedrawWindow_(hWnd, #Null, #Null, #RDW_UPDATENOW | #RDW_ALLCHILDREN | #RDW_FRAME) 
      CompilerEndIf
      SetWindowColor(window,RGB(36,36,36))
      
      JSWindows(Str(window))\Visible = #False
      JSWindows(Str(window))\Injected = #False
      
      ; For Windows
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        SetWindowCallback(@WindowCallback(),window,#PB_Window_NoChildEvents)
      CompilerEndIf
      
      webViewGadget = WebViewGadget(#PB_Any, -1, -1, MaxDesktopWidth, MaxDesktopHeight,#PB_WebView_Debug)
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        HideGadget(webViewGadget,#True)
      CompilerEndIf
      
      BindWebViewCallback(webViewGadget, "callbackReadyState", @CallbackReadyState())
      BindWebViewCallback(webViewGadget, "callbackInjected", @CallbackInjected())
      
      SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
      
      RegisterSync(webViewGadget)
      WebViewExecuteScript(webViewGadget, js)
      RegisterWebViewScale(webViewGadget)
      
      ; Set initial scale 
      UpdateWebViewScale(webViewGadget, WindowWidth(window), WindowHeight(window))
      *Window = AddManagedWindow(title, window,webViewGadget, @HandleEvent(), @RemoveWindow())
      
      
      Repeat : Delay(1) : Until WindowEvent() = 0
      
      
      
      
      
      ProcedureReturn *Window
    EndIf 
    ProcedureReturn -1
  EndProcedure 
  
  
  
  Procedure RegisterSync(webViewGadget)
    WebViewExecuteScript(webViewGadget, "")
    
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
          UpdateWebViewScale(*Window\WebViewGadget, w, h)  
          ProcedureReturn #True
          
      EndSelect
      
      ProcedureReturn #PB_ProcessPureBasicEvents 
    EndProcedure 
    
  CompilerEndIf
  
  
  
  
  Procedure.i HandleEvent(*Window.AppWindow,Event.i, Gadget.i, Type.i)
    
    Protected closeWindow = #False
    
    If Not JSWindows(Str(*Window\Window))\Injected And ElapsedMilliseconds()-*Window\InjectTimer > 16
      InjectStartJS(*Window)
    EndIf 
    
    
    Select Event
      Case #PB_Event_CloseWindow
        closeWindow = #True
      Case #PB_Event_Gadget
        Select Gadget
        EndSelect
      Case #PB_Event_SizeWindow
       w = WindowWidth(*Window\Window)
       h = WindowHeight(*Window\Window)
       UpdateWebViewScale(*Window\WebViewGadget, w, h)  
    EndSelect
    
    If closeWindow
      CloseManagedWindow(*Window)
    EndIf    
    ProcedureReturn #True
  EndProcedure
  
  Procedure RemoveWindow(*Window.AppWindow)
    CloseWindow(*Window\Window)
  EndProcedure
  
  Procedure OpenJSWindow(*Window.AppWindow )  
    
    
    showWindow = #True 
    CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
      If  FindMapElement(JSWindows(),Str(*Window\Window)) And  JSWindows(Str(*Window\Window))\Ready = #False
        showWindow = #False 
      EndIf 
    CompilerEndIf
    OpenManagedWindow(*Window,showWindow)
    
  EndProcedure
  
  
EndModule


; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 749
; FirstLine = 733
; Folding = ----------
; EnableXP
; DPIAware
; Executable = ../main.exe