#!/usr/bin/env python3
"""Exploratory chart gallery from results/summary.csv (+ per-conversation
stream JSON where it sharpens the story). Run summarize.py first.

Outputs results/charts/gallery/*.png — a wider set of views than the
white-paper figures in charts.py; same palette and styling.
"""

import csv
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

from charts import (SYSTEM_COLOR, SYSTEM_ORDER, SURFACE, INK, SECONDARY,
                    MUTED, GRID, human_bytes, style_axes, load, GROWTH_SERIES)

BENCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(BENCH_ROOT, "results", "charts", "gallery")
PCAPS = os.path.join(BENCH_ROOT, "results", "pcaps")

# attachment scenario -> (label, raw file bytes)
ATTACH_RAW = {
    "m1p2a1m": ("1 MiB random", 1048576),
    "m1p2ascr": ("screenshot PNG", 335762),
    "m1p2aimg": ("photo JPG", 1021485),
    "m1p2adoc": ("document ODT", 376991),
}


def total(data, sys_name, sc):
    r = data.get((sys_name, sc))
    return int(r["bytes_total_median"]) if r else None


def fig_marginal(data, systems):
    """Average per-message cost between consecutive points of the series."""
    fig, ax = plt.subplots(figsize=(7, 4))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    for sys_name in systems:
        pts = [(n, total(data, sys_name, sc)) for sc, n in GROWTH_SERIES
               if n <= 20 and total(data, sys_name, sc) is not None]
        xs, ys = [], []
        for (n0, b0), (n1, b1) in zip(pts, pts[1:]):
            xs.append(n1)
            ys.append((b1 - b0) / (n1 - n0))
        if not xs:
            continue
        ax.plot(xs, ys, color=SYSTEM_COLOR[sys_name], linewidth=2,
                marker="o", markersize=5, label=sys_name, zorder=3)

    ax.set_xlabel("message number in the conversation (average between measured points)",
                  fontsize=9, color=SECONDARY)
    ax.set_ylabel("bytes per additional message", fontsize=9, color=SECONDARY)
    ax.set_xticks([2, 3, 4, 5, 10, 20])
    ax.yaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="y", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("What does the next reply cost?", fontsize=11, color=INK,
                 loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY,
              loc="upper left")
    fig.tight_layout()
    return fig, "marginal-cost"


def fig_attach_overhead(data, systems):
    """Wire bytes as % over (or under) the raw attachment size."""
    scenarios = [sc for sc in ATTACH_RAW if any(total(data, s, sc) for s in systems)]
    fig, ax = plt.subplots(figsize=(7.5, 0.62 * len(scenarios) * len(systems) / 2 + 1.6))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    n_sys = len(systems)
    bar_h = 0.8 / n_sys
    for i, sys_name in enumerate(systems):
        ys, xs = [], []
        for j, sc in enumerate(scenarios):
            t = total(data, sys_name, sc)
            if t is None:
                continue
            raw = ATTACH_RAW[sc][1]
            ys.append(j + (i - (n_sys - 1) / 2) * bar_h)
            xs.append(100.0 * (t - raw) / raw)
        ax.barh(ys, xs, height=bar_h * 0.9, color=SYSTEM_COLOR[sys_name],
                label=sys_name, zorder=3)
        for y, x in zip(ys, xs):
            ax.annotate(f"{x:+.0f}%", (x, y),
                        xytext=(5 if x >= 0 else -5, 0),
                        textcoords="offset points", va="center",
                        ha="left" if x >= 0 else "right",
                        fontsize=8, color=SECONDARY)

    ax.axvline(0, color=INK, linewidth=0.8, zorder=2)
    ax.set_yticks(range(len(scenarios)))
    ax.set_yticklabels([ATTACH_RAW[sc][0] for sc in scenarios])
    ax.invert_yaxis()
    ax.set_xlabel("wire bytes vs raw file size (negative = recompressed)",
                  fontsize=9, color=SECONDARY)
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Attachment overhead over the raw file", fontsize=11,
                 color=INK, loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY,
              loc="lower right")
    fig.tight_layout()
    return fig, "attachment-overhead"


def fig_single_anatomy(data, systems):
    """Where a single 120-byte message's bytes go, per system."""
    fig, ax = plt.subplots(figsize=(7, 2.8))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    ys, names = [], []
    for sys_name in systems:
        if total(data, sys_name, "m1p2") is None:
            continue
        names.append(sys_name)
    for i, sys_name in enumerate(names):
        left = 0
        sj = os.path.join(PCAPS, sys_name, "m1p2", "rep1.streams.json")
        segs = []
        if sys_name == "fmsg" and os.path.exists(sj):
            streams = json.load(open(sj))["streams"]
            streams.sort(key=lambda s: s["first_ts"])
            labels = ["message delivery", "challenge-response"]
            for st, lbl in zip(streams, labels):
                segs.append((lbl, sum(st["frame_bytes"].values())))
        else:
            segs.append(("single conversation", total(data, sys_name, "m1p2")))
        shades = [1.0, 0.55]
        for k, (lbl, b) in enumerate(segs):
            color = SYSTEM_COLOR[sys_name]
            ax.barh(i, b, left=left, height=0.5, color=color,
                    alpha=shades[k % 2], zorder=3,
                    edgecolor=SURFACE, linewidth=1)
            if b > 1500:
                ax.annotate(f"{lbl}\n{human_bytes(b)}", (left + b / 2, i),
                            ha="center", va="center", fontsize=8,
                            color="white" if k % 2 == 0 else INK)
            left += b

    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Anatomy of a single 120-byte message", fontsize=11,
                 color=INK, loc="left")
    fig.tight_layout()
    return fig, "single-message-anatomy"


def fig_cross_domain(data, systems):
    """fmsg vs email where recipients span domains/providers."""
    rows = [("m1p3", "1 msg, 2 recipients,\none remote domain"),
            ("m1p3x", "1 msg, 2 recipients,\ntwo domains"),
            ("m10p3x", "10 msgs, 3 participants,\nthree domains"),
            ("m10p4x", "10 msgs, 4 participants,\nthree domains")]
    present = [s for s in systems if s in ("fmsg", "email")]
    fig, ax = plt.subplots(figsize=(7.5, 3.6))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    bar_h = 0.8 / len(present)
    for i, sys_name in enumerate(present):
        ys, xs = [], []
        for j, (sc, _) in enumerate(rows):
            t = total(data, sys_name, sc)
            if t is None:
                continue
            ys.append(j + (i - (len(present) - 1) / 2) * bar_h)
            xs.append(t)
        ax.barh(ys, xs, height=bar_h * 0.9, color=SYSTEM_COLOR[sys_name],
                label=sys_name, zorder=3)
        for y, x in zip(ys, xs):
            ax.annotate(human_bytes(x), (x, y), xytext=(4, 0),
                        textcoords="offset points", va="center", fontsize=8,
                        color=SECONDARY)

    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([r[1] for r in rows], fontsize=8.5)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Federation cost: recipients on multiple domains",
                 fontsize=11, color=INK, loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY,
              loc="lower right")
    fig.tight_layout()
    return fig, "cross-domain"


def fig_single_times(data, systems):
    """Transfer duration for the single-message scenarios (indicative)."""
    rows = ["m1p2", "m1p2a10k", "m1p2a1m"]
    labels = ["text message", "+10 KiB attachment", "+1 MiB attachment"]
    fig, ax = plt.subplots(figsize=(7, 3.2))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    n_sys = len(systems)
    bar_h = 0.8 / n_sys
    for i, sys_name in enumerate(systems):
        ys, xs = [], []
        for j, sc in enumerate(rows):
            r = data.get((sys_name, sc))
            if not r:
                continue
            ys.append(j + (i - (n_sys - 1) / 2) * bar_h)
            xs.append(float(r["duration_s_median"]))
        ax.barh(ys, xs, height=bar_h * 0.9, color=SYSTEM_COLOR[sys_name],
                label=sys_name, zorder=3)
        for y, x in zip(ys, xs):
            ax.annotate(f"{x:.1f}s", (x, y), xytext=(4, 0),
                        textcoords="offset points", va="center", fontsize=8,
                        color=SECONDARY)

    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels(labels)
    ax.invert_yaxis()
    ax.set_xlabel("first SYN to last FIN, seconds (indicative — real internet)",
                  fontsize=9, color=SECONDARY)
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Single-message transfer time", fontsize=11, color=INK,
                 loc="left")
    ax.legend(frameon=False, fontsize=9, labelcolor=SECONDARY,
              loc="lower right")
    fig.tight_layout()
    return fig, "single-message-times"


def fig_protocol_tax(data, systems):
    """TCP/IP framing share: frame bytes vs TLS/TCP payload bytes (m20p2)."""
    fig, ax = plt.subplots(figsize=(7, 2.8))
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    names, payloads, framing = [], [], []
    for sys_name in systems:
        r = data.get((sys_name, "m20p2"))
        if not r:
            continue
        tot, pay = int(r["bytes_total_median"]), int(r["tls_bytes_median"])
        names.append(sys_name)
        payloads.append(pay)
        framing.append(tot - pay)

    for i, name in enumerate(names):
        ax.barh(i, payloads[i], height=0.5, color=SYSTEM_COLOR[name], zorder=3)
        ax.barh(i, framing[i], left=payloads[i], height=0.5,
                color=SYSTEM_COLOR[name], alpha=0.35, zorder=3)
        ax.annotate(f"payload {human_bytes(payloads[i])}",
                    (payloads[i] / 2, i), ha="center", va="center",
                    fontsize=8, color="white")
        ax.annotate(f"+{human_bytes(framing[i])} TCP/IP",
                    (payloads[i] + framing[i], i), xytext=(5, 0),
                    textcoords="offset points", va="center", fontsize=8,
                    color=SECONDARY)

    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names)
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(human_bytes))
    ax.grid(axis="x", color=GRID, linewidth=0.7, zorder=0)
    ax.set_title("Transport payload vs TCP/IP framing (20-message conversation)",
                 fontsize=11, color=INK, loc="left")
    fig.tight_layout()
    return fig, "payload-vs-framing"


def main():
    data, systems = load()
    os.makedirs(OUT_DIR, exist_ok=True)
    figs = [fig_marginal(data, systems),
            fig_attach_overhead(data, systems),
            fig_single_anatomy(data, systems),
            fig_cross_domain(data, systems),
            fig_single_times(data, systems),
            fig_protocol_tax(data, systems)]
    for fig, name in figs:
        fig.savefig(os.path.join(OUT_DIR, f"{name}.png"), dpi=180,
                    facecolor=SURFACE, bbox_inches="tight")
        plt.close(fig)
        print(f"wrote {OUT_DIR}/{name}.png")


if __name__ == "__main__":
    main()
