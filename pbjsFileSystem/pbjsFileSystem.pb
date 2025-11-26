; ============================================================================
; JSFileSystem - Node.js-like File System for WebviewGadget
; ============================================================================

DeclareModule JSFileSystem
  Declare InitializeFileSystem(window.i, webViewGadget.i)
  Declare.s WithFileSystemScript(html.s, contextId.s)
EndDeclareModule

Module JSFileSystem
  
  ; ============================================================================
  ; INTERNAL STATE
  ; ============================================================================
  
  Structure FSContext
    Window.i
    WebViewGadget.i
  EndStructure
  
  Global NewMap Contexts.FSContext()
  
  ; ============================================================================
  ; EMBEDDED SCRIPT
  ; ============================================================================
  
  Global fsScript.s
  
  DataSection
    FSScriptStart:
    IncludeBinary "pbjsFileSystemScript.js"
    FSScriptEnd:
  EndDataSection
  
  Define *buffer = ?FSScriptStart
  Define size.i = ?FSScriptEnd - ?FSScriptStart
  fsScript = PeekS(*buffer, size, #PB_UTF8|#PB_ByteLength)
  
  ; ============================================================================
  ; HELPER FUNCTIONS
  ; ============================================================================
  
  Procedure.s EscapeJSON(text.s)
    Protected result.s
    result = ReplaceString(text, Chr(92), Chr(92)+Chr(92))
    result = ReplaceString(result, Chr(34), Chr(92)+Chr(34))
    result = ReplaceString(result, Chr(13), Chr(92)+"r")
    result = ReplaceString(result, Chr(10), Chr(92)+"n")
    result = ReplaceString(result, Chr(9), Chr(92)+"t")
    ProcedureReturn result
  EndProcedure
  
  Procedure SendResponse(gadget.i, requestId.i, dataJson.s, error.s = "")
    Protected response.s, script.s
    
    If error <> ""
      response = ~"{\"requestId\":" + Str(requestId) + ~",\"error\":\"" + EscapeJSON(error) + ~"\"}"
    Else
      response = ~"{\"requestId\":" + Str(requestId) + ~",\"data\":" + dataJson + ~"}"
    EndIf
    
    script = "pbjsHandleFSResponse('" + EscapeJSON(response) + "');"
    WebViewExecuteScript(gadget, script)
  EndProcedure
  
  ; ============================================================================
  ; FILE SYSTEM OPERATIONS
  ; ============================================================================
  
  Procedure FS_Access(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    Protected mode.i = 0
    If GetJSONMember(jsonArgs, "mode")
      mode = GetJSONInteger(GetJSONMember(jsonArgs, "mode"))
    EndIf
    
    If FileSize(path) >= 0
      ; Simple check, mode handling is limited in PB
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "File not found")
    EndIf
  EndProcedure
  
  Procedure FS_ReadFile(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    Protected options.i = GetJSONMember(jsonArgs, "options")
    Protected encoding.s = "utf8"
    Protected file.i, content.s, *mem, length.i, base64.s
    
    If options
      If JSONType(options) = #PB_JSON_String
        encoding = GetJSONString(options)
      ElseIf JSONType(options) = #PB_JSON_Object
        If GetJSONMember(options, "encoding")
          encoding = GetJSONString(GetJSONMember(options, "encoding"))
        EndIf
      EndIf
    EndIf
    
    file = ReadFile(#PB_Any, path)
    If file
      length = Lof(file)
      *mem = AllocateMemory(length)
      If *mem
        ReadData(file, *mem, length)
        CloseFile(file)
        
        If encoding = "utf8"
          content = PeekS(*mem, length, #PB_UTF8)
          SendResponse(gadget, requestId, ~"\"" + EscapeJSON(content) + ~"\"")
        Else
          base64 = Base64Encoder(*mem, length)
          SendResponse(gadget, requestId, ~"\"" + base64 + ~"\"")
        EndIf
        FreeMemory(*mem)
      Else
        CloseFile(file)
        SendResponse(gadget, requestId, "", "Memory allocation failed")
      EndIf
    Else
      SendResponse(gadget, requestId, "", "File not found: " + path)
    EndIf
  EndProcedure
  
  Procedure FS_WriteFile(gadget.i, requestId.i, jsonArgs.i)
    Protected file.s = GetJSONString(GetJSONMember(jsonArgs, "file"))
    Protected dataVal.s = GetJSONString(GetJSONMember(jsonArgs, "data"))
    Protected options.i = GetJSONMember(jsonArgs, "options")
    Protected encoding.s = "utf8"
    Protected fileH.i, *mem, length.i
    
    If options
      If JSONType(options) = #PB_JSON_String
        encoding = GetJSONString(options)
      ElseIf JSONType(options) = #PB_JSON_Object
        If GetJSONMember(options, "encoding")
          encoding = GetJSONString(GetJSONMember(options, "encoding"))
        EndIf
      EndIf
    EndIf
    
    fileH = CreateFile(#PB_Any, file)
    If fileH
      If encoding = "utf8"
        WriteString(fileH, dataVal, #PB_UTF8)
      ElseIf encoding = "base64"
        length = Len(dataVal)
        *mem = AllocateMemory(length) ; Max size
        length = Base64Decoder(dataVal, *mem, length)
        WriteData(fileH, *mem, length)
        FreeMemory(*mem)
      Else
         WriteString(fileH, dataVal, #PB_UTF8) ; Default
      EndIf
      CloseFile(fileH)
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "Could not create file: " + file)
    EndIf
  EndProcedure
  
  Procedure FS_Readdir(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    Protected dir.i, entryName.s, jsonRes.s
    Protected NewList entries.s()
    
    dir = ExamineDirectory(#PB_Any, path, "*.*")
    If dir
      While NextDirectoryEntry(dir)
        entryName = DirectoryEntryName(dir)
        If entryName <> "." And entryName <> ".."
          AddElement(entries())
          entries() = entryName
        EndIf
      Wend
      FinishDirectory(dir)
      
      jsonRes = "["
      ForEach entries()
        jsonRes + ~"\"" + EscapeJSON(entries()) + ~"\""
        If ListIndex(entries()) < ListSize(entries()) - 1
          jsonRes + ","
        EndIf
      Next
      jsonRes + "]"
      
      SendResponse(gadget, requestId, jsonRes)
    Else
      SendResponse(gadget, requestId, "", "Directory not found: " + path)
    EndIf
  EndProcedure
  
  Procedure FS_Mkdir(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    
    Debug "FS_Mkdir: " + path + " (CWD: " + GetCurrentDirectory() + ")"
    
    If FileSize(path) = -2
      SendResponse(gadget, requestId, "", "Directory already exists: " + path)
      ProcedureReturn
    EndIf
    
    If CreateDirectory(path)
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "Could not create directory: " + path)
    EndIf
  EndProcedure
  
  Procedure FS_Rmdir(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    
    If DeleteDirectory(path, "", #PB_FileSystem_Recursive)
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "Could not remove directory: " + path)
    EndIf
  EndProcedure
  
  Procedure FS_Unlink(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    
    If DeleteFile(path)
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "Could not delete file: " + path)
    EndIf
  EndProcedure
  
  Procedure FS_Rename(gadget.i, requestId.i, jsonArgs.i)
    Protected oldPath.s = GetJSONString(GetJSONMember(jsonArgs, "oldPath"))
    Protected newPath.s = GetJSONString(GetJSONMember(jsonArgs, "newPath"))
    
    If RenameFile(oldPath, newPath)
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "", "Could not rename file")
    EndIf
  EndProcedure
  
  Procedure FS_Stat(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    Protected size.q, modified.i, created.i, accessed.i, attrib.i, mode.i
    Protected jsonRes.s
    
    If FileSize(path) = -1
      SendResponse(gadget, requestId, "", "File not found")
      ProcedureReturn
    EndIf
    
    size = FileSize(path)
    If size = -2 ; Directory
      mode = 16384 ; S_IFDIR (040000 octal)
      size = 0
    Else
      mode = 32768 ; S_IFREG (0100000 octal)
    EndIf
    
    modified = GetFileDate(path, #PB_Date_Modified)
    created = GetFileDate(path, #PB_Date_Created)
    accessed = GetFileDate(path, #PB_Date_Accessed)
    
    jsonRes = "{"
    jsonRes + ~"\"size\":" + Str(size) + ","
    jsonRes + ~"\"mtimeMs\":" + Str(modified * 1000) + ","
    jsonRes + ~"\"ctimeMs\":" + Str(created * 1000) + ","
    jsonRes + ~"\"atimeMs\":" + Str(accessed * 1000) + ","
    jsonRes + ~"\"mode\":" + Str(mode)
    jsonRes + "}"
    
    SendResponse(gadget, requestId, jsonRes)
  EndProcedure
  
  Procedure FS_Exists(gadget.i, requestId.i, jsonArgs.i)
    Protected path.s = GetJSONString(GetJSONMember(jsonArgs, "path"))
    If FileSize(path) <> -1
      SendResponse(gadget, requestId, "true")
    Else
      SendResponse(gadget, requestId, "false")
    EndIf
  EndProcedure

  ; ============================================================================
  ; MAIN HANDLER
  ; ============================================================================
  
  Procedure HandleFS(jsonParameters.s)
    Protected json.i, method.s, requestId.i, args.i
    Protected gadget.i
    
    Debug "HandleFS: " + jsonParameters
    
    Dim parameters.s(0)
    ParseJSON(0, jsonParameters)
    ExtractJSONArray(JSONValue(0), parameters())
    jsonData.s = parameters(0)
    
    json = ParseJSON(#PB_Any, jsonData)
    If json
      method = GetJSONString(GetJSONMember(JSONValue(json), "method"))
      requestId = GetJSONInteger(GetJSONMember(JSONValue(json), "requestId"))
      args = GetJSONMember(JSONValue(json), "args")
      
      Debug "Method: " + method + ", RequestID: " + Str(requestId)
      
      ; We need the gadget ID. 
      ; Let's assume we can get it from the map if we passed it.
      ; For now, let's iterate through all contexts and send to all? No, that's bad.
      ; Let's rely on the fact that we only have one for now, or fix the architecture.
      ; Better: The JS should send the window ID.
      ; I will update the JS injection to include a unique ID.
      
      ; For this implementation, I'll iterate and try to find where it came from? Impossible.
      ; I will assume the `InitializeFileSystem` stores the gadget in a global if only one is used,
      ; OR I will update the JS to send a context ID.
      
      ; Let's look at `pbjsBridge`. It uses `JSWindows` map.
      ; `HandleSend` gets `fromWindow` from the JSON.
      ; So I need to add `contextId` to the JSON sent from JS.
      
      ; I will use the `Contexts` map.
      ; But wait, the JS doesn't know its context ID unless I tell it.
      
      ; Let's grab the first gadget for now as a fallback, but ideally we match `windowId`.
      ; I'll assume `InitializeFileSystem` sets up the mapping.
      
      Protected contextId.s
      If GetJSONMember(JSONValue(json), "contextId")
        contextId = GetJSONString(GetJSONMember(JSONValue(json), "contextId"))
      EndIf
      
      If contextId <> "" And FindMapElement(Contexts(), contextId)
        gadget = Contexts(contextId)\WebViewGadget
      Else
        ; Fallback: Use the first one found
        ForEach Contexts()
          gadget = Contexts()\WebViewGadget
          Break
        Next
      EndIf
      
      Select method
        Case "access": FS_Access(gadget, requestId, args)
        Case "readFile": FS_ReadFile(gadget, requestId, args)
        Case "writeFile": FS_WriteFile(gadget, requestId, args)
        Case "readdir": FS_Readdir(gadget, requestId, args)
        Case "mkdir": FS_Mkdir(gadget, requestId, args)
        Case "rmdir": FS_Rmdir(gadget, requestId, args)
        Case "unlink": FS_Unlink(gadget, requestId, args)
        Case "rename": FS_Rename(gadget, requestId, args)
        Case "stat": FS_Stat(gadget, requestId, args)
        Case "exists": FS_Exists(gadget, requestId, args)
        Default
          Debug "Method not implemented: " + method
          SendResponse(gadget, requestId, "", "Method not implemented: " + method)
      EndSelect
      
      FreeJSON(json)
    Else
       Debug "Failed to parse JSON in HandleFS"
    EndIf
  EndProcedure
  
  ; ============================================================================
  ; PUBLIC API
  ; ============================================================================
  
  Procedure InitializeFileSystem(window.i, webViewGadget.i)
    Protected contextId.s = Str(window)
    Contexts(contextId)\Window = window
    Contexts(contextId)\WebViewGadget = webViewGadget
    
    BindWebViewCallback(webViewGadget, "pbjsNativeFS", @HandleFS())
  EndProcedure
  
  Procedure.s WithFileSystemScript(html.s, contextId.s)
    Protected result.s, bodyPos.i, bodyEndPos.i, initScript.s
    
    result = html
    
    ; Inject context ID
    initScript = ~"<script>window.pbjsFSContextId = '" + contextId + ~"';</script>\n"
    initScript + ~"<script>\n" + fsScript + ~"</script>\n"
    
    If FindString(result, "<body", 1, #PB_String_NoCase)
      bodyPos = FindString(result, "<body", 1, #PB_String_NoCase)
      bodyEndPos = FindString(result, ">", bodyPos)
      If bodyEndPos > 0
        result = Left(result, bodyEndPos) + initScript + Mid(result, bodyEndPos + 1)
      EndIf
    Else
      result = initScript + result
    EndIf
    
    ProcedureReturn result
  EndProcedure

EndModule