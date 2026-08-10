# How many bytes does a message really cost? fmsg vs email vs WhatsApp

I benchmarked three ways of sending a message — [fmsg](https://fmsg.io) (an
open host-to-host messaging protocol), email (SMTP), and WhatsApp — and
measured what actually crosses the wire: every frame, TLS handshakes and
all, from first SYN to last FIN. All three ran over the real internet:
fmsg between production hosts on three domains spanning opposite sides of
the world, email between a self-hosted mail server, Gmail, and Outlook,
and WhatsApp between two phones' linked clients. The harness, raw data,
and charts are in [fmsg-bench](https://github.com/markmnl/fmsg-bench).

## Method in one paragraph

Every scenario sends the same content on every system: natural-language
message bodies of exactly 120 bytes, identical attachments, five
repetitions (medians reported; email one repetition — its byte counts are
stable). fmsg and email were captured host-to-host at the local host's
network interface; WhatsApp has no observable host-to-host wire, so its
numbers are the client's traffic to Meta's servers (TCP and UDP — media
rides QUIC) less an idle baseline. Scenario IDs read like `m5p2`: 5
messages, 2 participants; `a1m` = 1 MiB attachment; `x` = recipients on
different domains; `-fwd` = bring a third participant into an existing
message. A separately reported lab column (`fmsg-lab`, two containerised
stacks on one machine) provides a fully replicable baseline for fmsg.

## Conversations

| messages exchanged | fmsg | email | whatsapp |
|---|---|---|---|
| 1 | 16.4 kB | 12.9 kB | 4.8 kB |
| 5 | 49.7 kB | 70.8 kB | 26.0 kB |
| 20 | 175 kB | 334 kB | 132 kB |
| **200** | **1.68 MB** | **18.19 MB** | **1.19 MB** |

![conversation growth](charts/conversation-growth.svg)

WhatsApp is cheapest per message — one long-lived multiplexed connection.
fmsg pays a TLS handshake per message but stays **linear**: a reply
references its parent by a 32-byte hash, so message 200 costs the same as
message 2 (five repetitions of the 200-message conversation landed within
±0.1% of each other). Email's replies quote the entire history each time,
so its per-message cost *grows* — by 200 messages it is paying ~91 kB per
message and the conversation has cost **10× fmsg**. And that is with
120-byte messages; the gap widens with longer ones.

## Attachments

| attachment | fmsg | email | whatsapp |
|---|---|---|---|
| 1 MiB (incompressible) | 1.12 MB | 1.51 MB | 1.14 MB |
| screenshot, 336 kB PNG | 368 kB | 496 kB | 45.7 kB |
| photo, 1.02 MB JPG | 1.09 MB | 1.47 MB | **59.3 kB** |
| document, 377 kB ODT | 414 kB | 555 kB | 419 kB |

fmsg sends raw binary: a few percent of framing over the file itself.
Email still base64-encodes everything inside MIME: **+33% on every
attachment, every hop**. WhatsApp's numbers hide a trade: images pass
through its native pipeline and get recompressed — the 1 MB photo
travelled as 59 kB, quality silently traded for bandwidth — while
documents upload verbatim (and its servers deduplicate repeat content:
sending the same file twice never uploads it again).

## Bringing someone into a conversation

| action | fmsg | email | whatsapp |
|---|---|---|---|
| add a participant to a sent 1 MiB message | **+19 kB** | +1.51 MB | not supported |

This is where protocol design diverges most. fmsg's `add-to` re-sends
only a header; hosts that already hold the message answer "skip the
data", so the attachment never travels again — the newcomer's host
fetches what it lacks and everyone's thread is intact. Email can only
*forward*: the entire MIME body, base64 attachment included, is
re-transmitted — ~80× the bytes here. WhatsApp has no equivalent at all:
adding someone to a group shares no history with them.

## Recipients on different domains

| scenario | fmsg | email |
|---|---|---|
| 1 message → 2 recipients, same remote domain | 16.4 kB | 13.2 kB |
| 1 message → 2 recipients, different domains | 32.8 kB | 13.5 kB |
| 10-message conversation, 4 participants, 3 domains | 150 kB | 164 kB |

fmsg opens one connection per recipient *domain* from the sender's own
host — visible on the wire as double cost for two domains. The email
sender's wire barely moves because a smarthost relay accepts one
transaction and performs the per-provider fan-out downstream, out of
sight (self-hosted mail on residential connections must relay — ISPs
block direct SMTP). Over a full three-domain conversation the totals
converge; the difference is *where* the fan-out happens and who carries
it. WhatsApp has no notion of domains — every message goes to Meta.

## Capability differences at a glance

| capability | fmsg | email | whatsapp |
|---|---|---|---|
| multiple recipients, one message | native; one transfer per domain | native (To/Cc); relay/server fan-out | groups only |
| add participant to a sent message | native, header-only | full re-send (forward) | not supported, no history |
| branching threads | native DAG (32-byte parent ref) | threading headers + re-quoted history | flat chat, quote metadata |
| attachments | raw binary | base64 (+33%) | encrypted upload; images recompressed; dedup |
| federation | any domain, direct host-to-host | any domain, via MX/relays | single closed operator |

## Caveats, honestly

Byte counts proved highly stable across repetitions on every system;
timings cross the real internet and third-party infrastructure and are
indicative only. fmsg numbers include its challenge-response verification
(a second TLS connection on first contact per thread, under the default
`HAS_NOT_PARTICIPATED` mode). WhatsApp is a closed platform: only
client↔server traffic is measurable, automation used whatsapp-web.js
(against WhatsApp's ToS — tiny volumes, human-like pacing), and extra
"participants" are a group with one real second account. Email's Outlook
participant runs via Microsoft Graph; its Gmail participant via the Gmail
API; both reply with standard threading headers and full quoted history,
as real clients do. Every scenario, command, and software version needed
to replicate is in the repo.

Full tables, figures, per-repetition data and retained packet captures:
[fmsg-bench](https://github.com/markmnl/fmsg-bench).
