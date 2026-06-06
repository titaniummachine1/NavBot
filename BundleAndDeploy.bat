@echo off

set /p LUATITLE=<title.txt

node scripts\bundle-and-deploy.cjs
exit