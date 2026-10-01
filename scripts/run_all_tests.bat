@echo off
rem ===========================================================================
rem  run_all_tests.bat - esegue in serie tutti i test di gpu-psu-stress
rem
rem  Uso:  run_all_tests.bat           sessione completa (circa 55 minuti)
rem        run_all_tests.bat rapido    prova della sessione con durate minime (~3 min)
rem
rem  L'eseguibile viene cercato accanto a questo file, poi in ..\build\Release.
rem  Tutto l'output va in gpu-psu-out\sessione_AAAAMMGG_HHMMSS\ accanto a questo file:
rem    NN_<test>.csv   campioni NVML del test
rem    NN_<test>.log   output completo del programma (calibrazione, fasi, riepilogo)
rem    sessione.log    GPU, driver, comandi eseguiti, orari ed esito di ogni test
rem
rem  Ctrl+C interrompe il test in corso (il CSV viene salvato comunque); alla domanda
rem  "Terminare il processo batch (S/N)?" rispondi N per passare al test successivo,
rem  S per fermare tutta la sessione.
rem ===========================================================================
setlocal
chcp 65001 >nul

rem --- Durate (moltiplicatori --scale) e pausa tra un test e l'altro ---------
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

rem --- Eseguibile ------------------------------------------------------------
set "EXE=%~dp0gpu-psu-stress.exe"
if not exist "%EXE%" set "EXE=%~dp0..\build\Release\gpu-psu-stress.exe"
if not exist "%EXE%" (
    echo ERRORE: gpu-psu-stress.exe non trovato.
    echo Copialo nella stessa cartella di questo file: %~dp0
    if not defined RAPIDO pause
    exit /b 1
)
for %%F in ("%EXE%") do set "EXE=%%~fF"

rem --- Cartella della sessione -----------------------------------------------
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%T"
set "OUT=%~dp0gpu-psu-out\sessione_%TS%"
if defined RAPIDO set "OUT=%~dp0gpu-psu-out\rapido_%TS%"
mkdir "%OUT%" 2>nul
set "SLOG=%OUT%\sessione.log"

rem Comando PowerShell che esegue il programma mostrando l'output a schermo e
rem salvandolo nel .log (UTF-8). Riceve eseguibile, argomenti e log da variabili
rem d'ambiente, cosi' non ci sono problemi di virgolette.
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

rem --- Parte A: solo GPU ---------------------------------------------------------
>> "%SLOG%" echo === Parte A - solo GPU ===
call :run_test 01_prova_breve_gpu_sola "--scale %SCALA_BREVE%"
call :run_test 02_completo_gpu_sola_scala1 "--scale %SCALA_1%"
call :run_test 03_completo_gpu_sola_scala2 "--scale %SCALA_2%"

rem --- Parte B: GPU + CPU -------------------------------------------------------
rem Il carico CPU e' interno al programma (--cpu): parte dopo la calibrazione, si scalda
rem per 30 s x scala e resta al massimo per tutto il test. Nessun software esterno.
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
rem  :run_test <nome> "<argomenti>"
rem  Esegue un test nella cartella della sessione: <nome>.csv e <nome>.log.
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
rem Pausa tra un test e l'altro: la GPU si raffredda e i test restano confrontabili.
echo  Pausa di %PAUSA_S% s prima del prossimo test...
powershell -NoProfile -Command "Start-Sleep -Seconds %PAUSA_S%"
exit /b 0
