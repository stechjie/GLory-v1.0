@echo off
setlocal
cd /d "%~dp0.."
if errorlevel 1 (
  echo Cannot open the project folder.
  pause
  exit /b 1
)
where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found on PATH. Install Python with openpyxl, then try again.
  pause
  exit /b 1
)
python "%~dp0run_with_final.py" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo Final status sync or Godot failed with code %RESULT%.
echo.
echo Press any key to close this window after reviewing the result.
pause >nul
exit /b %RESULT%
