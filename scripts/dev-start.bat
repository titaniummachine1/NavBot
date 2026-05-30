@echo off
echo 🔥 Starting NavBot Development Mode...

:: Start auto-bundle watcher
echo 📦 Starting auto-bundle watcher...
start "Auto-Bundle" cmd /k "npm run watch"

:: Start hot reload system
echo 🔥 Starting hot reload system...
start "Hot-Reload" cmd /k "npm run hot-reload"

:: Start LMAOBox if available
echo 🎮 Checking for LMAOBox...
if exist "C:\Program Files (x86)\LMAOBox\LMAOBox.exe" (
    echo 🚀 Launching LMAOBox...
    start "" "C:\Program Files (x86)\LMAOBox\LMAOBox.exe"
) else (
    echo ⚠️  LMAOBox not found at default location
)

echo ✅ Development mode started!
echo.
echo 💡 Make changes to NavBot/**/*.lua files and they will:
echo    • Auto-bundle to NavBot.lua
echo    • Auto-deploy to LMAOBox
echo    • Hot reload in real-time
echo.
echo 🎯 Press Ctrl+C in each window to stop
pause
