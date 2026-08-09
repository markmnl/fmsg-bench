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

# Message bodies are "<scenario> r<rep> m<n>" padded with '.' to exactly
# 120 bytes so every system sends a same-size, per-message-unique body.
BODY_SIZE=120

msg_tag() {
  local scenario="$1" rep="$2" n="$3"
  printf '%s r%s m%s' "$scenario" "$rep" "$n"
}

msg_body() {
  local tag pad_len
  tag="$(msg_tag "$@")"
  pad_len=$((BODY_SIZE - ${#tag}))
  [ "$pad_len" -ge 0 ] || fail "message tag longer than body size: $tag"
  printf '%s%s' "$tag" "$(printf '%*s' "$pad_len" '' | tr ' ' '.')"
}

# now_ms: epoch milliseconds, for meta timestamps.
now_ms() {
  date +%s%3N
}
