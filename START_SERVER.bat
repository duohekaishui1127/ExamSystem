@echo off
title LAN Exam System
cd /d "%~dp0"
echo.
echo Starting LAN Exam System...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
echo.
echo ============================================================
echo Server stopped or failed to start.
echo Please keep this window open and send the error text/screenshot.
echo ============================================================
echo.
pause
