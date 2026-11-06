@echo off
rem Runs the dsh-superagent profile, detached from whatever started it.
rem Start it through scripts\win\dsh-superagent.ps1 (action: start), which is
rem what detaches the process and reads the panel URL back out of the log.
rem
rem The log is truncated on every start: the panel URL carries the auth token of
rem the current run, and that token changes on each start.
rem
rem Everything below can be overridden from the environment instead of edited.

setlocal

rem A process started outside DSH Desktop does not inherit DSH_HOME, and the
rem plugin cannot be found without it. The desktop build keeps its home here;
rem change the default if yours differs.
if not defined DSH_HOME set "DSH_HOME=%APPDATA%\dsh-desktop\harness"

rem Run the service as a second GitHub account by giving it its own gh config
rem directory (log that account in there with GH_CONFIG_DIR set). The setup
rem check, every worker and the git credential helper then all act as that
rem account. Do NOT wrap gh in a .cmd shim instead: Node cannot spawn a .cmd
rem without shell: true and the setup probe fails.
rem
rem It has to be a *different* account from whoever writes the instructions:
rem triggers whose actor is the agent account are dropped on purpose
rem (src/sources/github-trigger.ts:63 and src/core/model.ts:76).
rem if not defined GH_CONFIG_DIR set "GH_CONFIG_DIR=C:\dsh-superagent-state\gh-config"

if not defined DSH_PROFILE set "DSH_PROFILE=superagent"

rem The service log. Keep the default in step with DSH_LOG and with
rem scripts\win\dsh-superagent.ps1, which reads the panel URL back out of it.
if not defined DSH_LOG set "DSH_LOG=%LOCALAPPDATA%\dsh-superagent\service.log"
for %%d in ("%DSH_LOG%") do if not exist "%%~dpd" mkdir "%%~dpd"

rem dsh-superagent's setup check runs each probe as `env PATH=... <cli> ...`,
rem a POSIX shape: Windows itself has no env.exe. Git for Windows ships one, and
rem also the sh.exe the worker shims and the git credential helpers call.
set "GIT_USR_BIN=%ProgramFiles%\Git\usr\bin"
if exist "%GIT_USR_BIN%\env.exe" set "PATH=%GIT_USR_BIN%;%PATH%"

if not defined DSH set "DSH=dsh.cmd"
where "%DSH%" >nul 2>nul
if errorlevel 1 (
  echo.
  echo dsh was not found: %DSH%
  echo Install it with:  npm i -g @deepseek-ai/dsh@0.2.1-rc.3
  echo or set DSH to the full path of dsh.cmd before starting.
  echo.
  exit /b 1
)

echo ==== dsh-superagent start %DATE% %TIME% ==== > "%DSH_LOG%"
echo profile: %DSH_PROFILE%  log: %DSH_LOG% >> "%DSH_LOG%"
call "%DSH%" --profile %DSH_PROFILE% --no-open >> "%DSH_LOG%" 2>&1
