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
  ; requestId is the id SendSystemRequest returned for this specific call —
  ; callers that can have more than one request in flight over a session's
  ; lifetime (e.g. DndService, superseded/timed-out drops) MUST compare it
  ; against the id they stored, not just against loose state (a reply that
  ; arrives late, after its own request timed out, would otherwise be
  ; indistinguishable from a reply to a newer request reusing the same
  ; requestName/fromWindow).
  Prototype SystemResponseHandler(requestName.s, fromWindow.s, dataJson.s, requestId.i)
  Declare RegisterSystemResponseHandler(*handler.SystemResponseHandler)
  ; Per-request-name reply routing, checked before the global handler above —
  ; lets modules (e.g. DndService's "dnd:drop") own their replies without the
  ; host app's catch-all having to know about them.
  Declare RegisterSystemResponseHandlerFor(requestName.s, *handler.SystemResponseHandler)
  ; Returns the generated requestId (0 if the window/sink was invalid and no
  ; request was sent) so the caller can correlate its own reply later.
  Declare.i SendSystemRequest(*JSWindow, requestName.s, paramsJson.s = "{}")
  ; Proactively frees a pending request's slot when the caller gives up on it
  ; (timeout/cancel) instead of waiting for a reply that may never come.
  ; Safe to call with an id that's already gone (no-op).
  Declare CancelPendingSystemRequest(requestId.i)
  ; Fire-and-forget native-originated message to one window (generic sibling
  ; of SendParameters): {type:"send", fromWindow:"system", name, params}.
  Declare SendSystemMessage(*JSWindow, name.s, paramsJson.s)
  Declare FlushPendingMessages(*JSWindow)
  Declare NotifyWindowEvent(subjectName.s, kind.s)
EndDeclareModule


; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 12
; Folding = -
; EnableXP
; DPIAware
