#!/usr/bin/env bash
# Email driver: mailcow (local, via SSH tunnel) <-> Gmail (remote, via
# Gmail API). Sourced by bench.sh.
#
# Measurement point: host-to-host SMTP (TCP 25) captured on the mailcow
# host's LAN/WAN interface via `ssh <host> tcpdump -w -` streaming — the
# mailcow box itself is never modified. Client->server submission (587)
# and IMAP run through an SSH tunnel and are deliberately outside the
# capture, per the white paper's method.
#
# Addresses/credentials live in ~/.config/fmsg-bench/ only; progress and
# results use redacted labels ([local], [remote], [remote+pN]).
#
# Comparability notes: extra participants (p>2) are plus-aliases of the
# one benchmark Gmail account, so a "reply-all" from any remote persona
# is a single inbound SMTP transaction; scenario duration includes Gmail
# internals and API polling — indicative, not replicable.

EMAIL_DIR="$BENCH_ROOT/drivers/email"
EMAIL_SSH_HOST="${BENCH_EMAIL_SSH_HOST:-mailhost}"
EMAIL_WAN_IFACE="${BENCH_EMAIL_WAN_IFACE:-enp2s0}"
TUNNEL_SMTP_PORT="${BENCH_TUNNEL_SMTP_PORT:-15870}"
TUNNEL_IMAP_PORT="${BENCH_TUNNEL_IMAP_PORT:-19930}"
EMAIL_TIMEOUT="${BENCH_EMAIL_TIMEOUT:-300}"

export BENCH_TUNNEL_SMTP_PORT="$TUNNEL_SMTP_PORT"
export BENCH_TUNNEL_IMAP_PORT="$TUNNEL_IMAP_PORT"

GOOGLE_CIDR_ARGS=""
REMOTE_BASE=""
LOCAL_BASE=""
LOCAL2_BASE=""
OUTLOOK_BASE=""

epy() {  # run one of this driver's python tools
  local tool="$1"
  shift
  PYTHONPATH="$EMAIL_DIR" python3 "$EMAIL_DIR/$tool" "$@"
}

remote_alias() {  # participant index >= 3 -> plus-alias of the base account
  echo "${REMOTE_BASE%@*}+p$1@${REMOTE_BASE#*@}"
}

driver_init() {
  require_cmd ssh python3 jq dig

  local env_file="$HOME/.config/fmsg-bench/email.env"
  [ -f "$env_file" ] || fail "missing $env_file"

  # Pin the responder-API hostnames for the run (SMTP/IMAP go via the SSH
  # tunnel to localhost and need no DNS); see lib/dns-pin.sh.
  dns_pin gmail.googleapis.com oauth2.googleapis.com \
    graph.microsoft.com login.microsoftonline.com
  REMOTE_BASE="$(sed -n 's/^BENCH_REMOTE_ADDR=//p' "$env_file")"
  [ -n "$REMOTE_BASE" ] || fail "BENCH_REMOTE_ADDR not set in $env_file"
  LOCAL_BASE="$(sed -n 's/^BENCH_LOCAL_ADDR=//p' "$env_file")"
  LOCAL2_BASE="$(sed -n 's/^BENCH_LOCAL2_ADDR=//p' "$env_file")"
  OUTLOOK_BASE="$(sed -n 's/^BENCH_OUTLOOK_ADDR=//p' "$env_file")"

  # Deployment-specific host/iface live in the (uncommitted) env file so
  # the repo stays free of personal infrastructure details.
  local v
  v="$(sed -n 's/^BENCH_EMAIL_SSH_HOST=//p' "$env_file")" && [ -n "$v" ] && EMAIL_SSH_HOST="$v"
  v="$(sed -n 's/^BENCH_EMAIL_WAN_IFACE=//p' "$env_file")" && [ -n "$v" ] && EMAIL_WAN_IFACE="$v"
  v="$(sed -n 's/^BENCH_EMAIL_RELAY_PORT=//p' "$env_file")"
  if [ -n "$v" ]; then EMAIL_RELAY_PORT="$v"; fi

  [ -f "$HOME/.config/fmsg-bench/gmail-token.json" ] \
    || fail "no Gmail token — run: PYTHONPATH=$EMAIL_DIR python3 $EMAIL_DIR/gmail_oauth_bootstrap.py"

  # SSH tunnel for submission + IMAP (idempotent).
  if ! ss -tln 2>/dev/null | grep -q ":$TUNNEL_SMTP_PORT "; then
    log "Starting SSH tunnel to $EMAIL_SSH_HOST..."
    ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -f -N \
      -L "$TUNNEL_SMTP_PORT:localhost:587" \
      -L "$TUNNEL_IMAP_PORT:localhost:993" "$EMAIL_SSH_HOST"
  fi

  # Remote capture prerequisites (read-only on the mail host).
  ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$EMAIL_SSH_HOST" 'sudo -n tcpdump --version >/dev/null' \
    || fail "passwordless sudo tcpdump unavailable on $EMAIL_SSH_HOST"

  # The mail host's own IP: passed to extract.py as the authoritative
  # local side (a rep that catches a connection mid-stream has no SYN to
  # infer it from).
  EMAIL_LOCAL_IP=$(ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$EMAIL_SSH_HOST" \
    "ip -4 -o addr show $EMAIL_WAN_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$EMAIL_LOCAL_IP" ] || fail "could not determine $EMAIL_SSH_HOST's IP on $EMAIL_WAN_IFACE"

  # Gmail token sanity (refresh if stale).
  PYTHONPATH="$EMAIL_DIR" python3 -c "import gmail_api; gmail_api.access_token()" \
    || fail "Gmail token refresh failed"

  # Google SMTP netblocks for the extraction filter — keeps unrelated
  # production mail out of the results.
  local blocks cidr
  blocks=$(for b in _netblocks _netblocks2 _netblocks3; do
    dig +tcp +short TXT "$b.google.com" @8.8.8.8 2>/dev/null
  done | grep -o 'ip[46]:[^ "]*' | sed 's/^ip[46]://')
  [ -n "$blocks" ] || blocks="64.233.160.0/19 66.102.0.0/20 66.249.80.0/20 72.14.192.0/18 74.125.0.0/16 108.177.8.0/21 173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19 172.217.0.0/16 142.250.0.0/15 2607:f8b0:4000::/36 2800:3f0:4000::/36 2a00:1450:4000::/36 2c0f:fb50:4000::/36"
  local ms_blocks
  ms_blocks=$(dig +tcp +short TXT spf.protection.outlook.com @8.8.8.8 2>/dev/null \
    | grep -o 'ip[46]:[^ "]*' | sed 's/^ip[46]://')
  [ -n "$ms_blocks" ] || ms_blocks="40.92.0.0/15 40.107.0.0/16 52.100.0.0/14 104.47.0.0/17 2a01:111:f400::/48 2a01:111:f403::/49"
  for cidr in $blocks $ms_blocks; do
    GOOGLE_CIDR_ARGS="$GOOGLE_CIDR_ARGS --remote-cidr $cidr"
  done
}

# Outbound transport: direct SMTP on port 25 when the mail host can send
# directly (rDNS/SPF/DKIM in place, port unblocked) — the sender's host
# then performs the per-provider fan-out itself, all of it on the
# measured wire. Where direct port 25 is unavailable, set
# BENCH_EMAIL_RELAY_PORT (env or email.env) to the smarthost port
# (e.g. 2525) and the measured outbound hop becomes mailcow->relay.
# Inbound is provider->mailcow on port 25 either way, kept only when the
# remote IP is in the providers' netblocks so unrelated production mail
# never enters the results.
EMAIL_RELAY_PORT="${BENCH_EMAIL_RELAY_PORT:-}"

driver_capture_spec() {
  CAPTURE_IFACE="ssh:$EMAIL_SSH_HOST:$EMAIL_WAN_IFACE"
  CAPTURE_FILTER="tcp port 25"
  [ -n "$EMAIL_RELAY_PORT" ] && CAPTURE_FILTER="tcp port 25 or tcp port $EMAIL_RELAY_PORT"
}

driver_extract_args() {
  local args="--port 25 --local $EMAIL_LOCAL_IP $GOOGLE_CIDR_ARGS"
  [ -n "$EMAIL_RELAY_PORT" ] \
    && args="--port 25 --port $EMAIL_RELAY_PORT --keep-remote-port $EMAIL_RELAY_PORT --local $EMAIL_LOCAL_IP $GOOGLE_CIDR_ARGS"
  echo "$args"
}

# Cool-down between reps so postfix's SMTP connection cache expires and
# every rep negotiates its own connection (comparable, self-contained
# captures). Also re-establishes the SSH tunnel if it died mid-campaign.
driver_rep_gap() {
  sleep "${BENCH_EMAIL_REP_GAP:-10}"
  if ! ss -tln 2>/dev/null | grep -q ":$TUNNEL_SMTP_PORT "; then
    log "SSH tunnel to $EMAIL_SSH_HOST is down — re-establishing..."
    ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -f -N \
      -L "$TUNNEL_SMTP_PORT:localhost:587" \
      -L "$TUNNEL_IMAP_PORT:localhost:993" "$EMAIL_SSH_HOST" || true
  fi
}

driver_run_scenario() {
  local scenario="$1" messages="$2" participants="$3" attach="$4" modifier="$5" rep="$6"
  local attach_path="-"
  [ "$attach" != "-" ] && attach_path="$PAYLOADS_DIR/$attach"
  [ "$attach_path" = "-" ] || [ -f "$attach_path" ] || fail "payload missing: $attach_path"

  local tag="[$scenario r$rep]"
  local rep_tmp
  rep_tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$rep_tmp'" RETURN

  # Recipients for the first message: for cross-domain (x) scenarios the
  # third participant is a second local-side mailbox on its own domain;
  # otherwise extra participants are plus-aliases of the remote account.
  local first_to=(--to "$REMOTE_BASE")
  local i
  if [ "$modifier" = "x" ]; then
    [ -n "$OUTLOOK_BASE" ] || { echo "ERROR: BENCH_OUTLOOK_ADDR not configured for $scenario" >&2; return 1; }
    first_to+=(--to "$OUTLOOK_BASE")
    for i in $(seq 4 "$participants"); do
      first_to+=(--to "$(remote_alias "$i")")
    done
  else
    for i in $(seq 3 "$participants"); do
      first_to+=(--to "$(remote_alias "$i")")
    done
  fi

  local n sender prev_sender="" body_file out
  local root_gmail_id="" last_gmail_sent="" last_remote_json="$rep_tmp/last_remote.json"

  for n in $(seq 1 "$messages"); do
    local sender_idx=$(( (n - 1) % participants + 1 ))
    [ "$n" -eq 1 ] && sender_idx=1
    [ "$modifier" = "br" ] && [ "$n" -gt 1 ] && sender_idx=2
    if [ "$sender_idx" -eq 1 ]; then
      sender=local
    elif [ "$modifier" = "x" ] && [ "$sender_idx" -eq 3 ]; then
      sender=outlook     # third provider, its own domain
    else
      sender=remote
    fi

    body_file="$rep_tmp/body_$n.txt"
    msg_body "$scenario" "$rep" "$n" > "$body_file"

    if [ "$sender" = "local" ]; then
      if [ "$n" -eq 1 ]; then
        local attach_args=()
        [ "$attach_path" != "-" ] && attach_args=(--attach "$attach_path")
        epy send.py "${first_to[@]}" --subject "$tag fmsg-bench" \
          --body-file "$body_file" "${attach_args[@]}" >/dev/null || return 1
        echo "    [$scenario r$rep] m$n: [local] -> [remote x$((participants - 1))]"
      else
        local reply_to=(--to "$REMOTE_BASE")
        [ "$modifier" = "x" ] && reply_to+=(--to "$OUTLOOK_BASE")
        epy send.py "${reply_to[@]}" --subject "Re: $tag fmsg-bench" \
          --body-file "$body_file" --reply-json "$last_remote_json" >/dev/null || return 1
        echo "    [$scenario r$rep] m$n: [local] -> [remote] (reply)"
      fi
      # Confirm arrival at Gmail when no remote turn follows to do it
      # (also marks it read, so a later fwd confirmation can't match it).
      if [ "$n" -eq "$messages" ]; then
        out=$(epy gmail_reply.py --tag "$tag" --wait-only --timeout "$EMAIL_TIMEOUT") || return 1
        [ -z "$root_gmail_id" ] && root_gmail_id=$(jq -r '.id' <<<"$out")
      fi
    elif [ "$sender" = "outlook" ]; then
      epy outlook_reply.py --tag "$tag" --reply-body-file "$body_file" --reply-all \
        --timeout "$EMAIL_TIMEOUT" >/dev/null || return 1
      echo "    [$scenario r$rep] m$n: [outlook] -> [remote]+[local] (reply)"
      epy imap_wait.py --tag "$tag" --timeout "$EMAIL_TIMEOUT" > "$last_remote_json" || return 1
    else
      local reply_args=(--reply-body-file "$body_file" --timeout "$EMAIL_TIMEOUT")
      [ "$participants" -gt 2 ] && reply_args+=(--reply-all)
      if [ "$modifier" = "br" ] && [ "$n" -gt 2 ]; then
        # Branch: another reply to the FIRST message.
        out=$(epy gmail_reply.py --reply-to-id "$root_gmail_id" "${reply_args[@]}") || return 1
      elif [ "$prev_sender" = "remote" ]; then
        # Consecutive remote turns: reply to own previous reply.
        out=$(epy gmail_reply.py --reply-to-id "$last_gmail_sent" "${reply_args[@]}") || return 1
      else
        out=$(epy gmail_reply.py --tag "$tag" "${reply_args[@]}") || return 1
        [ -z "$root_gmail_id" ] && root_gmail_id=$(jq -r '.id' <<<"$out")
      fi
      last_gmail_sent=$(jq -r '.sent_id' <<<"$out")
      echo "    [$scenario r$rep] m$n: [remote] -> [local] (reply)"
      # Wait for the reply to land in the mailcow inbox (delivery
      # confirmation + quoting state for any later local reply).
      epy imap_wait.py --tag "$tag" --timeout "$EMAIL_TIMEOUT" > "$last_remote_json" || return 1
    fi
    prev_sender="$sender"
  done

  if [ "$modifier" = "fwd" ]; then
    # Forward the first message (attachment re-sent in full) to a new
    # participant persona.
    local fwd_to fwd_body="$rep_tmp/fwd_body.txt"
    fwd_to="${REMOTE_BASE%@*}+fwd@${REMOTE_BASE#*@}"
    {
      echo "---------- Forwarded message ---------"
      echo "From: [local]"
      echo "Subject: $tag fmsg-bench"
      echo
      cat "$rep_tmp/body_1.txt"
    } > "$fwd_body"
    local attach_args=()
    [ "$attach_path" != "-" ] && attach_args=(--attach "$attach_path")
    epy send.py --to "$fwd_to" --subject "Fwd: $tag fmsg-bench" \
      --body-file "$fwd_body" "${attach_args[@]}" >/dev/null || return 1
    echo "    [$scenario r$rep] fwd: [local] -> [remote+fwd]"
    epy gmail_reply.py --tag "$tag" --wait-only --timeout "$EMAIL_TIMEOUT" >/dev/null || return 1
  fi
}
