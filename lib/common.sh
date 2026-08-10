#!/usr/bin/env bash
# Shared helpers for bench scripts.

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$BENCH_ROOT/.." && pwd)"
RESULTS_DIR="$BENCH_ROOT/results"
PAYLOADS_DIR="$BENCH_ROOT/scenarios/payloads"
STATE_DIR="$BENCH_ROOT/.state"

# Container runtime: docker where available, else podman (whose
# `podman compose` delegates to a compose provider).
if command -v docker >/dev/null 2>&1; then
  CTR=docker
elif command -v podman >/dev/null 2>&1; then
  CTR=podman
else
  CTR=""
fi

log() {
  echo "==> $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
  done
}

# Message bodies are "<scenario> r<rep> m<n>" followed by natural-language
# text, cut to exactly 120 bytes so every system sends a same-size,
# per-message-unique body. The corpus is ASCII (bytes == chars) and is
# mirrored in drivers/whatsapp/lib.js — keep the two in sync.
BODY_SIZE=120

BODY_CORPUS=(
  "Hey, are we still on for coffee tomorrow morning before the standup?"
  "Just landed. The flight was delayed two hours but the sunset over the wing almost made up for it."
  "Can you send me the notes from yesterday? I want to double-check the figures before the review."
  "The garden is finally coming together. The tomatoes survived the frost after all."
  "I tried that recipe you mentioned and somehow burnt the rice twice. Teach me your ways."
  "Meeting moved to three. Same room, bring the printouts if you can."
  "Saw a kingfisher by the river this morning. First one in years around here."
  "The car is making that noise again. Booking it in for Thursday unless you need it."
  "Finished the book you lent me. The ending was not what I expected at all."
  "Rain forecast all weekend, so the hike is off. Movie marathon instead?"
  "Grandad says thanks for the photos. He printed one and put it on the mantel."
  "The quote came in higher than expected. I think we should get a second opinion."
  "New neighbours moved in next door. They have a dog that already likes me more than you do."
  "Power was out for an hour tonight. Candles, cards, and terrible ghost stories."
  "I fixed the leak under the sink. Only flooded the cupboard a little bit this time."
  "Tickets go on sale Friday at nine sharp. Set an alarm, they sold out fast last year."
)

msg_tag() {
  local scenario="$1" rep="$2" n="$3"
  printf '%s r%s m%s' "$scenario" "$rep" "$n"
}

msg_body() {
  local tag body i
  tag="$(msg_tag "$@")"
  body="$tag"
  i=$(( ($3 - 1) % ${#BODY_CORPUS[@]} ))
  while [ "${#body}" -lt "$BODY_SIZE" ]; do
    body="$body ${BODY_CORPUS[$i]}"
    i=$(( (i + 1) % ${#BODY_CORPUS[@]} ))
  done
  printf '%.*s' "$BODY_SIZE" "$body"
}

# now_ms: epoch milliseconds, for meta timestamps.
now_ms() {
  date +%s%3N
}
