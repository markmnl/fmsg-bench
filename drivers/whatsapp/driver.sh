#!/usr/bin/env bash
# WhatsApp driver: wa-bot (measured, on the wa-bench bridge) exchanges
# messages with the autonomous wa-responder (second account, unmeasured).
# Sourced by bench.sh.
#
# Measurement point: ALL of the bot container's TCP traffic to Meta on
# the wa-bench bridge (there is no host-to-host wire in a closed
# platform — prominent caveat in the paper). The control API port is
# excluded by filter; idle background chatter is baseline-adjusted using
# .state/wa-baseline.bps (run baseline.sh per session).
#
# Config (~/.config/fmsg-bench/whatsapp.env):
#   BENCH_WA_REMOTE_NUMBER=<digits, e.g. 614xxxxxxxx>   responder account
#
# Comparability notes (recorded, not predicted): only 2 automatable
# accounts, so p>2 scenarios use a group chat with the responder and
# -fwd forwards to the responder chat; group-creation cost is excluded
# (group reused across reps).

WA_DIR="$BENCH_ROOT/drivers/whatsapp"
WA_API="${BENCH_WA_API:-http://localhost:3999}"
WA_TIMEOUT="${BENCH_WA_TIMEOUT:-180}"
WA_PACE="${BENCH_WA_PACE:-2}"

WA_REMOTE_NUMBER=""
WA_REMOTE_CHAT=""
WA_GROUP_ID=""
WA_BASELINE_BPS=""

wa_api() {  # wa_api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sf -X "$method" -H 'Content-Type: application/json' -d "$body" "$WA_API$path"
  else
    curl -sf -X "$method" "$WA_API$path"
  fi
}

driver_init() {
  require_cmd curl jq

  local env_file="$HOME/.config/fmsg-bench/whatsapp.env"
  [ -f "$env_file" ] || fail "missing $env_file (set BENCH_WA_REMOTE_NUMBER=<digits>)"
  WA_REMOTE_NUMBER="$(sed -n 's/^BENCH_WA_REMOTE_NUMBER=//p' "$env_file")"
  [ -n "$WA_REMOTE_NUMBER" ] || fail "BENCH_WA_REMOTE_NUMBER not set in $env_file"
  WA_REMOTE_CHAT="${WA_REMOTE_NUMBER}@c.us"

  local state
  state=$(wa_api GET /status | jq -r '.state') \
    || fail "wa-bot control API unreachable at $WA_API — start drivers/whatsapp/compose.yml"
  [ "$state" = "ready" ] || fail "wa-bot not ready (state: $state) — pair via GET /pair"

  if [ -f "$STATE_DIR/wa-baseline.bps" ]; then
    WA_BASELINE_BPS="$(cat "$STATE_DIR/wa-baseline.bps")"
  else
    log "note: no idle baseline recorded — run drivers/whatsapp/baseline.sh first"
  fi
}

driver_capture_spec() {
  CAPTURE_IFACE="$(resolve_network_iface wa-bench)"
  CAPTURE_FILTER="not port 3999 and not port 53 and (tcp or udp)"
}

driver_extract_args() {
  local args=""
  [ -n "$WA_BASELINE_BPS" ] && args="--baseline-bps $WA_BASELINE_BPS"
  echo "$args"
}

driver_rep_gap() {
  sleep "${BENCH_WA_REP_GAP:-5}"
}

urlq() {
  python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# Wait until an OWN outgoing message with the given body prefix reaches
# ack >= 2 (delivered). Tracked via the bot's message_create/ack events,
# not sendMessage's return value (unreliable on some WhatsApp Web builds).
wa_wait_sent_delivered() {
  local prefix="$1" deadline ack
  deadline=$((SECONDS + WA_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ack=$(wa_api GET "/sent?prefix=$(urlq "$prefix")" | jq -r '.[0].ack // -1')
    [ "$ack" -ge 2 ] 2>/dev/null && return 0
    sleep 0.5
  done
  echo "ERROR: timed out waiting for delivery of '$prefix'" >&2
  return 1
}

# Local id of an own sent message, by body prefix (for forward/quote).
wa_get_sent_id() {
  wa_api GET "/sent?prefix=$(urlq "$1")" | jq -r '.[0].id // empty'
}

# Wait for an incoming message whose body starts with the given prefix;
# echoes its message id.
wa_wait_received() {
  local prefix="$1" deadline out
  deadline=$((SECONDS + WA_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    out=$(wa_api GET "/received?prefix=$(urlq "$prefix")")
    if [ "$(jq 'length' <<<"$out")" -gt 0 ]; then
      jq -r '.[0].id' <<<"$out"
      return 0
    fi
    sleep 0.5
  done
  echo "ERROR: timed out waiting for incoming message '$prefix'" >&2
  return 1
}

wa_body() {  # 120-byte body incl. the T<total> token the responder parses
  local scenario="$1" rep="$2" n="$3" total="$4"
  local tag="$scenario r$rep m$n T$total"
  printf '%s%s' "$tag" "$(printf '%*s' $((BODY_SIZE - ${#tag})) '' | tr ' ' '.')"
}

# NOTE: called via $(...) — never use fail/exit here, only return 1.
wa_target_chat() {  # group for p>2, direct chat otherwise
  local participants="$1"
  if [ "$participants" -gt 2 ]; then
    if [ -z "$WA_GROUP_ID" ]; then
      WA_GROUP_ID="$(sed -n 's/^BENCH_WA_GROUP_ID=//p' "$HOME/.config/fmsg-bench/whatsapp.env")"
    fi
    if [ -z "$WA_GROUP_ID" ]; then
      # Chat listing is broken on some WhatsApp Web builds, so derive the
      # group id from any message the responder sent into the group.
      WA_GROUP_ID=$(wa_api GET "/received?prefix=" \
        | jq -r '[.[] | select(.from | endswith("@g.us"))][0].from // empty')
    fi
    if [ -z "$WA_GROUP_ID" ]; then
      echo "ERROR: group id unknown — set BENCH_WA_GROUP_ID or send a group message from the responder phone" >&2
      return 1
    fi
    echo "$WA_GROUP_ID"
  else
    echo "$WA_REMOTE_CHAT"
  fi
}

driver_run_scenario() {
  local scenario="$1" messages="$2" participants="$3" attach="$4" modifier="$5" rep="$6"
  local attach_path="" unique_host_file=""
  if [ "$attach" != "-" ]; then
    # WhatsApp deduplicates identical media server-side (a repeat send of
    # the same file never re-uploads), so each rep sends a UNIQUE random
    # file of the same size — like-for-like with systems that always
    # retransmit. Written into the payloads dir, which is mounted
    # read-only into the bot container at /payloads.
    local size unique_name
    unique_name=".wa-$scenario-r$rep-$attach"
    unique_host_file="$PAYLOADS_DIR/$unique_name"
    case "$attach" in
      real-*)
        # Realistic file: keep content, append a tiny random tail so the
        # media hash is unique per rep (defeats server-side dedup while
        # remaining a valid image/document).
        cp "$PAYLOADS_DIR/$attach" "$unique_host_file"
        head -c 16 /dev/urandom >> "$unique_host_file"
        ;;
      *)
        size=$(stat -c%s "$PAYLOADS_DIR/$attach")
        head -c "$size" /dev/urandom > "$unique_host_file"
        ;;
    esac
    attach_path="/payloads/$unique_name"
    # shellcheck disable=SC2064
    trap "rm -f '$unique_host_file'" RETURN
  fi

  local chat
  chat="$(wa_target_chat "$participants")" || return 1
  [ -n "$chat" ] || return 1

  local n=1 sender body received_prefix=""
  while [ "$n" -le "$messages" ]; do
    if [ "$n" -eq 1 ]; then sender=1
    elif [ "$modifier" = "br" ]; then sender=2
    else sender=$(( ((n - 1) % participants) + 1 )); fi

    if [ "$sender" -eq 1 ]; then
      body="$(wa_body "$scenario" "$rep" "$n" "$messages")"
      # Images go through WhatsApp's native image pipeline (realistic —
      # it may recompress); everything else is sent as a document.
      local as_doc=true
      case "$attach" in *.png|*.jpg|*.jpeg) as_doc=false ;; esac
      local payload
      payload=$(jq -n --arg to "$chat" --arg body "$body" \
        --arg media "${attach_path:-}" --arg quote "${received_prefix:-}" \
        --argjson asdoc "$as_doc" \
        --argjson first "$([ "$n" -eq 1 ] && echo true || echo false)" \
        '{to: $to, body: $body}
         + (if ($media != "" and $first) then {mediaPath: $media, asDocument: $asdoc} else {} end)
         + (if $quote != "" then {quotePrefix: $quote} else {} end)')
      wa_api POST /send "$payload" >/dev/null || return 1
      echo "    [$scenario r$rep] m$n: [local] -> [chat]"
      wa_wait_sent_delivered "$scenario r$rep m$n " || return 1
      sleep "$WA_PACE"
      n=$((n + 1))
    else
      # Remote turns are autonomous (the responder chains all its
      # consecutive replies itself); wait for the LAST message of this
      # remote run to arrive at the bot, then resume after it.
      local last_remote=$n s nxt
      while [ "$last_remote" -lt "$messages" ]; do
        nxt=$((last_remote + 1))
        if [ "$modifier" = "br" ]; then s=2
        else s=$(( (nxt - 1) % participants + 1 )); fi
        [ "$s" -eq 1 ] && break
        last_remote=$nxt
      done
      wa_wait_received "$scenario r$rep m$last_remote " >/dev/null || return 1
      received_prefix="$scenario r$rep m$last_remote "
      echo "    [$scenario r$rep] m$n..m$last_remote: [remote] -> [local]"
      n=$((last_remote + 1))
    fi
  done

  if [ "$modifier" = "fwd" ]; then
    # Forward message 1 (the wire cost of the forward action itself),
    # resolved by body prefix — ids are unreliable on this build.
    wa_api POST /forward "$(jq -n --arg p "$scenario r$rep m1 " --arg to "$WA_REMOTE_CHAT" \
      '{prefix: $p, to: $to}')" >/dev/null \
      || { echo "ERROR: /forward API call failed" >&2; return 1; }
    echo "    [$scenario r$rep] fwd: [local] forwards m1"
    sleep "$WA_PACE"
  fi
}
