@echo off
setlocal
if exist "%~dp0test-output\polished-app\bin\kest.exe" (
    start "" "%~dp0test-output\polished-app\bin\kest.exe" --demo
    exit /b 0
)
if exist "%~dp0zig-out\bin\kest.exe" (
    start "" "%~dp0zig-out\bin\kest.exe" --demo
    exit /b 0
)
echo Build Kest first: zig build -Doptimize=ReleaseFast
pause
exit /b 1
