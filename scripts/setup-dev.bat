@echo off
echo 🔄 Setting up NavBot Development Environment...

:: Install dependencies
echo 📦 Installing Node.js dependencies...
call npm install

:: Create VERSION file if it doesn't exist
if not exist VERSION (
    echo 1.0.0 > VERSION
    echo 📝 Created VERSION file
)

:: Initial bundle
echo 📦 Running initial bundle...
call npm run bundle

echo ✅ Development environment setup complete!
echo.
echo 🎯 Quick start commands:
echo    npm run dev        - Start development mode with hot reload
echo    npm run build      - Build and deploy
echo    npm run watch      - Watch for changes and auto-bundle
echo    npm run hot-reload - Start hot reload only
echo.
echo 💡 Commit with version bumping:
echo    git commit -m "feat: add new feature"     - Auto bump minor version
echo    git commit -m "fix: resolve bug"          - Auto bump patch version
echo    git commit -m "major: breaking change"    - Auto bump major version
echo.
pause
