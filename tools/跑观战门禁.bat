@echo off
cd /d "%~dp0.."
echo Running spectator gates (3 checks) via tools\run_gates.ps1 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_gates.ps1 -Names spectator_check,spectator_lobby_check,spectator_match_check
echo.
echo Done. Summary: reports\checks\summary.json
pause
