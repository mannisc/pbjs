
;=====================================================================
;-  Window Dark Mode Support
;=====================================================================
DeclareModule OsTheme
  Declare IsDarkModeActive()
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare ApplyThemeToWinHandle(hWnd)
    ; Raw dynamic DwmSetWindowAttribute (returns HRESULT, or 0 when dwmapi.dll
    ; is unavailable — 0 is also S_OK, so callers must not branch on it).
    Declare.i DwmSetWindowAttributeDynamic(hwnd.i, dwAttribute.i, *pvAttribute, cbAttribute.i)
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
  
  #Debug_On = #PB_Compiler_Debugger  
  
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
      Protected isDark = #False
      Protected determined = #False
      Protected prog, file, line$, theme$, cmd$, tmp$
      
      ; --- 1️⃣ Try freedesktop.org unified color-scheme (Modern Standard)
      If Not determined
        prog = RunProgram("gsettings", "get org.freedesktop.appearance color-scheme", "", #PB_Program_Open | #PB_Program_Read)
        If prog
          tmp$ = Trim(ReadProgramString(prog), "'")
          CloseProgram(prog)
          If LCase(tmp$) = "prefer-dark"
            isDark = #True
            determined = #True
          ElseIf LCase(tmp$) = "prefer-light"
            isDark = #False
            determined = #True
          EndIf
          ; "default" or empty -> Not determined, fall through
        EndIf
      EndIf
      
      ; --- 1.5️⃣ Try XDG Desktop Portal via gdbus (Wayland/Strict Sandbox Standard)
      If Not determined
        ; gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.portal.Settings.Read org.freedesktop.appearance color-scheme
        prog = RunProgram("gdbus", "call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.portal.Settings.Read org.freedesktop.appearance color-scheme", "", #PB_Program_Open | #PB_Program_Read)
        If prog
          tmp$ = ""
          While AvailableProgramOutput(prog)
            tmp$ + ReadProgramString(prog)
          Wend
          CloseProgram(prog)
          ; Output format: (<<uint32 1>>, ) where 1=dark, 2=light, 0=no preference
          If FindString(tmp$, "uint32 1")
            isDark = #True
            determined = #True
          ElseIf FindString(tmp$, "uint32 2")
            isDark = #False
            determined = #True
          EndIf
        EndIf
      EndIf

      ; --- 2️⃣ Try GNOME prefer-dark-theme (Older Standard)
      If Not determined
        prog = RunProgram("gsettings", "get org.gnome.desktop.interface prefer-dark-theme", "", #PB_Program_Open | #PB_Program_Read)
        If prog
          tmp$ = Trim(ReadProgramString(prog), "'")
          CloseProgram(prog)
          If tmp$ = "true" Or tmp$ = "1"
            isDark = #True
            determined = #True
          ElseIf tmp$ = "false" Or tmp$ = "0"
            ; Arguably this means explicit light preference, specifically for GNOME-ish setups
            ; determining here might skip the theme name check which might be "PiXOnyx" on a system that returns false here?
            ; Safer to only confirm DARK here, unless we are sure.
            ; Standard behavior: If this is explicitly set to false, it usually means "Don't force dark". 
            ; It DOES NOT necessarily mean "Force Light". So we continue if false to check theme name.
          EndIf
        EndIf
      EndIf

      ; --- 3️⃣ Try GTK Theme Name (The catch-all fallback)
      If Not determined
        prog = RunProgram("gsettings", "get org.gnome.desktop.interface gtk-theme", "", #PB_Program_Open | #PB_Program_Read)
        If prog
          theme$ = Trim(ReadProgramString(prog), "'")
          CloseProgram(prog)
          theme$ = LCase(theme$)
          If FindString(theme$, "dark") Or FindString(theme$, "noir") Or FindString(theme$, "onyx")
            isDark = #True
            determined = #True
          ElseIf theme$ <> ""
             ; found a theme name but it didn't have dark keywords.
             ; likely light mode. But config files might override?
             ; Let's assume if we found a valid theme string that isn't dark, it's light.
             ; UNLESS it's empty.
             isDark = #False
             determined = #True
          EndIf
        EndIf
      EndIf
      
      ; --- 4️⃣ Try Config Files (KDE, GTK, LXDE) - Only if execution methods failed
      
      ; KDE Plasma
      If Not determined And FileSize(GetHomeDirectory() + ".config/kdeglobals") > 0
        file = ReadFile(#PB_Any, GetHomeDirectory() + ".config/kdeglobals")
        If file
          While Eof(file) = 0
            line$ = ReadString(file)
            If Left(line$, 11) = "ColorScheme"
              theme$ = Trim(StringField(line$, 2, "="))
              If FindString(LCase(theme$), "dark") Or FindString(LCase(theme$), "noir") Or FindString(LCase(theme$), "onyx")
                isDark = #True
                determined = #True
              Else
                isDark = #False
                determined = #True
              EndIf
              Break
            EndIf
          Wend
          CloseFile(file)
        EndIf
      EndIf
      
      ; GTK 3.0 Settings
      If Not determined And FileSize(GetHomeDirectory() + ".config/gtk-3.0/settings.ini") > 0
        file = ReadFile(#PB_Any, GetHomeDirectory() + ".config/gtk-3.0/settings.ini")
        If file
          While Eof(file) = 0
            line$ = ReadString(file)
            If FindString(line$, "gtk-application-prefer-dark-theme")
               tmp$ = LCase(StringField(line$, 2, "="))
               If FindString(tmp$, "1") Or FindString(tmp$, "true")
                 isDark = #True
                 determined = #True
                 Break
               EndIf
            EndIf
            If FindString(line$, "gtk-theme-name")
              theme$ = LCase(StringField(line$, 2, "="))
              If FindString(theme$, "dark") Or FindString(theme$, "noir") Or FindString(theme$, "onyx")
                isDark = #True
                determined = #True
                Break
              EndIf
            EndIf
          Wend
          CloseFile(file)
        EndIf
      EndIf

      ; Legacy LXDE (Raspberry Pi)
      If Not determined And FileSize(GetHomeDirectory() + ".config/lxsession/LXDE-pi/desktop.conf") > 0
         file = ReadFile(#PB_Any, GetHomeDirectory() + ".config/lxsession/LXDE-pi/desktop.conf")
         If file
           While Eof(file) = 0
             line$ = ReadString(file)
             If FindString(line$, "sNet/ThemeName")
               theme$ = LCase(StringField(line$, 2, "="))
                If FindString(theme$, "dark") Or FindString(theme$, "noir") Or FindString(theme$, "onyx")
                  isDark = #True
                  determined = #True
                  Break
                EndIf
             EndIf
           Wend
           CloseFile(file)
         EndIf
      EndIf
      
      ProcedureReturn isDark
      
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
