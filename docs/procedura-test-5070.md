# Procedura di test sulla RTX 5070

Come usare `gpu-psu-stress` per capire se l'alimentatore da 650 W regge la RTX 5070.
Si procede per gradi: prima una prova breve per controllare che tutto funzioni, poi la sola
GPU, poi GPU e CPU insieme, ripetendo più volte i test più duri.

Per compilare l'eseguibile su un altro PC vedi [piano-build-sm120.md](piano-build-sm120.md).

## Software necessari

Il minimo:

- `gpu-psu-stress.exe`;
- **uno** tra OCCT e Prime95, per caricare la CPU;
- **HWiNFO**, facoltativo ma consigliato;
- il **Visualizzatore eventi**, già incluso in Windows.

Scarica sempre dai siti ufficiali: le copie su siti di download di terze parti spesso
contengono adware.

| Programma | Cos'è | A cosa serve qui |
|---|---|---|
| **HWiNFO** (HWiNFO64) | Monitor gratuito per Windows che legge tutti i sensori di scheda madre, CPU e GPU. All'avvio scegli "Sensors-only". | Mostra quello che NVML non vede: consumo della CPU, temperatura dell'hotspot e della memoria della GPU e, su molte RTX 50, la tensione sul connettore a 16 pin. Può salvare un log CSV da confrontare con quello del tool. |
| **OCCT** | Programma di stress test e stabilità per Windows, gratuito per uso personale, con interfaccia grafica. | Mette la CPU al massimo mentre gira il tool. Ha anche un test "Power" che carica CPU e GPU insieme, utile come controprova. |
| **Prime95** | Programma del progetto GIMPS (ricerca di numeri primi di Mersenne), usato da anni come stress test della CPU. Al primo avvio scegli "Just Stress Testing". | La modalità **Small FFTs** porta la CPU al consumo e al calore massimi. Alternativa a OCCT: ne basta uno dei due. |
| **stress-ng** | Programma da riga di comando per **Linux**. | Equivalente di Prime95/OCCT se il test si fa su Linux: `stress-ng --cpu 0` carica tutti i core. |
| **Visualizzatore eventi** | Incluso in Windows (`eventvwr.msc`). | Dopo un eventuale spegnimento dice se è stato l'alimentatore (Kernel-Power 41) o il driver video (Display 4101). |
| **Python + pandas + matplotlib** | Linguaggio e librerie per l'analisi dei dati. | Servono solo a `scripts/plot_log.py` per disegnare il grafico dal CSV. |

### Strumenti hardware (non necessari)

Servono a **misurare** i picchi sotto il millisecondo, cosa che nessun software può fare.
Per questo test non servono: il verdetto pratico è se il PC arriva in fondo senza spegnersi.

- **Oscilloscopio con pinza amperometrica**: lo strumento classico da laboratorio elettronico.
- **NVIDIA PCAT** (Power Capture Analysis Tool): una scheda che si inserisce tra alimentatore
  e GPU e misura la potenza molte volte al secondo. La usano soprattutto i recensori.
- **ElmorLabs PMD2**: un piccolo dispositivo USB che misura la potenza su PCIe e 12V-2x6 con
  campionamento rapido.

## Esecuzione automatica: `scripts\run_all_tests.bat`

Lo script esegue in serie tutti i test delle fasi 1-3 qui sotto. Copia nella stessa cartella
`gpu-psu-stress.exe` e `run_all_tests.bat`, poi fai doppio clic sul `.bat` (oppure lancialo
da un prompt dei comandi).

| # | Test | Parametri | Durata |
|---|---|---|---|
| 01 | `prova_breve_gpu_sola` | `--scale 0.05` | ~20 s |
| 02 | `completo_gpu_sola_scala1` | `--scale 1` | ~4 min |
| 03 | `completo_gpu_sola_scala2` | `--scale 2` | ~8 min |
| — | *pausa: lo script chiede di avviare lo stress della CPU* | | |
| 04-05 | `completo_gpu_cpu_scala2_run1..2` | `--scale 2` | ~8 min ciascuno |
| 06-08 | `onde_quadre_gpu_cpu_scala2_run1..3` | `--only square --scale 2` | ~4 min ciascuno |
| 09-11 | `burst_gpu_cpu_scala2_run1..3` | `--only burst --scale 2` | ~1 min ciascuno |

Tra un test e l'altro c'è una pausa di 30 s. In totale circa 45 minuti. Alla domanda sulla
CPU puoi rispondere **N** per saltare la parte con la CPU sotto stress.

Tutto finisce in `gpu-psu-out\sessione_AAAAMMGG_HHMMSS\`, accanto al `.bat`:

- `NN_<test>.csv`: i campioni, da cui si fanno i grafici con `plot_log.py`;
- `NN_<test>.log`: l'output completo del programma (calibrazione, fasi, riepilogo), con il
  comando in testa e il codice di uscita in fondo;
- `sessione.log`: GPU, driver e power limit (da `nvidia-smi`), orario ed esito di ogni test.

Ctrl+C interrompe il test in corso, e il CSV viene salvato comunque. Alla domanda
*"Terminare il processo batch (S/N)?"* rispondi **N** per passare al test successivo, **S**
per fermare tutto. Dopo un Ctrl+C la fine del `.log` di quel test può mancare: il CSV è
comunque completo fino al momento dell'interruzione.

Per controllare che lo script funzioni prima della sessione vera:
`run_all_tests.bat rapido` esegue tutti gli 11 test con durate minime (~2-3 minuti), senza
domande né pause, e scrive in `gpu-psu-out\rapido_...`.

## 0. Preparazione (una volta sola)

- Copia sul PC con la 5070 `gpu-psu-stress.exe`. Se vuoi i grafici direttamente lì, copia
  anche `scripts/plot_log.py` e installa Python con `pandas` e `matplotlib`; altrimenti
  riporta i CSV sul PC di sviluppo.
- **Driver aggiornato, nessun overclock né undervolt**, power limit di fabbrica: il test deve
  rappresentare l'uso normale.
- Controlla il **connettore 12V-2x6**: inserito fino in fondo e senza pieghe strette vicino
  alla scheda. Case chiuso, ventole come le usi di solito.
- Chiudi giochi, browser con accelerazione hardware e altri programmi che usano la GPU.
- Facoltativo: avvia **HWiNFO** con il log attivo.

## 1. Prova breve (circa 1 minuto)

```powershell
.\gpu-psu-stress.exe --list
.\gpu-psu-stress.exe --scale 0.05 --out prova.csv
```

Controlla che:

- il **power limit attivo** sia circa 250 W;
- le **calibrazioni** arrivino a circa 2,0 ms e 0,5 ms;
- la riga **"Potenza istantanea NVML"** dica "disponibile".

Se qualcosa non torna, fermati e analizza l'output prima di proseguire.

## 2. Solo GPU (circa 4 minuti)

```powershell
.\gpu-psu-stress.exe --out gpu_sola.csv
python plot_log.py gpu_sola.csv --out gpu_sola.png --limit 250
```

Cosa aspettarsi:

- nei carichi sostenuti la potenza è vicina a 250 W;
- se i clock calano mentre la temperatura sale, la scheda sta riducendo le prestazioni per
  il calore;
- nella tabella, **"Max ist. W" deve essere diversa da "Max W"**: è il segno che la lettura
  della potenza istantanea funziona davvero (sulla MX550 di sviluppo coincidevano).

## 3. Caso peggiore: GPU e CPU insieme

1. Avvia **OCCT** (test CPU) oppure **Prime95 Small FFTs** e aspetta 1-2 minuti, finché il
   consumo della CPU si stabilizza.
2. Con la CPU ancora sotto carico:
   ```powershell
   .\gpu-psu-stress.exe --out gpu_cpu.csv
   ```
3. Ripeti più volte i test che provocano i transienti, perché un intervento della protezione
   del PSU è un evento casuale e una sola esecuzione dice poco:
   ```powershell
   .\gpu-psu-stress.exe --only square --scale 2 --out square_cpu.csv
   .\gpu-psu-stress.exe --only burst  --scale 2 --out burst_cpu.csv
   ```
   Fai almeno 3 giri di ciascuno. Con `--scale 2` le onde quadre durano 20 s per frequenza;
   i burst restano di 300 ms, ma gli idle tra un burst e l'altro raddoppiano.

## 4. Controlli dopo ogni esecuzione

- Apri il Visualizzatore eventi di Windows, sezione Registri di Windows → Sistema, e cerca:
  - **Kernel-Power 41**: spegnimento improvviso, cioè l'alimentatore ha tagliato la corrente;
  - **Display 4101**: il driver video si è bloccato e si è ripreso da solo. È un problema della
    GPU o del driver, non dell'alimentatore.
- Confronta i grafici di `gpu_sola` e `gpu_cpu`.

## 5. Come leggere l'esito

| Cosa succede | Significato probabile |
|---|---|
| Arriva in fondo a tutto, anche con la CPU sotto carico e nelle ripetizioni | **Il PSU regge** |
| Si spegne o si riavvia durante onde quadre o burst | Intervento OCP/OPP sui transienti: alimentatore al limite |
| Si spegne solo con la CPU sotto carico | Potenza totale del sistema al limite |
| Si spegne durante i carichi sostenuti | Potenza continua insufficiente, oppure un problema termico o del connettore |
| Schermo nero ma il PC resta acceso, con evento 4101 | Driver o instabilità della GPU, non il PSU |
| Fischio (coil whine) durante le onde quadre | Normale |

**Quando interrompere (Ctrl+C):**

- la temperatura della GPU supera stabilmente 85-90 °C, oppure l'hotspot o la memoria salgono
  molto più del solito;
- senti odore di bruciato o rumori diversi dal coil whine.

Il CSV viene salvato comunque.

Una nota sui numeri: 250 W di GPU più una CPU sotto stress stanno di solito ben dentro 650 W.
Il rischio vero sono i transienti di pochi microsecondi. Se l'alimentatore è certificato
**ATX 3.0/3.1**, è progettato per sopportare picchi brevi fino a circa il doppio della potenza
nominale.
