@echo off
set PORT=20127
set DIR=%~dp0

:: Check if port is already in use
netstat -ano | findstr ":%PORT% " | findstr LISTEN >nul 2>&1
if %errorlevel% equ 0 (
    echo 9Router is already running on http://localhost:%PORT%
    start http://localhost:%PORT%
    exit /b 0
)

echo Starting 9Router dev server...
start "" /B bun run dev
if %errorlevel% neq 0 (
    start "" /B "%DIR%node_modules\.bin\next.exe" dev --port %PORT%
)

:: Wait for server to be ready
echo Waiting for server...
:wait
timeout /t 2 /nobreak >nul
netstat -ano | findstr ":%PORT% " | findstr LISTEN >nul 2>&1
if %errorlevel% neq 0 goto wait

start http://localhost:%PORT%
echo 9Router started at http://localhost:%PORT%
