; ============================================================================
; UNIFIED WINDOW COMMUNICATION BRIDGE FOR PUREBASIC WEBVIEW
; Simple peer-to-peer window communication with unified invoke method
; ============================================================================

;;---------------------------
;; Used Module
; DeclareModule JSWindow
;   
;   Structure JSWindow
;     Window.i
;     WebViewGadget.i
;     Name.s
;     Ready.b
;   EndStructure 
;   
;   Global NewMap JSWindows.JSWindow()
;   Global NewMap WindowsByName.i()
;   
; EndDeclareModule
; 
; Module JSWindow
; EndModule
;;---------------------------





Module JSBridge
  UseModule JSWindow
  
  ; ============================================================================
  ; JAVASCRIPT BRIDGE SCRIPT - Loaded from external file
  ; ============================================================================
  
  Global bridgeScript.s
  
  DataSection
    BridgeScript:
    IncludeBinary "pbjsBridgeScript.js"
    EndBridgeScript:
  EndDataSection
  
  
  
  ; ============================================================================
  ; HELPER FUNCTIONS
  ; ============================================================================
  
  Procedure GetJSWindowByName(windowName.s)
    If FindMapElement(WindowsByName(), windowName) 
      ProcedureReturn WindowsByName(windowName)
    EndIf 
    ProcedureReturn -1
  EndProcedure
  
  Procedure.s GetJSWindowNameByID(window.i)
    ForEach JSWindows()
      If JSWindows()\Window = window
        ProcedureReturn JSWindows()\Name
      EndIf
    Next
    ProcedureReturn ""
  EndProcedure
  
  Procedure.s EscapeJSON(text.s)
    Protected result.s
    result = ReplaceString(text, Chr(92), Chr(92)+Chr(92))
    result = ReplaceString(result, Chr(34), Chr(92)+Chr(34))
    result = ReplaceString(result, Chr(13), Chr(92)+"r")
    result = ReplaceString(result, Chr(10), Chr(92)+"n")
    result = ReplaceString(result, Chr(9), Chr(92)+"t")
    ; Escape single quotes LAST (after the backslash pass above, so the
    ; backslash we introduce here is not doubled). Every caller wraps the
    ; result in a single-quoted JS string literal — pbjsHandleMessage('...') —
    ; so an unescaped apostrophe in any payload (e.g. "Tim's shell") would
    ; terminate the literal and throw a SyntaxError, silently dropping the
    ; message. `\'` is a valid escape inside single-quoted JS strings and the
    ; inner JSON stays intact after JS un-escapes it. (Same pattern already
    ; used in pbjsFileSystem.pb.)
    result = ReplaceString(result, Chr(39), Chr(92)+Chr(39))
    ProcedureReturn result
  EndProcedure
  
  Procedure FlushPendingMessages(*JSWindow.JSWindow)
    If *JSWindow
      ForEach *JSWindow\PendingMessages()
        WebViewExecuteScript(*JSWindow\WebViewGadget, *JSWindow\PendingMessages())
      Next
      ClearList(*JSWindow\PendingMessages())
    EndIf
  EndProcedure

  ; Cap per-window pending-message buffers so a slow-to-init (or stuck) window
  ; can't accumulate injected scripts unboundedly. Drops the oldest when full
  ; (FIFO) and counts drops. Replaces the bare AddElement+assign at every
  ; buffering site below. (P2 / pbjs.md §5.3 "Pending queue is unbounded".)
  #MaxPendingMessages = 500
  Global g_DroppedPendingMessages.i = 0
  Procedure QueuePending(*JSWindow.JSWindow, script.s)
    If *JSWindow
      If ListSize(*JSWindow\PendingMessages()) >= #MaxPendingMessages
        If FirstElement(*JSWindow\PendingMessages())
          DeleteElement(*JSWindow\PendingMessages())
          g_DroppedPendingMessages + 1
        EndIf
      EndIf
      LastElement(*JSWindow\PendingMessages())
      AddElement(*JSWindow\PendingMessages())
      *JSWindow\PendingMessages() = script
    EndIf
  EndProcedure
  
  ; ============================================================================
  ; NATIVE CALLBACKS
  ; ============================================================================
  
  
  
  
  Procedure HandleSend(jsonParameters.s)
    Protected json.i, fromWindow.s, toWindow.s, name.s, paramsJson.s, dataJson.s, script.s, messageJson.s
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)  
    If json
      fromWindow = GetJSONString(GetJSONMember(JSONValue(json), "fromWindow"))
      toWindow = GetJSONString(GetJSONMember(JSONValue(json), "toWindow"))
      name = GetJSONString(GetJSONMember(JSONValue(json), "name"))
      paramsJson = GetJSONString(GetJSONMember(JSONValue(json), "params"))
      dataJson = GetJSONString(GetJSONMember(JSONValue(json), "data"))
      
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"" + fromWindow + 
                    ~"\",\"name\":\"" + name + 
                    ~"\",\"params\":" + paramsJson + 
                    ~",\"data\":" + dataJson + ~"}"
      
      Protected targetWindow.i = GetJSWindowByName(toWindow)
      If targetWindow > -1
        ForEach JSWindows()
          If JSWindows()\Window = targetWindow
            script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
            If JSWindows()\Ready
               WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            Else
               QueuePending(@JSWindows(), script)
            EndIf
            Break
          EndIf
        Next
      EndIf
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleGet(jsonParameters.s)
    Protected json.i, fromWindow.s, toWindow.s, name.s, paramsJson.s, dataJson.s, requestId.i, script.s, messageJson.s
    Protected windowNotOpen.b
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    json = ParseJSON(#PB_Any, parameters(0))
    
    If json
      fromWindow = GetJSONString(GetJSONMember(JSONValue(json), "fromWindow"))
      toWindow = GetJSONString(GetJSONMember(JSONValue(json), "toWindow"))
      name = GetJSONString(GetJSONMember(JSONValue(json), "name"))
      paramsJson = GetJSONString(GetJSONMember(JSONValue(json), "params"))
      dataJson = GetJSONString(GetJSONMember(JSONValue(json), "data"))
      requestId = GetJSONInteger(GetJSONMember(JSONValue(json), "requestId"))
      
      messageJson = ~"{\"type\":\"get\",\"fromWindow\":\"" + fromWindow + 
                    ~"\",\"name\":\"" + name + 
                    ~"\",\"params\":" + paramsJson +   
                    ~",\"data\":" + dataJson + 
                    ~",\"requestId\":" + Str(requestId) + ~"}"
      
      Protected targetWindow.i = GetJSWindowByName(toWindow)
      If targetWindow > -1
        ForEach JSWindows()
          If JSWindows()\Window = targetWindow
            If Not JSWindows()\Open
              ; Window is registered but currently closed.
              ; Set flag and break — error response is sent below.
              windowNotOpen = #True
            Else
              script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
              If JSWindows()\Ready
                 WebViewExecuteScript(JSWindows()\WebViewGadget, script)
              Else
                 QueuePending(@JSWindows(), script)
              EndIf
            EndIf
            Break
          EndIf
        Next
      EndIf
      
      ; Send immediate error back to caller when target window is not found or not open.
      ; Both cases use the same response path so the caller's .catch() fires right away
      ; instead of waiting for the 30s pending-request timeout.
      If targetWindow = -1 Or windowNotOpen
        Protected errorMsg.s
        If windowNotOpen
          errorMsg = "Window not open: " + toWindow
        Else
          errorMsg = "Window not found: " + toWindow
        EndIf
        
        Protected sourceWindow.i = GetJSWindowByName(fromWindow)
        If sourceWindow > -1
          ForEach JSWindows()
            If JSWindows()\Window = sourceWindow
              script = "pbjsHandleResponse('" + EscapeJSON(~"{\"requestId\":" + Str(requestId) + 
                                                           ~",\"fromWindow\":\"" + toWindow + 
                                                           ~"\",\"data\":{\"error\":\"" + errorMsg + ~"\"}}") + "');"
               If JSWindows()\Ready
                 WebViewExecuteScript(JSWindows()\WebViewGadget, script)
               Else
                 QueuePending(@JSWindows(), script)
               EndIf
               Break
            EndIf
          Next
        EndIf
      EndIf
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleSendAll(jsonParameters.s)
    Protected json.i, fromWindow.s, name.s, paramsJson.s, dataJson.s, script.s, messageJson.s, count.i
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)    
    If json
      fromWindow = GetJSONString(GetJSONMember(JSONValue(json), "fromWindow"))
      name = GetJSONString(GetJSONMember(JSONValue(json), "name"))
      paramsJson = GetJSONString(GetJSONMember(JSONValue(json), "params"))
      dataJson = GetJSONString(GetJSONMember(JSONValue(json), "data"))
      
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"" + fromWindow + 
                    ~"\",\"name\":\"" + name + 
                    ~"\",\"params\":" + paramsJson + 
                    ~",\"data\":" + dataJson + ~"}"
      
      script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"

      ForEach JSWindows()
        ; Skip pool spares: they are dormant, off-screen template windows that
        ; are not assigned to any caller and should not receive broadcasts.
        If JSWindows()\Name <> fromWindow And Not JSWindows()\IsPoolSpare
          If JSWindows()\Ready
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
          Else
            QueuePending(@JSWindows(), script)
          EndIf
          count + 1
        EndIf
      Next
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleGetAll(jsonParameters.s)
    Protected json.i, fromWindow.s, name.s, paramsJson.s, dataJson.s, requestId.i, script.s, messageJson.s
    Protected count.i, sourceWindow.i
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)    
    If json
      fromWindow = GetJSONString(GetJSONMember(JSONValue(json), "fromWindow"))
      name = GetJSONString(GetJSONMember(JSONValue(json), "name"))
      paramsJson = GetJSONString(GetJSONMember(JSONValue(json), "params"))
      dataJson = GetJSONString(GetJSONMember(JSONValue(json), "data"))
      requestId = GetJSONInteger(GetJSONMember(JSONValue(json), "requestId"))
      
      ; Count broadcast targets. Must use the SAME predicate as the multicast
      ; loop below, or expectedCount won't match the windows that can reply.
      ; Pool spares are excluded: a warming spare never registers the handler,
      ; so it would never reply and invokeAll would hang to the 30s timeout.
      count = 0
      ForEach JSWindows()
        If JSWindows()\Name <> fromWindow And Not JSWindows()\IsPoolSpare
          count + 1
        EndIf
      Next
      
      sourceWindow = GetJSWindowByName(fromWindow)
      If sourceWindow > -1
        ForEach JSWindows()
          If JSWindows()\Window = sourceWindow
            script = "pbjsSetGetAllExpectedCount(" + Str(requestId) + ", " + Str(count) + ");"
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            Break
          EndIf
        Next
      EndIf
      
      If count > 0
        messageJson = ~"{\"type\":\"getAll\",\"fromWindow\":\"" + fromWindow + 
                      ~"\",\"name\":\"" + name + 
                      ~"\",\"params\":" + paramsJson + 
                      ~",\"data\":" + dataJson + 
                      ~",\"requestId\":" + Str(requestId) + ~"}"
        
        script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
        
        ForEach JSWindows()
          ; Same predicate as the count loop above (excludes pool spares).
          If JSWindows()\Name <> fromWindow And Not JSWindows()\IsPoolSpare
            If IsGadget(JSWindows()\WebViewGadget)
              WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            EndIf
          EndIf
        Next
      EndIf
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleReply(jsonParameters.s)
    Protected json.i, toWindow.s, fromWindow.s, requestId.i, dataJson.s, script.s, responseJson.s
    Protected isGetAll.i
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)    
    If json
      toWindow = GetJSONString(GetJSONMember(JSONValue(json), "toWindow"))
      fromWindow = GetJSONString(GetJSONMember(JSONValue(json), "fromWindow"))
      requestId = GetJSONInteger(GetJSONMember(JSONValue(json), "requestId"))
      dataJson = GetJSONString(GetJSONMember(JSONValue(json), "data"))
      isGetAll = GetJSONBoolean(GetJSONMember(JSONValue(json), "isGetAll"))
      
      If toWindow = "system"
        ; --- SYSTEM MESSAGE HANDLING (e.g. Close Check) ---
        Protected *SourceJSWindow.JSWindow = 0
        Protected sourceWindowID.i = GetJSWindowByName(fromWindow)
        If sourceWindowID > -1
           ForEach JSWindows()
             If JSWindows()\Window = sourceWindowID
               *SourceJSWindow = @JSWindows()
               Break
             EndIf
           Next
        EndIf
        
        If *SourceJSWindow
          ; Check response data
          ; dataJson is a JSON string of the object returned by JS
          Protected dataObj = ParseJSON(#PB_Any, dataJson)
          If dataObj
             Protected success = #False
             Protected val = JSONValue(dataObj)
             If JSONType(val) = #PB_JSON_Boolean
                success = GetJSONBoolean(val)
             ElseIf JSONType(val) = #PB_JSON_Object
                If GetJSONMember(val, "success")
                   success = GetJSONBoolean(GetJSONMember(val, "success"))
                EndIf 
             EndIf
             FreeJSON(dataObj)
             
               If success

                If JSWindow::ClosingScope <> 0
               *SourceJSWindow\BypassCloseCheck = #True
               ; Post a close event to retry closing
               ; PostEvent removed - let CheckCloseProgress handle it
               
               If JSWindow::ClosingScope <> 0
                  JSWindow::CheckCloseProgress()
                EndIf
                EndIf 
               
             Else
               
               If JSWindow::ClosingScope <> 0
                 JSWindow::CancelClose(*SourceJSWindow\Name + " refused to close")
               EndIf 
               
             EndIf
          EndIf
        EndIf
        ; -----------------------------------------------
      Else
      
        responseJson = ~"{\"requestId\":" + Str(requestId) + 
                       ~",\"fromWindow\":\"" + fromWindow + 
                       ~"\",\"data\":" + dataJson + 
                       ~",\"isGetAll\":" + Str(isGetAll) + ~"}"
        
        Protected targetWindow.i = GetJSWindowByName(toWindow)
        If targetWindow > -1
          ForEach JSWindows()
            If JSWindows()\Window = targetWindow
              script = "pbjsHandleResponse('" + EscapeJSON(responseJson) + "');"
              If JSWindows()\Ready
                 WebViewExecuteScript(JSWindows()\WebViewGadget, script)
              Else
                 QueuePending(@JSWindows(), script)
              EndIf
              Break
            EndIf
          Next
        EndIf
      
      EndIf
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleLog(jsonParameters.s)
    Protected json.i, level.s, message.s, windowName.s
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)
    If json
      level = GetJSONString(GetJSONMember(JSONValue(json), "level"))
      message = GetJSONString(GetJSONMember(JSONValue(json), "message"))
      windowName = GetJSONString(GetJSONMember(JSONValue(json), "window"))
      
      Debug "[JS][" + windowName + "] " + level + ": " + message
      
      FreeJSON(json)
    EndIf
  EndProcedure

  Procedure SendParameters(*JSWindow.JSWindow, paramsJson.s)
    If *JSWindow And IsGadget(*JSWindow\WebViewGadget)
      Protected messageJson.s
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"system\",\"name\":\"handleParameters\",\"params\":" + paramsJson + ~",\"data\":{}}"
      
      Protected escapedJson.s
      escapedJson = EscapeJSON(messageJson)
      
      Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + escapedJson + "');"
      If *JSWindow\Ready
         WebViewExecuteScript(*JSWindow\WebViewGadget, script)
      Else
         QueuePending(*JSWindow, script)
      EndIf
    EndIf
  EndProcedure

  Procedure SendCloseCheck(*JSWindow.JSWindow)
    Debug "[SEND_CLOSE_CHECK] ENTER. Window=" + *JSWindow\Name
    If *JSWindow And IsGadget(*JSWindow\WebViewGadget)
      Protected requestId.i = ElapsedMilliseconds() 
      
      Protected messageJson.s
      messageJson = ~"{\"type\":\"get\",\"fromWindow\":\"system\",\"name\":\"close-window\",\"params\":{},\"data\":{},\"requestId\":" + Str(requestId) + "}"
      
      Protected escapedJson.s
      escapedJson = EscapeJSON(messageJson)
      
      Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + escapedJson + "');"
      If *JSWindow\Ready
         WebViewExecuteScript(*JSWindow\WebViewGadget, script)
      Else
         ; Window not ready - auto-approve since JS cannot respond
         *JSWindow\BypassCloseCheck = #True
         JSWindow::CheckCloseProgress()
      EndIf
    EndIf
  EndProcedure
  
  ; ============================================================================
  ; INITIALIZATION
  ; ============================================================================
  
  Procedure InitializeBridge(windowName.s, window.i, webViewGadget.i)
    Protected windowKey.s
    
    If Trim(windowName) = ""
      Debug "Error: Window name cannot be empty"
      ProcedureReturn #False
    EndIf
    
    BindWebViewCallback(webViewGadget, "pbjsNativeSend", @HandleSend())
    BindWebViewCallback(webViewGadget, "pbjsNativeGet", @HandleGet())
    BindWebViewCallback(webViewGadget, "pbjsNativeSendAll", @HandleSendAll())
    BindWebViewCallback(webViewGadget, "pbjsNativeGetAll", @HandleGetAll())
    BindWebViewCallback(webViewGadget, "pbjsNativeReply", @HandleReply())
    BindWebViewCallback(webViewGadget, "pbjsNativeLog", @HandleLog())
    
    ProcedureReturn window
  EndProcedure
  
  ; ============================================================================
  ; HTML WRAPPER
  ; ============================================================================
  
  
  Procedure.s PrepateBridgeScript(windowName.s)
    
    Protected bodyPos.i, bodyEndPos.i, initScript.s, bridgeScriptWithName.s
    
    
    ; Load the bridge script
    Define *buffer = ?BridgeScript
    Define size.i = ?EndBridgeScript - ?BridgeScript
    bridgeScript = PeekS(*buffer, size, #PB_UTF8|#PB_ByteLength)
    
    bridgeScript = ReplaceString(bridgeScript, "_WINDOW_NAME_INJECTED_BY_NATIVE_", windowName)
    
    Protected osName.s
    CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
      osName = "mac"
    CompilerElseIf  #PB_Compiler_OS = #PB_OS_Windows
      osName = "windows"
    CompilerElseIf #PB_Compiler_OS = #PB_OS_Linux
      osName = "linux"
    CompilerElse
      osName = "other"
    CompilerEndIf 
    
    bridgeScript = ReplaceString(bridgeScript, "_OS_NAME_INJECTED_BY_NATIVE_", osName)
    ProcedureReturn bridgeScript
  EndProcedure 
  
  Procedure.s WithBridgeScript(html.s, windowName.s)
    result.s = html
    
    bridgeScript.s = PrepateBridgeScript(windowName)
    
    
    initScript.s = ~"<script>\n" + bridgeScript + ~"</script>\n"
    
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + initScript + Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = initScript + result
    EndIf
    
    
    ProcedureReturn result
  EndProcedure
  
  Procedure.s GetStartUpJS(windowName.s)
    ProcedureReturn PrepateBridgeScript(windowName)
  EndProcedure 
  
EndModule
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 358
; FirstLine = 343
; Folding = ---
; EnableXP
; DPIAware