#!/usr/bin/env bash
# Shared fmsg scenario logic, used by both the lab driver (drivers/fmsg-lab)
# and the real-host driver (drivers/fmsg). The sourcing driver must define:
#   fmsg_p <idx> <cli args...>   run fmsg-cli as participant idx
#   P_ADDRS                      1-indexed participant address array
#   DELIVERY_TIMEOUT, POLL_SLEEP, FMSG_BIN, PAYLOADS_DIR

get_max_id() {
  local v
  v=$(fmsg_p "$1" --json list --limit 1 2>/dev/null | jq -r '.[0].id // 0' 2>/dev/null)
  echo "${v:-0}"   # transient API failure must not poison later waits
}

# Wait for a message whose body starts with the given tag to arrive in
# participant $idx's inbox with an id greater than $since. Echoes the id.
wait_msg_by_tag() {
  local idx="$1" since="${2:-0}" tag="$3"
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
  [ -n "$msg_id" ] || { echo "ERROR: wait_delivered called with empty message id" >&2; return 1; }
  local deadline ok
  deadline=$((SECONDS + DELIVERY_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    local sent_json
    sent_json=$(fmsg_p "$idx" --json sent --limit 20 2>/dev/null)
    ok=$(jq --argjson id "$msg_id" \
        '[.[] | select(.id == $id) | .to_delivery[].time_delivered] | (length > 0) and all(. != null)' <<<"$sent_json")
    [ "$ok" = "true" ] && return 0
    local rejected
    rejected=$(jq --argjson id "$msg_id" \
        '[.[] | select(.id == $id) | .to_delivery[].response_code] | map(select(. != null and . != 200 and . != 11 and . != 65)) | first // empty' <<<"$sent_json")
    if [ -n "$rejected" ]; then
      echo "ERROR: message $msg_id rejected with response code $rejected" >&2
      return 1
    fi
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

fmsg_scenario_run() {
  local scenario="$1" messages="$2" participants="$3" attach="$4" modifier="$5" rep="$6"
  local attach_path="-"
  [ "$attach" != "-" ] && attach_path="$PAYLOADS_DIR/$attach"
  [ "$attach_path" = "-" ] || [ -f "$attach_path" ] || fail "payload missing: $attach_path (run scenarios/gen-payloads.sh)"

  local n_participants=$(( ${#P_ADDRS[@]} - 1 ))
  if [ "$participants" -gt "$n_participants" ]; then
    echo "ERROR: $scenario needs $participants participants but only $n_participants are configured" >&2
    return 1
  fi

  local joiner_idx=0
  if [ "$modifier" = "fwd" ]; then
    joiner_idx=$((participants + 1))
    if [ "$joiner_idx" -gt "$n_participants" ]; then
      echo "ERROR: $scenario: no configured participant slot for the joining party" >&2
      return 1
    fi
  fi

  # Inbox baselines so tag-waits only scan messages from this repetition.
  local -a base
  local i
  for i in $(seq 1 "$n_participants"); do
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

    wait_delivered "$sender" "$msg_id" || return 1

    # The next sender needs their local copy's id to reply to; also
    # record everyone's local id of message 1 for -br / -fwd.
    if [ "$n" -lt "$messages" ]; then
      if [ "$modifier" = "br" ]; then
        prev_sender=2
      else
        prev_sender=$(( (n % participants) + 1 ))
      fi
      if [ "$n" -eq 1 ] || [ "$modifier" != "br" ]; then
        received_id=$(wait_msg_by_tag "$prev_sender" "${base[$prev_sender]}" "$tag") || return 1
        base[$prev_sender]="$received_id"
        [ "$n" -eq 1 ] && first_ids[$prev_sender]="$received_id"
      fi
    fi
  done

  if [ "$modifier" = "fwd" ]; then
    echo "    [$scenario r$rep] add-to: ${P_ADDRS[$joiner_idx]} joins message 1"
    fmsg_p 1 --json add-to "${first_ids[1]}" "${P_ADDRS[$joiner_idx]}" >/dev/null
    wait_addto_delivered 1 "${first_ids[1]}" || return 1
    # The joiner receives the original message; wait for it so the
    # capture window covers the whole transfer.
    wait_msg_by_tag "$joiner_idx" "${base[$joiner_idx]}" "$(msg_tag "$scenario" "$rep" 1)" >/dev/null || return 1
  fi
}
