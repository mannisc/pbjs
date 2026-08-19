

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
    
    
        

    ; ⚠ The 10th argument is *Parent, NOT CloseBehaviour. Passing
    ; #JSWindow_Behaviour_HideWindow here is what this line used to do, and it
    ; segfaulted on the spot: the behaviour constants are an Enumeration from
    ; #PB_Event_FirstCustomValue, so the value is 0x10000 — non-zero, so the
    ; `If *Parent And IsWindow(*Parent\Window)` guard let it through and the
    ; dereference read 0x10008. Pass the parent explicitly, then the behaviour.
    *Window1 = JSWindow::CreateJSWindow("main-window", 600, 100, 600, 400, "PBJS JS Example 1",
                                        #PB_Window_SystemMenu | #PB_Window_SizeGadget |
                                        #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget,
                                        mainWindowHtmlStart, mainWindowHtmlStop,
                                        0, #JSWindow_Behaviour_HideWindow)
    
    
    ; Same slots. @WindowLoaded() is *WindowReadyCallback, the 12th argument —
    ; it used to land in CloseBehaviour, so the callback was never called and
    ; the close behaviour was a function pointer.
    *Window2 = JSWindow::CreateJSWindow("sub-window", 500, 50, 700, 600, "PBJS JS Example 2",
                                        #PB_Window_SystemMenu | #PB_Window_SizeGadget |
                                        #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget,
                                        mainWindowHtmlStart, mainWindowHtmlStop,
                                        0, #JSWindow_Behaviour_HideWindow, @WindowLoaded())
   
    
   
   
   OpenWindow(1,100,300,300,300,"PBJS Native", #PB_Window_SystemMenu)
   ButtonGadget(1,75,10,150,30,"Open PBJS Window")
   ButtonGadget(2,75,50,150,30,"Resize PBJS Window")
   
   EditorGadget(3,0,100,300,200)
   
   
   
   JSWindow::OpenJSWindow(*Window1) 
   

 ;   OpenJSWindow(GetJSWindow("main-window"))
   

   

    ; Third slot is ShouldKeepRunning — the second is the network-event hook
    ; (web mode). Passing KeepRunning in the wrong slot silently disables it:
    ; NetworkServerEvent() never fires here, so it would never be called.
    WindowManager::RunEventLoop(@HandleMainEvent(), 0, @KeepRunning())
   
   
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
  IncludeBinary "reactExample/main-window/dist/index.html"
  EndMainWindow:
EndDataSection
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 122
; FirstLine = 91
; Folding = --
; EnableXP
; DPIAware
; Executable = ..\..\main.exe