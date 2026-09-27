@echo off
echo Building Glory server package, please wait...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_server_zip.ps1"
rem 传播 PowerShell 的退出码。此前这里没有 exit /b，打包失败也返回 0 ——
rem 在自动化里"失败"和"成功"完全一样，而失败时留在磁盘上的还是上一个旧 ZIP。
exit /b %ERRORLEVEL%
