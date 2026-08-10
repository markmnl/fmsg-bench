# fmsg-bench results

Bytes over the wire (including TLS framing; total frame bytes of all
TCP conversations, both directions) and first-SYN-to-last-FIN duration,
median of the repetitions per scenario. Raw per-repetition data:
`results.csv`; per-conversation detail: `pcaps/*/*/repN.streams.json`.

## Table 1 — bytes over the wire

| ID | Scenario (user action) | fmsg | fmsg-lab | email | whatsapp |
|---|---|---|---|---|---|
| m1p2 | one message to 1 recipient | 16.4 kB | 9.5 kB | 12.9 kB | 4.8 kB |
| m2p2 | 2 messages between 2 participants, each a reply to the previous | 24.8 kB | 19.3 kB | 27.8 kB | 6.1 kB |
| m3p2 | 3 messages between 2 participants, each a reply to the previous | 33.1 kB | 28.9 kB | 41.1 kB | 16.6 kB |
| m4p2 | 4 messages between 2 participants, each a reply to the previous | 41.5 kB | 38.6 kB | 57.0 kB | 17.4 kB |
| m5p2 | 5 messages between 2 participants, each a reply to the previous | 49.7 kB | 48.2 kB | 70.8 kB | 26.0 kB |
| m1p2a10k | one message to 1 recipient; first message carries a 10 KiB attachment | 27.2 kB | 20.3 kB | 28.4 kB | 26.8 kB |
| m1p2a1m | one message to 1 recipient; first message carries a 1 MiB attachment | 1.12 MB | 1.06 MB | 1.51 MB | 1.14 MB |
| m1p5 | one message to 4 recipients | — | 9.8 kB | 13.8 kB | 2.1 kB |
| m1p5a10k | one message to 4 recipients; first message carries a 10 KiB attachment | — | 20.3 kB | 29.1 kB | 23.2 kB |
| m1p5a1m | one message to 4 recipients; first message carries a 1 MiB attachment | — | 1.06 MB | 1.52 MB | 1.13 MB |
| m5p4 | 5 messages between 4 participants, each a reply to the previous | — | 48.4 kB | 73.3 kB | 218.8 kB |
| m1p2-fwd | one message to 1 recipient; then an additional participant is brought into the message | 32.4 kB | 19.1 kB | 26.2 kB | — |
| m1p2a1m-fwd | one message to 1 recipient; first message carries a 1 MiB attachment; then an additional participant is brought into the message | 1.14 MB | 1.07 MB | 3.02 MB | — |
| m3p2-br | 3 messages between 2 participants, each a reply to the previous; the final two messages are both replies to the first message | 33.3 kB | 29.0 kB | 42.5 kB | 13.9 kB |
| m10p2 | 10 messages between 2 participants, each a reply to the previous | 91.7 kB | 96.4 kB | 151.0 kB | 75.5 kB |
| m20p2 | 20 messages between 2 participants, each a reply to the previous | 175.4 kB | 193.0 kB | 333.8 kB | 132.4 kB |
| m200p2 | 200 messages between 2 participants, each a reply to the previous | 1.68 MB | — | 18.19 MB | 1.19 MB |
| m1p2ascr | one message to 1 recipient; first message carries a realistic screenshot (PNG, ~336 kB) | 367.9 kB | — | 496.4 kB | 45.7 kB |
| m1p2aimg | one message to 1 recipient; first message carries a realistic photo (JPG, ~1.0 MB) | 1.09 MB | — | 1.47 MB | 59.3 kB |
| m1p2adoc | one message to 1 recipient; first message carries a realistic document (ODT, ~377 kB) | 414.0 kB | — | 555.4 kB | 418.6 kB |
| m1p3 | one message to 2 recipients | 16.4 kB | — | 13.2 kB | — |
| m1p3x | one message to 2 recipients; recipients on two different domains | 32.8 kB | — | 13.5 kB | — |
| m10p4x | 10 messages between 4 participants, each a reply to the previous; recipients on two different domains | 150.1 kB | — | 164.0 kB | — |
| m10p3x | 10 messages between 3 participants, each a reply to the previous; recipients on two different domains | 133.4 kB | — | — | — |

## Table 2 — transmission time (seconds, median)

| ID | fmsg | fmsg-lab | email | whatsapp |
|---|---|---|---|---|
| m1p2 | 1.4324 | 0.0288 | 1.3827 | 1.6954 |
| m2p2 | 6.7129 | 0.6149 | 23.3177 | 4.1779 |
| m3p2 | 9.7235 | 1.1891 | 26.2042 | 5.8974 |
| m4p2 | 14.0143 | 1.7611 | 40.8344 | 6.3253 |
| m5p2 | 17.7455 | 2.3366 | 45.672 | 6.8419 |
| m1p2a10k | 1.4391 | 0.0293 | 0.9072 | 5.2004 |
| m1p2a1m | 2.6307 | 0.0316 | 1.2637 | 6.5225 |
| m1p5 | — | 0.0554 | 1.3889 | 1.9718 |
| m1p5a10k | — | 0.059 | 0.8846 | 5.2287 |
| m1p5a1m | — | 0.0585 | 1.8043 | 5.8949 |
| m5p4 | — | 2.4878 | 41.8344 | 14.7419 |
| m1p2-fwd | 3.3794 | 0.6042 | 13.4826 | — |
| m1p2a1m-fwd | 4.9249 | 0.6126 | 27.4861 | — |
| m3p2-br | 9.8816 | 1.2173 | 29.3919 | 6.8302 |
| m10p2 | 38.147 | 5.2154 | 103.2229 | 25.8924 |
| m20p2 | 78.3173 | 10.7383 | 203.5202 | 63.6502 |
| m200p2 | 706.3895 | — | 2559.3081 | 357.2406 |
| m1p2ascr | 2.1813 | — | 1.1264 | 4.1428 |
| m1p2aimg | 2.6873 | — | 1.2726 | 4.3586 |
| m1p2adoc | 2.2604 | — | 1.1395 | 3.4754 |
| m1p3 | 1.442 | — | 1.0269 | — |
| m1p3x | 7.0316 | — | 2.9038 | — |
| m10p4x | 107.1787 | — | 84.102 | — |
| m10p3x | 104.7156 | — | — | — |

## Figures

![bytes-by-scenario](charts/bytes-by-scenario.svg)
![conversation-growth](charts/conversation-growth.svg)
![fwd-cost](charts/fwd-cost.svg)

## Protocol capability differences

Not every scenario maps onto every system — a '—' in the tables is often
a capability gap, not a missing measurement:

| capability | fmsg | email | whatsapp |
|---|---|---|---|
| multiple recipients on one message | native; one transfer per recipient *domain* | native (To/Cc); one transaction per destination server | not supported — nearest equivalent is a group chat |
| bring a participant into an already-sent message | native (`add-to`): header-only, data never retransmitted | only by forwarding — the full message incl. attachments is re-sent | not supported; adding someone to a group shares no history |
| branching conversations | native: any message can be replied to, forming a DAG (32-byte parent reference) | supported via threading headers; each reply re-quotes history | flat chat; quoted replies reference but do not branch |
| binary attachments | raw binary on the wire | base64-encoded (+33%) inside MIME | encrypted media upload (server dedupes repeat content) |
| reply context | 32-byte parent hash | full quoted history re-sent each reply | quote metadata only |

## Method notes & caveats

- **fmsg**: two REAL production hosts on opposite sides of the world,
  host-to-host fmsg (TCP 4930) captured at the local host and filtered to
  the remote host's IPs. Challenge mode is the fmsgd default
  (HAS_NOT_PARTICIPATED): only first-contact messages incur the
  challenge-response second connection. TLS uses production certificate
  chains. Timings cross the real internet — indicative, like email's.
- **fmsg-lab**: the same protocol between two containerised stacks on one
  machine (self-signed certs, challenge ALWAYS, LAN-free bridge) — the
  fully replicable environment. Byte differences vs fmsg are certificate
  chain size and challenge frequency.
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
- Message bodies are natural-language text cut to exactly 120 bytes each;
  attachments are incompressible random bytes (regenerable from a fixed
  seed; unique per repetition on WhatsApp, which dedupes repeat media).
- Byte counts are stable across runs; timings vary — treat every duration
  as indicative.

## Appendix — software versions

```
recorded: 2026-08-10T00:47:46Z
host: Linux 7.1.4-204.fc44.x86_64 x86_64 GNU/Linux

## workspace repos
fmsg-spec: d8e9446 (2026-08-09)
fmsgd: 59cb7eb (2026-08-09)
fmsg-webapi: 9a5451e (2026-08-05)
fmsgid: 5a74176 (2026-08-03)
fmsg-cli: f450ba5 (2026-08-05)
fmsg-docker: ce2ec75 (2026-08-10)
fmsg-bench: 1cb1514 (2026-08-09)

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
./bench.sh fmsg          # real hosts — needs ~/.config/fmsg-bench/fmsg.env
./drivers/fmsg-lab/lab-up.sh && ./bench.sh fmsg-lab   # replicable lab
./bench.sh email         # needs mailcow + Gmail OAuth (see README)
./drivers/whatsapp/baseline.sh && ./bench.sh whatsapp
python3 analysis/summarize.py && python3 analysis/charts.py && python3 analysis/report.py
```
