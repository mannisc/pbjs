; ============================================================================
; STANDALONE COMPILE CHECK
; ============================================================================
; The entire point of this file is its brevity: it includes pbjs and nothing
; else. If it stops syntax-checking, pbjs has grown a dependency on a symbol
; that exists only in a host application — the class of leak that compiles
; fine here (pbjs is developed as a nested repo inside Vynce, where Ptym,
; StartupTrace and friends all happen to be in scope) and fails in a
; stranger's terminal. `UseModule Ptym` shipped exactly that way.
;
; Run it through the wrapper, which also finds the compiler and checks the
; example:
;
;     ci/check-purebasic.sh
;
; Or directly — note the flag is -k / --check. (`-c` is --commented, which
; dumps the generated C instead; a different tool for a different job.)
;
;     PUREBASIC_HOME=... pbcompiler ci/standalone-check.pb --check
;
; ⚠ Needs a LICENSED PureBasic: the free version caps each source file at 800
; lines and modules/JSWindow.pb is ~3,500. See .github/workflows/ci.yml for
; what that means for CI.
; ============================================================================

IncludeFile "../pbjs.pb"
