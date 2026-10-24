@echo off
setlocal
pushd "%~dp0.."
if errorlevel 1 (
    echo Cannot open the project folder.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1" -Interactive
set "buildExitCode=%ERRORLEVEL%"
echo.
pause
popd
exit /b %buildExitCode%
