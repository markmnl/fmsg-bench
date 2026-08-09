# fmsg-bench results

Bytes over the wire (including TLS framing; total frame bytes of all
TCP conversations, both directions) and first-SYN-to-last-FIN duration,
median of the repetitions per scenario. Raw per-repetition data:
`results.csv`; per-conversation detail: `pcaps/*/*/repN.streams.json`.

## Table 1 — bytes over the wire

| ID | Scenario (user action) | fmsg | email | whatsapp |
|---|---|---|---|---|
| m1p2 | one message to 1 recipient | 9.5 kB | 12.9 kB | 4.8 kB |
| m2p2 | 2 messages between 2 participants, each a reply to the previous | 19.3 kB | 27.8 kB | 6.1 kB |
| m3p2 | 3 messages between 2 participants, each a reply to the previous | 28.9 kB | 41.1 kB | 16.6 kB |
| m4p2 | 4 messages between 2 participants, each a reply to the previous | 38.6 kB | 57.0 kB | 17.4 kB |
| m5p2 | 5 messages between 2 participants, each a reply to the previous | 48.2 kB | 70.8 kB | 26.0 kB |
| m1p2a10k | one message to 1 recipient; first message carries a 10 KiB attachment | 20.3 kB | 28.4 kB | 26.8 kB |
| m1p2a1m | one message to 1 recipient; first message carries a 1 MiB attachment | 1.06 MB | 1.51 MB | 1.14 MB |
| m1p5 | one message to 4 recipients | 9.8 kB | 13.8 kB | 2.1 kB |
| m1p5a10k | one message to 4 recipients; first message carries a 10 KiB attachment | 20.3 kB | 29.1 kB | 23.2 kB |
| m1p5a1m | one message to 4 recipients; first message carries a 1 MiB attachment | 1.06 MB | 1.52 MB | 1.13 MB |
| m5p4 | 5 messages between 4 participants, each a reply to the previous | 48.4 kB | 73.3 kB | 218.8 kB |
| m1p2-fwd | one message to 1 recipient; then an additional participant is brought into the message | 19.1 kB | 26.2 kB | — |
| m1p2a1m-fwd | one message to 1 recipient; first message carries a 1 MiB attachment; then an additional participant is brought into the message | 1.07 MB | 3.02 MB | — |
| m3p2-br | 3 messages between 2 participants, each a reply to the previous; the final two messages are both replies to the first message | 29.0 kB | 42.5 kB | 13.9 kB |
| m10p2 | 10 messages between 2 participants, each a reply to the previous | 96.4 kB | 151.0 kB | 75.5 kB |
| m20p2 | 20 messages between 2 participants, each a reply to the previous | 193.0 kB | 333.8 kB | 132.4 kB |

## Table 2 — transmission time (seconds, median)

| ID | fmsg | email | whatsapp |
|---|---|---|---|
| m1p2 | 0.0288 | 1.3827 | 1.6954 |
| m2p2 | 0.6149 | 23.3177 | 4.1779 |
| m3p2 | 1.1891 | 26.2042 | 5.8974 |
| m4p2 | 1.7611 | 40.8344 | 6.3253 |
| m5p2 | 2.3366 | 45.672 | 6.8419 |
| m1p2a10k | 0.0293 | 0.9072 | 5.2004 |
| m1p2a1m | 0.0316 | 1.2637 | 6.5225 |
| m1p5 | 0.0554 | 1.3889 | 1.9718 |
| m1p5a10k | 0.059 | 0.8846 | 5.2287 |
| m1p5a1m | 0.0585 | 1.8043 | 5.8949 |
| m5p4 | 2.4878 | 41.8344 | 14.7419 |
| m1p2-fwd | 0.6042 | 13.4826 | — |
| m1p2a1m-fwd | 0.6126 | 27.4861 | — |
| m3p2-br | 1.2173 | 29.3919 | 6.8302 |
| m10p2 | 5.2154 | 103.2229 | 25.8924 |
| m20p2 | 10.7383 | 203.5202 | 63.6502 |

## Figures

![bytes-by-scenario](charts/bytes-by-scenario.svg)
![conversation-growth](charts/conversation-growth.svg)
![fwd-cost](charts/fwd-cost.svg)

## Method notes & caveats

- **fmsg**: two full stacks (two domains) as containers on one machine;
  capture on the shared bridge, TCP 4930. Includes the challenge-response
  second connection (always on in the tested fmsgd). Replicable.
- **email**: self-hosted mailcow ↔ Gmail over the public internet.
  Outbound leaves via a smarthost relay (port 2525) — typical for
  residential hosting where ISPs block direct port 25 — so the measured
  outbound hop is mailcow→relay; inbound is Gmail→mailcow on port 25,
  filtered to Google's published netblocks. Replies are generated via the
  Gmail API with standard threading headers and full quoted history.
  Timings cross the internet and Gmail's internals: indicative, not
  replicable. Submission (client→server) is excluded by design.
- **whatsapp**: closed platform — no host-to-host wire exists to observe.
  Numbers are the measured client's TLS traffic to Meta's servers, less an
  idle baseline (background chatter), captured on a dedicated container
  bridge. Automation via whatsapp-web.js (against WhatsApp ToS; tiny
  volumes, human-like pacing). Extra participants are aliases/groups of
  one benchmark account — see scenario notes.
- Message bodies are 120 bytes each; attachments are incompressible
  random bytes (regenerable from a fixed seed).
- Byte counts are stable across runs; timings vary — treat every duration
  as indicative.

## Appendix — software versions

```
recorded: 2026-08-09T10:31:17Z
host: Linux 7.1.4-204.fc44.x86_64 x86_64 GNU/Linux

## workspace repos
fmsg-spec: d8e9446 (2026-08-09)
fmsgd: b6a9d2a (2026-08-09)
fmsg-webapi: 9a5451e (2026-08-05)
fmsgid: 5a74176 (2026-08-03)
fmsg-cli: f450ba5 (2026-08-05)
fmsg-docker: 29bc006 (2026-08-05)
fmsg-bench: (not a git checkout)

## tools
tcpdump version 4.99.6
go version go1.26.4 linux/amd64
Python 3.14.6
jq-1.8.1

## payloads
bd2d6fbef9eee073ec42627be5c21857e5e13b2172c692049092be4356ff965f  /home/markmnl/github.com/fmsg/fmsg-bench/scenarios/payloads/attach-10KiB.bin
fab28477ff0ed0bfa700de7e1449f6e30ff6a7de9cff269d8995a77af0d46adb  /home/markmnl/github.com/fmsg/fmsg-bench/scenarios/payloads/attach-1MiB.bin
230391ff7e0219baa9df49685d8cc3389a0707d031ffe8f209961c9f45f804d8  /home/markmnl/github.com/fmsg/fmsg-bench/scenarios/payloads/body-120B.txt
```

## Appendix — replication

```sh
./scenarios/gen-payloads.sh
./drivers/fmsg/lab-up.sh && ./bench.sh fmsg
./bench.sh email        # needs mailcow + Gmail OAuth (see README)
./drivers/whatsapp/baseline.sh && ./bench.sh whatsapp
python3 analysis/summarize.py && python3 analysis/charts.py && python3 analysis/report.py
```
