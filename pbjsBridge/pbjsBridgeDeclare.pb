; ============================================================================
; UNIFIED WINDOW COMMUNICATION BRIDGE FOR PUREBASIC WEBVIEW
; Simple peer-to-peer window communication with unified invoke method
; ============================================================================


DeclareModule JSBridge
  
  Declare InitializeBridge(windowName.s, window.i, webViewGadget.i)
  Declare.s WithBridgeScript(html.s, windowName.s)
  Declare GetJSWindowByName(windowName.s)
  Declare.s GetJSWindowNameByID(window.i)
  Declare.s GetStartUpJS(windowName.s)
  Declare.s EscapeJSON(text.s)
  Declare SendParameters(*JSWindow, paramsJson.s)
  Declare FlushPendingMessages(*JSWindow)
EndDeclareModule


; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 12
; Folding = -
; EnableXP
; DPIAware