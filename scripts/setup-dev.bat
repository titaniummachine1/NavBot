@echo off
echo 🔄 Setting up NavBot Development Environment...

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
echo    npm run watch      - Watch NavBot\ and bundle + deploy on save
echo    npm run build      - Bundle and deploy once
echo.
echo 💡 Commit with version bumping:
echo    git commit -m "feat: add new feature"     - Auto bump minor version
echo    git commit -m "fix: resolve bug"          - Auto bump patch version
echo    git commit -m "major: breaking change"    - Auto bump major version
echo.
pause
