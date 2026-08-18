; =============================================================================
;- PBJS BUILD CONFIGURATION
; =============================================================================
;
; Every compile-time switch pbjs honours, in one place. Included FIRST from
; pbjs.pb, before any module that reads a flag.
;
; Why this file exists: build-mode had no home. `#Debug_On` was declared in
; OsTheme.pb — the *theming* module — while gating content-loading branches in
; JSWindow.pb, up to and including whether a URL can be loaded at all. Nobody
; auditing content loading reads a theme module. Devtools had the opposite
; problem: `#PB_WebView_Debug` was passed unconditionally, so shipped apps
; exposed the inspector on windows holding the full native binding set.
;
; It is a MODULE, not a list of plain constants, because PureBasic modules
; cannot see top-level constants at all — verified with 6.21: a `#FOO = 1`
; outside any module is "Constant not found" inside one. That is also why
; `#Debug_On` lived in DeclareModule OsTheme in the first place. Consumers do
; `UseModule PbjsConfig`.
;
; ---------------------------------------------------------------------------
;- HOW A HOST OVERRIDES A FLAG  (two ways, both verified against PB 6.21)
; ---------------------------------------------------------------------------
;
; 1. PER BUILD — a compiler command-line constant. It DOES reach module scope
;    and is seen by the Defined() guards below:
;
;      pbcompiler main.pb -co PBJS_EnableDevTools=1
;      pbcompiler main.pb --constant PBJS_DevMode=0
;
;    This is the one to use from a build script (dev.js / build.js already
;    invoke pbcompiler directly).
;
; 2. PERMANENTLY — declare the module yourself, before including pbjs.pb. The
;    whole file is guarded on the module already existing, so yours wins:
;
;      DeclareModule PbjsConfig
;        #PBJS_DevMode        = 0
;        #PBJS_EnableDevTools = 1
;      EndDeclareModule
;      Module PbjsConfig
;      EndModule
;      IncludeFile "pbjs/pbjs.pb"
;
;    ⚠ Declaring it yourself means declaring EVERY constant pbjs reads — the
;    defaults below are skipped wholesale, not merged. Copy this file's
;    constant list and change what you need.
;
; What does NOT work: a plain `#PBJS_DevMode = 0` at the top level of your
; main.pb. Module scoping means neither pbjs nor the Defined() guard here can
; see it, and it is silently ignored — the defaults below apply and nothing
; warns you. Use one of the two mechanisms above.
;
; These are compile-time constants by design. A build either ships the
; inspector or it does not; there is no runtime toggle.
; =============================================================================

CompilerIf Not Defined(PbjsConfig, #PB_Module)

  DeclareModule PbjsConfig

    ; -------------------------------------------------------------------------
    ;- Dev mode — where a window's CONTENT comes from
    ; -------------------------------------------------------------------------
    ; #True  = load each window from its `debugUrl` (a Vite dev server), keep
    ;          re-injecting the bootstrap scripts after page reloads, and
    ;          reload recycled pool instances via window.location.reload().
    ; #False = load the embedded single-file HTML (IncludeBinary → DataSection)
    ;          through #PB_WebView_HtmlCode. This is what ships.
    ;
    ; Defaults to "the PureBasic debugger is attached" — what the dev task
    ; compiles with (/DEBUGGER) and what a release build never has. Override to
    ; decouple the two: a URL-loading build without the debugger, or a
    ; debugger-attached build that still serves the embedded HTML.
    ;
    ; ⚠ This is the flag the B3 origin work (roadmap 3.2) hangs off. The
    ; URL/baseURL content path must be selectable on its own merits, NOT on
    ; "is the PB debugger attached" — that coupling is a large part of why the
    ; missing-origin blocker stayed invisible.
    CompilerIf Not Defined(PBJS_DevMode, #PB_Constant)
      #PBJS_DevMode = #PB_Compiler_Debugger
    CompilerEndIf

    ; -------------------------------------------------------------------------
    ;- Devtools / web inspector
    ; -------------------------------------------------------------------------
    ; Passes #PB_WebView_Debug to every WebViewGadget: right-click → Inspect
    ; Element, remote inspection, the whole DevTools surface.
    ;
    ; A real exposure decision, not a nicety. A pbjs page holds the full native
    ; binding set — open/close/focus windows, drag, and window.fs when the host
    ; includes it — so an inspector on a shipped build is a console into those
    ; bindings for anyone at the machine.
    ;
    ; Defaults to dev mode. Set it #True deliberately for a release-diagnostics
    ; build you hand to a tester knowing what it opens.
    CompilerIf Not Defined(PBJS_EnableDevTools, #PB_Constant)
      #PBJS_EnableDevTools = #PBJS_DevMode
    CompilerEndIf

  EndDeclareModule

  Module PbjsConfig
  EndModule

CompilerEndIf
