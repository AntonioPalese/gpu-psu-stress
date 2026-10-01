# Piano: compilare per la RTX 5070 (sm_120) su un PC senza la scheda

## Contesto

Per compilare non serve avere la RTX 5070 nel PC: `nvcc` genera codice per qualsiasi
architettura, indipendentemente dalla GPU installata. La GPU serve solo per *eseguire*.

Sul PC di sviluppo (GeForce MX550, compute capability 7.5, driver 573.76) la build per sm_120
oggi si ferma solo perché il toolkit installato è CUDA 11.6: sm_120 richiede CUDA ≥ 12.8.
Il controllo è in `CMakeLists.txt`, prima di `project()`.

Il punto chiave: con `-DCMAKE_CUDA_ARCHITECTURES="75;120"` si ottiene **un solo eseguibile**
che gira sia sulla MX550 (sm_75, provabile sul PC di sviluppo) sia sulla RTX 5070 (sm_120).
Il codice non va modificato: il controllo in `CMakeLists.txt` gestisce già una lista di
architetture e applica il requisito più alto (12.8).

## Passi

1. **Installare CUDA 12.8 o 12.9** (non la 13.x) per Windows da developer.nvidia.com.
   - Perché non la 13: CUDA 13 richiede un driver ≥ 580. Con il driver attuale (573.76) un
     eseguibile compilato con CUDA 13 non partirebbe sulla MX550. Sulla 5070 funzionerebbe,
     se il suo driver è abbastanza recente.
   - Scegliere l'installazione **personalizzata**: togliere la spunta al componente "Driver"
     (si tiene quello attuale) e lasciare "Visual Studio Integration". La 12.x si installa
     accanto alla 11.6, senza rimuoverla.
2. **Riaprire il terminale**, così `CUDA_PATH` e `PATH` puntano alla 12.x. Cancellare la
   cartella `build`, poi:
   ```powershell
   cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"
   cmake --build build --config Release
   ```
   Se CMake usasse ancora la 11.6, indicare il toolkit esplicitamente:
   `-T "cuda=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"`.
3. **Copiare `build\Release\gpu-psu-stress.exe` sul PC con la 5070.** Lì non serve
   installare CUDA: il runtime CUDA è incluso nell'eseguibile e `nvml.dll` viene installata
   con il driver NVIDIA.

## Cosa non si può verificare sul PC di sviluppo

- La parte sm_120 si compila, ma si può eseguire solo sulla 5070.
- Con gli header di CUDA 12.x si compila per la prima volta la lettura di
  `NVML_FI_DEV_POWER_INSTANT` (`src/monitor.cpp`). Sulla MX550 probabilmente risulterà
  "non disponibile"; il comportamento reale va controllato sulla 5070.

## Documentazione

- Fatto: il `README.md` contiene la sezione "Compilare su un PC senza la GPU di
  destinazione" con questi punti (build `"75;120"`, CUDA 12.8/12.9 e requisito del driver).

## Verifica (dopo l'installazione di CUDA 12.x)

Eseguita il 2026-10-01 con CUDA 12.8.61, driver 573.76, sulla MX550.

- [x] `cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"` e la build terminano senza errori
      né warning (CMake trova da solo CUDA 12.8).
- [x] `cuobjdump --list-elf build\Release\gpu-psu-stress.exe` mostra sia `sm_75` sia `sm_120`.
      Il kernel tensor per sm_120 usa istruzioni `HMMA.16816.F32` (tensor core).
- [x] `bash tests/smoke_test.sh` passa sulla MX550 in 17 s.
- [x] `compute-sanitizer --tool memcheck build\Release\gpu-psu-stress.exe --scale 0.02`
      riporta 0 errori.
- [x] Riga "Potenza istantanea NVML" sulla MX550: "disponibile", ma il valore coincide con la
      media (stesso massimo, 31,94 W). Probabilmente il driver per portatili restituisce lo
      stesso sensore.
- [ ] Sulla 5070: controllare la riga "Potenza istantanea NVML" e che nella tabella
      "Max ist. W" sia diversa da "Max W" (segno che la lettura istantanea funziona davvero).
- [ ] Sulla 5070: eseguire il test completo (il codice sm_120 non è mai stato eseguito).
