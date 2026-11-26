@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_gates.ps1 -Names audio_0921_check,audio_0922_check,ui_feedback_check,voice_music_check,boss_battle_bgm_check,spectator_check
pause
