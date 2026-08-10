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
    m = re.match(r"m(\d+)p(\d+)(x)?(a10k|a1m|ascr|aimg|adoc)?(-fwd|-br)?$", scenario)
    if not m:
        return scenario
    msgs, parts = int(m.group(1)), int(m.group(2))
    cross, attach, mod = m.group(3), m.group(4), m.group(5)
    bits = []
    if msgs == 1:
        bits.append(f"one message to {parts - 1} recipient{'s' if parts > 2 else ''}")
    else:
        bits.append(f"{msgs} messages between {parts} participants, each a reply to the previous")
    if cross:
        bits.append("recipients on two different domains")
    if attach == "a10k":
        bits.append("first message carries a 10 KiB attachment")
    if attach == "a1m":
        bits.append("first message carries a 1 MiB attachment")
    if attach == "ascr":
        bits.append("first message carries a realistic screenshot (PNG, ~336 kB)")
    if attach == "aimg":
        bits.append("first message carries a realistic photo (JPG, ~1.0 MB)")
    if attach == "adoc":
        bits.append("first message carries a realistic document (ODT, ~377 kB)")
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

    add("## Protocol capability differences")
    add("")
    add("Not every scenario maps onto every system — a '—' in the tables is often")
    add("a capability gap, not a missing measurement:")
    add("")
    add("| capability | fmsg | email | whatsapp |")
    add("|---|---|---|---|")
    add("| multiple recipients on one message | native; one transfer per recipient *domain* | native (To/Cc); one transaction per destination server | not supported — nearest equivalent is a group chat |")
    add("| bring a participant into an already-sent message | native (`add-to`): header-only, data never retransmitted | only by forwarding — the full message incl. attachments is re-sent | not supported; adding someone to a group shares no history |")
    add("| branching conversations | native: any message can be replied to, forming a DAG (32-byte parent reference) | supported via threading headers; each reply re-quotes history | flat chat; quoted replies reference but do not branch |")
    add("| binary attachments | raw binary on the wire | base64-encoded (+33%) inside MIME | encrypted media upload (server dedupes repeat content) |")
    add("| reply context | 32-byte parent hash | full quoted history re-sent each reply | quote metadata only |")
    add("")
    add("## Method notes & caveats")
    add("")
    add("- **fmsg**: real production hosts on three domains spanning the world,")
    add("  host-to-host fmsg (TCP 4930) captured at the local host and filtered to")
    add("  the remote host's IPs. Challenge mode is the fmsgd default")
    add("  (HAS_NOT_PARTICIPATED): only first-contact messages incur the")
    add("  challenge-response second connection. TLS uses production certificate")
    add("  chains with session resumption — connections after the first to a")
    add("  given host resume and skip the certificate exchange. Timings cross")
    add("  the real internet — indicative, like email's.")
    add("- **email**: self-hosted mailcow ↔ Gmail (and, in cross-provider")
    add("  scenarios, ↔ Outlook via Microsoft Graph) over the public internet.")
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
    add("- Message bodies are natural-language text cut to exactly 120 bytes each;")
    add("  attachments are incompressible random bytes (regenerable from a fixed")
    add("  seed; unique per repetition on WhatsApp, which dedupes repeat media).")
    add("- Repetitions: fmsg and email run one repetition per scenario — their")
    add("  byte counts are stable across runs; whatsapp runs five (medians")
    add("  reported, idle baseline subtracted). Timings vary — treat every")
    add("  duration as indicative.")
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
    add("./bench.sh fmsg          # real hosts — needs ~/.config/fmsg-bench/fmsg.env")
    add("./bench.sh email         # needs mailcow + Gmail OAuth (see README)")
    add("./drivers/whatsapp/baseline.sh && ./bench.sh whatsapp")
    add("python3 analysis/summarize.py && python3 analysis/charts.py && python3 analysis/report.py")
    add("```")

    out = os.path.join(RESULTS, "report.md")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
