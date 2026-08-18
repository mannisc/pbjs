; =============================================================================
;- test.pb — does WebViewBaseUrl actually re-enable the disabled web APIs?
; =============================================================================
;
; Loads the SAME probe page twice into the SAME gadget:
;   RUN 1  the way PureBasic normally does it (no base URL)   -> expect failures
;   RUN 2  through WebViewBaseUrl::SetHtml with a base URL    -> expect OK
;
; and prints a side-by-side table of eleven origin-gated web APIs. Results go
; to the window, to stdout, and to results-<os>.txt next to the executable.
;
; Readback is via BindWebViewCallback, which exists on all three platforms, so
; this harness is genuinely cross-platform even though the fix underneath is
; not. If RUN 2 reports nothing at all on your OS, that is itself the finding:
; the binding did not survive the alternate load path (see README).
;
; Run it, then send the printed table to whoever is fixing the port.
; =============================================================================

IncludeFile "WebViewBaseUrl.pb"

; Per-app host. NOT bare "localhost" — see the header of WebViewBaseUrl.pb.
#BaseUrl = "http://pbwebview.localhost/"

Global Report.s = ""      ; last JSON pushed from the page
Global GotReport = #False

; --- the probe -----------------------------------------------------------
; Every check is individually try/caught so one failure cannot hide the rest.
; Async APIs (indexedDB.open, caches.open, storage.estimate) resolve into the
; same object, and a 2.5s timer reports regardless so a hang still yields data.
Procedure.s ProbeHtml()
  Protected js.s = "var R={};" +
    "function t(k,f){try{R[k]=f();}catch(e){R[k]='THROW:'+e.name;}}" +
    "t('isSecureContext',function(){return ''+window.isSecureContext;});" +
    "t('origin',function(){return location.origin;});" +
    "t('localStorage',function(){localStorage.setItem('a','1');return localStorage.getItem('a')==='1'?'OK':'READBACK-FAIL';});" +
    "t('sessionStorage',function(){sessionStorage.setItem('a','1');return 'OK';});" +
    "t('cookie',function(){document.cookie='a=1';return document.cookie.indexOf('a=1')>=0?'OK':'SILENT-FAIL';});" +
    "t('crypto.randomUUID',function(){return (self.crypto&&crypto.randomUUID)?'OK':'ABSENT';});" +
    "t('crypto.subtle',function(){return (self.crypto&&crypto.subtle)?'OK':'ABSENT';});" +
    "t('caches',function(){return (typeof caches!=='undefined')?'present':'ABSENT';});" +
    "t('serviceWorker',function(){return navigator.serviceWorker?'present':'ABSENT';});" +
    "t('clipboard',function(){return navigator.clipboard?'present':'ABSENT';});" +
    "var pending=3,sent=false;" +
    "function fin(){if(sent){return;}sent=true;" +
    "  try{pbReport(JSON.stringify(R));}catch(e){document.title='REPORT-FAILED:'+e.name;}}" +
    "function done(){pending--;if(pending<=0){fin();}}" +
    "try{var q=indexedDB.open('probe',1);" +
    "  q.onsuccess=function(){R['indexedDB.open']='OK';done();};" +
    "  q.onerror=function(){R['indexedDB.open']='ERROR';done();};" +
    "  q.onblocked=function(){R['indexedDB.open']='BLOCKED';done();};" +
    "}catch(e){R['indexedDB.open']='THROW:'+e.name;done();}" +
    "try{caches.open('probe').then(function(){R['caches.open']='OK';done();})" +
    "  ['catch'](function(e){R['caches.open']='REJ:'+e.name;done();});" +
    "}catch(e){R['caches.open']='THROW:'+e.name;done();}" +
    "try{navigator.storage.estimate().then(function(){R['storage.estimate']='OK';done();})" +
    "  ['catch'](function(e){R['storage.estimate']='REJ:'+e.name;done();});" +
    "}catch(e){R['storage.estimate']='THROW:'+e.name;done();}" +
    "setTimeout(fin,2500);"
  ProcedureReturn "<html><head><meta charset='utf-8'><title>probe</title></head>" +
                  "<body><script>" + js + "</script></body></html>"
EndProcedure

; PB bound callback: the page calls window.pbReport(json).
Procedure.i pbReport(JsonParameters.s)
  ; PB delivers the JS arguments as a JSON ARRAY: ["{...}"]
  Protected payload.s = JsonParameters
  Protected j = ParseJSON(#PB_Any, JsonParameters)
  If j
    Protected v = JSONValue(j)
    If JSONType(v) = #PB_JSON_Array And JSONArraySize(v) >= 1
      payload = GetJSONString(GetJSONElement(v, 0))
    EndIf
    FreeJSON(j)
  EndIf
  Report = payload
  GotReport = #True
  ProcedureReturn UTF8("{}")
EndProcedure

; Pump the event loop until the page reports, or we give up.
Procedure.s RunProbe(gadget.i, useBaseUrl.i)
  Report = "" : GotReport = #False

  Protected ok.i
  If useBaseUrl
    ok = WebViewBaseUrl::SetHtml(gadget, ProbeHtml(), #BaseUrl)
  Else
    ; Deliberately the ordinary PureBasic path — the behaviour we are fixing.
    SetGadgetItemText(gadget, #PB_WebView_HtmlCode, ProbeHtml())
    ok = #True
  EndIf

  If Not ok
    ProcedureReturn "SetHtml FAILED: " + WebViewBaseUrl::LastError()
  EndIf

  Protected deadline.q = ElapsedMilliseconds() + 8000
  While Not GotReport And ElapsedMilliseconds() < deadline
    While WindowEvent() : Wend
    Delay(20)
  Wend

  If Not GotReport
    ProcedureReturn "NO REPORT (page never called pbReport within 8s)"
  EndIf
  ProcedureReturn Report
EndProcedure

; Pull one key out of the reported JSON object.
Procedure.s Field(json.s, key.s)
  Protected out.s = "-"
  Protected j = ParseJSON(#PB_Any, json)
  If j
    Protected v = JSONValue(j)
    If JSONType(v) = #PB_JSON_Object
      Protected m = GetJSONMember(v, key)
      If m : out = GetJSONString(m) : EndIf
    EndIf
    FreeJSON(j)
  EndIf
  ProcedureReturn out
EndProcedure

Procedure.s Pad(s.s, n.i)
  While Len(s) < n : s + " " : Wend
  ProcedureReturn s
EndProcedure

; --- main ----------------------------------------------------------------
Define out.s = ""
Define osName.s
CompilerSelect #PB_Compiler_OS
  CompilerCase #PB_OS_MacOS   : osName = "macos"
  CompilerCase #PB_OS_Windows : osName = "windows"
  CompilerCase #PB_OS_Linux   : osName = "linux"
  CompilerDefault             : osName = "unknown"
CompilerEndSelect

If OpenWindow(0, 100, 100, 900, 620, "WebViewBaseUrl — origin test (" + osName + ")",
              #PB_Window_SystemMenu | #PB_Window_ScreenCentered)

  ; The probe runs in this gadget; it is parked off to the side because the
  ; results, not the page, are the point.
  web = WebViewGadget(#PB_Any, 0, 0, 10, 10)
  BindWebViewCallback(web, "pbReport", @pbReport())

  ; Give the engine a moment to finish creating itself before the first load.
  For i = 1 To 20 : While WindowEvent() : Wend : Delay(25) : Next

  before.s = RunProbe(web, #False)
  after.s  = RunProbe(web, #True)

  HideGadget(web, #True)
  ed = EditorGadget(#PB_Any, 10, 10, 880, 600, #PB_Editor_ReadOnly)

  Dim keys.s(12)
  keys(0)  = "origin"          : keys(1)  = "isSecureContext"
  keys(2)  = "localStorage"    : keys(3)  = "sessionStorage"
  keys(4)  = "indexedDB.open"  : keys(5)  = "cookie"
  keys(6)  = "crypto.randomUUID" : keys(7) = "crypto.subtle"
  keys(8)  = "caches"          : keys(9)  = "caches.open"
  keys(10) = "serviceWorker"   : keys(11) = "clipboard"
  keys(12) = "storage.estimate"

  out + "WebViewBaseUrl origin test" + #LF$
  out + "OS       : " + osName + #LF$
  out + "backend  : " + WebViewBaseUrl::Backend() + #LF$
  out + "baseUrl  : " + #BaseUrl + #LF$
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; The point of the Windows implementation: the document must never touch
    ; the disk. (The old folder-mapping wrote here; the module now serves from
    ; RAM and scrubs what earlier builds left behind.)
    Define leakDir.s = GetTemporaryDirectory() + "pbWebViewBaseUrl"
    If FileSize(leakDir) = -2
      out + "on disk  : LEAK — " + leakDir + " still exists" + #LF$
    Else
      out + "on disk  : nothing — document served from RAM" + #LF$
    EndIf
  CompilerEndIf
  out + #LF$

  If FindString(before, "{") = 0
    out + "RUN 1 (no base URL) -> " + before + #LF$
  EndIf
  If FindString(after, "{") = 0
    out + "RUN 2 (with base URL) -> " + after + #LF$
    out + #LF$ + "The fix did not report. See README.md 'If it does not work'." + #LF$
  EndIf

  If FindString(before, "{") And FindString(after, "{")
    out + Pad("API", 22) + Pad("no baseURL (today)", 24) + "with baseURL (fixed)" + #LF$
    out + Pad("", 22) + Pad("", 24) + "" + #LF$
    Define fixedCount = 0, totalCount = 0
    For i = 0 To 12
      b.s = Field(before, keys(i))
      a.s = Field(after, keys(i))
      out + Pad(keys(i), 22) + Pad(b, 24) + a + #LF$
      If keys(i) <> "origin" And keys(i) <> "isSecureContext"
        totalCount + 1
        If b <> a And (a = "OK" Or a = "present") : fixedCount + 1 : EndIf
      EndIf
    Next
    out + #LF$
    out + "APIs repaired by the fix: " + Str(fixedCount) + " of " + Str(totalCount) + #LF$
    If fixedCount >= 8
      out + "VERDICT: WORKING on " + osName + #LF$
    ElseIf fixedCount > 0
      out + "VERDICT: PARTIAL on " + osName + " — see README.md" + #LF$
    Else
      out + "VERDICT: NOT WORKING on " + osName + " — see README.md" + #LF$
    EndIf
  EndIf

  out + #LF$ + "--- raw ---" + #LF$
  out + "before: " + before + #LF$
  out + "after : " + after + #LF$

  SetGadgetText(ed, out)

  ; PrintN without a console is a hard error under the debugger and silently
  ; swallowed in a plain build — attach one so stdout is real either way.
  ; (On Windows' GUI executable format this pops a console window: fine for a
  ; test harness, that is where the table goes.)
  If OpenConsole()
    PrintN(out)
  EndIf

  ; Also drop a file next to the executable so it is easy to send on.
  resPath.s = GetPathPart(ProgramFilename()) + "results-" + osName + ".txt"
  fh = CreateFile(#PB_Any, resPath)
  If fh
    WriteString(fh, out, #PB_UTF8)
    CloseFile(fh)
  EndIf

  Repeat
    ev = WaitWindowEvent()
  Until ev = #PB_Event_CloseWindow
EndIf
End
