#!/usr/bin/env bash
# fmsg driver: runs scenarios against the two-domain bench lab via
# fmsg-cli --json. Sourced by bench.sh, which provides lib/common.sh.
#
# Contract with bench.sh:
#   driver_init                 one-time setup (CLI binary, API keys)
#   driver_capture_spec         sets CAPTURE_IFACE and CAPTURE_FILTER
#   driver_extract_args         echoes extra args for capture/extract.py
#   driver_run_scenario <id> <messages> <participants> <attach> <modifier> <rep>

FMSG_BIN="$BENCH_ROOT/.bin/fmsg"
KEYS_ENV="$STATE_DIR/fmsg-keys.env"

HAIRPIN_API_URL="${HAIRPIN_API_URL:-http://localhost:8181}"
EXAMPLE_API_URL="${EXAMPLE_API_URL:-http://localhost:8182}"

# Participant registry. Index 1 is the local (hairpin.local) sender; the
# rest live on example.com so every message crosses the host-to-host wire.
P_ADDRS=("" "@alice@hairpin.local" "@bob@example.com" "@carol@example.com" "@dave@example.com" "@erin@example.com")
P_OWNERS=("" alice bob carol dave erin)

DELIVERY_TIMEOUT="${DELIVERY_TIMEOUT:-90}"
POLL_SLEEP=0.25

p_api_url() {
  if [ "$1" -eq 1 ]; then echo "$HAIRPIN_API_URL"; else echo "$EXAMPLE_API_URL"; fi
}

p_webapi_container() {
  if [ "$1" -eq 1 ]; then echo "hairpin-fmsg-webapi-1"; else echo "example-fmsg-webapi-1"; fi
}

p_key_var() {
  echo "$(echo "${P_OWNERS[$1]}" | tr '[:lower:]' '[:upper:]')_API_KEY"
}

fmsg_p() {
  local idx="$1"
  shift
  local key_var
  key_var="$(p_key_var "$idx")"
  FMSG_API_URL="$(p_api_url "$idx")" FMSG_API_KEY="${!key_var}" "$FMSG_BIN" "$@"
}

# Adapted from fmsg-docker/test/run-tests.sh (create_or_rotate_api_key),
# hardened: fall back to rotate whenever create yields no key (not only
# on a non-zero exit), and surface both outputs on failure.
create_or_rotate_api_key() {
  local container="$1" owner="$2" addr="$3"
  local create_out rotate_out api_key

  create_out=$("$CTR" exec "$container" /opt/fmsg-webapi/fmsg-webapi api-key create-delegation \
      -owner "$owner" -agent bench -addr "$addr" \
      -cidr "0.0.0.0/0,::/0" -expires "2099-01-01T00:00:00Z" 2>&1) || true
  api_key=$(echo "$create_out" | sed -n 's/^api_key=//p' | head -1)

  if [ -z "$api_key" ]; then
    rotate_out=$("$CTR" exec "$container" /opt/fmsg-webapi/fmsg-webapi api-key rotate-delegation \
        -owner "$owner" -agent bench \
        -cidr "0.0.0.0/0,::/0" -expires "2099-01-01T00:00:00Z" 2>&1) || true
    api_key=$(echo "$rotate_out" | sed -n 's/^api_key=//p' | head -1)
  fi

  if [ -z "$api_key" ]; then
    {
      echo "Failed to create API key for $addr"
      echo "create-delegation: $(echo "$create_out" | sed 's/^api_key=.*/api_key=<redacted>/')"
      echo "rotate-delegation: $(echo "${rotate_out:-'(not attempted)'}" | sed 's/^api_key=.*/api_key=<redacted>/')"
    } >&2
    return 1
  fi
  echo "$api_key"
}

driver_init() {
  [ -n "$CTR" ] || fail "neither docker nor podman found"
  require_cmd jq go

  if [ ! -x "$FMSG_BIN" ]; then
    log "Building fmsg CLI from $WORKSPACE_ROOT/fmsg-cli..."
    mkdir -p "$(dirname "$FMSG_BIN")"
    (cd "$WORKSPACE_ROOT/fmsg-cli" && go build -o "$FMSG_BIN" .)
  fi

  mkdir -p "$STATE_DIR"
  if [ -f "$KEYS_ENV" ]; then
    # shellcheck source=/dev/null
    source "$KEYS_ENV"
  fi

  # Validate cached keys; (re)create any that are missing or rejected.
  local idx key_var refreshed=false
  for idx in 1 2 3 4 5; do
    key_var="$(p_key_var "$idx")"
    if [ -n "${!key_var:-}" ] && fmsg_p "$idx" whoami >/dev/null 2>&1; then
      continue
    fi
    log "Creating API key for ${P_ADDRS[$idx]}..."
    local new_key
    new_key="$(create_or_rotate_api_key \
      "$(p_webapi_container "$idx")" "${P_ADDRS[$idx]}" "${P_ADDRS[$idx]}")" \
      || fail "could not obtain API key for ${P_ADDRS[$idx]}"
    [ -n "$new_key" ] || fail "empty API key for ${P_ADDRS[$idx]}"
    declare -g "$key_var"="$new_key"
    refreshed=true
  done

  if [ "$refreshed" = "true" ]; then
    {
      for idx in 1 2 3 4 5; do
        key_var="$(p_key_var "$idx")"
        echo "export $key_var='${!key_var}'"
      done
    } > "$KEYS_ENV"
    chmod 600 "$KEYS_ENV"
  fi
}

driver_capture_spec() {
  CAPTURE_IFACE="$(resolve_network_iface fmsg-test)"
  CAPTURE_FILTER="tcp port 4930"
}

driver_extract_args() {
  echo "--port 4930"
}

get_max_id() {
  fmsg_p "$1" --json list --limit 1 2>/dev/null | jq -r '.[0].id // 0'
}

# Wait for a message whose body starts with the given tag to arrive in
# participant $idx's inbox with an id greater than $since. Echoes the id.
wait_msg_by_tag() {
  local idx="$1" since="$2" tag="$3"
  local deadline id ids tmp
  deadline=$((SECONDS + DELIVERY_TIMEOUT))
  tmp=$(mktemp)

  while [ "$SECONDS" -lt "$deadline" ]; do
    ids=$(fmsg_p "$idx" --json list --limit 20 2>/dev/null \
      | jq -r --argjson s "$since" '[.[] | select(.id > $s) | .id] | sort | .[]')
    for id in $ids; do
      if fmsg_p "$idx" get-data "$id" "$tmp" >/dev/null 2>&1 \
          && [ "$(head -c "${#tag}" "$tmp")" = "$tag" ]; then
        rm -f "$tmp"
        echo "$id"
        return 0
      fi
    done
    sleep "$POLL_SLEEP"
  done

  rm -f "$tmp"
  echo "ERROR: timed out waiting for '$tag' in ${P_ADDRS[$idx]}'s inbox" >&2
  return 1
}

# Wait until every primary recipient of the sender's message $msg_id has
# time_delivered set (i.e. the wire transfer completed).
wait_delivered() {
  local idx="$1" msg_id="$2"
  local deadline ok
  deadline=$((SECONDS + DELIVERY_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    ok=$(fmsg_p "$idx" --json sent --limit 20 2>/dev/null \
      | jq --argjson id "$msg_id" \
        '[.[] | select(.id == $id) | .to_delivery[].time_delivered] | (length > 0) and all(. != null)')
    [ "$ok" = "true" ] && return 0
    sleep "$POLL_SLEEP"
  done

  echo "ERROR: timed out waiting for delivery of message $msg_id from ${P_ADDRS[$idx]}" >&2
  return 1
}

# Wait until every recipient in every add-to batch of $msg_id has
# time_delivered set.
wait_addto_delivered() {
  local idx="$1" msg_id="$2"
  local deadline ok
  deadline=$((SECONDS + DELIVERY_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    ok=$(fmsg_p "$idx" --json sent --limit 20 2>/dev/null \
      | jq --argjson id "$msg_id" \
        '[.[] | select(.id == $id) | .add_to[].to_delivery[].time_delivered] | (length > 0) and all(. != null)')
    [ "$ok" = "true" ] && return 0
    sleep "$POLL_SLEEP"
  done

  echo "ERROR: timed out waiting for add-to delivery of message $msg_id" >&2
  return 1
}

# send_msg <sender_idx> <pid|-> <attach_file|-> <body> <recipient_addr...>
# Echoes the sender's local message id.
send_msg() {
  local idx="$1" pid="$2" attach="$3" body="$4"
  shift 4
  local recipients=("$@")
  local id out pid_args=()

  [ "$pid" != "-" ] && pid_args=(--pid "$pid")

  if [ "$attach" = "-" ] && [ "${#recipients[@]}" -eq 1 ]; then
    out=$(fmsg_p "$idx" --json send "${pid_args[@]}" "${recipients[0]}" "$body")
    jq -r '.id' <<<"$out"
    return
  fi

  out=$(fmsg_p "$idx" --json draft create "${pid_args[@]}" "${recipients[0]}" "$body")
  id=$(jq -r '.id' <<<"$out")

  if [ "${#recipients[@]}" -gt 1 ]; then
    fmsg_p "$idx" --json update "$id" --to "$(IFS=,; echo "${recipients[*]}")" >/dev/null
  fi
  if [ "$attach" != "-" ]; then
    fmsg_p "$idx" --json attach "$id" "$attach" >/dev/null
  fi

  out=$(fmsg_p "$idx" --json draft send "$id")
  jq -r '.id' <<<"$out"
}

driver_run_scenario() {
  local scenario="$1" messages="$2" participants="$3" attach="$4" modifier="$5" rep="$6"
  local attach_path="-"
  [ "$attach" != "-" ] && attach_path="$PAYLOADS_DIR/$attach"
  [ "$attach_path" = "-" ] || [ -f "$attach_path" ] || fail "payload missing: $attach_path (run scenarios/gen-payloads.sh)"

  local joiner_idx=0
  if [ "$modifier" = "fwd" ]; then
    joiner_idx=$((participants + 1))
    [ "$joiner_idx" -le 5 ] || fail "$scenario: no participant slot for the joining party"
  fi

  # Inbox baselines so tag-waits only scan messages from this repetition.
  local -a base
  local i
  for i in $(seq 1 5); do
    base[$i]=$(get_max_id "$i")
  done

  # first_ids[i]: participant i's local id of message 1 (for -br replies
  # and the sender's -fwd add-to target).
  local -a first_ids
  local sender prev_sender recipients tag body msg_id received_id n

  for n in $(seq 1 "$messages"); do
    # Sender rotation: 2-party alternates; multi-party goes round-robin.
    # Branch scenarios: every message after the first is sent by
    # participant 2 as a reply to message 1.
    if [ "$n" -eq 1 ]; then
      sender=1
    elif [ "$modifier" = "br" ]; then
      sender=2
    else
      sender=$(( ((n - 1) % participants) + 1 ))
    fi

    recipients=()
    for i in $(seq 1 "$participants"); do
      [ "$i" -ne "$sender" ] && recipients+=("${P_ADDRS[$i]}")
    done

    tag="$(msg_tag "$scenario" "$rep" "$n")"
    body="$(msg_body "$scenario" "$rep" "$n")"

    local pid="-"
    if [ "$n" -gt 1 ]; then
      if [ "$modifier" = "br" ]; then
        pid="${first_ids[$sender]}"
      else
        pid="$received_id"   # sender's local id of the previous message
      fi
    fi

    local msg_attach="-"
    [ "$n" -eq 1 ] && msg_attach="$attach_path"

    msg_id=$(send_msg "$sender" "$pid" "$msg_attach" "$body" "${recipients[@]}")
    [ "$n" -eq 1 ] && first_ids[$sender]="$msg_id"
    echo "    [$scenario r$rep] m$n: ${P_ADDRS[$sender]} -> ${recipients[*]} (id $msg_id)"

    wait_delivered "$sender" "$msg_id"

    # The next sender needs their local copy's id to reply to; also
    # record everyone's local id of message 1 for -br / -fwd.
    if [ "$n" -lt "$messages" ]; then
      if [ "$modifier" = "br" ]; then
        prev_sender=2
      else
        prev_sender=$(( (n % participants) + 1 ))
      fi
      if [ "$n" -eq 1 ] || [ "$modifier" != "br" ]; then
        received_id=$(wait_msg_by_tag "$prev_sender" "${base[$prev_sender]}" "$tag")
        base[$prev_sender]="$received_id"
        [ "$n" -eq 1 ] && first_ids[$prev_sender]="$received_id"
      fi
    fi
  done

  if [ "$modifier" = "fwd" ]; then
    echo "    [$scenario r$rep] add-to: ${P_ADDRS[$joiner_idx]} joins message 1"
    fmsg_p 1 --json add-to "${first_ids[1]}" "${P_ADDRS[$joiner_idx]}" >/dev/null
    wait_addto_delivered 1 "${first_ids[1]}"
    # The joiner receives the original message; wait for it so the
    # capture window covers the whole transfer.
    wait_msg_by_tag "$joiner_idx" "${base[$joiner_idx]}" "$(msg_tag "$scenario" "$rep" 1)" >/dev/null
  fi
}
