# webviewBaseUrl

Give a PureBasic `WebViewGadget`'s document a **real origin**, so the web APIs
that are silently disabled today start working — without an HTTP server, a port,
a custom scheme handler, or a file on disk.

**Status:** macOS and Windows implemented and **tested (11/11 APIs repaired on
each)** — on Windows the document is served **from RAM, nothing touches the
disk**. Linux implemented but **never compiled or run** — that is the work this
folder exists to make easy.

---

## The problem

`SetGadgetItemText(gadget, #PB_WebView_HtmlCode, html$)` hands the engine a bare
HTML string with no base URL. The document therefore lands on an **opaque
("null") origin** and is **not a secure context**. Measured on macOS/WKWebView:

| API | pbjs/PureBasic today |
|---|---|
| `localStorage` / `sessionStorage` | throws `SecurityError` |
| `indexedDB.open()` | throws `SecurityError` |
| `document.cookie` | **silently dropped** — no exception |
| `crypto.subtle`, `crypto.randomUUID` | absent |
| `caches`, `serviceWorker`, `clipboard` | absent |
| `navigator.storage.estimate()` | absent |

The IndexedDB one is the nastiest: the `indexedDB` global **is** present, so
`if (indexedDB)` passes and the failure only appears at the first real call.
Cookies are worse still — nothing throws, the write just vanishes.

## The fix

Load the same HTML, but tell the engine what URL it came from. One call.

```purebasic
IncludeFile "WebViewBaseUrl.pb"

web = WebViewGadget(#PB_Any, 0, 0, 800, 600)
WebViewBaseUrl::SetHtml(web, myHtml$, "http://myapp.localhost/")
```

Use a **per-app** host like `myapp.localhost`, not bare `localhost`: the origin
is a global storage namespace, so two apps on `http://localhost` would share one
`localStorage`/IndexedDB bucket. Anything under `*.localhost` is still treated as
potentially-trustworthy, so `isSecureContext` stays `true`.

### API

```purebasic
WebViewBaseUrl::SetHtml(gadget, html$, baseUrl$)  ; #True on success
WebViewBaseUrl::LastError()                        ; why it returned #False
WebViewBaseUrl::Backend()                          ; e.g. "macos/WKWebView"
```

Passing `baseUrl$ = ""` deliberately reproduces the old broken behaviour — that
is how `test.pb` gets its "before" column.

## Measured result — macOS

`./wvtest` on macOS 15 / PureBasic 6.21 / arm64:

```
OS       : macos
backend  : macos/WKWebView
baseUrl  : http://pbwebview.localhost/

API                   no baseURL (today)      with baseURL (fixed)
origin                null                    http://pbwebview.localhost
isSecureContext       false                   true
localStorage          THROW:SecurityError     OK
sessionStorage        THROW:SecurityError     OK
indexedDB.open        THROW:SecurityError     OK
cookie                SILENT-FAIL             OK
crypto.randomUUID     ABSENT                  OK
crypto.subtle         ABSENT                  OK
caches                ABSENT                  present
caches.open           THROW:ReferenceError    OK
serviceWorker         ABSENT                  present
clipboard             ABSENT                  present
storage.estimate      THROW:TypeError         OK

APIs repaired by the fix: 11 of 11
VERDICT: WORKING on macos
```

## Measured result — Windows

`wvtest.exe` on Windows 11 / PureBasic 6.30 / x64:

```
OS       : windows
backend  : windows/WebView2 WebResourceRequested (RAM)
baseUrl  : http://pbwebview.localhost/
on disk  : nothing — document served from RAM

API                   no baseURL (today)      with baseURL (fixed)
origin                null                    http://pbwebview.localhost
isSecureContext       false                   true
localStorage          THROW:SecurityError     OK
sessionStorage        THROW:SecurityError     OK
indexedDB.open        THROW:SecurityError     OK
cookie                THROW:SecurityError     OK
crypto.randomUUID     ABSENT                  OK
crypto.subtle         ABSENT                  OK
caches                ABSENT                  present
caches.open           THROW:ReferenceError    OK
serviceWorker         ABSENT                  present
clipboard             ABSENT                  present
storage.estimate      THROW:TypeError         OK

APIs repaired by the fix: 11 of 11
VERDICT: WORKING on windows
```

The same run also verified the de-leak: a `%TEMP%\pbWebViewBaseUrl\` tree left
behind by the old folder-mapping build existed before the run and was gone
after it (the module scrubs it once, then never writes there again).

## Build and run

The harness writes `results-<os>.txt` next to the executable, prints the same
table to stdout, and shows it in a window. Send that file on.

**macOS**
```bash
/Applications/PureBasic.app/Contents/Resources/compilers/pbcompiler test.pb -e wvtest && ./wvtest
```

**Linux**
```bash
$PUREBASIC_HOME/compilers/pbcompiler test.pb -e wvtest && ./wvtest
```

**Windows**
```
"%PROGRAMFILES%\PureBasic\Compilers\pbcompiler.exe" test.pb /EXE wvtest.exe && wvtest.exe
```

A `VERDICT:` line at the bottom says WORKING / PARTIAL / NOT WORKING.

## How each platform does it

| OS | Engine | Mechanism |
|---|---|---|
| macOS | WKWebView | `-[WKWebView loadHTMLString:baseURL:]` |
| Linux | WebKitGTK | `webkit_web_view_load_html(view, html, base_uri)` |
| Windows | WebView2 | `NavigateToString` has **no** baseURL param, so: register a `WebResourceRequested` handler for `http://<host>/*`, navigate to `http://<host>/index.html`, and answer that request from a memory stream (`SHCreateMemStream` → `CreateWebResourceResponse`) — served from RAM, nothing written to disk |

On macOS and Linux, `GadgetID()` does **not** give you the web view — PureBasic
wraps it. Measured macOS hierarchy:

```
PBWebViewBox2 -> NSView -> NSKVONotifying_WKWebView -> WKFlippedView
```

so the module walks the view tree matching on class name (`WKWebView` substring
— note the `NSKVONotifying_` prefix, something KVO-observes it). Linux does the
equivalent walk over GTK children matching `WebKitWebView`.

On Windows the interception needs a real COM object — an
`ICoreWebView2WebResourceRequestedEventHandler` — which the module implements
in plain PureBasic: a 4-slot vtable (QueryInterface / AddRef / Release /
Invoke) built from procedure pointers. WebView2 invokes it synchronously on
the UI thread inside the ordinary message pump. Everything it touches is v1
WebView2 API, so any WebView2 Runtime is new enough (the old folder mapping
needed Runtime 98+). Earlier revisions wrote the document to
`%TEMP%\pbWebViewBaseUrl\<host>\index.html`; the module now scrubs that folder
once on first use and never writes it again — `test.pb` prints an `on disk`
line asserting exactly that.

## If it does not work

Ordered by how likely each is. The harness's `LastError()` output names most of
these directly.

### Windows

Verified working (see the measured result above), so these are now "if it
breaks on YOUR machine" notes rather than expected failures:

1. **It crashes.** Almost certainly the hand-counted COM vtable slots at the
   top of the Windows block in `WebViewBaseUrl.pb` (`25`, `55`, `57`, `67`,
   `4`, and the small arg-interface slots `3`/`5`). Every derivation is
   written out in comments — check them against Microsoft's `WebView2.h`. A
   wrong slot calls the wrong function pointer, which crashes rather than
   failing politely. The method *counts* are empirically pinned (the old
   revision's slot 71 worked); only the order inside each block rests on the
   header.
2. **`GetGadgetAttribute(#PB_WebView_ICoreController)` returns 0.** That PB
   build is not using WebView2, or the attribute name differs in your version.
3. **`add_WebResourceRequested` / `AddWebResourceRequestedFilter` /
   `CreateWebResourceResponse` return a non-zero HRESULT.** `LastError()`
   names which one. All of it is v1 WebView2 API, present in every Runtime —
   so unlike the old folder mapping, a too-old Runtime is *not* a suspect;
   re-check the slot constants first.
4. **Page loads but APIs still fail.** The handler did not fire. Check that
   RUN 2 reported at all, and that the navigation went to
   `http://<host>/index.html` — the filter host is lowercased, so a mismatch
   usually means the URL's host/port differs from what `SetHtml` parsed out
   of `baseUrl$`.
5. **`SetHtml FAILED: SHCreateMemStream not found`.** Pre-Vista Windows only —
   not a real target.
6. **Fallback:** the old folder-mapping implementation (works, but writes the
   document to `%TEMP%` and needs Runtime 98+) is preserved in git history for
   this file.

### Linux

1. **Link error: `undefined reference to webkit_web_view_load_html`.** PB links a
   different WebKitGTK ABI. In the `ImportC ""` block try
   `ImportC "-lwebkit2gtk-4.1"`, then `-lwebkit2gtk-4.0`, then `-lwebkitgtk-6.0`.
   Match whatever `ldd` on the built binary shows.
2. **`WebKitWebView not found under GadgetID`.** The GTK nesting differs. Add a
   debug print of `GObjectTypeName()` for each node in `FindWebView` and look at
   the actual tree — the macOS spike found a two-level wrapper, Linux may differ.
3. **GTK4 vs GTK3.** `gtk_container_get_children` does not exist in GTK4. If PB
   is GTK4-based, use `gtk_widget_get_first_child` / `gtk_widget_get_next_sibling`
   instead. This changes `FindWebView` only.

### Any platform

- **`NO REPORT (page never called pbReport within 8s)` on RUN 2 only.** The
  `BindWebViewCallback` binding did not survive the alternate load path. On macOS
  it does survive (tested). If it does not on yours, the fix may still be working
  — verify by reading `document.title` instead, or by re-binding after the load.
- **RUN 1 also reports nothing.** Something unrelated to this fix is wrong; the
  harness never got off the ground.

## Integrating into pbjs

The change is confined to one place. In `pbjs/modules/JSWindow.pb`,
`#Event_Loaded_Html` currently does:

```purebasic
SetGadgetItemText(webViewGadget, #PB_WebView_HtmlCode, html)
```

That becomes a `WebViewBaseUrl::SetHtml(webViewGadget, html, baseUrl$)`, with the
base URL derived per window (e.g. `http://<appname>.localhost/`). Everything else
— the bridge script injection, `BindWebViewCallback`, the deferred content-ready
handshake — is untouched, and on macOS and Windows the bindings are confirmed to
survive (the harness's RUN 2 reports through `BindWebViewCallback` after the
alternate load). On Windows it also means a window's HTML no longer appears
under `%TEMP%` at all.

Consider making the base URL a host-app setting rather than hardcoding it, so a
consumer picks its own origin. `iplan/roadmap.md` step 3.2 (B3) carries the
wider context and the per-OS route table.

## What this does NOT fix

- **Packaging.** The document is still one string, so keep everything inlined
  (`vite-plugin-singlefile` or equivalent). A relative subresource now resolves
  against the real origin and does not exist there (the Windows handler answers
  404; macOS/Linux would hit the network).
- **Service workers.** The `serviceWorker` object appears, but registration needs
  a fetchable script URL on the origin — so it will still fail. (On Windows,
  serving `/sw.js` from the handler is not enough either: service-worker script
  fetches bypass `WebResourceRequested` on current runtimes.) Offline/PWA and
  `@capacitor/push-notifications` need a real server on the origin.

On Windows the interception *can* serve more than one path — the handler already
owns all of `http://<host>/*`, so teaching it a path → bytes map would serve a
whole `www/` tree from RAM and fix packaging there too. That is a natural
extension, not implemented here (today everything but `/index.html` and `/`
gets a 404).
