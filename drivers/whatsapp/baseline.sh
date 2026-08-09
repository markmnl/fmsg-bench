#!/usr/bin/env bash
# Measure the wa-bot container's idle background traffic (keepalives,
# presence sync) so scenario captures can be baseline-adjusted.
# Writes bytes/s to .state/wa-baseline.bps.
#
# Usage: ./baseline.sh [seconds]   (default 90)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/../../lib/capture.sh"

SECONDS_TO_CAPTURE="${1:-90}"
PCAP="$STATE_DIR/wa-baseline.pcap"
mkdir -p "$STATE_DIR"

IFACE="$(resolve_network_iface wa-bench)"
FILTER="not port 3999 and not port 53 and (tcp or udp)"

log "Capturing $SECONDS_TO_CAPTURE s of idle traffic on $IFACE..."
start_capture "$IFACE" "$FILTER" "$PCAP"
sleep "$SECONDS_TO_CAPTURE"
stop_capture

python3 - "$PCAP" "$SECONDS_TO_CAPTURE" "$STATE_DIR/wa-baseline.bps" "$BENCH_ROOT/capture" <<'PY'
import sys
pcap, secs, out, capdir = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
sys.path.insert(0, capdir)
from extract import read_packets, aggregate_streams
rows = read_packets(pcap, [])
total = sum(sum(s["frame_bytes"].values())
            for s in aggregate_streams(rows).values())
bps = total / secs
with open(out, "w") as f:
    f.write(f"{bps:.2f}\n")
print(f"idle baseline: {total} bytes over {secs:.0f}s = {bps:.2f} B/s -> {out}")
PY
