@echo off
cd /d "%~dp0.."
echo Running pet gates (2 checks) via tools\run_gates.ps1 ...
echo Note: open the project in the Godot editor once first, so new pet models and art get imported.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_gates.ps1 -Names pet_feature_check,final_status_check
echo.
echo Done. Summary: reports\checks\summary.json
pause
