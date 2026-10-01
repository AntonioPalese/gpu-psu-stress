# gpu-psu-stress

Un piccolo programma da riga di comando che mette sotto stress una scheda video NVIDIA per
capire se l'**alimentatore (PSU)** regge i picchi di assorbimento. È pensato per una
**RTX 5070 (250 W) con un alimentatore da 650 W**, ma funziona su qualsiasi GPU NVIDIA
recente.

> ⚠️ **Avvertenza.** Il test porta la GPU al massimo per alcuni minuti. Usalo con il case
> ben ventilato, tieni d'occhio la temperatura e interrompilo con **Ctrl+C** se sale a
> livelli anomali (per una scheda desktop, stabilmente sopra gli 85-90 °C).

## Cosa fa

1. **Genera carichi** sulla GPU in modo ripetibile:
   - carichi **sostenuti** (calcolo FP32, tensor core, memoria, e tensor + memoria insieme);
   - **onde quadre**: la GPU passa da pieno carico a zero e viceversa a 1, 2, 5, 10, 20, 50,
     100 e 200 volte al secondo;
   - **burst da idle**: la GPU resta ferma 3 secondi (i clock scendono al minimo), poi va al
     massimo di colpo per 300 ms, per 10 volte.
2. **Misura** potenza, clock e temperatura tramite NVML (la libreria di monitoraggio del
   driver NVIDIA) in un thread separato.
3. **Riassume** i risultati a schermo per ogni fase e **salva** tutti i campioni in un file CSV.
4. Uno script Python separato **disegna il grafico** del CSV.

### Perché onde quadre e burst sono i test più severi

Un carico costante è facile per un alimentatore: la tensione si stabilizza e i condensatori
non devono fare nulla. I problemi nascono con i **cambi bruschi**: quando la GPU passa da
quasi zero a pieno carico in pochi microsecondi, assorbe per un istante molto più della sua
potenza nominale (transienti che su schede moderne possono arrivare a 1,5-2 volte il TGP).
Se il picco supera le protezioni del PSU (OCP, sovracorrente, o OPP, sovrapotenza),
l'alimentatore si spegne per sicurezza e il PC si spegne o si riavvia di colpo.

- Le **onde quadre** ripetono questi fronti centinaia di volte al secondo, a frequenze
  diverse: alcune frequenze possono entrare in risonanza con il circuito di regolazione del PSU.
- I **burst da idle** riproducono il caso peggiore reale: GPU ferma a clock minimi che riceve
  all'improvviso un carico pesante (es. l'avvio di un gioco o di una scena).

## Il limite importante: NVML non vede i picchi veri

NVML campiona ogni ~10-100 ms e riporta valori mediati. I transienti che fanno scattare
l'alimentatore durano **meno di un millisecondo**: il tool **non può misurarli**.
Il tool li **provoca**; i numeri a schermo servono solo a confermare che i carichi stanno
funzionando.

**Il verdetto reale è semplice**: se il PC arriva in fondo al test **senza spegnersi,
riavviarsi o andare in schermo nero**, l'alimentatore regge. Il **coil whine** (fischio o
ronzio elettrico) durante le onde quadre è **normale** e non indica un guasto.

Per misurare davvero i picchi sotto il millisecondo servono strumenti hardware:
oscilloscopio con pinza amperometrica, NVIDIA PCAT, Elmorlabs PMD2 o simili.

## Consigli per un test serio

- **Stressa anche la CPU in parallelo.** L'alimentatore alimenta tutto il sistema, e lo
  scenario peggiore è CPU e GPU al massimo insieme. Avvia prima uno di questi:
  - Windows: **Prime95** (Small FFTs) oppure **OCCT**;
  - Linux: `stress-ng --cpu 0` (oppure Prime95 / mprime).
- **Controlla il connettore 12V-2x6** (o 12VHPWR) della scheda: deve essere inserito
  **fino in fondo**, senza spazi visibili, e il cavo non deve avere pieghe strette vicino
  al connettore.
- Chiudi giochi e altri programmi che usano la GPU, così i carichi sono ripetibili.

Per una procedura completa passo per passo (prova breve, solo GPU, GPU + CPU, ripetizioni,
come interpretare uno spegnimento) e una descrizione dei software citati, vedi
[docs/procedura-test-5070.md](docs/procedura-test-5070.md).

## Requisiti

- GPU NVIDIA con driver recente.
- **CUDA Toolkit ≥ 12.8** per compilare per le RTX 50xx (Blackwell, sm_120). Per GPU più
  vecchie basta un toolkit che supporti la loro architettura (vedi sotto).
- **CMake ≥ 3.24**.
- Un compilatore C++17: GCC o Clang su Linux, **Visual Studio 2022** (con il componente
  "Sviluppo di applicazioni desktop con C++") su Windows.
- Per il grafico: **Python 3.10+** con `pandas` e `matplotlib`.

## Compilazione

Per default il programma viene compilato per la **RTX 50xx** (compute capability 12.0).
Per un'altra GPU passa `-DCMAKE_CUDA_ARCHITECTURES` con la sua compute capability senza
punto: `89` per le RTX 40xx (Ada), `86` per le RTX 30xx (Ampere), `75` per Turing.
Puoi trovarla con `nvidia-smi --query-gpu=name,compute_cap --format=csv`.

### Linux

```bash
cmake -B build                  # RTX 50xx
# oppure: cmake -B build -DCMAKE_CUDA_ARCHITECTURES=89
cmake --build build -j
./build/gpu-psu-stress
```

### Windows (Prompt dei comandi o PowerShell)

```bat
cmake -B build
cmake --build build --config Release
build\Release\gpu-psu-stress.exe
```

Se la variabile d'ambiente `CUDA_PATH` non è impostata, CMake usa automaticamente il
toolkit del `nvcc` che trova nel `PATH`. Se compare comunque l'errore
*"The CUDA Toolkit directory '' does not exist"*, cancella la cartella `build` (conserva la
configurazione fallita) e indica il percorso esplicitamente:

```bat
cmake -B build -T "cuda=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
```

### Compilare su un PC senza la GPU di destinazione

Per compilare non serve avere la scheda: basta il toolkit CUDA giusto. Si può anche creare
**un solo eseguibile per più GPU**, ad esempio per provarlo sul PC di sviluppo (qui una
scheda Turing, `75`) e poi usarlo sulla RTX 5070 (`120`):

```bat
cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"
cmake --build build --config Release
```

- Serve **CUDA 12.8 o 12.9**, che si può installare accanto a una versione più vecchia.
  Nell'installazione personalizzata puoi togliere il driver e tenere quello attuale.
- CUDA 13.x richiede un driver ≥ 580: un eseguibile compilato con CUDA 13 non parte sui PC
  con driver più vecchi.
- Sul PC di destinazione **non serve installare CUDA**: basta il driver NVIDIA (il runtime
  CUDA è incluso nell'eseguibile, NVML arriva con il driver).

## Uso

```
gpu-psu-stress [--scale X] [--sample-ms N] [--device N] [--out file.csv]
               [--only sustained|square|burst] [--list]
```

| Opzione | Significato |
|---|---|
| `--scale X` | moltiplica tutte le durate (default 1.0, circa 4 minuti compresi i cooldown). I burst da 300 ms non vengono scalati. |
| `--sample-ms N` | periodo di campionamento NVML in millisecondi (default 10, minimo 1) |
| `--device N` | quale GPU usare, se ne hai più di una (default 0) |
| `--out FILE` | nome del file CSV (default `power_log.csv`) |
| `--only GRUPPO` | esegue solo `sustained`, `square` o `burst` (più l'idle iniziale) |
| `--list` | mostra la sequenza delle fasi con le durate ed esce, senza toccare la GPU |

Esempi:

```bash
gpu-psu-stress                          # test completo
gpu-psu-stress --list                   # cosa verrà eseguito e quanto dura
gpu-psu-stress --only square            # solo le onde quadre
gpu-psu-stress --scale 2 --out lungo.csv   # test lungo il doppio
gpu-psu-stress --scale 0.05             # prova veloce (~20 s) per vedere se tutto funziona
```

**Ctrl+C** interrompe il test in qualsiasi momento: i carichi si fermano e il riepilogo e il
CSV vengono scritti comunque con i dati raccolti fino a quel punto (codice di uscita 130).

### Sequenza predefinita

| Fase | Durata |
|---|---|
| Idle baseline | 5 s |
| FMA FP32 sostenuto | 20 s |
| Tensor FP16 sostenuto | 20 s |
| Memoria VRAM sostenuto | 15 s |
| Tensor + memoria (max) | 30 s |
| Onde quadre 1, 2, 5, 10, 20, 50, 100, 200 Hz | 10 s ciascuna |
| Burst da idle: 10 cicli (3 s idle + 300 ms di carico) | ~33 s |

Tra una fase e l'altra c'è un cooldown di 5 s (3 s dopo ogni onda quadra). Prima di
iniziare, il programma **calibra** i carichi per qualche secondo in modo che ogni lancio duri
un tempo preciso (2 ms, o 0,5 ms per le onde quadre): per questo il comportamento è simile
su GPU diverse.

## Come leggere i risultati

### All'avvio

Il programma stampa nome della GPU, numero di SM, compute capability, VRAM, power limit
attivo e di default, e se la GPU fornisce la potenza istantanea. Poi mostra il risultato
della calibrazione di ogni carico.

### La tabella finale

| Colonna | Significato |
|---|---|
| Campioni | quante misure NVML sono state prese nella fase |
| Media W | potenza media della fase |
| Max W | massimo della potenza media riportata da NVML |
| Max ist. W | massimo della potenza "istantanea" NVML (`n/d` se la GPU/driver non la fornisce) |
| Max SM MHz | clock massimo dei core |
| Max temp | temperatura massima in °C |

Sotto la tabella c'è il **picco globale** e la sua percentuale rispetto al power limit attivo.
Valori intorno al 100% del power limit nei carichi sostenuti sono normali: la scheda lavora
al massimo consentito. Ricorda però che i transienti veri, invisibili a NVML, sono più alti.

Cose da notare:
- nelle **onde quadre ad alta frequenza** la media è circa la metà del carico pieno: NVML
  media i cicli on/off. È atteso;
- se i **clock SM** calano molto mentre la temperatura sale, la GPU sta andando in
  *thermal throttling*: migliora la ventilazione.

### Il grafico

Il modo più semplice è con [uv](https://docs.astral.sh/uv/): il file `pyproject.toml` nella
cartella del progetto elenca le dipendenze, e uv crea da solo l'ambiente in `.venv`.

```bash
uv sync                                       # solo la prima volta
uv run scripts/plot_log.py power_log.csv --out grafico.png --limit 250
```

In alternativa, con pip:

```bash
pip install pandas matplotlib
python scripts/plot_log.py power_log.csv --out grafico.png --limit 250
```

Senza `--out` il grafico si apre in una finestra. `--limit W` disegna una linea tratteggiata
(ad esempio al TGP della scheda). Lo script stampa anche la stessa tabella riassuntiva.

Il grafico ha tre pannelli con lo stesso asse del tempo:
1. **Potenza**: media (blu) e, se disponibile, istantanea (arancione);
2. **Clock SM**;
3. **Temperatura**.

Le fasce grigie alternate separano le fasi, con il nome scritto in alto; i cooldown non
hanno etichetta. Nelle onde quadre dovresti vedere la potenza oscillare (alle frequenze
basse) o stabilizzarsi a un valore intermedio (alle alte); nei burst, dieci picchi netti.

## Formato del CSV

```
t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C
```

Una riga per campione: tempo in secondi dall'inizio del test, nome della fase, potenza media
e istantanea in watt, clock SM e memoria in MHz, temperatura in °C. Il valore **-1** indica
una misura non disponibile. Le fasi il cui nome inizia con `_` (cooldown, idle tra i burst)
sono nel CSV ma non nel riepilogo.

## Test

```bash
tests/smoke_test.sh            # esecuzione breve con --scale 0.05, deve durare < 30 s
```

Su Windows eseguilo da Git Bash. Controlla che il CSV esista, abbia l'intestazione corretta
e contenga almeno una riga per ogni fase.

## Cosa il tool NON fa

Il programma **genera solo carico e osserva**: non modifica power limit, clock, voltaggi o
altre impostazioni della GPU e non richiede privilegi di amministratore.
