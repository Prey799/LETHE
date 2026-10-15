@echo off
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build\Build.ps1" %*
if errorlevel 1 (echo Build failed. & pause & exit /b 1)
pause
