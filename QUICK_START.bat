@echo off
echo 🚀 NavBot Quick Start - GitHub Actions Automation
echo.

:: Check if Node.js is available
node --version >nul 2>&1
if errorlevel 1 (
    echo ❌ Node.js not found. Please install Node.js first.
    pause
    exit /b 1
)

:: Create VERSION file if missing
if not exist VERSION (
    echo 1.0.0 > VERSION
    echo 📝 Created VERSION file
)

:: Initial setup
echo 🔄 Setting up automation...
call scripts\setup-dev.bat

echo.
echo ✅ SETUP COMPLETE!
echo.
echo 🎯 DEVELOPMENT COMMANDS:
echo    npm run dev         - Start file watcher (auto-bundle + deploy)
echo    npm run watch       - Watch files and auto-bundle + deploy
echo    npm run build       - Build and deploy once
echo.
echo 💡 VERSION MANAGEMENT:
echo    git commit -m "feat: new feature"     - Auto bump minor version
echo    git commit -m "fix: bug fix"          - Auto bump patch version  
echo    git commit -m "major: breaking"       - Auto bump major version
echo    npm run version:bump patch           - Manual patch bump
echo.
echo � AUTO BUNDLE + DEPLOY:
echo    Changes to NavBot/**/*.lua files will:
echo    • Auto-bundle to NavBot.lua
echo    • Auto-deploy to LMAOBox
echo    • Ready to load in LMAOBox
echo.
echo 🎮 STARTING DEVELOPMENT MODE...
call npm run dev

pause
