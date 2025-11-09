

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
  
  Global canClose = #False 
  
  Global *Window1, *Window2 
  
  Procedure.i HandleMainEvent( Event.i, EventWindow.i, EventGadget.i,EventType.i)
    
    If Event <> 0
      
      EventWindow = EventWindow()
      EventGadget = EventGadget()
      EventType = EventType()
      If EventWindow = 1 
        If Event = #PB_Event_Gadget And EventType = #PB_EventType_LeftClick   
           If EventGadget = 1
             JSWindow::OpenJSWindow(*Window2)
           ElseIf EventGadget = 2
             JSWindow::ResizeJSWindow(*Window2,650,20,250,500)
           EndIf 
          
        ElseIf event = #PB_Event_CloseWindow
          CloseWindow(1)
          canClose = #True 
          End 
        EndIf 
      EndIf 
    EndIf 
    
    
  EndProcedure 
  
  
  Procedure WindowLoaded(*Window.AppWindow,*JSWindow.JSWindow)
    ; Debug *Window\Title
    ; Debug *JSWindow\Html
  EndProcedure 
  
  Procedure KeepRunning()
    ProcedureReturn Bool(Not canClose)
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
    
    
        

    *Window1 = JSWindow::CreateJSWindow("main-window",600, 100, 600, 400, "PBJS JS Example 1",   #PB_Window_SystemMenu | #PB_Window_SizeGadget |  #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget,  mainWindowHtmlStart, mainWindowHtmlStop ,#JSWindow_Behaviour_HideWindow)
    
    
    *Window2 = JSWindow::CreateJSWindow("sub-window",500, 50, 700, 600, "PBJS JS Example 2", 
                                        #PB_Window_SystemMenu | #PB_Window_SizeGadget | 
                                        #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget, mainWindowHtmlStart, mainWindowHtmlStop, #JSWindow_Behaviour_HideWindow, @WindowLoaded())
   
    
   
   
   OpenWindow(1,100,300,300,300,"PBJS Native", #PB_Window_SystemMenu)
   ButtonGadget(1,75,10,150,30,"Open PBJS Window")
   ButtonGadget(2,75,50,150,30,"Resize PBJS Window")
   
   EditorGadget(3,0,100,300,200)
   
   
   
   JSWindow::OpenJSWindow(*Window1) 
   

 ;   OpenJSWindow(GetJSWindow("main-window"))
   

   

    WindowManager::RunEventLoop(@HandleMainEvent(),@KeepRunning()) 
   
   
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
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 41
; FirstLine = 22
; Folding = --
; EnableXP
; DPIAware
; Executable = ..\..\main.exe