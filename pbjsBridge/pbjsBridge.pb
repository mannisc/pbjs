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
    ProcedureReturn result
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
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            Break
          EndIf
        Next
      EndIf
      
      FreeJSON(json)
    EndIf
  EndProcedure
  
  Procedure HandleGet(jsonParameters.s)
    Protected json.i, fromWindow.s, toWindow.s, name.s, paramsJson.s, dataJson.s, requestId.i, script.s, messageJson.s
    
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
            script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            Break
          EndIf
        Next
      Else
        Protected sourceWindow.i = GetJSWindowByName(fromWindow)
        If sourceWindow > -1
          ForEach JSWindows()
            If JSWindows()\Window = sourceWindow
              script = "pbjsHandleResponse('" + EscapeJSON(~"{\"requestId\":" + Str(requestId) + 
                                                          ~",\"fromWindow\":\"" + toWindow + 
                                                          ~"\",\"data\":{\"error\":\"Window not found: " + toWindow + ~"\"}}") + "');"
              
              WebViewExecuteScript(JSWindows()\WebViewGadget, script)
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
        If JSWindows()\Name <> fromWindow
          WebViewExecuteScript(JSWindows()\WebViewGadget, script)
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
      
      count = 0
      ForEach JSWindows()
        If JSWindows()\Name <> fromWindow
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
          If JSWindows()\Name <> fromWindow
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
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
      
      responseJson = ~"{\"requestId\":" + Str(requestId) + 
                     ~",\"fromWindow\":\"" + fromWindow + 
                     ~"\",\"data\":" + dataJson + 
                     ~",\"isGetAll\":" + Str(isGetAll) + ~"}"
      
      Protected targetWindow.i = GetJSWindowByName(toWindow)
      If targetWindow > -1
        ForEach JSWindows()
          If JSWindows()\Window = targetWindow
            script = "pbjsHandleResponse('" + EscapeJSON(responseJson) + "');"
            WebViewExecuteScript(JSWindows()\WebViewGadget, script)
            Break
          EndIf
        Next
      EndIf
      
      FreeJSON(json)
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
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 370
; FirstLine = 316
; Folding = -v-
; EnableXP
; DPIAware