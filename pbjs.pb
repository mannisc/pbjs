

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
  
  Global IsDarkModeActiveCached = #False
  Global darkThemeBackgroundColor = RGB(15,15,15)
  Global darkThemeForegroundColor = RGB(255, 255, 255)
  Global lightThemeBackgroundColor = RGB(250,250,250)
  Global lightThemeForegroundColor = RGB(0,0,0)
  
  ;darkThemeBackgroundColor = RGB(255,255,255)
  
  Global themeBackgroundColor = lightThemeBackgroundColor
  Global themeForegroundColor = lightThemeForegroundColor
  
EndDeclareModule

Module OsTheme
  
  Global NewMap StaticControlThemeProcs()
  
  Procedure InitOsTheme()
    IsDarkModeActive()
  EndProcedure 
  
  Procedure IsDarkModeActive()
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      
      Protected key, result = 0, value.l, size = SizeOf(Long)
      If RegOpenKeyEx_(#HKEY_CURRENT_USER, "Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", 0, #KEY_READ, @key) = #ERROR_SUCCESS
        If RegQueryValueEx_(key, "AppsUseLightTheme", 0, 0, @value, @size) = #ERROR_SUCCESS
          result = Bool(value = 0) ; 0 = dark mode
        EndIf
        RegCloseKey_(key)
      EndIf
      
    CompilerElseIf #PB_Compiler_OS = #PB_OS_MacOS
      Define mode$, result
      result = RunProgram("/usr/bin/defaults", "read -g AppleInterfaceStyle", "", #PB_Program_Open | #PB_Program_Read)
      If result
        mode$ = ReadProgramString(result)
        CloseProgram(result)
      EndIf
      
      If mode$ = "Dark"
        result = #True 
      Else
        result = #False 
      EndIf
    CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
      Debug "DARKMODE??"
      Protected result, line$, theme$, cmd$, tmp$
      
      ; --- 1️⃣ Try freedesktop.org unified color-scheme (modern GNOME/KDE)
      result = RunProgram("gsettings", "get org.freedesktop.appearance color-scheme", "", #PB_Program_Open | #PB_Program_Read)
      If result
        tmp$ = Trim(ReadProgramString(result), "'")
        CloseProgram(result)
        If LCase(tmp$) = "prefer-dark"
          result = #True
        ElseIf LCase(tmp$) = "default"
          result = #False
        EndIf
      EndIf
      
      ; --- 2️⃣ Try GNOME / Cinnamon / XFCE GTK theme
      result = RunProgram("gsettings", "get org.gnome.desktop.interface gtk-theme", "", #PB_Program_Open | #PB_Program_Read)
      If result
        theme$ = Trim(ReadProgramString(result), "'")
        CloseProgram(result)
        If FindString(LCase(theme$), "dark")
          result = #True
        ElseIf theme$ <> ""
          result = #False
        EndIf
      EndIf
      
      ; --- 3️⃣ Try KDE Plasma config
      If FileSize(GetHomeDirectory() + ".config/kdeglobals") > 0
        result = ReadFile(#PB_Any, GetHomeDirectory() + ".config/kdeglobals")
        If result
          While Eof(result) = 0
            line$ = ReadString(result)
            If Left(line$, 11) = "ColorScheme"
              theme$ = Trim(StringField(line$, 2, "="))
              Break
            EndIf
          Wend
          CloseFile(result)
          If FindString(LCase(theme$), "dark")
            result = #True
          Else
            result = #False
          EndIf
        EndIf
      EndIf
      
      Debug "DARK?"
      Debug result
      
    CompilerEndIf
    
    If result
      themeBackgroundColor = darkThemeBackgroundColor
      themeForegroundColor = darkThemeForegroundColor
    Else
      themeBackgroundColor = lightThemeBackgroundColor
      themeForegroundColor = lightThemeForegroundColor
    EndIf 
    IsDarkModeActiveCached = result
    ProcedureReturn result
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
  
  Prototype.i HandleMainEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i MaxSizeChangedEvent(*Window, widht, height)
  Prototype.i ProtoHideWindow(*Window)
  Prototype.i ProtoOpenWindow(*Window)
  Prototype.i ProtoHandleEvent(Event.i, Window.i, Gadget.i, Type.i)
  Prototype.i ProtoCloseWindow(Window.i)
  Prototype.i ProtoCleanupWindow()
  
  Prototype.i ShouldKeepRunning()
  
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
  Declare RunEventLoop(*HandleMainEvent.HandleMainEvent,*ShouldKeepRunning.ShouldKeepRunning = 0)
  Declare CleanupManagedWindows()
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
            Debug "OPEN MANAGED WINDOW 1"

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
        Debug "OPEN MANAGED WINDOW 2"
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
  
  
  
  Procedure CleanupManagedWindows()
    NewList Windows()
    ForEach ManagedWindows()
      If ManagedWindows()\Open 
        AddElement(Windows())
        Windows() = ManagedWindows()\Window
        
        If ManagedWindows()\CloseProc
          CallFunctionFast(ManagedWindows()\CloseProc, ManagedWindows()\Window)
        EndIf 
      EndIf
      If ManagedWindows()\CleanupProc
        CallFunctionFast( ManagedWindows()\CleanupProc)
      EndIf
    Next
    
    endTime = ElapsedMilliseconds()
    Repeat
      Delay(10)
      windowExists = #False 
      ForEach Windows() 
        If IsWindow(Windows())
          CloseWindow(Windows())
          windowExists = #True
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
  
  Procedure RunEventLoop(*HandleMainEvent.HandleMainEvent,*ShouldKeepRunning.ShouldKeepRunning = 0)
    Protected Event.i
    Protected EventWindow.i
    Protected EventGadget.i
    Protected KeepRunning.i = #True
    Protected KeepWindow.i
    Protected OpenedWindowExists.i 
    While KeepRunning
      Event = WindowEvent()
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


; =============================================================================
;- JS BRIDGE DECLARE
; =============================================================================

IncludeFile "pbjsBridge/pbjsBridgeDeclare.pb"


; =============================================================================
;- JS WINDOW
; =============================================================================

DeclareModule JSWindow
  UseModule WindowManager
  
  ; Callback prototype for resize/move events
  Prototype ResizeCallback(windowName.s, x.l, y.l, w.l, h.l)
  
  Enumeration #PB_Event_FirstCustomValue
    #Event_Loaded_Html
    #Event_Content_Ready
  EndEnumeration
  Enumeration #PB_Event_FirstCustomValue
    #JSWindow_Behaviour_HideWindow
    #JSWindow_Behaviour_CloseWindow
  EndEnumeration
  
  Declare CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0)
  Declare OpenJSWindow(*Window.AppWindow )    
  Declare HideJSWindow(*Window.AppWindow, FromManagedWindow)
  Declare CloseJSWindow(*Window.AppWindow)
  Declare ResizeJSWindow(*Window.AppWindow, x, y, w, h)
  Declare GetWebView(*Window.AppWindow)
  
  Structure JSWindow
    Name.s
    
    Window.i
    WebViewGadget.i
    
    ;Stages
    OpenTime.i
    LoadedCode.b
    Ready.b
    Open.b
    Visible.b
    
    CloseBehaviour.i
    
    Html.s
    *HtmlStart
    *HtmlEnd
    *WindowReadyProc.ProtoWindowReady
    *ResizeProc.ResizeCallback  ; Optional callback for resize/move events
  EndStructure 
  
  Global NewMap JSWindows.JSWindow()
  Global NewMap WindowsByName.i()
  
EndDeclareModule


Module JSWindow
  UseModule OsTheme
  
  Declare UpdateWebViewScale(gadget, width, height)
  Declare HandleEvent(*Window.AppWindow, Event.i, Gadget.i, Type.i)
  Declare ForceContentVisible(window)
  
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare WindowCallback(hWnd, uMsg, WParam, LParam)
  CompilerEndIf
  
  Prototype.i ProtoWindowReady(*Window, *JSWindow)

    Procedure MakeContentVisible(window)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_Linux
        Delay(100) 
      CompilerElseIf #PB_Compiler_OS = #PB_OS_MacOS
        Delay(100)  
      CompilerElse 
        Delay(100)  
      CompilerEndIf
      
      
      If IsWindow(window)
        PostEvent(#CustomWindowEvent, window, 0,#Event_Content_Ready) 
      EndIf 
    EndProcedure
  
  Procedure JSReadyState(JsonParameters.s)
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    window = Parameters(0)
    *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
    
    If Not JSWindows(Str(window))\Ready
      
      
      JSWindows(Str(window))\Ready = #True
      ;CompilerIf #PB_Compiler_OS = #PB_OS_Windows Or #PB_Compiler_OS = #PB_OS_Linux
        
        CreateThread(@MakeContentVisible(),window)
        
      ;CompilerElse
        
       ; PostEvent(#CustomWindowEvent, window, 0,#Event_Content_Ready) 
      ;CompilerEndIf
    EndIf 
    ProcedureReturn UTF8(~"")
  EndProcedure
  
  Procedure JSGetWindow(JsonParameters.s)
    Dim Parameters.s(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    windowName.s = Parameters(0)
    ForEach JSWindows()
      If Trim(JSWindows()\Name)=Trim(windowName)
        ProcedureReturn UTF8(~"{\"id\":"+Str(JSWindows()\Window)+"}")
        Break 
      EndIf 
    Next 
    ProcedureReturn UTF8(~"{\"error\":false}")
  EndProcedure
  
  Procedure JSOpenWindow(JsonParameters.s)
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    window = Parameters(0)
    *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
    If *Window
      OpenJSWindow(*Window) 
      ProcedureReturn UTF8(~"{\"success\":true}")  
    EndIf 
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  Procedure JSHideWindow(JsonParameters.s)
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    window = Parameters(0)
    *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
    If *Window
      HideJSWindow(*Window, #False ) 
      ProcedureReturn UTF8(~"{\"success\":true}")  
    EndIf 
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  Procedure JSCloseWindow(JsonParameters.s)
    Dim Parameters(0)
    ParseJSON(0, JsonParameters)
    ExtractJSONArray(JSONValue(0), Parameters())
    window = Parameters(0)
    Debug window
    *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
    If *Window
      CloseJSWindow(*Window) 
      ProcedureReturn UTF8(~"{\"success\":true}")  
    EndIf 
    ProcedureReturn UTF8(~"{\"error\":true}")
  EndProcedure
  
  
  
  Procedure UpdateWebViewScale(*JSWindow.JSWindow, width, height)
    Protected script$ = "pbjsUpdateScale(" + Str(width) + "," + Str(height) + ");"
    
    Debug *JSWindow\Name
    
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      If IsIconic_(WindowID(*JSWindow\Window))
        ProcedureReturn
      EndIf
    CompilerEndIf
    
    Debug *JSWindow\WebViewGadget
    If Not IsGadget(*JSWindow\WebViewGadget) Or width = 0 Or height = 0
      ProcedureReturn
    EndIf
    WebViewExecuteScript(*JSWindow\WebViewGadget, script$)
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
    
    
    Procedure ShowGadgetThread(gadget)
      Delay(200)
      HideGadget(gadget,#False)
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
            
            CreateThread(@ShowGadgetThread(),webViewGadget)
          ElseIf MacOSResizeStates()\isFulscreen 
            MacOSResizeStates()\isFulscreen = #False
            
            HideGadget(webViewGadget,#True)
            CocoaMessage(0, WindowID(MacOSResizeStates()\Window\Window), "display")
            
            CreateThread(@ShowGadgetThread(),webViewGadget)
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
  
  
  Procedure SetBodyFadeIn(*JSWindow.JSWindow)
    If IsGadget(*JSWindow\WebViewGadget)
      If *JSWindow\Visible
        fadeInTime = 150 
      Else
        fadeInTime = 0
      EndIf 
      bodyFadeInScript.s =  "(function(){const style=document.createElement('style');" +
                            "style.id='pbjs-dynamic-style-pbjs-document-ready';" +
                            "style.textContent='body.pbjs-document-ready{" +
                            "transition:opacity " + fadeInTime + "ms ease-out!important;" +
                            "}';" +
                            "document.head.appendChild(style);})()";
      WebViewExecuteScript(*JSWindow\WebViewGadget, bodyFadeInScript)
    EndIf 
  EndProcedure 
  
  
  
  DataSection
    WindowBridgeScript:
    IncludeBinary "pbjsWindowScript.js"
    EndWindowBridgeScript:
  EndDataSection
  
  
  
  Procedure.s WithPbjsWindowScript(html.s)
    Protected result.s, bodyPos.i, bodyEndPos.i, startupJS.s
    ; Load the bridge script
    Define *buffer = ?WindowBridgeScript
    Define size.i = ?EndWindowBridgeScript - ?WindowBridgeScript
    windowScript.s = PeekS(*buffer, size, #PB_UTF8|#PB_ByteLength)
    
    result = html
    
    
    insertScript.s = ~"<script>\n" + windowScript + ~"</script>\n"
    
    
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + insertScript + Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = insertScript + result
    EndIf
    
    ProcedureReturn result
  EndProcedure
  
  
  
  
  
  
  Procedure.s WithPbjsBasicScript(html.s,*JSWindow.JSWindow)
    Protected result.s, bodyPos.i, bodyEndPos.i, startupJS.s
    
    result = html
    window.i = *JSWindow\Window
    webViewGadget.i = *JSWindow\WebViewGadget
    width = WindowWidth(window)
    height = WindowHeight(window)
    
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
    
    startupJS.s = "<script>" +
                  "if(!window.__pbjsAdded){" +
                  "" + 
                  " window.pbjsUpdateScale =  function(width, height) {" +
                  "   console.log('resize',width,height);"+
                  "   document.documentElement.style.setProperty('--container-width', width + 'px');" +
                  "   document.documentElement.style.setProperty('--container-height', height + 'px')" +
                  " };"+         
                  ""+
                  " window.pbjsDocumentReady = function () {" +
                  "  setTimeout(()=>{"+
                  "    document.body.classList.add('pbjs-document-ready');" +
                  "  },0);"+
                  "  callbackReadyState(" + Str(window) + "," + Str(webViewGadget) + ");" +
                  " };"+
                  ""+
                  "(function (){"+
                  ""+
                  " pbjsUpdateScale(" + Str(width) + "," + Str(height) + ");"+
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
                  "     pbjsDocumentReady();"+
                  "   });" +
                  " } else {" +
                  "   pbjsDocumentReady();"+
                  " }" +
                  ""+
                  ""+
                  " window.__pbjsAdded=true;" + 
                  "})();"+
                  "}" +
                  "</script>"
    
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + startupJS + Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = startupJS + result
    EndIf
    
    ProcedureReturn result
  EndProcedure
  
  
  
  Procedure LoadHtml(window)
    html.s = PeekS(JSWindows(Str(window))\HtmlStart,JSWindows(Str(window))\HtmlEnd-JSWindows(Str(window))\HtmlStart, #PB_UTF8|#PB_ByteLength  )
    JSWindows(Str(window))\Html.s = html
    PostEvent(#CustomWindowEvent, window, 0,#Event_Loaded_Html)
  EndProcedure 
  
  
  
  
  
  
  Procedure.i CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0)
    
    window = OpenWindow(#PB_Any,x,y,w,h,title.s,flags | #PB_Window_Invisible)
    If window
      
      *Window.AppWindow = AddManagedWindow(title, window, @HandleEvent(), @HideJSWindow() , @CloseJSWindow())
      
      
      Protected hWnd = WindowID(window)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight, #PB_WebView_Debug)
        
        CocoaMessage(0, GadgetID(webViewGadget), "setBorderType:", 0) 
        
      CompilerElse
        webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight, #PB_WebView_Debug)
      CompilerEndIf
      
      SetWindowColor(window, themeBackgroundColor)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        SetWindowLongPtr_(WindowID(window), #GWL_STYLE, GetWindowLongPtr_(WindowID(window), #GWL_STYLE) | #WS_CLIPCHILDREN)
        ApplyThemeToWinHandle(hWnd)
        
        SetWindowCallback(@WindowCallback(),window, #PB_Window_NoChildEvents)
      CompilerEndIf
      CompilerIf #PB_Compiler_OS = #PB_OS_Windows Or #PB_Compiler_OS = #PB_OS_Linux 
        ResizeGadget(webViewGadget,-1000000000,1000000000,#PB_Ignore,#PB_Ignore)
      CompilerElse 
        HideGadget(webViewGadget,#True)
      CompilerEndIf 
      
      BindWebViewCallback(webViewGadget, "callbackReadyState", @JSReadyState())
      BindWebViewCallback(webViewGadget, "pbjsNativeGetWindow", @JSGetWindow())
      BindWebViewCallback(webViewGadget, "pbjsNativeOpenWindow", @JSOpenWindow())
      BindWebViewCallback(webViewGadget, "pbjsNativeHideWindow", @JSHideWindow())
      BindWebViewCallback(webViewGadget, "pbjsNativeCloseWindow", @JSCloseWindow())
      
      
      
      *JSWindow.JSWindow = JSWindows(Str(window)) 
      *JSWindow\Window = window
      *JSWindow\Name = windowName
      *JSWindow\Visible = #False
      *JSWindow\Ready = #False
      *JSWindow\HtmlStart = *htmlStart
      *JSWindow\HtmlEnd = *htmlStop
      *JSWindow\WindowReadyProc = *WindowReadyCallback
      *JSWindow\ResizeProc = *ResizeCallback
      *JSWindow\CloseBehaviour = CloseBehaviour
      *JSWindow\WebViewGadget = webViewGadget
      
      WindowsByName(windowName) = window
      JSBridge::InitializeBridge(windowName, window, webViewGadget)
      
      
      ; Register for live resize notifications on macOS
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        MacOSRegisterResizeNotifications(*Window)
      CompilerEndIf
      
      CreateThread(@LoadHtml(),window)
      
      ProcedureReturn *Window
    EndIf 
    ProcedureReturn -1
  EndProcedure 
  
  
  
  Procedure OpenJSWindow(*Window.AppWindow )  
    Protected manualOpen
    If IsWindow(*Window\Window)
      *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      
      If *JSWindow\Visible
        manualOpen = #False
      Else
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          manualOpen = #True
        CompilerElse
          manualOpen = #False
        CompilerEndIf 
      EndIf 
      *JSWindow\Open = #True
      
      *JSWindow\Visible = Bool(Not manualOpen)
      
      
      *JSWindow\OpenTime = ElapsedMilliseconds()
      OpenManagedWindow(*Window,manualOpen)
      If Not *JSWindow\Visible
        CreateThread(@ForceContentVisible(),*Window\Window)
      EndIf 
      
      
    EndIf 
  EndProcedure
  
  Procedure HideJSWindow(*Window.AppWindow, FromManagedWindow)
    If IsWindow(*Window\Window)
      Debug "HideJSWindow"
      Debug *Window\Open
      Debug *Window
      If *Window\Open 
        HideWindow(*Window\Window,#True)
      EndIf 
      
      Debug "TRY HIDE"
      If Not FromManagedWindow
        HideManagedWindow(*Window)
      EndIf 
        Debug "HIDE"
      
    EndIf 
  EndProcedure
  
  
  Procedure CloseJSWindow(*Window.AppWindow)
    If IsWindow(*Window\Window)
      If Not *Window\Closed 
        CloseManagedWindow(*Window)
      EndIf 
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        MacOSUnregisterResizeNotifications(*Window)
      CompilerEndIf
      If IsWindow(*Window\Window)
        CloseWindow(*Window\Window)
      EndIf 
    EndIf 
  EndProcedure
  
  
  Procedure ResizeJSWindow(*Window.AppWindow, x, y, w, h)
    If IsWindow(*Window\Window)
      ResizeWindow( *Window\Window,x, y, w, h)
    EndIf 
  EndProcedure
  
  
  Procedure.i HandleEvent(*Window.AppWindow,Event.i, Gadget.i, Type.i)
    
    *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
    
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
            webViewGadget = *JSWindow\WebViewGadget
            
            html.s =  JSBridge::WithBridgeScript(*JSWindow\Html, *JSWindow\Name)
            html.s =  WithPbjsBasicScript(html, *JSWindow)
            html.s =  WithPbjsWindowScript(html)
            
            
            
            SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
            *JSWindow\LoadedCode = #True 
          Case #Event_Content_Ready
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
            Debug " #Event_Content_Ready "+*Window\Title
            HideGadget(webViewGadget,#False)
            
            If *JSWindow\Open And Not *JSWindow\Visible
              HideWindow(*JSWindow\Window, #False)
              *JSWindow\Visible = #True 
            EndIf 
            SetBodyFadeIn(*JSWindow)
            If *JSWindow\Ready
              If *JSWindow\WindowReadyProc
                CallFunctionFast(*JSWindow\WindowReadyProc, *Window , *JSWindow)
              EndIf 
            EndIf 
        EndSelect 
        
    EndSelect
    
    If closeWindow
      Debug "CLOSE WINDOW"
      If *JSWindow\CloseBehaviour = #JSWindow_Behaviour_CloseWindow
        Debug "CLOSE"
        CloseManagedWindow(*Window)
      Else
        Debug "HIDE"
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
          ProcedureReturn #True
          
      EndSelect
      
      ProcedureReturn #PB_ProcessPureBasicEvents 
    EndProcedure
  CompilerEndIf
  
  
  Procedure ForceContentVisible(window)
    Delay(600)
    If IsWindow(window)
      If Not JSWindows(Str(window))\Ready Or Not JSWindows(Str(window))\Visible
        PostEvent(#CustomWindowEvent, window, 0,#Event_Content_Ready) 
      EndIf 
    EndIf 
  EndProcedure
  
EndModule



; =============================================================================
;- JS BRIDGE
; =============================================================================



IncludeFile "pbjsBridge/pbjsBridge.pb"


; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 447
; FirstLine = 428
; Folding = -----------
; EnableThread
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 714
; FirstLine = 709
; Folding = ------------
; EnableThread
; EnableXP
; DPIAware
; Executable = ../../main.exe