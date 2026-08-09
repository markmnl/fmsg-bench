#!/usr/bin/env bash
# =============================================================
# fmsg-bench orchestrator.
#
# Usage:
#   ./bench.sh <system> [scenario ...] [--reps N]
#
#   system      fmsg | email | whatsapp  (driver in drivers/<system>/)
#   scenario    ids from scenarios/scenarios.tsv; default: all "core"
#               rows that list the system in their systems column
#   --reps N    repetitions per scenario (default 5)
#
# Per repetition: start capture -> run scenario via the system driver
# -> stop capture -> extract metrics into results/results.csv.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/capture.sh"

REPS=5
SYSTEM=""
REQUESTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --reps)
      REPS="$2"
      shift 2
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      if [ -z "$SYSTEM" ]; then SYSTEM="$1"; else REQUESTED+=("$1"); fi
      shift
      ;;
  esac
done

[ -n "$SYSTEM" ] || fail "usage: ./bench.sh <system> [scenario ...] [--reps N]"
DRIVER="$SCRIPT_DIR/drivers/$SYSTEM/driver.sh"
[ -f "$DRIVER" ] || fail "no driver for system '$SYSTEM' ($DRIVER)"

require_cmd tcpdump python3 jq
command -v tshark >/dev/null 2>&1 \
  || log "note: tshark not found — extract.py will use its built-in pcap parser"
# shellcheck source=/dev/null
source "$DRIVER"

SCENARIOS_TSV="$SCRIPT_DIR/scenarios/scenarios.tsv"
RESULTS_CSV="$RESULTS_DIR/results.csv"

# ── Select scenario rows ─────────────────────────────────────
# Row: id, messages, participants, attach, modifier, tier, systems, notes
mapfile -t ROWS < <(tail -n +2 "$SCENARIOS_TSV" | grep -v '^\s*$')

selected_rows=()
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r id messages participants attach modifier tier systems notes <<<"$row"
  if [ "${#REQUESTED[@]}" -gt 0 ]; then
    match=false
    for want in "${REQUESTED[@]}"; do
      [ "$want" = "$id" ] && match=true
    done
    [ "$match" = "true" ] || continue
  else
    [ "$tier" = "core" ] || continue
    case ",$systems," in
      *",$SYSTEM,"*) ;;
      *) continue ;;
    esac
  fi
  selected_rows+=("$row")
done

[ "${#selected_rows[@]}" -gt 0 ] || fail "no scenarios selected"

# Requested ids that don't exist should fail loudly, not silently no-op.
for want in "${REQUESTED[@]+"${REQUESTED[@]}"}"; do
  found=false
  for row in "${selected_rows[@]}"; do
    [ "${row%%$'\t'*}" = "$want" ] && found=true
  done
  [ "$found" = "true" ] || fail "unknown scenario: $want"
done

# ── Init ─────────────────────────────────────────────────────
log "Initialising $SYSTEM driver..."
driver_init
driver_capture_spec
log "Capture: iface=$CAPTURE_IFACE filter='$CAPTURE_FILTER'"

EXTRACT_ARGS="$(driver_extract_args)"

# ── Run ──────────────────────────────────────────────────────
for row in "${selected_rows[@]}"; do
  IFS=$'\t' read -r id messages participants attach modifier tier systems notes <<<"$row"
  [ -n "$modifier" ] || modifier="-"
  [ -n "$attach" ] || attach="-"

  for rep in $(seq 1 "$REPS"); do
    log "$SYSTEM/$id rep $rep/$REPS"
    pcap="$RESULTS_DIR/pcaps/$SYSTEM/$id/rep${rep}.pcap"

    start_capture "$CAPTURE_IFACE" "$CAPTURE_FILTER" "$pcap"
    sleep 0.5
    started=$(now_ms)

    if ! driver_run_scenario "$id" "$messages" "$participants" "$attach" "$modifier" "$rep"; then
      stop_capture
      echo "FAILED: $SYSTEM/$id rep $rep (pcap kept at $pcap)" | tee -a "$RESULTS_DIR/failures.log" >&2
      break   # skip remaining reps of this scenario, continue campaign
    fi

    finished=$(now_ms)
    sleep 2   # let FINs land in the capture
    stop_capture

    cat > "${pcap%.pcap}.meta.json" <<EOF
{
  "system": "$SYSTEM",
  "scenario": "$id",
  "rep": $rep,
  "messages": $messages,
  "participants": $participants,
  "attach": "$attach",
  "modifier": "$modifier",
  "capture_iface": "$CAPTURE_IFACE",
  "capture_filter": "$CAPTURE_FILTER",
  "started_epoch_ms": $started,
  "finished_epoch_ms": $finished,
  "host": "$(uname -srm)"
}
EOF

    # shellcheck disable=SC2086
    python3 "$SCRIPT_DIR/capture/extract.py" "$pcap" \
      --csv "$RESULTS_CSV" \
      --system "$SYSTEM" --scenario "$id" --rep "$rep" \
      --notes "$notes" \
      $EXTRACT_ARGS

    # Optional driver hook, e.g. a cool-down so per-rep connections are
    # independent (SMTP connection caching would otherwise let one rep
    # ride another's TLS session).
    if declare -F driver_rep_gap >/dev/null; then
      driver_rep_gap
    fi
  done
done

log "Done. Results in $RESULTS_CSV"
