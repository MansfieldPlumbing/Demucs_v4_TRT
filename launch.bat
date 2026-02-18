@echo off
:: Demucs v4 TRT - First-run launcher
:: MOTW immune — elevates once, unblocks everything, then opens setup.ps1 menu.
:: Double-click this after cloning. You won't need it again.

echo.
echo  Demucs v4 TRT
echo  Requesting elevation to unblock downloaded scripts...
echo.

powershell -ExecutionPolicy Bypass -Command ^
  "Start-Process pwsh -ArgumentList '-ExecutionPolicy Bypass -File ""%~dp0setup.ps1""' -Verb RunAs -Wait"

echo.
echo  Done. You can close this window.
pause