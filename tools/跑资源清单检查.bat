@echo off
cd /d "%~dp0.."
echo Running asset_manifest_check via tools\run_check.ps1 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_check.ps1 -Name asset_manifest_check
echo.
echo ---------------------------------------------------------
echo Done. Full log: reports\checks\asset_manifest_check.stdout.log
echo Send that file (or the lines after "===== FAIL") back to Claude.
echo ---------------------------------------------------------
pause
