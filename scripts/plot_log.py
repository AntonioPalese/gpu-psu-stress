#!/usr/bin/env python3
"""Grafico di potenza, clock SM e temperatura dal log CSV di gpu-psu-stress.

Uso:
    python scripts/plot_log.py power_log.csv [--out grafico.png] [--limit W]

Senza --out il grafico viene mostrato in una finestra.
"""

from __future__ import annotations

import argparse
import sys

import pandas as pd

EXPECTED_COLUMNS = [
    "t_s", "phase", "power_avg_W", "power_instant_W",
    "sm_clock_MHz", "mem_clock_MHz", "temp_C",
]

# Colori: serie categoriali in ordine fisso, inchiostri neutri per testo e assi.
C_AVG = "#2a78d6"
C_INSTANT = "#eb6834"
C_LIMIT = "#d03b3b"
C_SURFACE = "#fcfcfb"
C_BAND = "#f0efec"
C_TEXT = "#0b0b0b"
C_TEXT_2 = "#52514e"
C_MUTED = "#898781"


def is_hidden(phase: str) -> bool:
    return phase.startswith("_")


def load_log(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, keep_default_na=False)
    missing = [c for c in EXPECTED_COLUMNS if c not in df.columns]
    if missing:
        sys.exit(f"Errore: colonne mancanti nel CSV: {', '.join(missing)}")
    df["phase"] = df["phase"].astype(str)
    # -1 indica "non disponibile": diventa NaN, così non entra in grafici e statistiche.
    for col in EXPECTED_COLUMNS[2:]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
        df.loc[df[col] < 0, col] = float("nan")
    return df


def segments(df: pd.DataFrame) -> list[tuple[str, float, float]]:
    """Tratti contigui con la stessa fase: (nome, t_inizio, t_fine)."""
    seg_id = (df["phase"] != df["phase"].shift()).cumsum()
    out = []
    for _, g in df.groupby(seg_id, sort=False):
        out.append((g["phase"].iloc[0], g["t_s"].iloc[0], g["t_s"].iloc[-1]))
    # Ogni tratto si estende fino all'inizio del successivo, senza buchi.
    for i in range(len(out) - 1):
        name, t0, _ = out[i]
        out[i] = (name, t0, out[i + 1][1])
    return out


def fmt(v: float, digits: int = 1) -> str:
    return "n/d" if pd.isna(v) else f"{v:.{digits}f}"


def print_summary(df: pd.DataFrame, limit: float | None) -> None:
    visible = df[~df["phase"].map(is_hidden)]
    header = (f"{'Fase':<28} {'Campioni':>8} {'Media W':>9} {'Max W':>9} "
              f"{'Max ist. W':>12} {'Max SM MHz':>10} {'Max temp':>8}")
    print(header)
    print("-" * len(header))
    for phase, g in visible.groupby("phase", sort=False):
        print(f"{phase:<28} {len(g):>8} {fmt(g['power_avg_W'].mean()):>9} "
              f"{fmt(g['power_avg_W'].max()):>9} {fmt(g['power_instant_W'].max()):>12} "
              f"{fmt(g['sm_clock_MHz'].max(), 0):>10} {fmt(g['temp_C'].max(), 0):>8}")
    print("-" * len(header))
    peak = df[["power_avg_W", "power_instant_W"]].max(axis=1)
    if peak.notna().any():
        i = peak.idxmax()
        line = f"Picco globale: {peak[i]:.1f} W (fase \"{df.loc[i, 'phase']}\")"
        if limit:
            line += f", {100 * peak[i] / limit:.0f}% del limite indicato ({limit:.0f} W)"
        print(line)
    else:
        print("Picco globale: n/d (nessun dato di potenza nel log)")
    print("Nota: NVML non vede i transienti sotto il millisecondo.")


def plot(df: pd.DataFrame, out: str | None, limit: float | None, title: str) -> None:
    import matplotlib
    if out:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({
        "font.size": 9,
        "axes.edgecolor": C_MUTED,
        "axes.labelcolor": C_TEXT_2,
        "xtick.color": C_MUTED,
        "ytick.color": C_MUTED,
        "axes.spines.top": False,
        "axes.spines.right": False,
    })

    fig, axes = plt.subplots(3, 1, sharex=True, figsize=(14, 8.5),
                             gridspec_kw={"height_ratios": [2.2, 1, 1]})
    fig.patch.set_facecolor(C_SURFACE)
    ax_p, ax_c, ax_t = axes

    # Sfondo alternato per fase (le fasi nascoste restano senza banda).
    segs = segments(df)
    visible_idx = 0
    for name, t0, t1 in segs:
        if is_hidden(name):
            continue
        if visible_idx % 2 == 0:
            for ax in axes:
                ax.axvspan(t0, t1, color=C_BAND, lw=0, zorder=0)
        visible_idx += 1

    t = df["t_s"]
    ax_p.plot(t, df["power_avg_W"], color=C_AVG, lw=1.2, label="Potenza media (NVML)", zorder=3)
    if df["power_instant_W"].notna().any():
        ax_p.plot(t, df["power_instant_W"], color=C_INSTANT, lw=0.8, alpha=0.9,
                  label="Potenza istantanea (NVML)", zorder=2)
    if limit:
        ax_p.axhline(limit, color=C_LIMIT, lw=1.2, ls="--", zorder=4)
        ax_p.annotate(f"limite {limit:.0f} W", xy=(1, limit), xycoords=("axes fraction", "data"),
                      xytext=(-4, 4), textcoords="offset points", ha="right", va="bottom",
                      color=C_TEXT_2, fontsize=8, zorder=5,
                      bbox={"facecolor": C_SURFACE, "edgecolor": "none", "alpha": 0.9, "pad": 1})
    ax_p.set_ylabel("Potenza (W)")
    ax_p.set_ylim(bottom=0)
    leg = ax_p.legend(loc="upper left", fontsize=8, labelcolor=C_TEXT_2, framealpha=0.9,
                      facecolor=C_SURFACE, edgecolor="none")
    leg.set_zorder(5)

    ax_c.plot(t, df["sm_clock_MHz"], color=C_AVG, lw=1.0, zorder=3)
    ax_c.set_ylabel("Clock SM (MHz)")
    ax_c.set_ylim(bottom=0)

    ax_t.plot(t, df["temp_C"], color=C_AVG, lw=1.0, zorder=3)
    ax_t.set_ylabel("Temperatura (°C)")
    ax_t.set_xlabel("Tempo (s)")

    for ax in axes:
        ax.set_facecolor(C_SURFACE)
        ax.grid(axis="y", color=C_BAND, lw=0.8, zorder=1)
        ax.margins(x=0)

    # Etichette delle fasi visibili sopra il pannello della potenza (una per nome:
    # i burst ripetuti vengono etichettati solo al primo ciclo).
    labelled = set()
    for name, t0, t1 in segs:
        if is_hidden(name) or name in labelled:
            continue
        labelled.add(name)
        ax_p.text((t0 + t1) / 2, 1.01, name, transform=ax_p.get_xaxis_transform(),
                  rotation=60, ha="left", va="bottom", fontsize=7, color=C_TEXT_2,
                  rotation_mode="anchor", clip_on=False)

    fig.suptitle(title, x=0.01, ha="left", color=C_TEXT, fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.subplots_adjust(top=0.80)

    if out:
        fig.savefig(out, dpi=130, facecolor=C_SURFACE)
        print(f"Grafico salvato in {out}")
    else:
        plt.show()


def main() -> None:
    ap = argparse.ArgumentParser(description="Grafico del log CSV di gpu-psu-stress.")
    ap.add_argument("csv", help="file CSV prodotto da gpu-psu-stress")
    ap.add_argument("--out", help="salva il grafico in questo file (es. grafico.png) invece di mostrarlo")
    ap.add_argument("--limit", type=float, help="disegna una linea orizzontale a W watt (es. power limit)")
    args = ap.parse_args()

    df = load_log(args.csv)
    if df.empty:
        sys.exit("Errore: il CSV non contiene campioni.")
    print_summary(df, args.limit)
    plot(df, args.out, args.limit, f"gpu-psu-stress — {args.csv}")


if __name__ == "__main__":
    main()
