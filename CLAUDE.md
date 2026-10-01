# gpu-psu-stress — Istruzioni per Claude Code

## Obiettivo del progetto

Sviluppare da zero un tool da riga di comando in CUDA C++ che mette sotto stress una GPU NVIDIA
(target principale: **RTX 5070, Blackwell, compute capability 12.0 / sm_120, TGP 250 W**) per
verificare se un alimentatore da **650 W** regge i picchi transitori di assorbimento.

Il tool deve:

1. **Generare** pattern di carico che provocano transienti di potenza in modo ripetibile
   (carichi sostenuti, onde quadre a varie frequenze, burst da idle).
2. **Monitorare** potenza, clock e temperatura tramite NVML in un thread separato.
3. **Riassumere** i risultati a schermo per fase e **salvare** un log CSV completo.
4. **Visualizzare** il log con uno script Python separato.

Limite noto da documentare sempre: NVML campiona ogni ~10–100 ms e **non può misurare** i
transienti sotto il millisecondo. Il tool li provoca; il verdetto reale è se il sistema si
spegne o si riavvia (intervento OCP/OPP dell'alimentatore).

## Vincoli tecnici

- Linguaggio: CUDA C++17. Toolkit richiesto: **CUDA ≥ 12.8** (necessario per sm_120).
- Build: **CMake ≥ 3.24**, con `CMAKE_CUDA_ARCHITECTURES` di default `120` e sovrascrivibile
  (es. `89` per Ada, `86` per Ampere) così il tool si usa anche su altre GPU.
- Dipendenze: solo CUDA runtime e NVML (`CUDA::nvml` via `find_package(CUDAToolkit)`).
  Niente cuBLAS o librerie esterne: i kernel di carico sono scritti a mano.
- Piattaforme: Linux e Windows. Niente API specifiche di un solo sistema operativo
  nel codice principale; se servono (es. `timeBeginPeriod` su Windows), isolarle dietro `#ifdef _WIN32`.
- Script di analisi: Python 3.10+, dipendenze solo `pandas` e `matplotlib`.
- Commenti nel codice e output del programma **in italiano**; identificatori in inglese.

## Struttura del repository

```
gpu-psu-stress/
├── CLAUDE.md
├── README.md                 # guida utente (italiano)
├── CMakeLists.txt
├── src/
│   ├── main.cu               # parsing CLI, orchestrazione delle fasi, riepilogo
│   ├── kernels.cuh / .cu     # kernel di carico
│   ├── loads.hpp / .cu       # calibrazione e astrazione "Load"
│   ├── patterns.hpp / .cpp   # sustained, idle, square wave, burst
│   ├── monitor.hpp / .cpp    # thread NVML, campioni, gestione fasi
│   ├── report.hpp / .cpp     # tabella riassuntiva e scrittura CSV
│   ├── cpu_load.hpp / .cpp   # carico CPU in parallelo (--cpu)
│   └── check.hpp             # macro CK() per CUDA e NK() per NVML
├── scripts/
│   └── plot_log.py           # grafico potenza/clock/temperatura dal CSV
└── tests/
    └── smoke_test.sh         # esecuzione breve con --scale 0.05
```

## Specifiche dei componenti

### Kernel di carico (`kernels.cu`)

Tutti i kernel ricevono un parametro `iters` che ne controlla la durata e **scrivono sempre**
un risultato in memoria globale, così il compilatore non elimina il lavoro.

- **`fmaBurn`**: FP32 puro, 8 catene indipendenti per thread. Usare la mappa `x = fmaf(x, x, -1.9f)`,
  che è caotica ma limitata: i bit commutano molto (più consumo) senza divergere a inf/NaN.
- **`tensorBurn`**: tensor core tramite WMMA (`nvcuda::wmma`), frammenti 16×16×16,
  input `__half`, accumulo `float`, 4 accumulatori indipendenti per ILP.
  Matrici caricate da shared memory una sola volta, poi `mma_sync` in loop. 4 warp per blocco.
- **`memBurn`**: streaming read+write su `float4` con grid-stride loop su 2 buffer da 512 MB,
  alternando sorgente e destinazione a ogni lancio.

Dimensionamento griglia: derivare sempre dal numero di SM (`multiProcessorCount`), mai
valori fissi (circa 8 blocchi per SM per FMA e tensor, 4 per la memoria).

### Calibrazione e astrazione dei carichi (`loads.cu`)

- `ParamLaunch = std::function<void(cudaStream_t, int iters)>`
- `Launch = std::function<void(cudaStream_t)>`
- `calibrate(paramLaunch, stream, targetMs, name) -> Launch`: warm-up, poi 4 iterazioni di
  misura con `cudaEvent` che correggono `iters` proporzionalmente fino a `targetMs`.
  Stampare il risultato di ogni calibrazione.
- Carichi da calibrare: FMA 2 ms, FMA "short" 0.5 ms (per le onde quadre ad alta frequenza),
  Tensor 2 ms, Memoria 2 ms.
- Onde quadre e burst usano l'FMA, non il tensor: sulla RTX 5070 l'FMA arriva al power limit
  (~245 W) mentre il kernel tensor si ferma a ~100 W (misurato nei test del 2026-10-01).

### Pattern (`patterns.cpp`)

- `idle(name, sec)`: imposta la fase e dorme.
- `sustained(name, {(Launch, stream)...}, sec)`: lancia tutti i carichi, ciascuno sul proprio
  stream, poi sincronizza tutti gli stream; ripete fino alla scadenza. Più stream servono a
  sovrapporre tensor e memoria.
- `squareWave(hz, shortLoad, stream, sec)`: per ogni periodo, pieno carico per metà periodo
  (lanci ripetuti del carico FMA "short" con sync), poi **spin-wait** fino a fine periodo.
  Niente `sleep` qui: su Windows la granularità (~15 ms) rovinerebbe le frequenze alte.
- `burstFromIdle(cycles, idleSec, burstSec)`: idle lungo (la GPU scende ai clock minimi),
  poi FMA + memoria al massimo per un tempo breve.

### Monitor NVML (`monitor.cpp`)

- Ottenere l'handle NVML **tramite PCI bus ID** (`cudaDeviceGetPCIBusId` →
  `nvmlDeviceGetHandleByPciBusId_v2`), non per indice: con più GPU gli indici CUDA e NVML
  possono non coincidere.
- Per ogni campione registrare: timestamp, indice di fase, `nvmlDeviceGetPowerUsage` (media),
  potenza istantanea tramite `NVML_FI_DEV_POWER_INSTANT` (dentro `#ifdef`, perché il campo
  esiste solo in header recenti; convertire in base a `valueType`; se non disponibile, -1),
  clock SM, clock memoria, temperatura.
- Accesso ai campioni e ai nomi di fase protetto da mutex; fase corrente in `std::atomic<int>`.
- `setPhase(name)` riusa l'indice se il nome esiste già. Le fasi il cui nome inizia con `_`
  (cooldown, idle tra burst) non vengono stampate né mostrate nel riepilogo.

### Report (`report.cpp`)

- Tabella per fase: numero campioni, media W, max W, max istantanea W (o "n/d"),
  max clock SM, max temperatura.
- Picco globale e percentuale rispetto al power limit attivo (`nvmlDeviceGetEnforcedPowerLimit`).
- Stampare sempre l'avviso che NVML non vede i transienti sotto il millisecondo.
- CSV con intestazione:
  `t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C`

### CLI (`main.cu`)

```
gpu-psu-stress [--scale X] [--sample-ms N] [--device N] [--out file.csv]
               [--only sustained|square|burst] [--cpu | --cpu-threads N] [--list]
```

- `--scale`: moltiplicatore di tutte le durate (default 1.0; circa 3,5 minuti totali).
- `--sample-ms`: periodo di campionamento NVML (default 10, minimo 1).
- `--device`: GPU CUDA da usare (default 0).
- `--only`: esegue solo un gruppo di test.
- `--list`: stampa la sequenza delle fasi con le durate stimate ed esce.
- `--cpu` / `--cpu-threads N`: carico CPU interno (`cpu_load.cpp`), un thread per processore
  logico di default. Parte dopo la calibrazione, fase nascosta `_riscaldamento CPU` di
  30 s × `--scale`, poi resta attivo per tutta la sequenza. Kernel `x = x*x - 1.9` con 8 catene
  indipendenti: AVX2+FMA con rilevamento a runtime (nessun flag di compilazione globale),
  altrimenti scalare. Thread a priorità bassa (API di sistema dietro `#ifdef`). Stampare a fine
  test thread, ISA e GFLOPS medi. Il CSV non cambia.
- Validare gli argomenti e stampare un help chiaro in italiano se non sono validi.
- All'avvio stampare nome GPU, numero di SM, compute capability, VRAM, power limit attivo e di default.
- Gestire Ctrl+C: fermare i carichi, chiudere il monitor e **scrivere comunque** riepilogo e CSV
  con i dati raccolti fino a quel momento.

### Sequenza di test predefinita (durate base, moltiplicate per `--scale`)

| Fase | Durata |
|---|---|
| idle baseline | 5 s |
| FMA FP32 sostenuto | 20 s |
| Tensor FP16 sostenuto | 20 s |
| Memoria GDDR7 sostenuto | 15 s |
| Tensor + memoria (max) | 30 s |
| Onde quadre 1, 2, 5, 10, 20, 50, 100, 200 Hz | 10 s ciascuna |
| Burst da idle: 10 cicli (3 s idle + 300 ms carico) | ~33 s |

Tra una fase di carico e l'altra: cooldown `_cooldown` di 5 s (3 s dopo ogni onda quadra).
La durata dei burst (300 ms) **non** va scalata.

### Script di analisi (`scripts/plot_log.py`)

- Uso: `python scripts/plot_log.py power_log.csv [--out grafico.png]`
- Tre pannelli con asse X condiviso: potenza (media e istantanea, più linea orizzontale
  opzionale `--limit W`), clock SM, temperatura.
- Sfondo colorato alternato per fase, con etichette per le fasi senza `_`.
- Stampa anche una tabella riassuntiva per fase (come il report C++).

## Piano di lavoro (milestone)

Procedere in quest'ordine, con un commit per milestone e build verificata a ogni passo.

1. **Scheletro**: CMakeLists, `check.hpp`, `main.cu` che stampa le info della GPU. Build ok.
2. **Monitor NVML**: thread di campionamento, gestione fasi, CSV. Test: 5 s di idle producono un CSV valido.
3. **Kernel e calibrazione**: i tre kernel + `calibrate`. Test: stampa delle iterazioni calibrate.
4. **Pattern**: sustained, square wave, burst. Test con `--scale 0.05`.
5. **Report e CLI completa**: tabella, argomenti, `--list`, `--only`, gestione Ctrl+C.
6. **Script Python** di plotting.
7. **README.md** e `tests/smoke_test.sh`.

## Verifica

- Se nell'ambiente non c'è una GPU NVIDIA, verificare almeno che il progetto **compili**
  (`cmake -B build && cmake --build build`) e dichiarare esplicitamente che l'esecuzione
  non è stata testata. Non inventare output o risultati di esecuzione.
- Se `nvcc` non è disponibile, dirlo chiaramente invece di aggirare il problema.
- Controllare che `compute-sanitizer --tool memcheck ./gpu-psu-stress --scale 0.02` non riporti errori (se c'è una GPU).
- Lo smoke test deve completarsi in meno di 30 secondi e verificare che il CSV esista e
  contenga l'intestazione corretta e almeno una riga per ogni fase non nascosta.
- Testare `plot_log.py` con un CSV di esempio generato sinteticamente (anche senza GPU).

## Contenuto del README.md

Scrivere in italiano, per un utente non esperto di CUDA:

- Cosa fa il tool e perché le onde quadre e i burst sono i test più severi per un alimentatore.
- Requisiti, compilazione su Linux e Windows, esempi d'uso.
- Come leggere la tabella e il grafico.
- **Il verdetto reale**: se il PC arriva in fondo senza spegnersi, riavviarsi o andare in schermo nero,
  il PSU regge. Il coil whine durante le onde quadre è normale.
- Consiglio: per lo scenario peggiore, stressare **anche la CPU** in parallelo con `--cpu`
  (in alternativa Prime95 Small FFTs, `stress-ng --cpu 0`, o OCCT), perché il PSU alimenta
  tutto il sistema.
- Controllare che il connettore 12V-2x6 sia inserito completamente e senza pieghe strette.
- Per misurare davvero i picchi sotto il millisecondo servono strumenti hardware
  (oscilloscopio con pinza amperometrica, NVIDIA PCAT, Elmorlabs PMD2).
- Avvertenza: il test porta la GPU al massimo per minuti; usarlo con case ventilato e
  interromperlo (Ctrl+C) se la temperatura supera livelli anomali.

## Cose da NON fare

- Non aggiungere funzioni per superare il power limit o modificare voltaggi e clock:
  il tool deve solo generare carico e osservare, senza cambiare impostazioni della GPU.
- Non usare `cudaDeviceReset` o API che richiedono privilegi di amministratore.
- Non introdurre dipendenze oltre CUDA, NVML e (per lo script) pandas/matplotlib.
- Non riempire la coda dei lanci senza sincronizzare: i pattern devono restare precisi nel tempo.
