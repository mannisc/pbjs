; ============================================================================
; JSFileSystem Test Runner
; ============================================================================

IncludeFile "pbjsFileSystem.pb"

UseModule JSFileSystem

Procedure RunTest()
  OpenWindow(0, 0, 0, 800, 600, "JSFileSystem Test", #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
  
  WebViewGadget(0, 0, 0, 800, 600, #PB_WebView_Debug)
  
  ; Initialize FS
  InitializeFileSystem(0, 0)
  
  ; Load HTML
  Define html.s
  If ReadFile(0, "pbjsFileSystemTest.html")
    html = ReadString(0, #PB_File_IgnoreEOL)
    CloseFile(0)
  Else
    Debug "Error: Could not read test HTML"
    End
  EndIf
  
  ; Inject Script
  html = WithFileSystemScript(html, "0")
  
  SetGadgetItemText(0, #PB_Web_HtmlCode, html)
  
  Repeat
    Event = WaitWindowEvent()
  Until Event = #PB_Event_CloseWindow
EndProcedure

RunTest()
