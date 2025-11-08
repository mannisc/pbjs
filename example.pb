

IncludeFile "pbjs.pb"



; =============================================================================
;- START APP 
; =============================================================================


DeclareModule Execute
  Declare StartApp(mainWindowHtmlStart,mainWindowHtmlStop)
EndDeclareModule
Module Execute
  
     UseModule WindowManager
     UseModule JSWindow

  Procedure.i HandleMainEvent( Event.i, Window.i, Gadget.i)
    Select Event
      Case #PB_Event_SysTray
      Case #PB_Event_Menu
      Case #PB_Event_Timer
    EndSelect
  EndProcedure 
  
  
  Procedure WindowLoaded(*Window.AppWindow,*JSWindow.JSWindow)
    ; Debug *Window\Title
    ; Debug *JSWindow\Html
  EndProcedure 
  
  
  Procedure StartApp(mainWindowHtmlStart,mainWindowHtmlStop)
    UseModule OsTheme
    UseModule WindowManager
    
    DPI_Scale = DesktopResolutionX()
    If DPI_Scale <= 0
      DPI_Scale = 1.0
    EndIf
    
    OsTheme::InitOsTheme()
    
    WindowManager::InitWindowManager()
    
    *Window1 = JSWindow::CreateJSWindow(600, 100, 600, 400, "PBJS Example",   #PB_Window_SystemMenu | #PB_Window_SizeGadget |  #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget,  mainWindowHtmlStart,mainWindowHtmlStop )
    
    
    *Window2 = JSWindow::CreateJSWindow(100, 50, 700, 600, "PBJS Example", 
                                        #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                        #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget, mainWindowHtmlStart,mainWindowHtmlStop,@WindowLoaded())
   
   ;JSWindow::OpenJSWindow(*Window1)
    
    JSWindow::OpenJSWindow(*Window2)

    WindowManager::RunEventLoop(@HandleMainEvent()) 
    
  EndProcedure
EndModule



; =============================================================================
;- BOOTSTRAP
; =============================================================================



Execute::StartApp(?MainWindow,?EndMainWindow)
WindowManager::CleanupManagedWindows()

End 
DataSection
  MainWindow:
  IncludeBinary "react/main-window/dist/index.html"
  EndMainWindow:
EndDataSection
; IDE Options = PureBasic 6.21 - C Backend (MacOS X - arm64)
; CursorPosition = 54
; FirstLine = 31
; Folding = -
; EnableXP
; DPIAware