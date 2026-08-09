#!/usr/bin/env bash
# Generate the fixed payload files every system sends.
#
# Attachments are deterministic but incompressible: a SHA-256 counter
# stream seeded with a fixed string, so anyone can regenerate
# byte-identical files without them being committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/payloads"
mkdir -p "$OUT_DIR"

# 120-byte reference body. Drivers build each message's actual body as
# "<scenario> r<rep> m<n>" padded with '.' to exactly 120 bytes so every
# system sends the same-size unique body per message.
printf '%s' \
  "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly beside the old riverbank at dawn." \
  > "$OUT_DIR/body-120B.txt"
BODY_LEN=$(wc -c < "$OUT_DIR/body-120B.txt")
if [ "$BODY_LEN" -ne 120 ]; then
  echo "body-120B.txt is $BODY_LEN bytes, expected 120" >&2
  exit 1
fi

gen_bin() {
  local size_bytes="$1"
  local out="$2"
  python3 - "$size_bytes" "$out" <<'PY'
import hashlib, sys
size, out = int(sys.argv[1]), sys.argv[2]
seed = b"fmsg-bench-v1"
with open(out, "wb") as f:
    written = 0
    counter = 0
    while written < size:
        block = hashlib.sha256(seed + counter.to_bytes(8, "little")).digest()
        take = min(len(block), size - written)
        f.write(block[:take])
        written += take
        counter += 1
PY
}

gen_bin 10240   "$OUT_DIR/attach-10KiB.bin"
gen_bin 1048576 "$OUT_DIR/attach-1MiB.bin"

sha256sum "$OUT_DIR"/* > "$OUT_DIR/checksums.txt"
echo "payloads written to $OUT_DIR:"
cat "$OUT_DIR/checksums.txt"
