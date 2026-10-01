@echo off
rem ===========================================================================
rem  run_all_tests.bat - runs all gpu-psu-stress tests in sequence
rem
rem  Usage:  run_all_tests.bat           full session (about 55 minutes)
rem          run_all_tests.bat rapido    trial of the session with minimal durations (~3 min)
rem
rem  The executable is looked for next to this file, then in ..\build\Release.
rem  All output goes to gpu-psu-out\sessione_YYYYMMDD_HHMMSS\ next to this file:
rem    NN_<test>.csv   NVML samples of the test
rem    NN_<test>.log   complete program output (calibration, phases, summary)
rem    sessione.log    GPU, driver, commands run, times and outcome of each test
rem
rem  Ctrl+C stops the running test (the CSV is still saved); when asked
rem  "Terminare il processo batch (S/N)?" answer N to move on to the next test,
rem  S to stop the whole session.
rem ===========================================================================
setlocal
chcp 65001 >nul

rem --- Durations (--scale multipliers) and pause between tests ---------------
set "SCALA_BREVE=0.05"
set "SCALA_1=1"
set "SCALA_2=2"
set "PAUSA_S=30"
set "RAPIDO="
if /i "%~1"=="rapido" (
    set "RAPIDO=1"
    set "SCALA_BREVE=0.02"
    set "SCALA_1=0.02"
    set "SCALA_2=0.02"
    set "PAUSA_S=2"
)

rem --- Executable ------------------------------------------------------------
set "EXE=%~dp0gpu-psu-stress.exe"
if not exist "%EXE%" set "EXE=%~dp0..\build\Release\gpu-psu-stress.exe"
if not exist "%EXE%" (
    echo ERRORE: gpu-psu-stress.exe non trovato.
    echo Copialo nella stessa cartella di questo file: %~dp0
    if not defined RAPIDO pause
    exit /b 1
)
for %%F in ("%EXE%") do set "EXE=%%~fF"

rem --- Session folder --------------------------------------------------------
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%T"
set "OUT=%~dp0gpu-psu-out\sessione_%TS%"
if defined RAPIDO set "OUT=%~dp0gpu-psu-out\rapido_%TS%"
mkdir "%OUT%" 2>nul
set "SLOG=%OUT%\sessione.log"

rem PowerShell command that runs the program, showing the output on screen and
rem saving it to the .log (UTF-8). It receives executable, arguments and log path
rem through environment variables, so there are no quoting problems.
set "PS_TEE=$ErrorActionPreference='Continue'; $e=New-Object Text.UTF8Encoding($false); [Console]::OutputEncoding=$e; $w=New-Object IO.StreamWriter($env:GPS_LOG,$false,$e); $w.AutoFlush=$true; $w.WriteLine('Comando: gpu-psu-stress '+$env:GPS_ARGS); $w.WriteLine('Avvio: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')); $w.WriteLine(''); $rc=-1; try { & $env:GPS_EXE ($env:GPS_ARGS -split ' ') 2>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $l=[string]$_.TargetObject } else { $l=[string]$_ }; [Console]::WriteLine($l); $w.WriteLine($l) }; $rc=$LASTEXITCODE } finally { $w.WriteLine(''); $w.WriteLine('Fine: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' - codice di uscita '+$rc); $w.Close() }; exit $rc"

> "%SLOG%" echo Sessione gpu-psu-stress del %date% %time%
if defined RAPIDO >> "%SLOG%" echo MODALITA' RAPIDA: durate ridotte, solo per provare lo script.
>> "%SLOG%" echo Eseguibile: %EXE%
>> "%SLOG%" echo.
nvidia-smi --query-gpu=name,driver_version,power.limit,power.default_limit,temperature.gpu --format=csv >> "%SLOG%" 2>&1
>> "%SLOG%" echo.

echo ============================================================================
echo  gpu-psu-stress - sessione completa di test
echo  Output in: %OUT%
if defined RAPIDO echo  MODALITA' RAPIDA: durate ridotte, solo per provare lo script.
echo.
echo  Parte A - solo GPU:       prova breve, completo x1, completo x2   (~13 min)
echo  Parte B - GPU + CPU:      2 completi x2, 3 onde quadre, 3 burst   (~40 min)
echo.
echo  Tieni d'occhio le temperature. Ctrl+C interrompe il test in corso.
echo ============================================================================
echo.

set /a NFAIL=0

rem --- Part A: GPU only ----------------------------------------------------------
>> "%SLOG%" echo === Parte A - solo GPU ===
call :run_test 01_prova_breve_gpu_sola "--scale %SCALA_BREVE%"
call :run_test 02_completo_gpu_sola_scala1 "--scale %SCALA_1%"
call :run_test 03_completo_gpu_sola_scala2 "--scale %SCALA_2%"

rem --- Part B: GPU + CPU --------------------------------------------------------
rem The CPU load is built into the program (--cpu): it starts after calibration, warms up
rem for 30 s x scale and stays at the maximum for the whole test. No external software.
echo.
echo ============================================================================
echo  Parte B - GPU + CPU: il programma carica anche tutti i core della CPU (--cpu)
echo ============================================================================
>> "%SLOG%" echo === Parte B - GPU + CPU sotto stress (--cpu) ===
call :run_test 04_completo_gpu_cpu_scala2_run1 "--cpu --scale %SCALA_2%"
call :run_test 05_completo_gpu_cpu_scala2_run2 "--cpu --scale %SCALA_2%"
call :run_test 06_onde_quadre_gpu_cpu_scala2_run1 "--cpu --only square --scale %SCALA_2%"
call :run_test 07_onde_quadre_gpu_cpu_scala2_run2 "--cpu --only square --scale %SCALA_2%"
call :run_test 08_onde_quadre_gpu_cpu_scala2_run3 "--cpu --only square --scale %SCALA_2%"
call :run_test 09_burst_gpu_cpu_scala2_run1 "--cpu --only burst --scale %SCALA_2%"
call :run_test 10_burst_gpu_cpu_scala2_run2 "--cpu --only burst --scale %SCALA_2%"
call :run_test 11_burst_gpu_cpu_scala2_run3 "--cpu --only burst --scale %SCALA_2%"

:fine
>> "%SLOG%" echo.
>> "%SLOG%" echo Fine sessione: %date% %time% - test non completati: %NFAIL%
echo.
echo ============================================================================
echo  Sessione finita. Test non completati: %NFAIL%
echo  Risultati in: %OUT%
echo.
echo  Controlla anche il Visualizzatore eventi di Windows (Kernel-Power 41 =
echo  spegnimento improvviso, Display 4101 = driver video ripristinato).
echo ============================================================================
if not defined RAPIDO pause
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
>> "%SLOG%" echo [%date% %time:~0,8%] AVVIO %NAME%: gpu-psu-stress %GPS_ARGS%
pushd "%OUT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "%PS_TEE%"
set "RC=%ERRORLEVEL%"
popd
if "%RC%"=="0" (
    >> "%SLOG%" echo [%date% %time:~0,8%] OK      %NAME%
) else (
    >> "%SLOG%" echo [%date% %time:~0,8%] NON COMPLETATO %NAME% - codice di uscita %RC%
    set /a NFAIL+=1
    echo  ATTENZIONE: %NAME% non completato, codice di uscita %RC%
)
rem Pause between tests: the GPU cools down and the tests stay comparable.
echo  Pausa di %PAUSA_S% s prima del prossimo test...
powershell -NoProfile -Command "Start-Sleep -Seconds %PAUSA_S%"
exit /b 0
