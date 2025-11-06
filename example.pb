

IncludeFile "pbjs.pb"



; =============================================================================
;- START APP 
; =============================================================================


DeclareModule Execute
  Declare StartApp(mainWindow.s)
EndDeclareModule
Module Execute
  
  
  Procedure.i HandleMainEvent( Event.i, Window.i, Gadget.i)
    Select Event
      Case #PB_Event_SysTray
      Case #PB_Event_Menu
      Case #PB_Event_Timer
    EndSelect
  EndProcedure 
  
  
  Procedure StartApp(mainWindow.s)
    UseModule OsTheme
    UseModule WindowManager
    
    DPI_Scale = DesktopResolutionX()
    If DPI_Scale <= 0
      DPI_Scale = 1.0
    EndIf
    
    
    OsTheme::InitOsTheme()
    
    WindowManager::InitWindowManager()
        *Window1 = JSWindow::CreateJSWindow(800, 100, 600, 400, "WebView List Example", 
                                        #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                        #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget, mainWindow)
    JSWindow::OpenJSWindow(*Window1)
        *Window2 = JSWindow::CreateJSWindow(100, 50, 700, 600, "WebView List Example", 
                                       #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                       #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget, mainWindow)
    
  JSWindow::OpenJSWindow(*Window2 )
    
    

    
    WindowManager::RunEventLoop(@HandleMainEvent()) 
    
  EndProcedure
EndModule


; =============================================================================
;- BOOTSTRAP
; =============================================================================

mainWindow.s = PeekS(?MainWindow,?EndMainWindow-?MainWindow, #PB_UTF8   )


Execute::StartApp(mainWindow.s)
WindowManager::CleanupManagedWindows()

Debug "End"
End 
DataSection
    MainWindow:
    IncludeBinary "react/main-window/dist/index.html"
    EndMainWindow:
  EndDataSection
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 68
; FirstLine = 26
; Folding = -
; EnableXP
; DPIAware