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

  Structure PendingSystemRequest
    Name.s
  EndStructure
  Global NewMap PendingSystemRequests.PendingSystemRequest()
  Global NextSystemRequestId.i = 1
  Global *SystemResponseHandler.SystemResponseHandler = 0
  ; requestName -> handler; consulted before the global catch-all above.
  Global NewMap SystemResponseHandlersByName.i()
  
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
    If FindMapElement(JSWindows(), Str(window))
      ProcedureReturn JSWindows()\Name
    EndIf
    ProcedureReturn ""
  EndProcedure

  ; Resolve a window NAME straight to its JSWindow record, or 0.
  ;
  ; JSWindows() is keyed by Str(window handle), so every "find the one window
  ; whose \Window = x" scan in this router was an O(n) walk standing in for two
  ; O(1) map hits — on the hot path of every send, get and reply.
  ;
  ; FindMapElement, never JSWindows(key): a bare map () access INSERTS the key
  ; when it is missing, and a ghost element here would be a phantom window in
  ; every broadcast loop for the rest of the run.
  Procedure.i GetJSWindowPtrByName(windowName.s)
    If Not FindMapElement(WindowsByName(), windowName)
      ProcedureReturn 0
    EndIf
    Protected handle.i = WindowsByName()
    If Not FindMapElement(JSWindows(), Str(handle))
      ProcedureReturn 0
    EndIf
    ProcedureReturn @JSWindows()
  EndProcedure
  
  ; Escape a string so it is a valid JSON string body (RFC 8259) — and nothing
  ; more. Use this for a VALUE going INTO a hand-built JSON frame (a window
  ; name, a handler name, an error message). For the finished frame on its way
  ; into an injected JS literal, use EscapeJSON below.
  ;
  ; Ported from pbjsFileSystem.pb, which already had to solve exactly this: JSON
  ; forbids ANY raw C0 control character (U+0000..U+001F) inside a string
  ; literal, not just the three that used to be handled here. An unescaped one
  ; makes JSON.parse throw "Bad control character in string literal" inside
  ; pbjsHandleMessage — where the catch only logs, so the message (a store-sync
  ; patch, a reply) is silently dropped. Control characters reach here from the
  ; native side, which assembles JSON by hand: an ESC in a terminal title, a
  ; pasted control char in a window or handler name.
  ;
  ; Deliberately NO single-quote escaping: \' is not valid JSON, and this
  ; result is destined for a JSON document, not a JS literal.
  Procedure.s EscapeJSONValue(text.s)
    Protected result.s, c.i
    ; Backslash first, before any \-escape below introduces one of its own,
    ; then the double quote.
    result = ReplaceString(text, Chr(92), Chr(92)+Chr(92))
    result = ReplaceString(result, Chr(34), Chr(92)+Chr(34))
    ; Named short escapes for the common control characters.
    result = ReplaceString(result, Chr(8),  Chr(92)+"b")
    result = ReplaceString(result, Chr(9),  Chr(92)+"t")
    result = ReplaceString(result, Chr(10), Chr(92)+"n")
    result = ReplaceString(result, Chr(12), Chr(92)+"f")
    result = ReplaceString(result, Chr(13), Chr(92)+"r")
    ; Every remaining C0 character as \u00XX. A raw NUL cannot survive in a PB
    ; string, so the range starts at 1.
    For c = 1 To 31
      Select c
        Case 8, 9, 10, 12, 13
          ; already handled as \b \t \n \f \r above
        Default
          result = ReplaceString(result, Chr(c), Chr(92)+"u00" + RSet(Hex(c), 2, "0"))
      EndSelect
    Next
    ProcedureReturn result
  EndProcedure

  ; Escape a finished JSON frame for embedding in a SINGLE-QUOTED JS string
  ; literal — pbjsHandleMessage('...') / pbjsHandleResponse('...'), which is how
  ; every native→JS message is delivered.
  ;
  ; That is the JSON escaping above plus one JS-literal concern: an unescaped
  ; apostrophe in any payload ("Tim's shell") would terminate the literal and
  ; throw a SyntaxError, dropping the message. `\'` is a valid escape inside a
  ; single-quoted JS string and the inner JSON is intact once JS un-escapes it.
  ; It goes LAST, after the backslash pass, so the backslash introduced here is
  ; not itself doubled.
  Procedure.s EscapeJSON(text.s)
    ProcedureReturn ReplaceString(EscapeJSONValue(text), Chr(39), Chr(92)+Chr(39))
  EndProcedure
  
  Procedure FlushPendingMessages(*JSWindow.JSWindow)
    If *JSWindow
      ForEach *JSWindow\PendingMessages()
        Sink::Exec(*JSWindow\Sink, *JSWindow\PendingMessages())
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

  ; §6.5 push tier: tell every other ready, non-spare window that `subjectName`
  ; changed lifecycle (kind = "ready" | "closed" | "reloaded"). Lets each window's
  ; JS readiness cache stay correct and reject in-flight requests to a window that
  ; just reloaded/closed immediately, instead of leaking to the 30s timeout
  ; (orphaned-request fix). Spares are skipped (same as HandleSendAll, F13).
  Procedure NotifyWindowEvent(subjectName.s, kind.s)
    Protected script.s = "if(window.pbjsWindowEvent){window.pbjsWindowEvent('" + EscapeJSON(subjectName) + "','" + kind + "');}"
    ForEach JSWindows()
      If JSWindows()\Name <> subjectName And Not JSWindows()\IsPoolSpare And JSWindows()\Ready
        Sink::Exec(JSWindows()\Sink, script)
      EndIf
    Next
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
      
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"" + EscapeJSONValue(fromWindow) +
                    ~"\",\"name\":\"" + EscapeJSONValue(name) +
                    ~"\",\"params\":" + paramsJson +
                    ~",\"data\":" + dataJson + ~"}"

      Protected *Target.JSWindow = GetJSWindowPtrByName(toWindow)
      If *Target
        script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
        If *Target\Ready
          Sink::Exec(*Target\Sink, script)
        Else
          QueuePending(*Target, script)
        EndIf
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
      
      messageJson = ~"{\"type\":\"get\",\"fromWindow\":\"" + EscapeJSONValue(fromWindow) +
                    ~"\",\"name\":\"" + EscapeJSONValue(name) +
                    ~"\",\"params\":" + paramsJson +
                    ~",\"data\":" + dataJson +
                    ~",\"requestId\":" + Str(requestId) + ~"}"
      
      Protected *Target.JSWindow = GetJSWindowPtrByName(toWindow)
      If *Target
        If Not *Target\Open
          ; Window is registered but currently closed — the error response
          ; below is sent instead.
          windowNotOpen = #True
        Else
          script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
          If *Target\Ready
            Sink::Exec(*Target\Sink, script)
          Else
            QueuePending(*Target, script)
          EndIf
        EndIf
      EndIf
      
      ; Send immediate error back to caller when target window is not found or not open.
      ; Both cases use the same response path so the caller's .catch() fires right away
      ; instead of waiting for the 30s pending-request timeout.
      If *Target = 0 Or windowNotOpen
        Protected errorMsg.s
        If windowNotOpen
          errorMsg = "Window not open: " + toWindow
        Else
          errorMsg = "Window not found: " + toWindow
        EndIf
        
        Protected *Source.JSWindow = GetJSWindowPtrByName(fromWindow)
        If *Source
          script = "pbjsHandleResponse('" + EscapeJSON(~"{\"requestId\":" + Str(requestId) +
                                                       ~",\"fromWindow\":\"" + EscapeJSONValue(toWindow) +
                                                       ~"\",\"data\":{\"error\":\"" + EscapeJSONValue(errorMsg) + ~"\"}}") + "');"
          If *Source\Ready
            Sink::Exec(*Source\Sink, script)
          Else
            QueuePending(*Source, script)
          EndIf
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
      
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"" + EscapeJSONValue(fromWindow) +
                    ~"\",\"name\":\"" + EscapeJSONValue(name) +
                    ~"\",\"params\":" + paramsJson +
                    ~",\"data\":" + dataJson + ~"}"

      script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"

      ForEach JSWindows()
        ; Skip pool spares: they are dormant, off-screen template windows that
        ; are not assigned to any caller and should not receive broadcasts.
        If JSWindows()\Name <> fromWindow And Not JSWindows()\IsPoolSpare
          If JSWindows()\Ready
            Sink::Exec(JSWindows()\Sink, script)
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
      
      Protected *Source.JSWindow = GetJSWindowPtrByName(fromWindow)
      If *Source
        script = "pbjsSetGetAllExpectedCount(" + Str(requestId) + ", " + Str(count) + ");"
        Sink::Exec(*Source\Sink, script)
      EndIf
      
      If count > 0
        messageJson = ~"{\"type\":\"getAll\",\"fromWindow\":\"" + EscapeJSONValue(fromWindow) +
                      ~"\",\"name\":\"" + EscapeJSONValue(name) +
                      ~"\",\"params\":" + paramsJson +
                      ~",\"data\":" + dataJson +
                      ~",\"requestId\":" + Str(requestId) + ~"}"
        
        script = "pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
        
        ForEach JSWindows()
          ; Same predicate as the count loop above (excludes pool spares).
          If JSWindows()\Name <> fromWindow And Not JSWindows()\IsPoolSpare
            If Sink::IsValid(JSWindows()\Sink)
              Sink::Exec(JSWindows()\Sink, script)
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
        ; Structured native-originated system request. Keep this separate from
        ; the legacy close-check path below, whose payload is deliberately a
        ; boolean veto/allow contract.
        If FindMapElement(PendingSystemRequests(), Str(requestId))
          Protected systemRequestName.s = PendingSystemRequests()\Name
          DeleteMapElement(PendingSystemRequests())
          If FindMapElement(SystemResponseHandlersByName(), systemRequestName)
            ; Per-name handler wins (module-owned requests, e.g. dnd:drop).
            Protected namedHandler.SystemResponseHandler = SystemResponseHandlersByName()
            namedHandler(systemRequestName, fromWindow, dataJson, requestId)
          ElseIf *SystemResponseHandler
            ; Prototype call, not CallFunctionFast — the compiler then handles
            ; the string parameters with the normal PB calling convention.
            *SystemResponseHandler(systemRequestName, fromWindow, dataJson, requestId)
          EndIf
          FreeJSON(json)
          ProcedureReturn
        EndIf
        ; --- SYSTEM MESSAGE HANDLING (e.g. Close Check) ---
        Protected *SourceJSWindow.JSWindow = GetJSWindowPtrByName(fromWindow)
        
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
                       ~",\"fromWindow\":\"" + EscapeJSONValue(fromWindow) +
                       ~"\",\"data\":" + dataJson +
                       ~",\"isGetAll\":" + Str(isGetAll) + ~"}"
        
        Protected *ReplyTarget.JSWindow = GetJSWindowPtrByName(toWindow)
        If *ReplyTarget
          script = "pbjsHandleResponse('" + EscapeJSON(responseJson) + "');"
          If *ReplyTarget\Ready
            Sink::Exec(*ReplyTarget\Sink, script)
          Else
            QueuePending(*ReplyTarget, script)
          EndIf
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

      ; Startup-trace marks from the webview (react/shared/services/startupPerf.ts)
      ; are re-stamped with the native clock so the line carries both clocks:
      ; "[PERF] +<native>ms  [win] [PERF-JS] +<webview>ms label". Host-only —
      ; standalone pbjs builds fall through to the plain Debug.
      CompilerIf Defined(StartupTrace, #PB_Module)
        If Left(message, 8) = "[PERF-JS"
          StartupTrace::Mark("[" + windowName + "] " + message)
        Else
          Debug "[JS][" + windowName + "] " + level + ": " + message
        EndIf
      CompilerElse
        Debug "[JS][" + windowName + "] " + level + ": " + message
      CompilerEndIf

      FreeJSON(json)
    EndIf
  EndProcedure

  Procedure SendParameters(*JSWindow.JSWindow, paramsJson.s)
    If *JSWindow And Sink::IsValid(*JSWindow\Sink)
      Protected messageJson.s
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"system\",\"name\":\"handleParameters\",\"params\":" + paramsJson + ~",\"data\":{}}"

      Protected escapedJson.s
      escapedJson = EscapeJSON(messageJson)

      ; Combine handleParameters dispatch with body-visibility restore in one script.
      ; On recycle the bridge removes 'pbjs-document-ready' to blank stale content;
      ; the rAF re-adds it after the handler fires so every instance window fades in
      ; correctly without needing per-window React code.
      Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + escapedJson + "');" +
                           "requestAnimationFrame(function(){document.body.classList.add('pbjs-document-ready');});"
      If *JSWindow\Ready
         Sink::Exec(*JSWindow\Sink, script)
      Else
         QueuePending(*JSWindow, script)
      EndIf
    EndIf
  EndProcedure

  Procedure SendCloseCheck(*JSWindow.JSWindow)
    Debug "[SEND_CLOSE_CHECK] ENTER. Window=" + *JSWindow\Name
    If *JSWindow And Sink::IsValid(*JSWindow\Sink)
      ; Same counter SendSystemRequest uses — NOT ElapsedMilliseconds(), which
      ; this used to be. RequestClose issues a check to every in-scope window in
      ; one tight loop, so same-millisecond collisions are routine, not rare:
      ; N windows could all be asked with the SAME requestId. It happened to be
      ; harmless only because close replies are routed by SOURCE WINDOW rather
      ; than by id — a coincidence, and a trap for anyone extending the protocol
      ; to correlate replies properly.
      NextSystemRequestId + 1
      If NextSystemRequestId <= 0
        NextSystemRequestId = 1
      EndIf
      Protected requestId.i = NextSystemRequestId


      Protected messageJson.s
      messageJson = ~"{\"type\":\"get\",\"fromWindow\":\"system\",\"name\":\"close-window\",\"params\":{},\"data\":{},\"requestId\":" + Str(requestId) + "}"
      
      Protected escapedJson.s
      escapedJson = EscapeJSON(messageJson)
      
      Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + escapedJson + "');"
      If *JSWindow\Ready
         Sink::Exec(*JSWindow\Sink, script)
      Else
         ; Window not ready - auto-approve since JS cannot respond
         *JSWindow\BypassCloseCheck = #True
         JSWindow::CheckCloseProgress()
      EndIf
    EndIf
  EndProcedure

  Procedure RegisterSystemResponseHandler(*handler.SystemResponseHandler)
    *SystemResponseHandler = *handler
  EndProcedure

  Procedure RegisterSystemResponseHandlerFor(requestName.s, *handler.SystemResponseHandler)
    If requestName <> "" And *handler
      SystemResponseHandlersByName(requestName) = *handler
    EndIf
  EndProcedure

  ; Fire-and-forget native→JS message (generic sibling of SendParameters):
  ; arrives at pbjs.handle("system", name, ...) handlers with `params` = the
  ; given JSON. Buffered like every other message while the window isn't ready.
  Procedure SendSystemMessage(*JSWindow.JSWindow, name.s, paramsJson.s)
    If *JSWindow And Sink::IsValid(*JSWindow\Sink)
      Protected messageJson.s
      messageJson = ~"{\"type\":\"send\",\"fromWindow\":\"system\",\"name\":\"" + EscapeJSONValue(name) +
                    ~"\",\"params\":" + paramsJson + ~",\"data\":{}}"
      Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
      If *JSWindow\Ready
        Sink::Exec(*JSWindow\Sink, script)
      Else
        QueuePending(*JSWindow, script)
      EndIf
    EndIf
  EndProcedure

  ; Send a native-originated request to one JS window.  Unlike SendCloseCheck,
  ; this supports structured replies and keeps the request name by id so the
  ; response router can dispatch it to the application layer. Returns the
  ; requestId (0 on failure) so the caller can correlate its own reply and
  ; distinguish it from a late reply to an abandoned earlier request.
  Procedure.i SendSystemRequest(*JSWindow.JSWindow, requestName.s, paramsJson.s = "{}")
    If Not *JSWindow Or Not Sink::IsValid(*JSWindow\Sink)
      ProcedureReturn 0
    EndIf

    NextSystemRequestId + 1
    If NextSystemRequestId <= 0
      NextSystemRequestId = 1
    EndIf
    Protected requestId.i = NextSystemRequestId
    PendingSystemRequests(Str(requestId))\Name = requestName

    Protected messageJson.s
    messageJson = ~"{\"type\":\"get\",\"fromWindow\":\"system\",\"name\":\"" + EscapeJSONValue(requestName) +
                  ~"\",\"params\":" + paramsJson + ~",\"data\":{},\"requestId\":" + Str(requestId) + "}"
    Protected script.s = "if(window.pbjsHandleMessage) window.pbjsHandleMessage('" + EscapeJSON(messageJson) + "');"
    If *JSWindow\Ready
      Sink::Exec(*JSWindow\Sink, script)
    Else
      QueuePending(*JSWindow, script)
    EndIf
    ProcedureReturn requestId
  EndProcedure

  ; Free a pending request's slot without waiting for its reply — used when
  ; the caller gives up (timeout/cancel) so a reply that never arrives can't
  ; leak the map entry forever. No-op if the id is already gone (already
  ; replied, or never existed).
  Procedure CancelPendingSystemRequest(requestId.i)
    If FindMapElement(PendingSystemRequests(), Str(requestId))
      DeleteMapElement(PendingSystemRequests())
    EndIf
  EndProcedure
  
  ; ============================================================================
  ; INITIALIZATION
  ; ============================================================================
  
  ; sink: the window's Sink handle — the WebViewGadget for real windows, a
  ; negative headless handle in web mode (routing via Sink::Bind either way).
  Procedure InitializeBridge(windowName.s, window.i, sink.i)
    Protected windowKey.s
    
    If Trim(windowName) = ""
      Debug "Error: Window name cannot be empty"
      ProcedureReturn #False
    EndIf
    
    Sink::Bind(sink, "pbjsNativeSend", @HandleSend())
    Sink::Bind(sink, "pbjsNativeGet", @HandleGet())
    Sink::Bind(sink, "pbjsNativeSendAll", @HandleSendAll())
    Sink::Bind(sink, "pbjsNativeGetAll", @HandleGetAll())
    Sink::Bind(sink, "pbjsNativeReply", @HandleReply())
    Sink::Bind(sink, "pbjsNativeLog", @HandleLog())
    
    ProcedureReturn window
  EndProcedure
  
  ; ============================================================================
  ; HTML WRAPPER
  ; ============================================================================
  
  
  ; Everything in the bridge script that does NOT vary per window, decoded and
  ; substituted once. Only the window name is per-instance.
  ;
  ; This used to be rebuilt from scratch on every call: a UTF-8 decode of the
  ; whole embedded script plus three or four full-string ReplaceStrings. It is
  ; called once per window created — and every pool spare is a window, so
  ; warming a pool paid for it repeatedly, on the UI thread, for a result that
  ; differed only in one identifier.
  Global bridgeTemplate.s = ""
  Global bridgeTemplateDnd.s = ""   ; the DnD flag the cached template was built with

  Procedure.s PrepateBridgeScript(windowName.s)

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
    
    ; Synchronous "is the DnD service actually live" flag — read once at page
    ; load, before pbjs.drag exists as an object at all. DndServiceDeclare.pb
    ; (included ahead of this file) exposes IsEnabled() precisely so this
    ; module doesn't need the full DndService body in scope. Lets
    ; PbjsDragService.available report the real answer (host without
    ; DndService / PBJS_DND=0 / non-mac / web mode) instead of only "does
    ; the native function exist", which stays true even when disabled.
    Protected dndEnabled.s
    If DndService::IsEnabled()
      dndEnabled = "1"
    Else
      dndEnabled = "0"
    EndIf

    ; Build the invariant part once. Keyed on the DnD flag as well as on
    ; "have we built it": DndService::Init() may run after the first window is
    ; created, and a template cached before that would report the service as
    ; unavailable to every later window.
    If bridgeTemplate = "" Or bridgeTemplateDnd <> dndEnabled
      Protected *buffer = ?BridgeScript
      Protected size.i = ?EndBridgeScript - ?BridgeScript
      Protected built.s = PeekS(*buffer, size, #PB_UTF8|#PB_ByteLength)
      built = ReplaceString(built, "_OS_NAME_INJECTED_BY_NATIVE_", osName)
      built = ReplaceString(built, "_DND_ENABLED_INJECTED_BY_NATIVE_", dndEnabled)
      bridgeTemplate    = built
      bridgeTemplateDnd = dndEnabled
    EndIf

    ; The only genuinely per-window substitution.
    ProcedureReturn ReplaceString(bridgeTemplate, "_WINDOW_NAME_INJECTED_BY_NATIVE_", windowName)
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
