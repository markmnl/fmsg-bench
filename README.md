# fmsg-bench

Benchmark harness producing the numbers for the fmsg white paper's
"Real World Comparison" section: bytes over the wire (including TLS
framing) and time taken, for **fmsg** vs **email (SMTP)** vs
**WhatsApp**, across a matrix of messaging scenarios.

## Method (summary)

- One packet capture per (system, scenario, repetition), retained under
  `results/pcaps/`.
- **Bytes**: total frame bytes of all matching TCP conversations in the
  capture, both directions reported separately and summed. A secondary
  `tls_bytes_total` column (sum of TCP payload bytes, i.e. TLS record
  bytes) lets readers subtract TCP/IP overhead.
- **Time**: first SYN to last FIN in the capture. Single host per
  capture, so one clock.
- Scenario descriptions are neutral user actions; protocol behaviour
  differences are surfaced by the results analysis, not baked into the
  tests.
- 5 repetitions per scenario; analysis reports median, min, max.

Per-system measurement points:

| System | What is captured | Where |
|---|---|---|
| fmsg | host-to-host fmsg protocol, TCP 4930, between two real hosts on opposite sides of the world | interface of the local fmsg host, filtered to the remote host's IPs |
| fmsg-lab | the same protocol between two containerised stacks (replicable) | bridge of the two-stack container lab |
| email | host-to-host SMTP, TCP 25, mailcow ↔ Gmail | WAN interface of the mailcow host |
| whatsapp | client ↔ Meta TLS traffic (no host-to-host wire exists) | dedicated bridge of the bot container |

Caveats (also to appear in the paper): email and WhatsApp legs cross the
public internet so their timings are indicative, not replicable; WhatsApp
numbers are client-side and have an idle-baseline subtracted; fmsgd's
challenge-response is always on and is included in fmsg numbers (also
reported separately per conversation).

## Prerequisites

- docker, or podman (rootless is fine; the compose provider needs the
  API socket: `systemctl --user enable --now podman.socket`)
- Go 1.24+ (builds `fmsg` CLI from the sibling `../fmsg-cli` checkout)
- `jq`, `python3`, `tcpdump`; `tshark` is optional — extract.py falls
  back to a built-in classic-pcap parser producing identical numbers
- capture privileges: root/passwordless sudo for tcpdump — except with
  rootless podman, where capture runs inside the user namespace
  (`podman unshare --rootless-netns`) and needs no privileges at all
- the sibling repos of this workspace checked out (`../fmsg-docker`,
  `../fmsg-cli`, …)

## Quick start (fmsg lab)

```sh
./scenarios/gen-payloads.sh            # one-time: create payload files
./drivers/fmsg-lab/lab-up.sh           # start the two-domain container lab
./versions.sh                          # record software versions
./bench.sh fmsg-lab m1p2 m1p2a10k      # run scenarios (5 reps each)
./bench.sh fmsg-lab                    # ... or the whole core matrix
./drivers/fmsg-lab/lab-down.sh         # tear down
```

The `fmsg` system instead targets two real fmsg hosts; configure
participants, webapi endpoints, API keys and the capture host in
`~/.config/fmsg-bench/fmsg.env` (see `drivers/fmsg/driver.sh`).

Results append to `results/results.csv`; raw pcaps and per-conversation
JSON live under `results/pcaps/<system>/<scenario>/`.

## Scenario IDs

`m<N>p<P>[a10k|a1m][-fwd|-br]`

- `m<N>` — total messages exchanged (each message after the first is a
  reply to the previous one)
- `p<P>` — participants (1 sender + P−1 recipients)
- `a10k` / `a1m` — first message carries one 10 KiB / 1 MiB attachment
- `-fwd` — after the exchange, an additional participant is brought into
  the existing message
- `-br` — the final two messages are both replies to the *first* message
  rather than a chain

The matrix is defined in `scenarios/scenarios.tsv` — the single source
of truth for all system drivers.

## Layout

```
bench.sh          orchestrator: capture + run + extract per rep
versions.sh       record software versions for the paper's appendix
lib/              shared bash helpers (capture, common)
scenarios/        scenarios.tsv + payload generator
drivers/fmsg/     two-domain lab + fmsg-cli driver
drivers/email/    (M3) mailcow send + Gmail API responder
drivers/whatsapp/ (M4) whatsapp-web.js bot + responder
capture/          extract.py: pcap -> results.csv row
results/          results.csv, versions.txt, pcaps/
analysis/         (M5) summarize, charts, report
```
