#!/usr/bin/env python3
"""Summarise results.csv into per-(system, scenario) stats.

Writes results/summary.csv and prints a markdown table. Bytes use the
median across repetitions (min/max shown as spread); duration likewise.
"""

import csv
import os
import statistics
import sys

BENCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS_CSV = os.path.join(BENCH_ROOT, "results", "results.csv")
SUMMARY_CSV = os.path.join(BENCH_ROOT, "results", "summary.csv")

SUMMARY_COLUMNS = [
    "system", "scenario", "reps", "conversations",
    "bytes_total_median", "bytes_total_min", "bytes_total_max",
    "bytes_ab_median", "bytes_ba_median", "tls_bytes_median",
    "duration_s_median", "duration_s_min", "duration_s_max",
    "notes",
]


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else RESULTS_CSV
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print("no rows in", path, file=sys.stderr)
        return 1

    groups: dict[tuple[str, str], list[dict]] = {}
    order: list[tuple[str, str]] = []
    for r in rows:
        key = (r["system"], r["scenario"])
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(r)

    summary = []
    for key in order:
        g = groups[key]
        totals = [int(r["bytes_total"]) for r in g]
        durs = [float(r["duration_s"]) for r in g]
        summary.append({
            "system": key[0],
            "scenario": key[1],
            "reps": len(g),
            "conversations": round(statistics.median(int(r["conversations"]) for r in g)),
            "bytes_total_median": round(statistics.median(totals)),
            "bytes_total_min": min(totals),
            "bytes_total_max": max(totals),
            "bytes_ab_median": round(statistics.median(int(r["bytes_ab"]) for r in g)),
            "bytes_ba_median": round(statistics.median(int(r["bytes_ba"]) for r in g)),
            "tls_bytes_median": round(statistics.median(int(r["tls_bytes_total"]) for r in g)),
            "duration_s_median": round(statistics.median(durs), 4),
            "duration_s_min": round(min(durs), 4),
            "duration_s_max": round(max(durs), 4),
            "notes": g[0].get("notes", ""),
        })

    with open(SUMMARY_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=SUMMARY_COLUMNS)
        writer.writeheader()
        writer.writerows(summary)

    print(f"| {'system':<8} | {'scenario':<12} | {'conv':>4} | {'bytes (median)':>14} | "
          f"{'spread':>15} | {'time s (median)':>15} |")
    print(f"|{'-'*10}|{'-'*14}|{'-'*6}|{'-'*16}|{'-'*17}|{'-'*17}|")
    for s in summary:
        spread = f"{s['bytes_total_min']}..{s['bytes_total_max']}"
        print(f"| {s['system']:<8} | {s['scenario']:<12} | {s['conversations']:>4} | "
              f"{s['bytes_total_median']:>14} | {spread:>15} | {s['duration_s_median']:>15} |")
    print(f"\nwrote {SUMMARY_CSV}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
