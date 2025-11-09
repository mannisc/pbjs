; Node.js API Bridge for PureBasic WebViewGadget
; This demonstrates how to bridge Node.js filesystem methods

Procedure fs_readFileSync(JsonParameters$)
  ; Parameters: [filepath, encoding]
  Debug #PB_Compiler_Procedure + ": " + JsonParameters$
  
  ParseJSON(0, JsonParameters$)
  Dim params.s(2)
  ExtractJSONArray(JSONValue(0), params())
  
  Protected filepath$ = params(0)
  Protected encoding$ = params(1) ; "utf8" or empty for binary
  Protected result$
  
  If ReadFile(0, filepath$)
    If encoding$ = "utf8"
      ; Read as text
      result$ = ""
      While Not Eof(0)
        result$ + ReadString(0) + #LF$
      Wend
      CloseFile(0)
      
      ; Return JSON with content
      ProcedureReturn UTF8(~"{ \"success\": true, \"data\": " + 
                          result$ + " }")
    Else
      ; Read as binary (base64 encoded)
      Protected size = Lof(0)
      Protected *buffer = AllocateMemory(size)
      
      If *buffer
        ReadData(0, *buffer, size)
        CloseFile(0)
        
        ; Convert to base64
        Protected base64$ = Base64Encoder(*buffer, size)
        FreeMemory(*buffer)
        
        ProcedureReturn UTF8(~"{ \"success\": true, \"data\": \"" + base64$ + ~"\", \"encoding\": \"base64\" }")
      EndIf
    EndIf
  EndIf
  
  ; Error case
  ProcedureReturn UTF8(~"{ \"success\": false, \"error\": \"File not found or cannot read\" }")
EndProcedure

Procedure fs_writeFileSync(JsonParameters$)
  ; Parameters: [filepath, data, encoding]
  Debug #PB_Compiler_Procedure + ": " + JsonParameters$
  
  Dim params.s(0)

  ParseJSON(0, JsonParameters$)
  ExtractJSONArray(JSONValue(0), params())
  
  Protected filepath$ = params(0)
  Protected Data$ = params(1)
  Protected encoding$ = params(2)
  
  If CreateFile(0, filepath$)
    If encoding$ = "utf8" Or encoding$ = ""
      WriteString(0, Data$)
    Else
      ; Handle base64 binary data
      Protected *buffer = AllocateMemory(Len(Data$))
      Protected size = Base64Decoder(Data$, *buffer, Len(Data$))
      WriteData(0, *buffer, size)
      FreeMemory(*buffer)
    EndIf
    CloseFile(0)
    
    ProcedureReturn UTF8(~"{ \"success\": true }")
  EndIf
  
  ProcedureReturn UTF8(~"{ \"success\": false, \"error\": \"Cannot write file\" }")
EndProcedure

Procedure fs_existsSync(JsonParameters$)
  ; Parameters: [filepath]
    Dim params.s(0)

  ParseJSON(0, JsonParameters$)
  ExtractJSONArray(JSONValue(0), params())
  
  Protected filepath$ = params(0)
  Protected exists = Bool(FileSize(filepath$) >= 0)
  
  ProcedureReturn UTF8(Str(exists))
EndProcedure

Procedure path_join(JsonParameters$)
  ; Parameters: array of path segments
    Dim params.s(0)

  ParseJSON(0, JsonParameters$)
  ExtractJSONArray(JSONValue(0), params())
  
  Protected result$ = ""
  Protected i
  
  For i = 0 To ArraySize(params())
    If i > 0 And Right(result$, 1) <> #PS$ And Left(params(i), 1) <> #PS$
      result$ + #PS$
    EndIf
    result$ + params(i)
  Next
  
  ProcedureReturn UTF8(~"\"" + result$ + ~"\"")
EndProcedure

Procedure process_cwd(JsonParameters$)
  ; Returns current working directory
  
  json = CreateJSON(#PB_Any)
root = SetJSONObject(JSONValue(json))
SetJSONString(AddJSONMember(root, "data"), GetCurrentDirectory())

  
response.s = ComposeJSON(json) ;~"{\"dir\":\"" + GetCurrentDirectory() + ~"\"}"
Debug "!!!!!!!!!!!"
  Debug response
  ProcedureReturn UTF8(response)
EndProcedure

Procedure os_platform(JsonParameters$)
  ; Returns platform name
  CompilerSelect #PB_Compiler_OS
    CompilerCase #PB_OS_Windows
      ProcedureReturn UTF8(~"\"win32\"")
    CompilerCase #PB_OS_Linux
      ProcedureReturn UTF8(~"\"linux\"")
    CompilerCase #PB_OS_MacOS
      ProcedureReturn UTF8(~"\"darwin\"")
  CompilerEndSelect
EndProcedure

; ============================================
; Main Program
; ============================================

Global HTML$ = ~"<!DOCTYPE html>\n" +
               ~"<html>\n" +
               ~"<head>\n" +
               ~"  <meta charset='utf-8'>\n" +
               ~"  <title>Node.js Bridge Test</title>\n" +
               ~"</head>\n" +
               ~"<body style='background: #fff'>\n" +
               ~"  <h1>Node.js API Bridge Test</h1>\n" +
               ~"  <button onclick='testFS()'>Test Filesystem</button>\n" +
               ~"  <button onclick='testPath()'>Test Path</button>\n" +
               ~"  <button onclick='testProcess()'>Test Process</button>\n" +
               ~"  <pre id='output'></pre>\n" +
               ~"\n" +
               ~"  <script>\n" +
               ~"    // Reconstruct Node.js-like API\n" +
               ~"    const fs = {\n" +
               ~"      readFileSync: (path, enc) => {\n" +
               ~"        const result = JSON.parse(fs_readFileSync([path, enc || 'utf8']));\n" +
               ~"        if (!result.success) throw new Error(result.error);\n" +
               ~"        return result.data;\n" +
               ~"      },\n" +
               ~"      writeFileSync: (path, data, enc) => {\n" +
               ~"        const result = JSON.parse(fs_writeFileSync([path, data, enc || 'utf8']));\n" +
               ~"        if (!result.success) throw new Error(result.error);\n" +
               ~"      },\n" +
               ~"      existsSync: (path) => JSON.parse(fs_existsSync([path]))\n" +
               ~"    };\n" +
               ~"\n" +
               ~"    const path = {\n" +
               ~"      join: (...segments) => JSON.parse((await path_join(segments)).data)\n" +
               ~"    };\n" +
               ~"\n" +
               ~"    const process = {\n" +
               ~"    "+
               ~"      cwd: async () => {(await process_cwd([]).data)}\n" +
               ~"    };\n" +
               ~"\n" +
               ~"    const os = {\n" +
               ~"      platform: () => JSON.parse(os_platform([]))\n" +
               ~"    };\n" +
               ~"\n" +
               ~"    function log(msg) {\n" +
               ~"      document.getElementById('output').textContent += msg + '\\n';\n" +
               ~"    }\n" +
               ~"\n" +
               ~"   async function  testFS() {\n" +
               ~"      log('\\n=== Filesystem Test ===');\n" +
               ~"      try {\n" +
               ~"      log('\\n=== 1 ===');\n" +
               ~"      let cwd = await process.cwd();\n" +
               ~"      console.log('CWD:',cwd);\n" +
               ~"      log('\\n=== 2 ===');\n" +
               ~"        const testFile = path.join(cwd, 'test.txt');\n" +
               ~"        log('Writing to: ' + testFile);\n" +
               ~"        fs.writeFileSync(testFile, 'Hello from WebView!');\n" +
               ~"        log('File written successfully');\n" +
               ~"        \n" +
               ~"        log('Reading back...');\n" +
               ~"        const content = fs.readFileSync(testFile);\n" +
               ~"        log('Content: ' + content);\n" +
               ~"        \n" +
               ~"        log('File exists: ' + fs.existsSync(testFile));\n" +
               ~"      } catch(e) {\n" +
               ~"        log('Error: ' + e.message);\n" +
               ~"      }\n" +
               ~"    }\n" +
               ~"\n" +
               ~"    function testPath() {\n" +
               ~"      log('\\n=== Path Test ===');\n" +
               ~"      const joined = path.join('folder', 'subfolder', 'file.txt');\n" +
               ~"      log('path.join result: ' + joined);\n" +
               ~"    }\n" +
               ~"\n" +
               ~"    function testProcess() {\n" +
               ~"      log('\\n=== Process Test ===');\n" +
               ~"      log('Current directory: ' + process.cwd());\n" +
               ~"      log('Platform: ' + os.platform());\n" +
               ~"    }\n" +
               ~"  </script>\n" +
               ~"</body>\n" +
               ~"</html>"

OpenWindow(0, 100, 100, 600, 500, "Node.js Bridge", #PB_Window_SystemMenu)
WebViewGadget(0, 0, 0, 600, 500,#PB_WebView_Debug)

; Bind all our bridge methods
BindWebViewCallback(0, "fs_readFileSync", @fs_readFileSync())
BindWebViewCallback(0, "fs_writeFileSync", @fs_writeFileSync())
BindWebViewCallback(0, "fs_existsSync", @fs_existsSync())
BindWebViewCallback(0, "path_join", @path_join())
BindWebViewCallback(0, "process_cwd", @process_cwd())
BindWebViewCallback(0, "os_platform", @os_platform())

; Set the HTML content
SetGadgetItemText(0, #PB_Web_HtmlCode, HTML$)

Repeat 
  Event = WaitWindowEvent()
Until Event = #PB_Event_CloseWindow
; IDE Options = PureBasic 6.21 (Windows - x64)
; CursorPosition = 228
; FirstLine = 206
; Folding = --
; EnableXP
; DPIAware