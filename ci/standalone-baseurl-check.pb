; ============================================================================
; STANDALONE COMPILE CHECK — with the opt-in base URL wired in
; ============================================================================
; Same job as standalone-check.pb, one include earlier: it puts
; webviewBaseUrl/ in scope before pbjs.pb, which is how a host switches the
; per-window `baseUrl` option on (README §2.1). That flips JSWindow.pb's
; `CompilerIf Defined(WebViewBaseUrl, #PB_Module)` to its OTHER branch — the
; one that actually calls WebViewBaseUrl::SetHtml.
;
; Without this file that branch is compiled by no check in this repo: the
; plain standalone check and pbjsExample.pb both take the CompilerElse path,
; so a rename or a signature change there would pass every gate and only
; surface in a host app.
;
; ⚠ Linux: check-purebasic.sh SKIPS this one. webviewBaseUrl's WebKitGTK
; branch has never been compiled or run (webviewBaseUrl/README.md says so and
; lists the likely failures) — failing the whole gate there would block a
; push over an optional module the host may not even include.
;
;     PUREBASIC_HOME=... pbcompiler ci/standalone-baseurl-check.pb --check
; ============================================================================

IncludeFile "../webviewBaseUrl/WebViewBaseUrl.pb"
IncludeFile "../pbjs.pb"
