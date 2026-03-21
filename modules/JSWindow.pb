
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
    #Event_Prepare_Complete
  EndEnumeration
  Enumeration #PB_Event_FirstCustomValue
    #JSWindow_Behaviour_HideWindow
    #JSWindow_Behaviour_CloseWindow
  EndEnumeration
  
  Declare CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, *Parent.AppWindow = 0, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0, debugUrl.s="")
  Declare PrepareJSWindow(*Window.AppWindow)
  Declare OpenJSWindow(*Window.AppWindow )    
  Declare HideJSWindow(*Window.AppWindow, FromManagedWindow)
  Declare CloseJSWindow(*Window.AppWindow)
  Declare ResizeJSWindow(*Window.AppWindow, x, y, w, h)
  Declare GetWebView(*Window.AppWindow)
  
  Structure JSWindow
    Name.s
    *Parent.AppWindow
    
    Window.i
    WebViewGadget.i
    
    ;Stages
    OpenTime.i
    LoadedCode.b
    Ready.b
    Open.b
    Visible.b
    
    BypassCloseCheck.b ; Flag to indicate if we can skip the JS check
    
    CloseBehaviour.i
    LastLocation.s
    
    Html.s
    
    StartupJS.s
    WindowJS.s
    
    List PendingMessages.s()
    
    *HtmlStart
    *HtmlEnd
    *WindowReadyProc.ProtoWindowReady
    *ResizeProc.ResizeCallback  ; Optional callback for resize/move events
    
    ; Prepare window state
    PrepareOriginalX.i
    PrepareOriginalY.i
    
  EndStructure 
  
  Global NewMap JSWindows.JSWindow()
  Global NewMap WindowsByName.i()
  
  Global AppClosing = #False 
  Global ClosingScope = 0 ; 0: None, -1: App, >0: WindowID
  Global ReloadedJS = #False 
  
  Declare RequestClose(Scope)
  Declare CheckCloseProgress()
  Declare CancelClose(Reason.s="")
  
EndDeclareModule


Module JSWindow
  UseModule OsTheme
  UseModule Ptym
  
  Declare UpdateWebViewScale(gadget, width, height)
  Declare HandleEvent(*Window.AppWindow, Event.i, Gadget.i, Type.i)
  Declare ForceContentVisible(window)
  Declare JSIsWindowOpen(JsonParameters.s)
  
  
  ; For Windows
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Declare WindowCallback(hWnd, uMsg, WParam, LParam)
  CompilerEndIf
  
  Prototype.i ProtoWindowReady(*Window, *JSWindow)
  
  Procedure MakeContentVisible(window)
    
    CompilerIf #PB_Compiler_OS = #PB_OS_Linux
      Delay(100) 
    CompilerElseIf #PB_Compiler_OS = #PB_OS_MacOS
      Delay(16)  
    CompilerElse 
      Delay(100)  
    CompilerEndIf
    
    
    If IsWindow(window)
      PostEvent(#CustomWindowEvent, window, 0,#Event_Content_Ready) 
    EndIf 
  EndProcedure
  
  Procedure LogToDebugFile(message.s)
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
    
    If window <> 0
      *Window.AppWindow = GetManagedWindowFromWindowHandle(WindowID(window))
      
      If Not JSWindows(Str(window))\Ready
        LogToDebugFile("JSReadyState: Initial Ready for window " + Str(window))
      Else
        LogToDebugFile("JSReadyState: Subsequent Ready (Reload) for window " + Str(window))
      EndIf
      
      JSWindows(Str(window))\Ready = #True
      CreateThread(@MakeContentVisible(),window)
      ReloadedJS = #True
    Else
      LogToDebugFile("ERROR: Invalid Window ID (0)")
    EndIf
    
    ; FLUSH PENDING MESSAGES
    JSBridge::FlushPendingMessages(@JSWindows(Str(window))) 
    
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
  
  
  
  Procedure UpdateWebViewScale(*JSWindow.JSWindow, width, height)
    
    Protected script$ = "if(window.pbjsUpdateScale) window.pbjsUpdateScale(" + Str(width) + "," + Str(height) + ");"
    
    
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      If IsIconic_(WindowID(*JSWindow\Window))
        ProcedureReturn
      EndIf
    CompilerEndIf
    
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
  
  
  
  Procedure PreparePbjsBasicScript(*JSWindow.JSWindow)
    window.i = *JSWindow\Window
    webViewGadget.i = *JSWindow\WebViewGadget
    width = WindowWidth(window)
    height = WindowHeight(window)
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
                          ""+
                          " window.pbjsDocumentReady = function () {" +
                          "  setTimeout(()=>{"+
                          "    document.body.classList.add('pbjs-document-ready');" +
                          "  },0);"+
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
  
  
  
  Procedure LoadHtml(window)
    html.s = PeekS(JSWindows(Str(window))\HtmlStart,JSWindows(Str(window))\HtmlEnd-JSWindows(Str(window))\HtmlStart, #PB_UTF8|#PB_ByteLength  )
    JSWindows(Str(window))\Html.s = html
    PostEvent(#CustomWindowEvent, window, 0,#Event_Loaded_Html)
  EndProcedure 
  
  
  Procedure BindWebviewEvents(webViewGadget)
    BindWebViewCallback(webViewGadget, "callbackReadyState", @JSReadyState())
    BindWebViewCallback(webViewGadget, "pbjsNativeGetWindow", @JSGetWindow())
    BindWebViewCallback(webViewGadget, "pbjsNativeOpenWindow", @JSOpenWindow())
    BindWebViewCallback(webViewGadget, "pbjsNativeHideWindow", @JSHideWindow())
    BindWebViewCallback(webViewGadget, "pbjsNativeCloseWindow", @JSCloseWindow())
    BindWebViewCallback(webViewGadget, "pbjsNativeIsWindowOpen", @JSIsWindowOpen())
  EndProcedure 
  
  
  
  Procedure.i CreateJSWindow(windowName.s,x,y,w,h,title.s,flags, *htmlStart,*htmlStop, *Parent.AppWindow = 0, CloseBehaviour= #JSWindow_Behaviour_HideWindow, *WindowReadyCallback=0, *ResizeCallback.ResizeCallback=0, debugUrl.s="")
    
    Protected parentWindowID = 0
    If *Parent And IsWindow(*Parent\Window)
      parentWindowID = WindowID(*Parent\Window)
    EndIf
    
    window = OpenWindow(#PB_Any,x,y,w,h,title.s,flags| #PB_Window_Invisible,parentWindowID)
    
    If window
      webViewGadget = WebViewGadget(#PB_Any, 0, 0, MaxDesktopWidth, MaxDesktopHeight, #PB_WebView_Debug)
      
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        CocoaMessage(0, GadgetID(webViewGadget), "setBorderType:", 0) 
      CompilerEndIf
      
      *Window.AppWindow = AddManagedWindow(title, window, @HandleEvent(), @HideJSWindow() , @CloseJSWindow())
      
      Protected hWnd = WindowID(window)
      
      SetWindowColor(window, themeBackgroundColor)

      CompilerIf #PB_Compiler_OS = #PB_OS_Windows
        SetWindowLongPtr_(WindowID(window), #GWL_STYLE, GetWindowLongPtr_(WindowID(window), #GWL_STYLE) | #WS_CLIPCHILDREN)
        ApplyThemeToWinHandle(hWnd)
        SetWindowCallback(@WindowCallback(),window, #PB_Window_NoChildEvents)
      CompilerEndIf
      
      CompilerIf Not #Debug_On
        
        CompilerIf #PB_Compiler_OS = #PB_OS_Windows Or #PB_Compiler_OS = #PB_OS_Linux 
          ResizeGadget(webViewGadget,-1000000000,1000000000,#PB_Ignore,#PB_Ignore)
        CompilerElse 
          HideGadget(webViewGadget,#True)
        CompilerEndIf 
      CompilerEndIf 
      
      BindWebviewEvents(webViewGadget)
      
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
      
      WindowsByName(windowName) = window
      JSBridge::InitializeBridge(windowName, window, webViewGadget)
      
      ; Register for live resize notifications on macOS
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        MacOSRegisterResizeNotifications(*Window)
      CompilerEndIf
      
      CreateThread(@LoadHtml(),window)
      
      CompilerIf  #Debug_On; remote debugging
        PreparePbjsBasicScript(*JSWindow.JSWindow)

        
        If debugUrl <> ""
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
      Debug "[OpenJSWindow] *JSWindow\Visible = " + Str(*JSWindow\Visible) + ", *JSWindow\Ready = " + Str(*JSWindow\Ready)
      If *JSWindow\Visible
        manualOpen = #False
        Debug "[OpenJSWindow] Taking FAST path (manualOpen = #False)"
      Else
        CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
          manualOpen = #True
          Debug "[OpenJSWindow] Taking SLOW path (manualOpen = #True, Mac)"
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
        Debug "[OpenJSWindow] Creating ForceContentVisible thread (this adds 600ms delay!)"
        CreateThread(@ForceContentVisible(),*Window\Window)
      Else
        Debug "[OpenJSWindow] Skipping ForceContentVisible (already visible)"
      EndIf 
    EndIf 
    Debug "[OpenJSWindow] END at " + Str(ElapsedMilliseconds() - startTime) + "ms"
  EndProcedure
  
  ; Thread procedure for non-blocking prepare
  Procedure PrepareJSWindowThread(windowHandle.i)
    Protected *JSWindow.JSWindow = JSWindows(Str(windowHandle))
    If *JSWindow = 0
      Debug "[PrepareJSWindowThread] JSWindow not found for handle: " + Str(windowHandle)
      ProcedureReturn
    EndIf
    
    Debug "[PrepareJSWindowThread] Waiting for Ready..."
    
    ; Wait for content to be ready (max 2 seconds)
    Protected i, maxWait = 200
    For i = 0 To maxWait
      If *JSWindow\Ready
        Debug "[PrepareJSWindowThread] Ready after " + Str(i * 10) + "ms"
        Break
      EndIf
      Delay(10)
    Next
    
    ; Mark as visible-ready so OpenJSWindow skips ForceContentVisible delay
    Debug "[PrepareJSWindowThread] Setting Visible = #True"
    *JSWindow\Visible = #True
    
    ; Post event to main thread to hide window
    PostEvent(#CustomWindowEvent, windowHandle, 0, #Event_Prepare_Complete)
    
    Debug "[PrepareJSWindowThread] END"
  EndProcedure
  
  Procedure PrepareJSWindow(*Window.AppWindow)  
    Debug "[PrepareJSWindow] START (non-blocking)"
    If IsWindow(*Window\Window)
      Protected WinID = WindowID(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      Protected windowHandle = *Window\Window
      
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
        ; FIRST: Set alpha to 0 before ANY showing to prevent flash
        Debug "[PrepareJSWindow] Win: Setting alpha to 0, moving off-screen, showing"
        Protected currentStyle = GetWindowLongPtr_(WinID, #GWL_EXSTYLE)
        SetWindowLongPtr_(WinID, #GWL_EXSTYLE, currentStyle | #WS_EX_LAYERED)
        SetLayeredWindowAttributes_(WinID, 0, 0, #LWA_ALPHA)  ; Alpha 0 = invisible
        
        ; Move off-screen
        ResizeWindow(*Window\Window, minValue, minValue, #PB_Ignore, #PB_Ignore)
        
        ; Now show window (it's invisible because alpha=0)
        HideWindow(*Window\Window, #False)
        
      CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
        ; FIRST: Set opacity to 0 before ANY showing to prevent flash
        Debug "[PrepareJSWindow] Linux: Setting opacity to 0, moving off-screen, showing"
        Protected *GtkWidget = WinID
        If *GtkWidget
          gtk_widget_set_opacity_(*GtkWidget, 0.0)
        EndIf
        
        ; Move off-screen
        ResizeWindow(*Window\Window, minValue, minValue, #PB_Ignore, #PB_Ignore)
        
        ; Now show window (it's invisible because opacity=0)
        HideWindow(*Window\Window, #False)
      CompilerEndIf
      
      ; Start background thread to wait for Ready
      CreateThread(@PrepareJSWindowThread(), windowHandle)
      
      Debug "[PrepareJSWindow] Thread started, returning immediately"
    EndIf 
  EndProcedure
  
  
  Procedure HideJSWindow(*Window.AppWindow, FromManagedWindow)
    If IsWindow(*Window\Window)
      Protected *JSWindow.JSWindow = JSWindows(Str(*Window\Window))
      
      If *Window\Open 
        HideWindow(*Window\Window,#True)
        
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
  
  
  Procedure CloseJSWindow(*Window.AppWindow)
    Protected *JSWindow.JSWindow
    If *Window <> 0 And IsWindow(*Window\Window)
      *JSWindow = JSWindows(Str(*Window\Window))
      
      
      If Not *Window\Closed 
        CloseManagedWindow(*Window)
      EndIf 
      CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
        MacOSUnregisterResizeNotifications(*Window)
      CompilerEndIf
      If IsWindow(*Window\Window)
        DeleteMapElement(JSWindows(), Str(*Window\Window))
        CloseWindow(*Window\Window)
      EndIf 
      
      If *JSWindow And *JSWindow\Parent
        If IsWindow(*JSWindow\Parent\Window)
          SetActiveWindow(*JSWindow\Parent\Window)
        EndIf
      EndIf
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
      EndIf 
    EndIf 
    
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
      ProcedureReturn #True 
    EndIf 
    
    ProcedureReturn #False 
    
  EndProcedure
  
  CompilerIf #Debug_On
    
    Global DEBUGMODEoldLocation.s
    Global DEBUGMODEinjectStartupOnce = #False 
    
    Procedure CallbackLocation(jsonParameters.s)
      Dim Parameters.s(0)
      ParseJSON(0, jsonParameters)
      ExtractJSONArray(JSONValue(0), Parameters())
      
      window.s = Parameters(0)
      location.s = Parameters(1)
      
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
    
    CompilerIf #Debug_On
      webViewGadget = *JSWindow\WebViewGadget
      If (Not *JSWindow\Ready Or DEBUGMODEinjectStartupOnce) And ElapsedMilliseconds() - DEBUGMODEcheckTime > 300
        DEBUGMODEinjectStartupOnce = #False 
        BindWebviewEvents(webViewGadget)
        DEBUGMODEcheckTime =  ElapsedMilliseconds() 
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
            CompilerIf Not #Debug_On
              
              webViewGadget = *JSWindow\WebViewGadget
              
              html.s =  JSBridge::WithBridgeScript(*JSWindow\Html, *JSWindow\Name)
              html.s =  WithPbjsBasicScript(html, *JSWindow)

              
              
              
              SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
              *JSWindow\LoadedCode = #True 
            CompilerEndIf 
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
            
            Debug " #Event_Content_Ready "+*JSWindow\Name
            
            HideGadget(webViewGadget,#False)
            
            If *JSWindow\Open And Not *JSWindow\Visible
              HideWindow(*JSWindow\Window, #False)
            EndIf 
            *JSWindow\Visible = #True 
            
            SetBodyFadeIn(*JSWindow)
            
            If *JSWindow\Ready
              If *JSWindow\WindowReadyProc
                CallFunctionFast(*JSWindow\WindowReadyProc, *Window , *JSWindow)
              EndIf 
            EndIf 
            
          Case #Event_Prepare_Complete
            Debug "[Event_Prepare_Complete] Hiding and restoring position for " + *JSWindow\Name
            
            Protected PrepWinID = WindowID(*JSWindow\Window)
            
            CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
              ; Use Cocoa to hide - orderOut removes from screen without affecting PB state
              CocoaMessage(0, PrepWinID, "orderOut:", #Null)
              
              ; Restore alpha to 1.0
              Protected restoreAlpha.d = 1.0
              CocoaMessage(0, PrepWinID, "setAlphaValue:@", @restoreAlpha)
            CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
              HideWindow(*JSWindow\Window, #True)
              SetLayeredWindowAttributes_(PrepWinID, 0, 255, #LWA_ALPHA)
            CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
              HideWindow(*JSWindow\Window, #True)
              gtk_widget_set_opacity_(PrepWinID, 1.0)
            CompilerEndIf
            
            ; Restore original position
            ResizeWindow(*JSWindow\Window, *JSWindow\PrepareOriginalX, *JSWindow\PrepareOriginalY, #PB_Ignore, #PB_Ignore)
            
            Debug "[Event_Prepare_Complete] Done for " + *JSWindow\Name
            
        EndSelect 
        
    EndSelect
    
    If closeWindow
      Debug "CLOSE WINDOW"
      
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
          ProcedureReturn #True
          
      EndSelect
      
      ProcedureReturn #PB_ProcessPureBasicEvents 
    EndProcedure
  CompilerEndIf
  
  
  Procedure ForceContentVisible(window)
    Delay(600)
    If IsWindow(window)
      If Not JSWindows(Str(window))\Ready 
        PostEvent(#CustomWindowEvent, window, 0,#Event_Content_Ready) 
      EndIf 
    EndIf 
  EndProcedure
  
EndModule
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 102
; FirstLine = 97
; Folding = ----------
; EnableXP
; DPIAware