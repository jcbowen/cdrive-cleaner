@echo off
title C Drive Cleaner
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "CleanCDrive.ps1"
pause
