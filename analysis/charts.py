#!/usr/bin/env python3
"""Generate white-paper figures from results/summary.csv (run summarize.py
first). Light-mode static figures for embedding in the paper.

Outputs results/charts/{bytes-by-scenario,conversation-growth,fwd-cost}.svg+.png
Systems missing from the data are simply omitted from the figures.
"""

import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

BENCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUMMARY_CSV = os.path.join(BENCH_ROOT, "results", "summary.csv")
OUT_DIR = os.path.join(BENCH_ROOT, "results", "charts")

# Fixed system -> categorical slot (never re-assigned by presence/rank).
SYSTEM_COLOR = {"fmsg": "#2a78d6", "email": "#eb6834", "whatsapp": "#1baf7a"}
SYSTEM_ORDER = ["fmsg", "email", "whatsapp"]

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
SECONDARY = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"

SCENARIO_ORDER = ["m1p2", "m2p2", "m3p2", "m4p2", "m5p2",
                  "m1p2a10k", "m1p2a1m", "m1p5", "m1p5a10k", "m1p5a1m",
                  "m5p4", "m1p2-fwd", "m1p2a1m-fwd", "m3p2-br",
                  "m1p2ascr", "m1p2aimg", "m1p2adoc", "m1p3", "m1p3x",
                  "m10p2", "m20p2", "m100p2", "m200p2", "m10p3x", "m10p4x"]
GROWTH_SERIES = [("m1p2", 1), ("m2p2", 2), ("m3p2", 3), ("m4p2", 4), ("m5p2", 5),
                 ("m10p2", 10), ("m20p2", 20), ("m100p2", 100), ("m200p2", 200)]


def load():
    with open(SUMMARY_CSV, newline="") as f:
        rows = list(csv.DictReader(f))
    data = {}
    for r in rows:
        data[(r["system"], r["scenario"])] = r
    systems = [s for s in SYSTEM_ORDER if any(k[0] == s for k in data)]
    return data, systems


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(BASELINE)
    ax.tick_params(colors=MUTED, labelsize=9)
    for lbl in ax.get_xticklabels() + ax.get_yticklabels():
        lbl.set_color(SECONDARY)


def human_bytes(n, _pos=None):
    def fmt(v):
        s = f"{v:.1f}".rstrip("0").rstrip(".")
        return s
    if n >= 1_000_000:
        return f"{fmt(n / 1_000_000)} MB"
    if n >= 1_000:
        return f"{fmt(n / 1_000)} kB"
    return f"{n:.0f} B"


def fig_bytes_by_scenario(data, systems):
    scenarios = [s for s in SCENARIO_ORDER
                 if any((sys, s) in data for sys in systems)]
    fig, ax = plt.subplots(figsize=(8, 0.42 * len(scenarios) + 1.4))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    n_sys = len(systems)
    bar_h = 0.8 / n_sys
    for i, sys_name in enumerate(systems):
        ys, xs = [], []
        for j, sc in enumerate(scenarios):
            r = data.get((sys_name, sc))
            if r:
                ys.append(j + (i - (n_sys - 1) / 2) * bar_h)
                xs.append(int(r["bytes_total_median"]))
        ax.barh(ys, xs, height=bar_h * 0.92, color=SYSTEM_COLOR[sys_name],
                label=sys_name, zorder=3)
        for y, x in zip(ys, xs):
            ax.annotate(human_bytes(x), (x, y), xytext=(4, 0),
                        textcoords="offset points", va="center",
                        fontsize=7.5, color=SECONDARY)

    ax.set_yticks(range(len(scenarios)))
    ax.set_yticklabels(scenarios)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.set_xlabel("total bytes on the wire (median)",
                  fontsize=9, color=SECONDARY)
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Bytes over the wire per scenario", fontsize=11,
                 color=INK, loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY, loc="lower right")
    fig.tight_layout()
    return fig, "bytes-by-scenario"


def fig_conversation_growth(data, systems):
    fig, ax = plt.subplots(figsize=(7, 4))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    for sys_name in systems:
        xs, ys = [], []
        for sc, n in GROWTH_SERIES:
            r = data.get((sys_name, sc))
            if r:
                xs.append(n)
                ys.append(int(r["bytes_total_median"]))
        if not xs:
            continue
        ax.plot(xs, ys, color=SYSTEM_COLOR[sys_name], linewidth=2,
                marker="o", markersize=5, label=sys_name, zorder=3)
        ax.annotate(sys_name, (xs[-1], ys[-1]), xytext=(6, 0),
                    textcoords="offset points", va="center", fontsize=9,
                    color=SECONDARY)

    ax.set_xlabel("messages exchanged (each a reply to the previous)",
                  fontsize=9, color=SECONDARY)
    ax.set_ylabel("cumulative bytes on the wire", fontsize=9, color=SECONDARY)
    ax.set_xticks([1, 5, 10, 20, 50, 100, 200])
    ax.yaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="y", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Conversation cost growth", fontsize=11, color=INK, loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY, loc="upper left")
    fig.tight_layout()
    return fig, "conversation-growth"


def fig_fwd_cost(data, systems):
    """Marginal cost of bringing a third participant into a message
    carrying a 1 MiB attachment: fwd-scenario total minus base total."""
    fig, ax = plt.subplots(figsize=(6, 2.6))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    ys, xs, colors, names = [], [], [], []
    for i, sys_name in enumerate(systems):
        base = data.get((sys_name, "m1p2a1m"))
        fwd = data.get((sys_name, "m1p2a1m-fwd"))
        if not (base and fwd):
            continue
        delta = int(fwd["bytes_total_median"]) - int(base["bytes_total_median"])
        ys.append(len(ys))
        xs.append(max(delta, 0))
        colors.append(SYSTEM_COLOR[sys_name])
        names.append(sys_name)

    ax.barh(ys, xs, height=0.55, color=colors, zorder=3)
    for y, x in zip(ys, xs):
        ax.annotate(human_bytes(x), (x, y), xytext=(4, 0),
                    textcoords="offset points", va="center", fontsize=9,
                    color=SECONDARY)
    ax.set_yticks(ys)
    ax.set_yticklabels(names)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Marginal wire cost of adding a participant\nto a sent 1 MiB-attachment message",
                 fontsize=11, color=INK, loc="left")
    fig.tight_layout()
    return fig, "fwd-cost"


def main():
    data, systems = load()
    os.makedirs(OUT_DIR, exist_ok=True)
    for fig, name in (fig_bytes_by_scenario(data, systems),
                      fig_conversation_growth(data, systems),
                      fig_fwd_cost(data, systems)):
        for ext in ("svg", "png"):
            fig.savefig(os.path.join(OUT_DIR, f"{name}.{ext}"),
                        dpi=180, facecolor=SURFACE, bbox_inches="tight")
        plt.close(fig)
        print(f"wrote {OUT_DIR}/{name}.svg/.png")


if __name__ == "__main__":
    main()
