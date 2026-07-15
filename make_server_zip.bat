@echo off
echo Building Glory server package, please wait...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_server_zip.ps1"
