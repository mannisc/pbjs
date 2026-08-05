; =============================================================================
;- DND SERVICE — DECLARE (see DndService.pb for the module body)
; =============================================================================
; Split declare/body like pbjsBridgeDeclare.pb: JSWindow.pb binds the JS-facing
; natives below (BindWebviewEvents) before the module body — which needs the
; JSWindow registry and JSBridge — can be included.

DeclareModule DndService
  ; Call once from the host app after the event loop infrastructure exists
  ; (creates the badge window, starts the tick timer, registers the reply
  ; handler). Safe to skip — the JS natives then report "unavailable" and the
  ; web UI falls back to its legacy single-window behavior.
  Declare Init()
  Declare.i IsEnabled()

  ; Register the pbjsNativeDnd* binds on a window's sink — called from
  ; JSWindow::BindWebviewEvents for every window. Lives here (not in JSWindow)
  ; because PB's @ operator cannot take module-qualified procedure addresses.
  ; The bound procs run inside webview callbacks → they only mutate state;
  ; every Cocoa-touching effect happens on the timer tick (docs/app-close.md).
  Declare BindNatives(sink.i)
EndDeclareModule
