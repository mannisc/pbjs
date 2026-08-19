@echo off
rem ============================================================================
rem Build the example end to end: web app -^> executable.  (Windows; see build.sh)
rem ============================================================================
rem Two steps, in this order, because the second depends on the first:
rem
rem   1. npm build in reactExample\main-window, producing dist\index.html;
rem   2. pbcompiler on pbjsExample.pb, which embeds that file with IncludeBinary.
rem
rem dist\ is gitignored, so on a fresh clone step 2 fails with
rem "Included file not found" until step 1 has run.
rem
rem Requires a LICENSED PureBasic (the free version caps source files at 800
rem lines each and modules\JSWindow.pb is ~3,500). PUREBASIC_HOME is honoured if
rem set; otherwise the usual install locations are probed, mirroring
rem ci/purebasic-home.sh.
rem
rem Usage:  build.cmd  [--run]
rem ============================================================================
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "ROOT=%CD%"
set "OUT=%ROOT%\pbjsExample.exe"
set "RUN=0"
if /i "%~1"=="--run" set "RUN=1"

echo == 1/2  web app ==
cd /d "%ROOT%\reactExample\main-window"
if exist package-lock.json (call npm ci) else (call npm install)
if errorlevel 1 exit /b 1
call npm run build
if errorlevel 1 exit /b 1
if not exist "dist\index.html" (
  echo The build did not produce dist\index.html - nothing for IncludeBinary to embed. 1>&2
  exit /b 1
)
echo    OK  reactExample\main-window\dist\index.html
echo.

echo == 2/2  executable ==
cd /d "%ROOT%"

rem PUREBASIC_HOME is not optional: pbcompiler refuses to start without it, and
rem that is not in the online CLI reference.
if not defined PUREBASIC_HOME (
  for %%D in (
    "%LOCALAPPDATA%\Programs\PureBasic"
    "%ProgramFiles%\PureBasic"
    "%ProgramFiles(x86)%\PureBasic"
  ) do (
    if exist "%%~D\compilers\pbcompiler.exe" set "PUREBASIC_HOME=%%~D"
  )
)
if not defined PUREBASIC_HOME (
  echo Could not find PureBasic. Set PUREBASIC_HOME to the install directory 1>&2
  echo the one holding compilers\, purelibraries\ and residents\. 1>&2
  exit /b 1
)
if not exist "%PUREBASIC_HOME%\compilers\pbcompiler.exe" (
  echo PUREBASIC_HOME is set to "%PUREBASIC_HOME%" but 1>&2
  echo %PUREBASIC_HOME%\compilers\pbcompiler.exe does not exist. 1>&2
  exit /b 1
)

"%PUREBASIC_HOME%\compilers\pbcompiler.exe" pbjsExample.pb --output "%OUT%" --quiet
if errorlevel 1 exit /b 1
echo    OK  %OUT%

if "%RUN%"=="1" (
  echo.
  echo == running ==
  "%OUT%"
)
endlocal
