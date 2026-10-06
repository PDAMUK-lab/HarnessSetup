@echo off
rem Test stub for scp (Windows), the same contract as the bash stub next to it (keep in sync):
rem `scp login:remote DEST` copies %FAKE_SCP_SRC% to DEST; without it the copy fails like a real scp.
rem The Windows CI job prepends tests\fakebin to PATH so this file shadows C:\Windows\System32\OpenSSH\scp.exe,
rem the way tests/test-powershell.sh lines the Linux run up on the bash stub.
setlocal
if not "%FAKE_LOG%"=="" echo scp %*>>"%FAKE_LOG%"
if "%FAKE_SCP_SRC%"=="" exit /b 1
set "dest="
:args
if "%~1"=="" goto copy
set "dest=%~1"
shift
goto args
:copy
if "%dest%"=="" exit /b 1
copy /y "%FAKE_SCP_SRC%" "%dest%" >nul
exit /b %ERRORLEVEL%
