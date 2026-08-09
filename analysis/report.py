#!/usr/bin/env python3
"""Generate results/report.md — white-paper-ready tables, caveats and
replication appendix from summary.csv + versions.txt.

Run summarize.py (and charts.py) first.
"""

import csv
import os
import re

BENCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(BENCH_ROOT, "results")

SYSTEM_ORDER = ["fmsg", "email", "whatsapp"]


def describe(scenario: str) -> str:
    """Neutral user-action description generated from the ID grammar."""
    m = re.match(r"m(\d+)p(\d+)(a10k|a1m)?(-fwd|-br)?$", scenario)
    if not m:
        return scenario
    msgs, parts, attach, mod = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
    bits = []
    if msgs == 1:
        bits.append(f"one message to {parts - 1} recipient{'s' if parts > 2 else ''}")
    else:
        bits.append(f"{msgs} messages between {parts} participants, each a reply to the previous")
    if attach == "a10k":
        bits.append("first message carries a 10 KiB attachment")
    if attach == "a1m":
        bits.append("first message carries a 1 MiB attachment")
    if mod == "-fwd":
        bits.append("then an additional participant is brought into the message")
    if mod == "-br":
        bits.append("the final two messages are both replies to the first message")
    return "; ".join(bits)


def human(n) -> str:
    n = int(n)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f} MB"
    if n >= 1_000:
        return f"{n / 1_000:.1f} kB"
    return f"{n} B"


def main():
    with open(os.path.join(RESULTS, "summary.csv"), newline="") as f:
        rows = list(csv.DictReader(f))
    data = {(r["system"], r["scenario"]): r for r in rows}
    scenarios = list(dict.fromkeys(r["scenario"] for r in rows))
    systems = [s for s in SYSTEM_ORDER if any(k[0] == s for k in data)]

    lines = []
    add = lines.append
    add("# fmsg-bench results")
    add("")
    add("Bytes over the wire (including TLS framing; total frame bytes of all")
    add("TCP conversations, both directions) and first-SYN-to-last-FIN duration,")
    add("median of the repetitions per scenario. Raw per-repetition data:")
    add("`results.csv`; per-conversation detail: `pcaps/*/*/repN.streams.json`.")
    add("")

    add("## Table 1 — bytes over the wire")
    add("")
    header = "| ID | Scenario (user action) | " + " | ".join(systems) + " |"
    add(header)
    add("|" + "---|" * (2 + len(systems)))
    for sc in scenarios:
        cells = []
        for sys_name in systems:
            r = data.get((sys_name, sc))
            cells.append(human(r["bytes_total_median"]) if r else "—")
        add(f"| {sc} | {describe(sc)} | " + " | ".join(cells) + " |")
    add("")

    add("## Table 2 — transmission time (seconds, median)")
    add("")
    add("| ID | " + " | ".join(systems) + " |")
    add("|" + "---|" * (1 + len(systems)))
    for sc in scenarios:
        cells = []
        for sys_name in systems:
            r = data.get((sys_name, sc))
            cells.append(r["duration_s_median"] if r else "—")
        add(f"| {sc} | " + " | ".join(cells) + " |")
    add("")

    add("## Figures")
    add("")
    for name in ("bytes-by-scenario", "conversation-growth", "fwd-cost"):
        if os.path.exists(os.path.join(RESULTS, "charts", f"{name}.svg")):
            add(f"![{name}](charts/{name}.svg)")
    add("")

    add("## Method notes & caveats")
    add("")
    add("- **fmsg**: two full stacks (two domains) as containers on one machine;")
    add("  capture on the shared bridge, TCP 4930. Includes the challenge-response")
    add("  second connection (always on in the tested fmsgd). Replicable.")
    add("- **email**: self-hosted mailcow ↔ Gmail over the public internet.")
    add("  Outbound leaves via a smarthost relay (port 2525) — typical for")
    add("  residential hosting where ISPs block direct port 25 — so the measured")
    add("  outbound hop is mailcow→relay; inbound is Gmail→mailcow on port 25,")
    add("  filtered to Google's published netblocks. Replies are generated via the")
    add("  Gmail API with standard threading headers and full quoted history.")
    add("  Timings cross the internet and Gmail's internals: indicative, not")
    add("  replicable. Submission (client→server) is excluded by design.")
    add("- **whatsapp**: closed platform — no host-to-host wire exists to observe.")
    add("  Numbers are the measured client's TLS traffic to Meta's servers, less an")
    add("  idle baseline (background chatter), captured on a dedicated container")
    add("  bridge. Automation via whatsapp-web.js (against WhatsApp ToS; tiny")
    add("  volumes, human-like pacing). Extra participants are aliases/groups of")
    add("  one benchmark account — see scenario notes.")
    add("- Message bodies are 120 bytes each; attachments are incompressible")
    add("  random bytes (regenerable from a fixed seed).")
    add("- Byte counts are stable across runs; timings vary — treat every duration")
    add("  as indicative.")
    add("")

    versions = os.path.join(RESULTS, "versions.txt")
    if os.path.exists(versions):
        add("## Appendix — software versions")
        add("")
        add("```")
        with open(versions) as f:
            add(f.read().rstrip())
        add("```")
        add("")

    add("## Appendix — replication")
    add("")
    add("```sh")
    add("./scenarios/gen-payloads.sh")
    add("./drivers/fmsg/lab-up.sh && ./bench.sh fmsg")
    add("./bench.sh email        # needs mailcow + Gmail OAuth (see README)")
    add("./drivers/whatsapp/baseline.sh && ./bench.sh whatsapp")
    add("python3 analysis/summarize.py && python3 analysis/charts.py && python3 analysis/report.py")
    add("```")

    out = os.path.join(RESULTS, "report.md")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
