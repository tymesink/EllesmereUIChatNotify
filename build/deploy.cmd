@echo off
rem Mirrors the addon source folder into the game's AddOns folder.
rem
rem   deploy.cmd "<source folder>" "<target addon folder>"
rem
rem Uses robocopy /MIR so files deleted from source are removed from the target
rem too. That makes the target argument destructive, hence the guards below.

setlocal

set "sourcedir=%~1"
set "targetdir=%~2"

if "%sourcedir%"=="" goto :usage
if "%targetdir%"=="" goto :usage

if not exist "%sourcedir%\" (
    echo ERROR: source folder does not exist:
    echo   %sourcedir%
    exit /b 1
)

rem A mistyped target would mirror over whatever it points at, so refuse the
rem obviously wrong ones: a drive root, or the AddOns folder itself rather than
rem this addon's folder inside it.
if "%targetdir:~1%"==":\" goto :badtarget
if /i "%targetdir:~-7%"=="\AddOns" goto :badtarget

echo source: %sourcedir%
echo target: %targetdir%
echo.

robocopy "%sourcedir%" "%targetdir%" /MIR /NJH /NJS /NP /NDL

rem Robocopy uses exit codes 0-7 for "succeeded, here is what changed" and 8+
rem for real failures, so anything below 8 is a successful deploy.
if errorlevel 8 (
    echo.
    echo Deploy FAILED.
    exit /b 1
)

echo.
echo Deploy complete.
exit /b 0

:badtarget
echo ERROR: refusing to mirror onto this target:
echo   %targetdir%
echo Point it at the addon's own folder, e.g. ...\Interface\AddOns\EllesmereUIChatNotify
exit /b 1

:usage
echo Usage: deploy.cmd "^<source folder^>" "^<target addon folder^>"
exit /b 1
