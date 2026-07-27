; ============================================================================
; UNIFIED WINDOW COMMUNICATION BRIDGE FOR PUREBASIC WEBVIEW
; Simple peer-to-peer window communication with unified invoke method
; ============================================================================


DeclareModule JSBridge
  
  Declare InitializeBridge(windowName.s, window.i, sink.i)  ; sink: gadget (native) or negative headless handle
  Declare.s WithBridgeScript(html.s, windowName.s)
  Declare GetJSWindowByName(windowName.s)
  Declare.s GetJSWindowNameByID(window.i)
  Declare.s GetStartUpJS(windowName.s)
  Declare.s EscapeJSON(text.s)
  Declare SendParameters(*JSWindow, paramsJson.s)
  Declare SendCloseCheck(*JSWindow)
  ; Native-owned system requests use the normal PBJS request/reply transport,
  ; but their replies return to PureBasic rather than another web window.
  Prototype SystemResponseHandler(requestName.s, fromWindow.s, dataJson.s)
  Declare RegisterSystemResponseHandler(*handler.SystemResponseHandler)
  Declare SendSystemRequest(*JSWindow, requestName.s, paramsJson.s = "{}")
  Declare FlushPendingMessages(*JSWindow)
  Declare NotifyWindowEvent(subjectName.s, kind.s)
EndDeclareModule


; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 12
; Folding = -
; EnableXP
; DPIAware
