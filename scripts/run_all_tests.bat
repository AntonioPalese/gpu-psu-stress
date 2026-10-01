@echo off
rem ===========================================================================
rem  run_all_tests.bat - runs all gpu-psu-stress tests in sequence
rem
rem  Usage:  run_all_tests.bat           full session (about 55 minutes)
rem          run_all_tests.bat quick     trial of the session with minimal durations (~3 min)
rem                                      ("rapido" is accepted as well)
rem
rem  The executable is looked for next to this file, then in ..\build\Release.
rem  All output goes to gpu-psu-out\session_YYYYMMDD_HHMMSS\ next to this file:
rem    NN_<test>.csv   NVML samples of the test
rem    NN_<test>.log   complete program output (calibration, phases, summary)
rem    session.log     GPU, driver, commands run, times and outcome of each test
rem
rem  Ctrl+C stops the running test (the CSV is still saved); when Windows asks
rem  "Terminate batch job (Y/N)?" (localized, e.g. "Terminare il processo batch (S/N)?")
rem  answer N to move on to the next test, Y to stop the whole session.
rem ===========================================================================
setlocal
chcp 65001 >nul

rem --- Durations (--scale multipliers) and pause between tests ---------------
set "SCALE_SHORT=0.05"
set "SCALE_1=1"
set "SCALE_2=2"
set "PAUSE_S=30"
set "QUICK="
if /i "%~1"=="quick" set "QUICK=1"
if /i "%~1"=="rapido" set "QUICK=1"
if defined QUICK (
    set "SCALE_SHORT=0.02"
    set "SCALE_1=0.02"
    set "SCALE_2=0.02"
    set "PAUSE_S=2"
)

rem --- Executable ------------------------------------------------------------
set "EXE=%~dp0gpu-psu-stress.exe"
if not exist "%EXE%" set "EXE=%~dp0..\build\Release\gpu-psu-stress.exe"
if not exist "%EXE%" (
    echo ERROR: gpu-psu-stress.exe not found.
    echo Copy it into the same folder as this file: %~dp0
    if not defined QUICK pause
    exit /b 1
)
for %%F in ("%EXE%") do set "EXE=%%~fF"

rem --- Session folder --------------------------------------------------------
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%T"
set "OUT=%~dp0gpu-psu-out\session_%TS%"
if defined QUICK set "OUT=%~dp0gpu-psu-out\quick_%TS%"
mkdir "%OUT%" 2>nul
set "SLOG=%OUT%\session.log"

rem PowerShell command that runs the program, showing the output on screen and
rem saving it to the .log (UTF-8). It receives executable, arguments and log path
rem through environment variables, so there are no quoting problems.
set "PS_TEE=$ErrorActionPreference='Continue'; $e=New-Object Text.UTF8Encoding($false); [Console]::OutputEncoding=$e; $w=New-Object IO.StreamWriter($env:GPS_LOG,$false,$e); $w.AutoFlush=$true; $w.WriteLine('Command: gpu-psu-stress '+$env:GPS_ARGS); $w.WriteLine('Start: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')); $w.WriteLine(''); $rc=-1; try { & $env:GPS_EXE ($env:GPS_ARGS -split ' ') 2>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $l=[string]$_.TargetObject } else { $l=[string]$_ }; [Console]::WriteLine($l); $w.WriteLine($l) }; $rc=$LASTEXITCODE } finally { $w.WriteLine(''); $w.WriteLine('End: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' - exit code '+$rc); $w.Close() }; exit $rc"

> "%SLOG%" echo gpu-psu-stress session of %date% %time%
if defined QUICK >> "%SLOG%" echo QUICK MODE: reduced durations, only to try the script.
>> "%SLOG%" echo Executable: %EXE%
>> "%SLOG%" echo.
nvidia-smi --query-gpu=name,driver_version,power.limit,power.default_limit,temperature.gpu --format=csv >> "%SLOG%" 2>&1
>> "%SLOG%" echo.

echo ============================================================================
echo  gpu-psu-stress - full test session
echo  Output in: %OUT%
if defined QUICK echo  QUICK MODE: reduced durations, only to try the script.
echo.
echo  Part A - GPU only:        short trial, full x1, full x2          (~13 min)
echo  Part B - GPU + CPU:       2 full x2, 3 square waves, 3 bursts    (~40 min)
echo.
echo  Keep an eye on the temperatures. Ctrl+C stops the running test.
echo ============================================================================
echo.

set /a NFAIL=0

rem --- Part A: GPU only ----------------------------------------------------------
>> "%SLOG%" echo === Part A - GPU only ===
call :run_test 01_short_trial_gpu_only "--scale %SCALE_SHORT%"
call :run_test 02_full_gpu_only_scale1 "--scale %SCALE_1%"
call :run_test 03_full_gpu_only_scale2 "--scale %SCALE_2%"

rem --- Part B: GPU + CPU --------------------------------------------------------
rem The CPU load is built into the program (--cpu): it starts after calibration, warms up
rem for 30 s x scale and stays at the maximum for the whole test. No external software.
echo.
echo ============================================================================
echo  Part B - GPU + CPU: the program also loads every CPU core (--cpu)
echo ============================================================================
>> "%SLOG%" echo === Part B - GPU + CPU under stress (--cpu) ===
call :run_test 04_full_gpu_cpu_scale2_run1 "--cpu --scale %SCALE_2%"
call :run_test 05_full_gpu_cpu_scale2_run2 "--cpu --scale %SCALE_2%"
call :run_test 06_square_waves_gpu_cpu_scale2_run1 "--cpu --only square --scale %SCALE_2%"
call :run_test 07_square_waves_gpu_cpu_scale2_run2 "--cpu --only square --scale %SCALE_2%"
call :run_test 08_square_waves_gpu_cpu_scale2_run3 "--cpu --only square --scale %SCALE_2%"
call :run_test 09_bursts_gpu_cpu_scale2_run1 "--cpu --only burst --scale %SCALE_2%"
call :run_test 10_bursts_gpu_cpu_scale2_run2 "--cpu --only burst --scale %SCALE_2%"
call :run_test 11_bursts_gpu_cpu_scale2_run3 "--cpu --only burst --scale %SCALE_2%"

:end
>> "%SLOG%" echo.
>> "%SLOG%" echo End of session: %date% %time% - tests not completed: %NFAIL%
echo.
echo ============================================================================
echo  Session finished. Tests not completed: %NFAIL%
echo  Results in: %OUT%
echo.
echo  Also check the Windows Event Viewer (Kernel-Power 41 =
echo  sudden shutdown, Display 4101 = display driver recovered).
echo ============================================================================
if not defined QUICK pause
endlocal & exit /b %NFAIL%


rem ---------------------------------------------------------------------------
rem  :run_test <name> "<arguments>"
rem  Runs a test in the session folder: <name>.csv and <name>.log.
rem ---------------------------------------------------------------------------
:run_test
set "NAME=%~1"
set "GPS_EXE=%EXE%"
set "GPS_ARGS=%~2 --out %NAME%.csv"
set "GPS_LOG=%OUT%\%NAME%.log"
echo.
echo ----------------------------------------------------------------------------
echo  [%time:~0,8%] %NAME%
echo  gpu-psu-stress %GPS_ARGS%
echo ----------------------------------------------------------------------------
>> "%SLOG%" echo [%date% %time:~0,8%] START %NAME%: gpu-psu-stress %GPS_ARGS%
pushd "%OUT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "%PS_TEE%"
set "RC=%ERRORLEVEL%"
popd
if "%RC%"=="0" (
    >> "%SLOG%" echo [%date% %time:~0,8%] OK      %NAME%
) else (
    >> "%SLOG%" echo [%date% %time:~0,8%] NOT COMPLETED %NAME% - exit code %RC%
    set /a NFAIL+=1
    echo  WARNING: %NAME% not completed, exit code %RC%
)
rem Pause between tests: the GPU cools down and the tests stay comparable.
echo  Pausing %PAUSE_S% s before the next test...
powershell -NoProfile -Command "Start-Sleep -Seconds %PAUSE_S%"
exit /b 0
