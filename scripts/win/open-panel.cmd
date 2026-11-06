@echo off
rem Opens the dsh-superagent panel in the default browser.
rem
rem The panel URL carries the auth token of the CURRENT run and that token
rem changes on every restart, so never bookmark the URL: use this instead.
setlocal
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-superagent.ps1""
set "URL="
for /f "usebackq delims=" %%u in (`%PS% url`) do set "URL=%%u"
if not defined URL (
  echo The service does not look like it is running.
  echo Start it with: "%~dp0dsh-superagent.ps1" start
  pause
  exit /b 1
)
start "" "%URL%"
