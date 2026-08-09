# How many bytes does a message really cost? fmsg vs email vs WhatsApp

I benchmarked three ways of sending a message — [fmsg](https://fmsg.io) (an
open host-to-host messaging protocol), email (SMTP, self-hosted mailcow ↔
Gmail), and WhatsApp — and measured what actually crosses the wire: every
frame, TLS handshakes and all, from first SYN to last FIN. The harness,
raw data, and charts are in
[fmsg-bench](https://github.com/markmnl/fmsg-bench).

## Method in one paragraph

Every scenario sends byte-identical content on all three systems: 120-byte
message bodies, incompressible random attachments (10 KiB / 1 MiB), 5
repetitions, medians reported. fmsg ran as two full stacks on two domains
in containers, captured on the bridge between them — fully replicable.
Email ran from my self-hosted mailcow to Gmail over the real internet,
with replies generated via the Gmail API using standard threading headers
and full quoted history, exactly as a mail client would. WhatsApp has no
observable host-to-host wire, so its numbers are the client's traffic to
Meta's servers (TCP *and* UDP — more on that below), with idle background
chatter subtracted. Scenario IDs read like `m5p2`: 5 messages, 2
participants; `a1m` = 1 MiB attachment; `-fwd` = bring a third participant
into an existing message.

## The numbers

| scenario | fmsg | email | whatsapp |
|---|---|---|---|
| one message | 9.5 kB | 12.9 kB | 4.8 kB |
| 5-message conversation | 48.2 kB | 70.8 kB | 26.0 kB |
| 20-message conversation | 193 kB | 334 kB | 132 kB |
| one message, 4 recipients | 9.8 kB | 13.8 kB | 2.1 kB (group) |
| 1 MiB attachment | 1.06 MB | 1.51 MB | 1.14 MB |
| forward that attachment to a 3rd person | **+7.7 kB** | +1.51 MB | n/a |

![conversation growth](charts/conversation-growth.svg)

Three things stand out.

**Email's replies get heavier as the thread grows.** Each reply quotes the
whole history, so the per-message cost climbs — 14 kB/message early in a
thread, 18+ kB/message by message twenty, and that's with 120-byte bodies.
fmsg replies reference the parent by a 32-byte hash instead; its
per-message cost is a flat 9.7 kB, dominated by the TLS handshakes of its
per-message connections plus its built-in challenge-response round trip.
WhatsApp, riding one long-lived multiplexed connection, is the cheapest of
all at ~1.3–5 kB per exchange.

**Attachments: base64 is still with us.** A 1 MiB file costs email
1.51 MB on the wire — the +33% base64 tax plus MIME framing, paid again by
every hop that relays it. fmsg sends raw binary: 1.06 MB, about 1.6%
overhead. WhatsApp lands at ~1.14 MB (encrypted media upload over QUIC).

**Adding someone to a conversation is where the protocols really
diverge.** Email "forwards" by re-sending everything: another 1.51 MB.
fmsg's `add-to` re-sends only a header — the receiving host already has
the message and says "skip the data": 7.7 kB, roughly **196× cheaper**.
WhatsApp couldn't be measured here (see caveats), though group-add
famously transfers no history at all.

![bytes by scenario](charts/bytes-by-scenario.svg)

## Things the benchmark caught that I didn't plan for

- **A real fmsg bug.** The add-to-with-attachments scenario failed on the
  first run: fmsgd's skip-data path never mapped stored attachment paths
  into the hash reconstruction. Benchmark finds bug, bug gets fixed,
  scenario passes. This alone paid for the harness.
- **WhatsApp deduplicates media server-side.** Sending the same 1 MiB
  file twice never re-uploads it — early runs showed a "1 MiB attachment"
  costing 9 kB. The harness now sends a unique random file per repetition
  for a fair comparison (email and fmsg retransmit fully either way).
- **WhatsApp media rides QUIC.** The uploads were invisible to a TCP-only
  capture; the harness captures UDP too.
- **Email deliverability is fragile infrastructure.** Mid-campaign, my
  smarthost relay silently started dropping the benchmark's mail — the
  free-tier quota had run out. Residential ISPs block port 25, relays
  meter you, Gmail spam-folders repetitive traffic (the responder searches
  `in:anywhere` for a reason). None of this exists in fmsg's or WhatsApp's
  world.

## Caveats, honestly

fmsg's numbers come from a controlled lab and are replicable; its
challenge-response was always on (a second TLS connection per message —
generous to nobody). Email crossed the real internet through a smarthost
relay, so its **timings** are indicative, not replicable — though its byte
counts are stable. WhatsApp is a closed platform: client↔server traffic is
the only thing measurable, automation relies on whatsapp-web.js (which
fought back — broken message ids, broken chat listing, and no automatable
true-forward on the current WhatsApp Web build), and extra "participants"
are aliases and a group with one real second account. All durations
include each system's real-world checks and are not bandwidth math.

Full method, per-repetition data, retained packet captures, and
replication scripts: [fmsg-bench](https://github.com/markmnl/fmsg-bench).
