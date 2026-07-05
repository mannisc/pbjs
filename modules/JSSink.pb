; =============================================================================
;- SINK — per-window script/callback routing (web-mode headless support)
; =============================================================================
;
; A "sink" is where a window's page lives. For a normal window it is the
; WebViewGadget number (positive) and every operation inlines to exactly the
; classic calls (WebViewExecuteScript / BindWebViewCallback / IsGadget). For a
; HEADLESS window (web mode: the page runs in a browser tab, bridged by the
; ui-webserver relay) it is a negative handle allocated here, and operations
; are forwarded through app-installed hooks (main.pb wires them to WebProxy).
;
; This module is the SINGLE interception point of the web-version design —
; pbjsBridge / JSWindow / ptym / pbjsFileSystem route through it and stay
; transport-unaware. With no hooks installed (standalone pbjs builds, native
; mode) headless sinks are inert no-ops and real sinks behave byte-identically
; to the direct calls. Design: iplan/webversion/plan.md §3.3, §0.5.
;
; Threading: everything here is main-thread only (all existing exec/bind call
; sites are main-thread — plan C9). No locking on purpose.

CompilerIf Not Defined(Sink, #PB_Module)

DeclareModule Sink
  ; Hook prototypes (implemented by the app layer, e.g. WebProxy in main repo)
  Prototype.i ProtoExecHook(win.s, script.s)          ; forward "eval this on the page"
  Prototype.i ProtoBindHook(win.s, name.s)            ; announce "define window[name] shim"
  Prototype.i ProtoWinCmdHook(win.s, cmd.s, dat.s)    ; window-level command (title/focus/…)
  ; The shape every BindWebViewCallback-style callback already has:
  ; one JSON-array string in, 0 or a UTF8() buffer pointer out (plan C2).
  Prototype.i ProtoCallbackProc(jsonParameters.s)

  Declare SetHooks(*execHook, *bindHook, *winCmdHook)

  ; Headless sink lifecycle
  Declare.i RegisterHeadless(win.s)                   ; -> negative sink handle (idempotent per win)
  Declare ReleaseHeadless(sink.i)
  Declare.i SinkForWindow(win.s)                      ; 0 if not headless-registered
  Declare.s WindowForSink(sink.i)

  ; Routing (work for BOTH real gadgets and headless sinks)
  Declare.i IsValid(sink.i)                           ; IsGadget() or live headless sink
  Declare.i IsHeadless(sink.i)
  Declare Exec(sink.i, script.s)                      ; WebViewExecuteScript or ExecHook
  Declare Bind(sink.i, name.s, *proc)                 ; BindWebViewCallback or registry+BindHook
  Declare WinCmd(sink.i, cmd.s, dat.s)                ; no-op for real gadgets (OS handles it)

  ; Inbound dispatch (proxy "call" messages -> the registered callback procs)
  Declare.i HasBind(win.s, name.s)
  Declare.s DispatchCall(win.s, name.s, argsJson.s)   ; "" for void callbacks (returned 0)
  Declare ReplayBinds(win.s)                          ; re-announce all binds (on tab (re)attach)
EndDeclareModule

Module Sink

  Structure HeadlessSink
    Win.s
    Sink.i
    Map Binds.i()      ; callback name -> *proc (mirrors what BindWebViewCallback would hold)
  EndStructure

  Global NewMap HeadlessByWin.HeadlessSink()   ; window name -> sink record
  Global NewMap WinBySink.s()                  ; Str(sink)   -> window name
  Global NextHeadless.i = 0                    ; allocator: -1, -2, …

  Global ExecHook.ProtoExecHook = 0
  Global BindHook.ProtoBindHook = 0
  Global WinCmdHook.ProtoWinCmdHook = 0

  Procedure SetHooks(*execHook, *bindHook, *winCmdHook)
    ExecHook = *execHook
    BindHook = *bindHook
    WinCmdHook = *winCmdHook
  EndProcedure

  Procedure.i RegisterHeadless(win.s)
    If FindMapElement(HeadlessByWin(), win)
      ProcedureReturn HeadlessByWin()\Sink
    EndIf
    NextHeadless - 1
    AddMapElement(HeadlessByWin(), win)
    HeadlessByWin()\Win = win
    HeadlessByWin()\Sink = NextHeadless
    WinBySink(Str(NextHeadless)) = win
    Debug "[Sink] Registered headless sink " + Str(NextHeadless) + " for '" + win + "'"
    ProcedureReturn NextHeadless
  EndProcedure

  Procedure ReleaseHeadless(sink.i)
    Protected key.s = Str(sink)
    If FindMapElement(WinBySink(), key)
      Protected win.s = WinBySink()
      DeleteMapElement(WinBySink(), key)
      If FindMapElement(HeadlessByWin(), win)
        DeleteMapElement(HeadlessByWin())
      EndIf
    EndIf
  EndProcedure

  Procedure.i SinkForWindow(win.s)
    If FindMapElement(HeadlessByWin(), win)
      ProcedureReturn HeadlessByWin()\Sink
    EndIf
    ProcedureReturn 0
  EndProcedure

  Procedure.s WindowForSink(sink.i)
    If FindMapElement(WinBySink(), Str(sink))
      ProcedureReturn WinBySink()
    EndIf
    ProcedureReturn ""
  EndProcedure

  Procedure.i IsHeadless(sink.i)
    If sink < 0 And FindMapElement(WinBySink(), Str(sink))
      ProcedureReturn #True
    EndIf
    ProcedureReturn #False
  EndProcedure

  Procedure.i IsValid(sink.i)
    If sink > 0
      ProcedureReturn IsGadget(sink)
    EndIf
    ProcedureReturn IsHeadless(sink)
  EndProcedure

  Procedure Exec(sink.i, script.s)
    If script = ""
      ProcedureReturn
    EndIf
    If sink > 0
      If IsGadget(sink)
        WebViewExecuteScript(sink, script)
      EndIf
    ElseIf sink < 0
      If ExecHook
        Protected win.s = WindowForSink(sink)
        If win <> ""
          ExecHook(win, script)
        EndIf
      EndIf
    EndIf
  EndProcedure

  Procedure Bind(sink.i, name.s, *proc)
    If sink > 0
      If IsGadget(sink)
        BindWebViewCallback(sink, name, *proc)
      EndIf
    ElseIf sink < 0
      Protected win.s = WindowForSink(sink)
      If win <> "" And FindMapElement(HeadlessByWin(), win)
        HeadlessByWin()\Binds(name) = *proc
        If BindHook
          BindHook(win, name)
        EndIf
      EndIf
    EndIf
  EndProcedure

  Procedure WinCmd(sink.i, cmd.s, dat.s)
    ; Only meaningful for headless sinks — for real windows the OS-level
    ; procedures (SetWindowTitle/FocusInstance/…) already did the work.
    If sink < 0 And WinCmdHook
      Protected win.s = WindowForSink(sink)
      If win <> ""
        WinCmdHook(win, cmd, dat)
      EndIf
    EndIf
  EndProcedure

  Procedure.i HasBind(win.s, name.s)
    If FindMapElement(HeadlessByWin(), win)
      If FindMapElement(HeadlessByWin()\Binds(), name)
        ProcedureReturn #True
      EndIf
    EndIf
    ProcedureReturn #False
  EndProcedure

  ; Invoke a registered callback exactly like the webview would: args as one
  ; JSON-array string; returns the callback's JSON string ("" when the proc
  ; returned 0 — a void callback). Validated by spike FC-1 (plan §5.7).
  Procedure.s DispatchCall(win.s, name.s, argsJson.s)
    Protected response.s = ""
    If FindMapElement(HeadlessByWin(), win)
      If FindMapElement(HeadlessByWin()\Binds(), name)
        Protected cb.ProtoCallbackProc = HeadlessByWin()\Binds()
        Protected *buf = cb(argsJson)
        If *buf
          response = PeekS(*buf, -1, #PB_UTF8)
          FreeMemory(*buf)
        EndIf
      EndIf
    EndIf
    ProcedureReturn response
  EndProcedure

  Procedure ReplayBinds(win.s)
    If BindHook And FindMapElement(HeadlessByWin(), win)
      ForEach HeadlessByWin()\Binds()
        BindHook(win, MapKey(HeadlessByWin()\Binds()))
      Next
    EndIf
  EndProcedure

EndModule

CompilerEndIf
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; EnableXP
; DPIAware
