@echo off
cd /d "%~dp0.."
echo.
echo ========================================
echo [RunOnSave] NavBot bundle + deploy
echo ========================================
node scripts\bundle-and-deploy.cjs
if errorlevel 1 (
  echo ========================================
  echo [RunOnSave] FAILED
  echo ========================================
  exit /b 1
)
echo ========================================
echo [RunOnSave] OK
echo ========================================
