; =============================================================================
;- DRAG BADGE — floating cursor chip for cross-window drag sessions
; =============================================================================
; A single reusable borderless, topmost, click-through window that follows the
; OS cursor during a DnD session (see DndService.pb). Drawn with VectorDrawing
; (one code path for every OS): rounded chip, terminal glyph, one-line label,
; optional hint text per style.
;
; Styles (mirror iplan/cross-window-dnd/plan.md §1):
;   #Style_NewWindow — over desktop / foreign apps: release opens a new window
;   #Style_Revert    — over an app window outside any drop zone: release reverts
;
; macOS specifics (the only fully supported platform today — DndService gates
; the whole feature to macOS): popup window level, ignoresMouseEvents (also
; excludes the badge from WindowFromPoint-style hit tests), joins all Spaces.
; The module still compiles everywhere; non-mac platforms simply never Show().
;
; No Cocoa work may happen in WebKit callbacks (docs/app-close.md) — all
; procedures here are called from the DndService timer tick / Init, which run
; on the main event loop.

DeclareModule DragBadge
  Enumeration ; badge visual style
    #Style_NewWindow
    #Style_Revert
  EndEnumeration

  Declare Init()
  Declare.i GetWindow()          ; PB window number, 0 when Init failed/not run
  Declare.i CocoaWindowNumber()  ; NSWindow windowNumber (macOS), else 0
  Declare Show(icon.s, label.s, style.i, x.i, y.i)  ; x/y: cursor in PB desktop coords
  Declare Move(x.i, y.i)
  Declare Hide()
  Declare.i IsVisible()
EndDeclareModule

Module DragBadge
  Global BadgeWindow.i = 0
  Global BadgeCanvas.i = 0
  Global BadgeFont.i = 0
  Global Visible.i = #False
  Global CurIcon.s, CurLabel.s
  Global CurStyle.i = -1
  Global CurW.i = 0

  #BadgeH = 30
  #Radius = 7
  ; Offset from the cursor hotspot so the chip never sits under the pointer tip.
  #OffsetX = 16
  #OffsetY = 20
  #MaxLabelWidth = 150
  #FontSize = 11

  Procedure Init()
    If BadgeWindow : ProcedureReturn : EndIf
    ; Invisible until the first Show(); parked far off-screen so the initial
    ; reveal never flashes at a stale position.
    BadgeWindow = OpenWindow(#PB_Any, -10000, -10000, 220, #BadgeH, "",
                             #PB_Window_BorderLess | #PB_Window_Invisible)
    If Not BadgeWindow
      BadgeWindow = 0
      ProcedureReturn
    EndIf
    BadgeCanvas = CanvasGadget(#PB_Any, 0, 0, 220, #BadgeH)
    StickyWindow(BadgeWindow, #True)

    CompilerSelect #PB_Compiler_OS
      CompilerCase #PB_OS_MacOS
        Protected nsWin = WindowID(BadgeWindow)
        ; NSPopUpMenuWindowLevel — above every normal app window.
        CocoaMessage(0, nsWin, "setLevel:", 101)
        ; Click-through: mouse events pass to whatever is underneath, and
        ; windowNumberAtPoint-based hit tests can exclude it explicitly.
        CocoaMessage(0, nsWin, "setIgnoresMouseEvents:", #True)
        ; CanJoinAllSpaces (1<<0) | FullScreenAuxiliary (1<<8): follow the
        ; cursor onto other Spaces and over fullscreen windows.
        CocoaMessage(0, nsWin, "setCollectionBehavior:", 257)
        ; No explicit "non-activating" flag needed (unlike the Windows branch
        ; below, which sets WS_EX_NOACTIVATE): AppKit's own NSWindow default
        ; -canBecomeKeyWindow returns NO for a borderless window with no
        ; title bar and no resize bar (this one — #PB_Window_BorderLess, no
        ; NSPanel), so a plain OpenWindow()/HideWindow() unhide here can't
        ; make it key or steal focus. If that default is ever relied on
        ; changing (e.g. this window gains a title bar), it would need an
        ; explicit override — there is no settable property for it, only a
        ; subclass method, which OpenWindow()'s plain NSWindow doesn't have.
      CompilerCase #PB_OS_Windows
        ; Click-through + no-activate; WS_EX_TRANSPARENT also removes the
        ; badge from WindowFromPoint hit tests. (Feature is macOS-gated today;
        ; kept so a future Windows backend only needs the hit-test half.)
        Protected hwnd = WindowID(BadgeWindow)
        Protected exStyle = GetWindowLongPtr_(hwnd, #GWL_EXSTYLE)
        SetWindowLongPtr_(hwnd, #GWL_EXSTYLE, exStyle | #WS_EX_LAYERED | #WS_EX_TRANSPARENT | #WS_EX_NOACTIVATE | #WS_EX_TOOLWINDOW)
        SetLayeredWindowAttributes_(hwnd, 0, 255, #LWA_ALPHA)
    CompilerEndSelect

    CompilerSelect #PB_Compiler_OS
      CompilerCase #PB_OS_MacOS
        BadgeFont = LoadFont(#PB_Any, "Helvetica Neue", #FontSize)
      CompilerCase #PB_OS_Windows
        BadgeFont = LoadFont(#PB_Any, "Segoe UI", #FontSize)
      CompilerDefault
        BadgeFont = LoadFont(#PB_Any, "DejaVu Sans", #FontSize)
    CompilerEndSelect
  EndProcedure

  Procedure.i GetWindow()
    ProcedureReturn BadgeWindow
  EndProcedure

  Procedure.i CocoaWindowNumber()
    CompilerIf #PB_Compiler_OS = #PB_OS_MacOS
      If BadgeWindow
        ProcedureReturn CocoaMessage(0, WindowID(BadgeWindow), "windowNumber")
      EndIf
    CompilerEndIf
    ProcedureReturn 0
  EndProcedure

  Procedure.i IsVisible()
    ProcedureReturn Visible
  EndProcedure

  ; Rounded-rect path via tangent arcs (PB VectorDrawing has no round-box
  ; primitive).
  Procedure RoundRectPath(x.d, y.d, w.d, h.d, r.d)
    MovePathCursor(x + r, y)
    AddPathArc(x + w, y, x + w, y + h, r)
    AddPathArc(x + w, y + h, x, y + h, r)
    AddPathArc(x, y + h, x, y, r)
    AddPathArc(x, y, x + w, y, r)
    ClosePath()
  EndProcedure

  ; Small terminal glyph: rounded square + ">" chevron + underscore. The one
  ; icon shipped today ("terminal"); unknown icon names fall back to it.
  Procedure DrawTerminalGlyph(gx.d, gy.d, color.q)
    RoundRectPath(gx, gy, 16, 16, 3.5)
    VectorSourceColor(color)
    StrokePath(1.5)
    MovePathCursor(gx + 4, gy + 5)
    AddPathLine(gx + 7.5, gy + 8)
    AddPathLine(gx + 4, gy + 11)
    VectorSourceColor(color)
    StrokePath(1.5, #PB_Path_RoundCorner | #PB_Path_RoundEnd)
    MovePathCursor(gx + 9.5, gy + 12)
    AddPathLine(gx + 12.5, gy + 12)
    VectorSourceColor(color)
    StrokePath(1.5, #PB_Path_RoundEnd)
  EndProcedure

  ; Full redraw. Measures the label, resizes the window to fit, renders the
  ; chip. Called on Show() and when icon/label/style change — not per Move().
  Procedure Draw()
    If Not BadgeWindow : ProcedureReturn : EndIf

    Protected hint.s = ""
    Protected bg.q, ring.q, fg.q, iconCol.q, hintCol.q
    Select CurStyle
      Case #Style_Revert
        ; Dimmed: release here reverts the drag to its origin.
        hint    = "back"
        bg      = RGBA(24, 26, 32, 205)
        ring    = RGBA(107, 114, 128, 200)
        fg      = RGBA(156, 163, 175, 255)
        iconCol = RGBA(107, 114, 128, 255)
        hintCol = RGBA(107, 114, 128, 230)
      Default ; #Style_NewWindow
        bg      = RGBA(24, 26, 32, 242)
        ring    = RGBA(59, 130, 246, 255)
        fg      = RGBA(229, 231, 235, 255)
        iconCol = RGBA(147, 197, 253, 255)
        hint    = "New Window"
        hintCol = RGBA(107, 114, 128, 255)
    EndSelect

    ; Pass 1: measure text to compute the chip width.
    Protected labelW.d = 0, hintW.d = 0, labelText.s = CurLabel
    If StartVectorDrawing(CanvasVectorOutput(BadgeCanvas))
      If BadgeFont : VectorFont(FontID(BadgeFont), #FontSize) : EndIf
      If labelText <> ""
        labelW = VectorTextWidth(labelText)
        While labelW > #MaxLabelWidth And Len(labelText) > 1
          labelText = Left(labelText, Len(labelText) - 1)
          labelW = VectorTextWidth(labelText + Chr($2026))
        Wend
        If labelText <> CurLabel : labelText + Chr($2026) : EndIf
      EndIf
      If hint <> "" : hintW = VectorTextWidth(hint) : EndIf
      StopVectorDrawing()
    EndIf

    ; Layout: [pad 8][glyph 16][gap 7][label][gap 8][hint][pad 9]
    Protected w.i = 8 + 16 + 7
    If labelW > 0 : w + labelW + 8 : EndIf
    If hintW > 0 : w + hintW : EndIf
    w + 9
    If w < 44 : w = 44 : EndIf

    If w <> CurW
      CurW = w
      ResizeWindow(BadgeWindow, #PB_Ignore, #PB_Ignore, w, #BadgeH)
      ResizeGadget(BadgeCanvas, 0, 0, w, #BadgeH)
    EndIf

    ; Pass 2: render.
    If StartVectorDrawing(CanvasVectorOutput(BadgeCanvas))
      VectorSourceColor(RGBA(0, 0, 0, 0))
      FillVectorOutput()
      RoundRectPath(1, 1, w - 2, #BadgeH - 2, #Radius)
      VectorSourceColor(bg)
      FillPath(#PB_Path_Preserve)
      VectorSourceColor(ring)
      StrokePath(1.2)

      DrawTerminalGlyph(8, (#BadgeH - 16) / 2, iconCol)

      If BadgeFont : VectorFont(FontID(BadgeFont), #FontSize) : EndIf
      Protected tx.d = 8 + 16 + 7
      Protected ty.d = (#BadgeH - VectorTextHeight("Ag")) / 2
      If labelText <> ""
        MovePathCursor(tx, ty)
        VectorSourceColor(fg)
        DrawVectorText(labelText)
        tx + labelW + 8
      EndIf
      If hint <> ""
        MovePathCursor(tx, ty)
        VectorSourceColor(hintCol)
        DrawVectorText(hint)
      EndIf
      StopVectorDrawing()
    EndIf
  EndProcedure

  Procedure Show(icon.s, label.s, style.i, x.i, y.i)
    If Not BadgeWindow : ProcedureReturn : EndIf
    If icon <> CurIcon Or label <> CurLabel Or style <> CurStyle Or Not Visible
      CurIcon = icon
      CurLabel = label
      CurStyle = style
      Draw()
    EndIf
    ResizeWindow(BadgeWindow, x + #OffsetX, y + #OffsetY, #PB_Ignore, #PB_Ignore)
    If Not Visible
      HideWindow(BadgeWindow, #False)
      Visible = #True
    EndIf
  EndProcedure

  Procedure Move(x.i, y.i)
    If BadgeWindow And Visible
      ResizeWindow(BadgeWindow, x + #OffsetX, y + #OffsetY, #PB_Ignore, #PB_Ignore)
    EndIf
  EndProcedure

  Procedure Hide()
    If BadgeWindow And Visible
      HideWindow(BadgeWindow, #True)
      Visible = #False
    EndIf
  EndProcedure
EndModule
