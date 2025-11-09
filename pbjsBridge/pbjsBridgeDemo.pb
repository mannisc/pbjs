; ============================================================================
; UNIFIED WINDOW COMMUNICATION BRIDGE FOR PUREBASIC WEBVIEW
; Simple peer-to-peer window communication with unified invoke method
; ============================================================================

DeclareModule JSWindow
  
  Structure JSWindow
    Window.i
    WebViewGadget.i
    Name.s
    Ready.b
  EndStructure 
  
  Global NewMap JSWindows.JSWindow()
  Global NewMap WindowsByName.i()
  
EndDeclareModule

Module JSWindow
EndModule

IncludeFile "pbjsBridgeDeclare.pb"

IncludeFile "pbjsBridge.pb"


; ============================================================================
; EXAMPLE USAGE WITH UNIFIED INVOKE
; ============================================================================

UseModule JSWindow
UseModule JSBridge


  Global windowHTML.s
  
  DataSection
    ContentHtml:
    IncludeBinary "pbjsBridgeDemo.html"
    EndContentHtml:
  EndDataSection
  
  ; Load the bridge script
  Define *buffer = ?ContentHtml
  Define size.i = ?EndContentHtml - ?ContentHtml
  windowHTML = PeekS(*buffer, size, #PB_UTF8|#PB_ByteLength)


If OpenWindow(0, 100, 100, 800, 700, "Window 1", #PB_Window_SystemMenu)
  WebViewGadget(0, 0, 0, 800, 700, #PB_WebView_Debug)
  SetGadgetItemText(0, #PB_WebView_HtmlCode, WithBridgeScript(windowHTML, "Window1"))
  InitializeBridge("Window1", 0, 0)
  WindowsByName("Window1") = 0

EndIf

If OpenWindow(1, 150, 150, 800, 700, "Window 2", #PB_Window_SystemMenu)
  WebViewGadget(1, 0, 0, 800, 700, #PB_WebView_Debug)
  SetGadgetItemText(1, #PB_WebView_HtmlCode, WithBridgeScript(windowHTML, "Window2"))
  InitializeBridge("Window2", 1, 1)
  WindowsByName("Window2") = 1


EndIf

If OpenWindow(2, 200, 200, 800, 700, "Window 3", #PB_Window_SystemMenu)
  WebViewGadget(2, 0, 0, 800, 700, #PB_WebView_Debug)
  SetGadgetItemText(2, #PB_WebView_HtmlCode, WithBridgeScript(windowHTML, "Window3"))
  InitializeBridge("Window3", 2, 2)
  WindowsByName("Window3") = 2

EndIf

Repeat
  event = WaitWindowEvent()
Until event = #PB_Event_CloseWindow
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 68
; FirstLine = 42
; Folding = -
; EnableXP
; DPIAware