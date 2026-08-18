; =============================================================================
;- WebViewBaseUrl — give a PureBasic WebViewGadget's document a REAL ORIGIN
; =============================================================================
;
; THE PROBLEM
;   SetGadgetItemText(gadget, #PB_WebView_HtmlCode, html$) hands the engine a
;   bare HTML string with no base URL. The resulting document lands on an
;   OPAQUE ("null") origin and is NOT a secure context, which disables:
;
;     localStorage / sessionStorage ... throw SecurityError
;     indexedDB.open() .............. throws SecurityError (the global still
;                                     exists, so feature-detects pass!)
;     document.cookie ............... silently dropped, no exception
;     crypto.subtle / randomUUID .... absent
;     caches / serviceWorker ........ absent
;     navigator.clipboard ........... absent
;     navigator.storage.estimate() .. absent
;
;   (All eleven measured on macOS/WKWebView and Windows/WebView2 — see test.pb,
;   which re-measures them on whatever machine you run it on.)
;
; THE FIX
;   Load the same HTML but tell the engine what URL it "came from". The
;   document then gets that origin, becomes a secure context, and every API
;   above starts working. No HTTP server, no port, no custom scheme handler,
;   no file on disk — the document goes to the engine straight from memory.
;
;   Each engine spells it differently, and Windows cannot do it at all with a
;   plain string load — hence three implementations behind one call:
;
;     macOS   WKWebView    -[WKWebView loadHTMLString:baseURL:]
;     Linux   WebKitGTK    webkit_web_view_load_html(view, html, base_uri)
;     Windows WebView2     NavigateToString() has NO baseURL parameter, so we
;                          intercept http://<host>/* via WebResourceRequested
;                          and answer the navigation from a memory stream —
;                          served from RAM, never written to disk
;
; USE A PER-APP HOST, e.g. "myapp.localhost" — NOT bare "localhost". The origin
; is a global storage namespace: two apps sharing "http://localhost" share one
; localStorage/IndexedDB bucket. Anything under *.localhost is still treated as
; potentially-trustworthy, so isSecureContext stays true.
;
; WHAT THIS DOES NOT FIX
;   Packaging. The document is still ONE string, so keep everything inlined
;   (vite-plugin-singlefile or equivalent) — a relative subresource now
;   resolves against the real origin and does not exist there (the Windows
;   handler answers 404; macOS/Linux would hit the network). Service workers
;   still cannot register (that needs a fetchable script URL on the origin,
;   and SW script fetches bypass the Windows interception anyway), so the
;   serviceWorker object appears but registration will fail. Everything else
;   in the list above genuinely works.
;
; STATUS
;   macOS   — implemented and TESTED (see README.md for the measured output).
;   Windows — implemented and TESTED: 11/11 APIs repaired, nothing on disk
;             (measured output in README.md).
;   Linux   — implemented, NEVER COMPILED OR RUN. Code inside CompilerIf for
;             another OS is not even parsed, so that branch has not been near
;             a compiler. Expect to fix something; README.md lists the likely
;             failures in order.
;
; =============================================================================

DeclareModule WebViewBaseUrl

  ; Load html$ into the gadget with baseUrl$ as the document's origin.
  ; baseUrl$ should look like "http://myapp.localhost/".
  ; Returns #True on success; on #False call LastError().
  Declare.i SetHtml(gadget.i, html.s, baseUrl.s)

  ; Which implementation this build uses, e.g. "macos/WKWebView".
  Declare.s Backend()

  ; Reason the last SetHtml() returned #False ("" if none).
  Declare.s LastError()

EndDeclareModule


Module WebViewBaseUrl

  Global Err.s = ""

  Procedure.s LastError()
    ProcedureReturn Err
  EndProcedure

  ; ===========================================================================
  ;- macOS — WKWebView loadHTMLString:baseURL:
  ; ===========================================================================
  CompilerIf #PB_Compiler_OS = #PB_OS_MacOS

    ImportC ""
      object_getClassName(obj.i)
    EndImport

    Procedure.s Backend() : ProcedureReturn "macos/WKWebView" : EndProcedure

    ; PB does NOT hand you the WKWebView: GadgetID() returns a PBWebViewBox2
    ; wrapper and the real view sits two levels down, as an NSKVONotifying_
    ; subclass (something KVO-observes it). Measured hierarchy:
    ;   PBWebViewBox2 -> NSView -> NSKVONotifying_WKWebView -> WKFlippedView
    ; So: search by class-name substring, and check a node BEFORE recursing so
    ; we return the WKWebView itself rather than its WKFlippedView child.
    Procedure.i FindWebView(view.i)
      If view = 0 : ProcedureReturn 0 : EndIf
      Protected cls.s = PeekS(object_getClassName(view), -1, #PB_Ascii)
      If FindString(cls, "WKWebView") : ProcedureReturn view : EndIf
      Protected subviews = CocoaMessage(0, view, "subviews")
      If subviews
        Protected n = CocoaMessage(0, subviews, "count"), i, found
        For i = 0 To n - 1
          found = FindWebView(CocoaMessage(0, subviews, "objectAtIndex:", i))
          If found : ProcedureReturn found : EndIf
        Next
      EndIf
      ProcedureReturn 0
    EndProcedure

    Procedure.i NSString(s.s)
      Protected *utf8 = UTF8(s)
      Protected ns = CocoaMessage(0, 0, "NSString stringWithUTF8String:", *utf8)
      FreeMemory(*utf8)
      ProcedureReturn ns
    EndProcedure

    Procedure.i SetHtml(gadget.i, html.s, baseUrl.s)
      Err = ""
      If Not IsGadget(gadget)
        Err = "not a gadget" : ProcedureReturn #False
      EndIf

      Protected wk = FindWebView(GadgetID(gadget))
      If wk = 0
        Err = "WKWebView not found under GadgetID (PB internals changed?)"
        ProcedureReturn #False
      EndIf

      Protected nsUrl = 0
      If baseUrl <> ""
        nsUrl = CocoaMessage(0, 0, "NSURL URLWithString:", NSString(baseUrl))
        If nsUrl = 0
          Err = "NSURL rejected baseUrl: " + baseUrl
          ProcedureReturn #False
        EndIf
      EndIf

      CocoaMessage(0, wk, "loadHTMLString:", NSString(html), "baseURL:", nsUrl)
      ProcedureReturn #True
    EndProcedure

  CompilerEndIf


  ; ===========================================================================
  ;- Linux — WebKitGTK webkit_web_view_load_html()
  ; ===========================================================================
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux

    ; If the link fails with "undefined reference to webkit_web_view_load_html",
    ; the WebKitGTK ABI PB links against differs. Try, in order:
    ;   ImportC "-lwebkit2gtk-4.1" / "-lwebkit2gtk-4.0" / "-lwebkitgtk-6.0"
    ImportC ""
      webkit_web_view_load_html(view.i, content.p-utf8, base_uri.p-utf8)
      gtk_container_get_children(container.i)
      g_list_length(List.i)
      g_list_nth_data(List.i, n.i)
      g_list_free(List.i)
      g_type_name(type.i)
    EndImport

    Procedure.s Backend() : ProcedureReturn "linux/WebKitGTK" : EndProcedure

    ; GObject type name without the GLib macros: a GtkWidget* points at a
    ; GTypeInstance whose first field is GTypeClass*, whose first field is the
    ; GType. So: name = g_type_name(**widget).
    Procedure.s GObjectTypeName(widget.i)
      If widget = 0 : ProcedureReturn "" : EndIf
      Protected gclass = PeekI(widget)
      If gclass = 0 : ProcedureReturn "" : EndIf
      Protected gtype = PeekI(gclass)
      If gtype = 0 : ProcedureReturn "" : EndIf
      Protected *name = g_type_name(gtype)
      If *name = 0 : ProcedureReturn "" : EndIf
      ProcedureReturn PeekS(*name, -1, #PB_UTF8)
    EndProcedure

    ; Same shape as the macOS walk: PB wraps the web view in one or more GTK
    ; containers, so recurse until the type name contains "WebKitWebView".
    Procedure.i FindWebView(widget.i)
      If widget = 0 : ProcedureReturn 0 : EndIf
      Protected name.s = GObjectTypeName(widget)
      If FindString(name, "WebKitWebView") : ProcedureReturn widget : EndIf

      ; Only containers have children; gtk_container_get_children on a
      ; non-container returns NULL, which is harmless.
      Protected children = gtk_container_get_children(widget)
      If children = 0 : ProcedureReturn 0 : EndIf

      Protected n = g_list_length(children), i, found = 0
      For i = 0 To n - 1
        found = FindWebView(g_list_nth_data(children, i))
        If found : Break : EndIf
      Next
      g_list_free(children)
      ProcedureReturn found
    EndProcedure

    Procedure.i SetHtml(gadget.i, html.s, baseUrl.s)
      Err = ""
      If Not IsGadget(gadget)
        Err = "not a gadget" : ProcedureReturn #False
      EndIf

      Protected view = FindWebView(GadgetID(gadget))
      If view = 0
        Err = "WebKitWebView not found under GadgetID (PB internals changed?)"
        ProcedureReturn #False
      EndIf

      ; base_uri = NULL reproduces the broken behaviour, which is exactly what
      ; test.pb wants for its "before" run — so pass "" through deliberately.
      If baseUrl = ""
        webkit_web_view_load_html(view, html, "")
      Else
        webkit_web_view_load_html(view, html, baseUrl)
      EndIf
      ProcedureReturn #True
    EndProcedure

  CompilerEndIf


  ; ===========================================================================
  ;- Windows — WebView2, document served from RAM via WebResourceRequested
  ; ===========================================================================
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows

    ; WebView2's NavigateToString() has no baseURL parameter, so the baseURL
    ; trick is unavailable. The previous revision (git history) mapped a
    ; virtual host onto a real folder instead
    ; (ICoreWebView2_3::SetVirtualHostNameToFolderMapping) — which worked, but
    ; WROTE THE DOCUMENT TO DISK (%TEMP%\pbWebViewBaseUrl\<host>\index.html):
    ; the page source leaked into the filesystem on every SetHtml. This
    ; implementation keeps it in RAM:
    ;
    ;   1. AddWebResourceRequestedFilter("http://<host>/*")   [once per host]
    ;   2. add_WebResourceRequested(handler)                  [once per webview]
    ;   3. navigate to http://<host>/index.html               [every SetHtml]
    ;   4. the handler answers the request from a memory stream
    ;      (SHCreateMemStream -> CreateWebResourceResponse -> put_Response)
    ;
    ; The request never reaches the network stack or the filesystem, and the
    ; document still gets its real origin — an origin comes from the URL, not
    ; from how the bytes were produced. This is the same mechanism Tauri uses
    ; to serve entire apps on Windows (http://tauri.localhost). Bonus: every
    ; interface used here is v1 WebView2 API surface, so any Runtime has it
    ; (the folder mapping needed Runtime 98+, ~2021).
    ;
    ; ---------------------------------------------------------------------
    ; !! THE SLOT NUMBERS BELOW ARE HAND-COUNTED COM VTABLE SLOTS AND ARE THE
    ; !! MOST LIKELY THING TO BE WRONG. A wrong slot calls the wrong function
    ; !! pointer, which crashes rather than fails politely. If this crashes,
    ; !! check these first. Derivations are spelled out so they are checkable
    ; !! against Microsoft's WebView2.h without re-deriving anything.
    ; !! Empirical anchor: the folder-mapping revision successfully called
    ; !! slot 71 = 3 + (58 + 7 + 4) - 1 on this same vtable, which confirms
    ; !! the "ICoreWebView2 has 58 methods" and "_2 adds 7" counts relied on
    ; !! below; only the order inside each block still rests on the header.
    ; ---------------------------------------------------------------------
    ;
    ; Slot 0,1,2 are always IUnknown (QueryInterface, AddRef, Release).
    ;
    ; ICoreWebView2Controller, methods after IUnknown, in header order:
    ;   1 get_IsVisible          2 put_IsVisible
    ;   3 get_Bounds             4 put_Bounds
    ;   5 get_ZoomFactor         6 put_ZoomFactor
    ;   7 add_ZoomFactorChanged  8 remove_ZoomFactorChanged
    ;   9 SetBoundsAndZoomFactor 10 MoveFocus
    ;  11 add_MoveFocusRequested 12 remove_MoveFocusRequested
    ;  13 add_GotFocus           14 remove_GotFocus
    ;  15 add_LostFocus          16 remove_LostFocus
    ;  17 add_AcceleratorKeyPressed 18 remove_AcceleratorKeyPressed
    ;  19 get_ParentWindow       20 put_ParentWindow
    ;  21 NotifyParentWindowPositionChanged
    ;  22 Close                  23 get_CoreWebView2      <-- want this
    ; => slot = 3 + 23 - 1 = 25
    #SLOT_Controller_get_CoreWebView2 = 25

    ; ICoreWebView2 (58 methods), tail in header order:
    ;   ...49 OpenDevToolsWindow
    ;   50 add_ContainsFullScreenElementChanged
    ;   51 remove_ContainsFullScreenElementChanged
    ;   52 get_ContainsFullScreenElement
    ;   53 add_WebResourceRequested                => slot = 3 + 53 - 1 = 55
    ;   54 remove_WebResourceRequested
    ;   55 AddWebResourceRequestedFilter           => slot = 3 + 55 - 1 = 57
    ;   56 RemoveWebResourceRequestedFilter
    ;   57 add_WindowCloseRequested
    ;   58 remove_WindowCloseRequested
    #SLOT_WebView2_add_WebResourceRequested      = 55
    #SLOT_WebView2_AddWebResourceRequestedFilter = 57

    ; ICoreWebView2_2 adds 7 methods (59..65), in header order:
    ;   59 add_WebResourceResponseReceived
    ;   60 remove_WebResourceResponseReceived
    ;   61 NavigateWithWebResourceRequest
    ;   62 add_DOMContentLoaded    63 remove_DOMContentLoaded
    ;   64 get_CookieManager
    ;   65 get_Environment                         => slot = 3 + 65 - 1 = 67
    ; Same single-vtable-inheritance trick as the old slot 71 (which worked,
    ; so this runtime provably implements >= _3): index the base pointer.
    #SLOT_WebView2_2_get_Environment = 67

    ; ICoreWebView2Environment, methods after IUnknown, in header order:
    ;   1 CreateCoreWebView2Controller
    ;   2 CreateWebResourceResponse                => slot = 3 + 2 - 1 = 4
    ;   3 get_BrowserVersionString
    ;   4 add_NewBrowserVersionAvailable  5 remove_NewBrowserVersionAvailable
    #SLOT_Env_CreateWebResourceResponse = 4

    ; ICoreWebView2WebResourceRequestedEventArgs, methods after IUnknown:
    ;   1 get_Request    => slot 3
    ;   2 get_Response
    ;   3 put_Response   => slot 5
    ;   4 GetDeferral    5 get_ResourceContext
    #SLOT_Args_get_Request  = 3
    #SLOT_Args_put_Response = 5

    ; ICoreWebView2WebResourceRequest, methods after IUnknown:
    ;   1 get_Uri        => slot 3  (returns a CoTaskMemAlloc'd LPWSTR)
    #SLOT_Request_get_Uri = 3

    #SLOT_IUnknown_Release = 2

    #COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0
    #WVBU_S_OK          = 0
    #WVBU_E_NOINTERFACE = $80004002
    #WVBU_E_POINTER     = $80004003

    Procedure.s Backend() : ProcedureReturn "windows/WebView2 WebResourceRequested (RAM)" : EndProcedure

    ; Call slot `slot` of the COM object *iface with the given arguments.
    ; Hand-rolled rather than declared as a PB Interface so that fixing a wrong
    ; offset is a one-number edit instead of re-typing a 70-entry vtable.
    Procedure.i ComCall0(*iface, slot.i)
      If *iface = 0 : ProcedureReturn -1 : EndIf
      Protected *vtbl = PeekI(*iface)
      If *vtbl = 0 : ProcedureReturn -1 : EndIf
      Protected *fn = PeekI(*vtbl + slot * SizeOf(Integer))
      If *fn = 0 : ProcedureReturn -1 : EndIf
      ProcedureReturn CallFunctionFast(*fn, *iface)
    EndProcedure

    Procedure.i ComCall1(*iface, slot.i, a.i)
      If *iface = 0 : ProcedureReturn -1 : EndIf
      Protected *vtbl = PeekI(*iface)
      If *vtbl = 0 : ProcedureReturn -1 : EndIf
      Protected *fn = PeekI(*vtbl + slot * SizeOf(Integer))
      If *fn = 0 : ProcedureReturn -1 : EndIf
      ProcedureReturn CallFunctionFast(*fn, *iface, a)
    EndProcedure

    Procedure.i ComCall2(*iface, slot.i, a.i, b.i)
      If *iface = 0 : ProcedureReturn -1 : EndIf
      Protected *vtbl = PeekI(*iface)
      If *vtbl = 0 : ProcedureReturn -1 : EndIf
      Protected *fn = PeekI(*vtbl + slot * SizeOf(Integer))
      If *fn = 0 : ProcedureReturn -1 : EndIf
      ProcedureReturn CallFunctionFast(*fn, *iface, a, b)
    EndProcedure

    Procedure.i ComCall5(*iface, slot.i, a.i, b.i, c.i, d.i, e.i)
      If *iface = 0 : ProcedureReturn -1 : EndIf
      Protected *vtbl = PeekI(*iface)
      If *vtbl = 0 : ProcedureReturn -1 : EndIf
      Protected *fn = PeekI(*vtbl + slot * SizeOf(Integer))
      If *fn = 0 : ProcedureReturn -1 : EndIf
      ProcedureReturn CallFunctionFast(*fn, *iface, a, b, c, d, e)
    EndProcedure

    ; SHCreateMemStream (shlwapi, exported by name since Vista) is not in PB's
    ; import set, so bind it at runtime. It COPIES the given bytes into the
    ; stream, which is what keeps the per-request lifetime below simple. The
    ; library handle is deliberately kept open for the process lifetime.
    Prototype.i ProtoSHCreateMemStream(*init, size.l)
    Global fnSHCreateMemStream.ProtoSHCreateMemStream = 0

    Procedure.i EnsureMemStreamApi()
      Static tried.i = 0
      If fnSHCreateMemStream : ProcedureReturn #True : EndIf
      If tried : ProcedureReturn #False : EndIf
      tried = #True
      Protected lib = OpenLibrary(#PB_Any, "shlwapi.dll")
      If lib
        fnSHCreateMemStream = GetFunction(lib, "SHCreateMemStream")
      EndIf
      ProcedureReturn Bool(fnSHCreateMemStream <> 0)
    EndProcedure

    ; The in-RAM documents, keyed by lowercase host. Because SHCreateMemStream
    ; copies, a later SetHtml can replace a buffer without pulling the rug out
    ; from under an in-flight response.
    Structure HostDoc
      *utf8
      size.i
    EndStructure
    Global NewMap Docs.HostDoc()

    ; Hooks persist on the webview (like the old host mapping did): the event
    ; handler is added once per webview, the URI filter once per (gadget, host).
    Global NewMap HookedViews.q()   ; Str(*webview) -> EventRegistrationToken
    Global NewMap HookedHosts.i()   ; Str(gadget) + "|" + host -> #True

    ; --- ICoreWebView2WebResourceRequestedEventHandler, implemented in PB ----
    ; IUnknown plus one Invoke(sender, args). WebView2 only AddRef/Invoke/
    ; Release's it, always on the UI thread inside the ordinary message pump.
    ; QueryInterface answers for IUnknown and the handler's own IID and says
    ; E_NOINTERFACE to everything else (incl. IAgileObject — fine, since
    ; nothing here ever crosses a thread).
    Structure RequestHandler
      *vtbl
      refs.i
    EndStructure

    Global Dim HandlerVtbl.i(3)
    Global *Handler.RequestHandler = 0

    Procedure.i Handler_AddRef(*this.RequestHandler)
      *this\refs + 1
      ProcedureReturn *this\refs
    EndProcedure

    Procedure.i Handler_Release(*this.RequestHandler)
      *this\refs - 1
      Protected refs = *this\refs
      If refs = 0
        ; Unreachable in practice — the module keeps one reference forever.
        FreeStructure(*this)
      EndIf
      ProcedureReturn refs
    EndProcedure

    Procedure.i Handler_QueryInterface(*this.RequestHandler, *riid, *ppv.Integer)
      If *ppv = 0 : ProcedureReturn #WVBU_E_POINTER : EndIf
      If CompareMemory(*riid, ?IID_IUnknown, 16) Or CompareMemory(*riid, ?IID_WebResourceRequestedEventHandler, 16)
        *ppv\i = *this
        Handler_AddRef(*this)
        ProcedureReturn #WVBU_S_OK
      EndIf
      *ppv\i = 0
      ProcedureReturn #WVBU_E_NOINTERFACE
    EndProcedure

    Procedure.i Handler_Invoke(*this.RequestHandler, *sender, *args)
      ; One call per request matching a registered filter. Serve /index.html
      ; (and /) of a known host from RAM; 404 everything else (favicon.ico...)
      ; so no request ever leaves for the network.
      Protected *req = 0, *uriW = 0, *env = 0, *resp = 0, *stream = 0
      Protected uri.s, rest.s, host.s, path.s, headers.s, reason.s
      Protected status.i, p.i
      Protected *doc.HostDoc = 0

      ComCall1(*args, #SLOT_Args_get_Request, @*req)
      If *req
        ComCall1(*req, #SLOT_Request_get_Uri, @*uriW)
        If *uriW
          uri = PeekS(*uriW, -1, #PB_Unicode)
          CoTaskMemFree_(*uriW)
        EndIf
        ComCall0(*req, #SLOT_IUnknown_Release)
      EndIf

      ; scheme://host/path?query -> host, path
      p = FindString(uri, "://")
      If p
        rest = Mid(uri, p + 3)
        p = FindString(rest, "/")
        If p
          host = LCase(Left(rest, p - 1))
          path = Mid(rest, p)
        Else
          host = LCase(rest)
          path = "/"
        EndIf
        p = FindString(path, "?")
        If p : path = Left(path, p - 1) : EndIf
      EndIf
      *doc = FindMapElement(Docs(), host)

      ; The environment is the response factory. Property getters AddRef, so
      ; everything fetched here is released on the way out.
      ComCall1(*sender, #SLOT_WebView2_2_get_Environment, @*env)
      If *env = 0
        ; No factory, no response — the request fails as a network error
        ; instead of hanging.
        ProcedureReturn #WVBU_S_OK
      EndIf

      If *doc And *doc\utf8 And (path = "/" Or path = "/index.html")
        ; A fresh stream per request: streams are consumed as they are read.
        *stream = fnSHCreateMemStream(*doc\utf8, *doc\size)
        status = 200
        reason = "OK"
        headers = "Content-Type: text/html; charset=utf-8" + #CRLF$ + "Cache-Control: no-store"
      Else
        *stream = 0
        status = 404
        reason = "Not Found"
        headers = "Cache-Control: no-store"
      EndIf

      ComCall5(*env, #SLOT_Env_CreateWebResourceResponse, *stream, status, @reason, @headers, @*resp)
      If *resp
        ComCall1(*args, #SLOT_Args_put_Response, *resp)
        ComCall0(*resp, #SLOT_IUnknown_Release)    ; put_Response holds its own ref
      EndIf
      If *stream
        ComCall0(*stream, #SLOT_IUnknown_Release)  ; the response holds its own ref
      EndIf
      ComCall0(*env, #SLOT_IUnknown_Release)
      ProcedureReturn #WVBU_S_OK
    EndProcedure

    Procedure.i EnsureHandler()
      If *Handler : ProcedureReturn #True : EndIf
      HandlerVtbl(0) = @Handler_QueryInterface()
      HandlerVtbl(1) = @Handler_AddRef()
      HandlerVtbl(2) = @Handler_Release()
      HandlerVtbl(3) = @Handler_Invoke()
      *Handler = AllocateStructure(RequestHandler)
      If *Handler = 0 : ProcedureReturn #False : EndIf
      *Handler\vtbl = @HandlerVtbl(0)
      *Handler\refs = 1               ; the module's own ref — never released
      ProcedureReturn #True
    EndProcedure

    ; Earlier revisions of this module wrote the document under
    ; %TEMP%\pbWebViewBaseUrl\ — exactly the leak this implementation removes.
    ; Scrub what old builds left behind, once, best-effort. The folder is
    ; namespaced and only ever written by this module.
    Procedure CleanupLegacyTempDir()
      Static done.i = 0
      If done : ProcedureReturn : EndIf
      done = #True
      Protected dir.s = GetTemporaryDirectory() + "pbWebViewBaseUrl"
      If FileSize(dir) = -2
        DeleteDirectory(dir, "*.*", #PB_FileSystem_Recursive | #PB_FileSystem_Force)
      EndIf
    EndProcedure

    Procedure.i SetHtml(gadget.i, html.s, baseUrl.s)
      Err = ""
      If Not IsGadget(gadget)
        Err = "not a gadget" : ProcedureReturn #False
      EndIf

      ; No baseUrl requested -> reproduce PB's normal (broken) behaviour, which
      ; is what test.pb's "before" run needs.
      If baseUrl = ""
        SetGadgetItemText(gadget, #PB_WebView_HtmlCode, html)
        ProcedureReturn #True
      EndIf

      CleanupLegacyTempDir()

      ; --- parse scheme://host[/] out of baseUrl -----------------------------
      Protected work.s = baseUrl
      Protected scheme.s = "http"
      Protected p = FindString(work, "://")
      If p
        scheme = Left(work, p - 1)
        work = Mid(work, p + 3)
      EndIf
      p = FindString(work, "/")
      If p : work = Left(work, p - 1) : EndIf
      Protected host.s = LCase(work)   ; hosts are case-insensitive; the map is not
      If host = ""
        Err = "could not parse a host out of baseUrl: " + baseUrl
        ProcedureReturn #False
      EndIf

      If EnsureMemStreamApi() = 0
        Err = "SHCreateMemStream not found in shlwapi.dll"
        ProcedureReturn #False
      EndIf

      ; --- keep the document in RAM (this replaces the old folder write) -----
      Protected size.i = StringByteLength(html, #PB_UTF8)
      Protected *utf8 = AllocateMemory(size + 1)   ; +1: PokeS writes a terminator
      If *utf8 = 0
        Err = "out of memory (" + Str(size) + " bytes)"
        ProcedureReturn #False
      EndIf
      PokeS(*utf8, html, -1, #PB_UTF8)

      Protected *doc.HostDoc = FindMapElement(Docs(), host)
      If *doc = 0
        *doc = AddMapElement(Docs(), host)
        If *doc = 0
          FreeMemory(*utf8)
          Err = "out of memory (host map)"
          ProcedureReturn #False
        EndIf
      EndIf
      If *doc\utf8 : FreeMemory(*doc\utf8) : EndIf
      *doc\utf8 = *utf8
      *doc\size = size

      ; --- hook the webview: handler once per view, filter once per host -----
      Protected key.s = Str(gadget) + "|" + host
      If FindMapElement(HookedHosts(), key) = 0
        Protected *controller = GetGadgetAttribute(gadget, #PB_WebView_ICoreController)
        If *controller = 0
          Err = "GetGadgetAttribute(#PB_WebView_ICoreController) returned 0 — " +
                "is this PB build using WebView2?"
          ProcedureReturn #False
        EndIf

        Protected *webview = 0
        Protected hr = ComCall1(*controller, #SLOT_Controller_get_CoreWebView2, @*webview)
        If hr <> 0 Or *webview = 0
          Err = "get_CoreWebView2 failed (hr=" + Str(hr) + ") — check " +
                "#SLOT_Controller_get_CoreWebView2"
          ProcedureReturn #False
        EndIf
        ; (the getter AddRef'd *webview — the reference is deliberately kept,
        ; the hook lives for the gadget's lifetime)

        If EnsureHandler() = 0
          Err = "could not allocate the WebResourceRequested handler"
          ProcedureReturn #False
        EndIf

        If FindMapElement(HookedViews(), Str(*webview)) = 0
          Protected token.q = 0
          hr = ComCall2(*webview, #SLOT_WebView2_add_WebResourceRequested, *Handler, @token)
          If hr <> 0
            Err = "add_WebResourceRequested failed (hr=" + Str(hr) + ") — check " +
                  "#SLOT_WebView2_add_WebResourceRequested"
            ProcedureReturn #False
          EndIf
          HookedViews(Str(*webview)) = token
        EndIf

        Protected pattern.s = scheme + "://" + host + "/*"
        hr = ComCall2(*webview, #SLOT_WebView2_AddWebResourceRequestedFilter, @pattern, #COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)
        If hr <> 0
          Err = "AddWebResourceRequestedFilter failed (hr=" + Str(hr) + ") — check " +
                "#SLOT_WebView2_AddWebResourceRequestedFilter"
          ProcedureReturn #False
        EndIf

        HookedHosts(key) = #True
      EndIf

      ; --- navigate: the handler above answers this from RAM -----------------
      SetGadgetText(gadget, scheme + "://" + host + "/index.html")
      ProcedureReturn #True
    EndProcedure

    DataSection
      ; GUIDs as raw little-endian bytes (Data1.l, Data2.w, Data3.w LE; Data4
      ; byte-for-byte), so CompareMemory can take them 16 bytes at a time.
      IID_IUnknown:                          ; 00000000-0000-0000-C000-000000000046
      Data.b $00, $00, $00, $00, $00, $00, $00, $00
      Data.b $C0, $00, $00, $00, $00, $00, $00, $46
      IID_WebResourceRequestedEventHandler:  ; AB00B74C-15F1-4646-80E8-E76341D25D71
      Data.b $4C, $B7, $00, $AB, $F1, $15, $46, $46   ; (from WebView2.h — re-check
      Data.b $80, $E8, $E7, $63, $41, $D2, $5D, $71   ;  there if QI ever fails)
    EndDataSection

  CompilerEndIf

EndModule

; IDE Options = PureBasic 6.40 (Linux - x64)
; CursorPosition = 219
; FirstLine = 207
; Folding = ----
; EnableXP
; DPIAware