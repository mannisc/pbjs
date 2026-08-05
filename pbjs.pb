
;=====================================================================
;-  Window Dark Mode Support
;=====================================================================
IncludeFile "modules/OsTheme.pb"

; =============================================================================
;- WINDOW MANAGER MODULE
; =============================================================================
XIncludeFile "modules/WindowManager.pb"

; =============================================================================
;- SINK (per-window script/callback routing — web-mode headless support)
; =============================================================================
; Internally guarded against double inclusion: the host app may include it
; earlier (main.pb includes it before ptym.pb, which also routes through Sink).
XIncludeFile "modules/JSSink.pb"

; =============================================================================
;- JS BRIDGE DECLARE
; =============================================================================

IncludeFile "pbjsBridge/pbjsBridgeDeclare.pb"

; =============================================================================
;- CROSS-WINDOW DRAG & DROP (badge + declares; module body follows JSBridge)
; =============================================================================
IncludeFile "modules/DragBadge.pb"
IncludeFile "modules/DndServiceDeclare.pb"

; =============================================================================
;- JS WINDOW
; =============================================================================
IncludeFile "modules/JSWindow.pb"

; =============================================================================
;- JS BRIDGE
; =============================================================================

IncludeFile "pbjsBridge/pbjsBridge.pb"

; =============================================================================
;- CROSS-WINDOW DRAG & DROP (module body — needs JSWindow registry + JSBridge)
; =============================================================================
IncludeFile "modules/DndService.pb"