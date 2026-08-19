; ============================================================================
; Native test harness — scaffolding shared by the .pb harnesses.
; ============================================================================
; Assertions, a captured-script log, and the fake window registry. No test
; cases live here; see router-harness.pb.
;
; Include AFTER ../../pbjs.pb.
; ============================================================================

CompilerIf Not Defined(Harness, #PB_Module)

DeclareModule Harness
  Declare Section(title.s)
  Declare.i Check(ok.i, what.s)
  Declare.i CheckEqS(actual.s, expected.s, what.s)
  Declare.i CheckEqI(actual.i, expected.i, what.s)
  Declare.i Report()                       ; -> process exit code (0 = all passed)

  ; Quote + escape a string as a JSON string literal, using the harness's OWN
  ; implementation. Deliberately not JSBridge::EscapeJSONValue: the fixture file
  ; records what the escaper under test is EXPECTED to produce, so writing it
  ; with that same escaper would make a broken escaper produce a fixture that
  ; agrees with itself. It also keeps the file valid JSON when the code under
  ; test is broken, so the failure reads as "wrong value" rather than "cannot
  ; parse the fixture".
  Declare.s JsonQuote(text.s)

  ; --- captured Sink traffic -------------------------------------------------
  Declare InstallHooks()                   ; route Sink::Exec into the log below
  Declare ClearCaptured()
  Declare.i CapturedCount()
  Declare.s CapturedScript(index.i)        ; 0-based; "" when out of range
  Declare.s CapturedWindow(index.i)
  Declare.i CapturedCountFor(win.s)
  Declare.s FirstScriptFor(win.s)

  ; --- fake window registry --------------------------------------------------
  ; A JSWindow record with a headless Sink and no OS window at all. Enough for
  ; every routing decision the bridge makes: it reads Name, Sink, Ready, Open
  ; and IsPoolSpare, and nothing else.
  Declare.i AddWindow(name.s, ready.i = #True, open.i = #True, spare.i = #False)
  ; A *JSWindow for the procedures that take one. JSBridge keeps its own
  ; name->record lookup module-private, and rightly so: the host receives the
  ; pointer as a callback argument (WindowLoaded / WindowClosing), never by
  ; name. So the harness does its own two map hits rather than widening the
  ; library's public surface for a test's benefit.
  Declare.i WindowPtr(name.s)
  Declare SetReady(name.s, ready.i)
  Declare ResetRegistry()
  Declare.i PendingCount(name.s)
EndDeclareModule

Module Harness
  UseModule JSWindow

  Global Passed.i = 0
  Global Failed.i = 0
  Global CurrentSection.s = ""

  Structure ExecRecord
    Win.s
    Script.s
  EndStructure
  Global NewList Captured.ExecRecord()

  Global NextFakeWindow.i = 9000

  ; --------------------------------------------------------------------------
  ;- Assertions
  ; --------------------------------------------------------------------------
  Procedure Section(title.s)
    CurrentSection = title
    PrintN("")
    PrintN("== " + title + " ==")
  EndProcedure

  Procedure.i Check(ok.i, what.s)
    If ok
      Passed + 1
      PrintN("  ok    " + what)
    Else
      Failed + 1
      PrintN("  FAIL  " + what)
    EndIf
    ProcedureReturn ok
  EndProcedure

  ; Render control characters so a diff is readable in a terminal instead of
  ; moving the cursor around.
  Procedure.s Visible(text.s)
    Protected out.s = "", i.i, c.i
    For i = 1 To Len(text)
      c = Asc(Mid(text, i, 1))
      If c < 32
        out + "<" + RSet(Hex(c), 2, "0") + ">"
      Else
        out + Chr(c)
      EndIf
    Next
    ProcedureReturn out
  EndProcedure

  Procedure.i CheckEqS(actual.s, expected.s, what.s)
    If actual = expected
      ProcedureReturn Check(#True, what)
    EndIf
    Check(#False, what)
    PrintN("          expected: " + Visible(expected))
    PrintN("          actual:   " + Visible(actual))
    ProcedureReturn #False
  EndProcedure

  Procedure.i CheckEqI(actual.i, expected.i, what.s)
    If actual = expected
      ProcedureReturn Check(#True, what)
    EndIf
    Check(#False, what)
    PrintN("          expected: " + Str(expected))
    PrintN("          actual:   " + Str(actual))
    ProcedureReturn #False
  EndProcedure

  Procedure.i Report()
    PrintN("")
    PrintN("----------------------------------------")
    PrintN(Str(Passed) + " passed, " + Str(Failed) + " failed")
    If Failed
      ProcedureReturn 1
    EndIf
    ProcedureReturn 0
  EndProcedure

  Procedure.s JsonQuote(text.s)
    Protected out.s = Chr(34), i.i, c.i
    For i = 1 To Len(text)
      c = Asc(Mid(text, i, 1))
      Select c
        Case 34            : out + Chr(92) + Chr(34)
        Case 92            : out + Chr(92) + Chr(92)
        Case 8             : out + Chr(92) + "b"
        Case 9             : out + Chr(92) + "t"
        Case 10            : out + Chr(92) + "n"
        Case 12            : out + Chr(92) + "f"
        Case 13            : out + Chr(92) + "r"
        Default
          If c < 32
            out + Chr(92) + "u" + RSet(Hex(c), 4, "0")
          Else
            out + Chr(c)
          EndIf
      EndSelect
    Next
    ProcedureReturn out + Chr(34)
  EndProcedure

  ; --------------------------------------------------------------------------
  ;- Captured Sink traffic
  ; --------------------------------------------------------------------------
  ; Sink::Exec on a headless sink forwards to the app's ExecHook instead of
  ; calling WebViewExecuteScript. That hook is the seam this whole harness hangs
  ; off: it is where "what the host would have run in the page" becomes an
  ; inspectable string.
  Procedure.i OnExec(win.s, script.s)
    AddElement(Captured())
    Captured()\Win = win
    Captured()\Script = script
    ProcedureReturn 1
  EndProcedure

  Procedure.i OnBind(win.s, name.s)
    ProcedureReturn 1
  EndProcedure

  Procedure.i OnWinCmd(win.s, cmd.s, dat.s)
    ProcedureReturn 1
  EndProcedure

  Procedure InstallHooks()
    Sink::SetHooks(@OnExec(), @OnBind(), @OnWinCmd())
  EndProcedure

  Procedure ClearCaptured()
    ClearList(Captured())
  EndProcedure

  Procedure.i CapturedCount()
    ProcedureReturn ListSize(Captured())
  EndProcedure

  Procedure.s CapturedScript(index.i)
    If index >= 0 And index < ListSize(Captured())
      SelectElement(Captured(), index)
      ProcedureReturn Captured()\Script
    EndIf
    ProcedureReturn ""
  EndProcedure

  Procedure.s CapturedWindow(index.i)
    If index >= 0 And index < ListSize(Captured())
      SelectElement(Captured(), index)
      ProcedureReturn Captured()\Win
    EndIf
    ProcedureReturn ""
  EndProcedure

  Procedure.i CapturedCountFor(win.s)
    Protected n.i = 0
    ForEach Captured()
      If Captured()\Win = win
        n + 1
      EndIf
    Next
    ProcedureReturn n
  EndProcedure

  Procedure.s FirstScriptFor(win.s)
    ForEach Captured()
      If Captured()\Win = win
        ProcedureReturn Captured()\Script
      EndIf
    Next
    ProcedureReturn ""
  EndProcedure

  ; --------------------------------------------------------------------------
  ;- Fake window registry
  ; --------------------------------------------------------------------------
  Procedure.i AddWindow(name.s, ready.i = #True, open.i = #True, spare.i = #False)
    Protected sink.i = Sink::RegisterHeadless(name)
    Protected win.i = NextFakeWindow
    NextFakeWindow + 1

    ; JSWindows() is keyed by Str(window handle) — see GetJSWindowNameByID.
    AddMapElement(JSWindows(), Str(win))
    JSWindows()\Name        = name
    JSWindows()\Window      = win
    JSWindows()\WebViewGadget = 0
    JSWindows()\Sink        = sink
    JSWindows()\Headless    = #True
    JSWindows()\Ready       = ready
    JSWindows()\Open        = open
    JSWindows()\IsPoolSpare = spare
    WindowsByName(name) = win

    ; Bind the router's callbacks onto the sink, exactly as a real window does.
    ; This is what lets Sink::DispatchCall drive HandleSend/HandleGet/… without
    ; those procedures being exported.
    JSBridge::InitializeBridge(name, win, sink)
    ProcedureReturn win
  EndProcedure

  Procedure.i WindowPtr(name.s)
    If FindMapElement(WindowsByName(), name)
      Protected handle.i = WindowsByName()
      ; FindMapElement, never JSWindows(key) — a bare access would INSERT.
      If FindMapElement(JSWindows(), Str(handle))
        ProcedureReturn @JSWindows()
      EndIf
    EndIf
    ProcedureReturn 0
  EndProcedure

  Procedure SetReady(name.s, ready.i)
    If FindMapElement(WindowsByName(), name)
      Protected handle.i = WindowsByName()
      If FindMapElement(JSWindows(), Str(handle))
        JSWindows()\Ready = ready
      EndIf
    EndIf
  EndProcedure

  Procedure.i PendingCount(name.s)
    If FindMapElement(WindowsByName(), name)
      Protected handle.i = WindowsByName()
      If FindMapElement(JSWindows(), Str(handle))
        ProcedureReturn ListSize(JSWindows()\PendingMessages())
      EndIf
    EndIf
    ProcedureReturn -1
  EndProcedure

  Procedure ResetRegistry()
    ForEach JSWindows()
      Sink::ReleaseHeadless(JSWindows()\Sink)
    Next
    ClearMap(JSWindows())
    ClearMap(WindowsByName())
    ClearCaptured()
  EndProcedure

EndModule

CompilerEndIf
