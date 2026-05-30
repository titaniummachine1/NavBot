@echo off

set /p LUATITLE=<title.txt

node bundle.js
node scripts\deploy.cjs
exit