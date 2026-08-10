# fmsg-bench

Benchmark harness producing the numbers for the fmsg white paper's
"Real World Comparison" section: bytes over the wire (including TLS
framing) and time taken, for **fmsg** vs **email (SMTP)** vs
**WhatsApp**, across a matrix of messaging scenarios. All three systems
are measured over the real internet. (A containerised two-domain fmsg
lab is also included as a fully replicable environment, though the
published results are all real-internet.)

Results: [`results/report.md`](results/report.md) ·
blog write-up: [`results/blog-summary.md`](results/blog-summary.md)

## Method (summary)

- One packet capture per (system, scenario, repetition), retained under
  `results/pcaps/` with per-conversation JSON.
- **Bytes**: total frame bytes of all matching TCP and UDP conversations
  in the capture (WhatsApp media rides QUIC), both directions reported
  separately and summed. A secondary `tls_bytes_total` column (transport
  payload bytes) lets readers subtract TCP/IP overhead.
- **Time**: first SYN to last FIN in the capture (falling back to
  first/last packet for connection-reuse and UDP). Single host per
  capture, so one clock.
- Message bodies are natural-language text cut to exactly 120 bytes;
  attachments are either incompressible random bytes (regenerable from a
  fixed seed) or realistic files (screenshot/photo/document, not
  committed). WhatsApp gets a unique payload per repetition because its
  servers deduplicate repeat media.
- Scenario descriptions are neutral user actions; protocol behaviour
  differences are surfaced by the results analysis, not baked into the
  tests.
- Repetitions: fmsg and email run 1 per scenario (their byte counts are
  stable across runs); WhatsApp runs 5 (analysis reports median, min,
  max). Repetitions are **additive**: a rep already in `results.csv` is
  skipped on re-run, so new scenarios extend the dataset without
  disturbing it.

Per-system measurement points:

| System | What is captured | Where |
|---|---|---|
| fmsg | host-to-host fmsg protocol, TCP 4930, between real production hosts on three domains spanning the world | interface of the local fmsg host, filtered to the remote hosts' IPs |
| fmsg-lab *(optional, not in published results)* | the same protocol between two containerised stacks on one machine | bridge of the two-stack container lab |
| email | host-to-host SMTP: self-hosted mailcow ↔ Gmail ↔ Outlook (relay outbound on port 2525, inbound port 25 filtered to provider netblocks) | WAN interface of the mail host |
| whatsapp | client ↔ Meta traffic, TCP+UDP, idle-baseline-subtracted (no host-to-host wire exists) | dedicated bridge of the bot container |

Caveats (also in the report): every leg crosses the public internet so
timings are indicative, not replicable — byte counts are the stable,
comparable metric. fmsg numbers include challenge-response verification
under fmsgd's default `HAS_NOT_PARTICIPATED` mode (a second connection
on first contact per thread) and reflect fmsgd's TLS session resumption
(connections after the first to a given host skip the certificate
exchange). WhatsApp numbers are client-side;
automation uses whatsapp-web.js. Email replies are generated via the
Gmail API / Microsoft Graph with standard threading headers and full
quoted history, as real clients produce.

## Prerequisites

- docker, or podman (rootless is fine; the compose provider needs the
  API socket: `systemctl --user enable --now podman.socket`)
- Go 1.24+ (builds `fmsg` CLI from the sibling `../fmsg-cli` checkout)
- `jq`, `python3`, `tcpdump`, `dig`; `tshark` is optional — extract.py
  falls back to a built-in classic-pcap parser producing identical
  numbers; `matplotlib` for charts
- capture privileges: passwordless sudo for tcpdump on capture hosts —
  except with rootless podman, where capture runs inside the user
  namespace (`podman unshare --rootless-netns`) and needs no privileges
- deployment specifics (hosts, accounts, keys, tokens) live in
  `~/.config/fmsg-bench/*.env` — never in the repo

## Quick start

Replicable lab (no accounts needed beyond the sibling repos):

```sh
./scenarios/gen-payloads.sh            # one-time: create payload files
./drivers/fmsg-lab/lab-up.sh           # start the two-domain container lab
./versions.sh                          # record software versions
./bench.sh fmsg-lab m1p2 m1p2a10k      # run scenarios (default 5 reps; --reps N)
./bench.sh fmsg-lab                    # ... or the whole core matrix
./drivers/fmsg-lab/lab-down.sh         # tear down
```

Real-system legs (each needs one-time setup, see the driver headers):

```sh
./bench.sh fmsg       # real fmsg hosts        — ~/.config/fmsg-bench/fmsg.env
./bench.sh email      # mailcow+Gmail+Outlook  — email.env, Gmail OAuth, Graph device login
./drivers/whatsapp/baseline.sh && ./bench.sh whatsapp   # paired whatsapp-web.js bots
```

Then regenerate the analysis:

```sh
python3 analysis/summarize.py && python3 analysis/charts.py && python3 analysis/report.py
```

Results append to `results/results.csv`; raw pcaps and per-conversation
JSON live under `results/pcaps/<system>/<scenario>/`.

## Scenario IDs

`m<N>p<P>[x][a10k|a1m|ascr|aimg|adoc][-fwd|-br]`

- `m<N>` — total messages exchanged (each message after the first is a
  reply to the previous one; round-robin senders when P > 2)
- `p<P>` — participants (1 sender + P−1 recipients)
- `x` — recipients on different domains/providers
- `a10k` / `a1m` — first message carries a 10 KiB / 1 MiB incompressible
  attachment; `ascr` / `aimg` / `adoc` — a realistic screenshot / photo /
  document
- `-fwd` — after the exchange, an additional participant is brought into
  the existing message (fmsg `add-to`, email forward; no WhatsApp
  equivalent)
- `-br` — the final two messages are both replies to the *first* message
  rather than a chain

The matrix is defined in `scenarios/scenarios.tsv` — the single source
of truth for all system drivers, including per-system comparability
notes.

## Layout

```
bench.sh            orchestrator: capture + run + extract per rep (additive)
versions.sh         record software versions for the paper's appendix
lib/                shared helpers: capture (local/rootless/ssh), bodies,
                    fmsg scenario logic shared by both fmsg drivers
scenarios/          scenarios.tsv + payload generator
drivers/fmsg/       real-host fmsg driver (config-driven participants)
drivers/fmsg-lab/   containerised two-domain lab + its driver
drivers/email/      mailcow submission/IMAP, Gmail API + Microsoft Graph
                    responders, OAuth bootstraps
drivers/whatsapp/   whatsapp-web.js bot + autonomous responder + baseline
capture/            extract.py: pcap -> results.csv row (+ streams JSON)
results/            results.csv, summary.csv, report.md, blog-summary.md,
                    charts/, versions.txt, pcaps/ (local only)
analysis/           summarize, charts, report generators
```
