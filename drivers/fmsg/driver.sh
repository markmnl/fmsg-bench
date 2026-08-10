#!/usr/bin/env bash
# fmsg driver — REAL production hosts across the internet, mirroring the
# email/whatsapp legs' real-world footing. Sourced by bench.sh.
#
# Local participant lives on the mail-host machine's fmsg stack; remote
# participant lives on a host on the other side of the world. Capture is
# host-to-host fmsg (TCP 4930) on the local host's interface via
# streamed `ssh sudo tcpdump` (read-only), filtered by the remote host's
# resolved IPs so unrelated production fmsg traffic never enters the
# results. Timings cross the real internet: indicative, like email's.
#
# Config (~/.config/fmsg-bench/fmsg.env, never committed):
#   BENCH_FMSG_LOCAL_ADDR/KEY/API     local participant + webapi
#   BENCH_FMSG_REMOTE_ADDR/KEY/API    remote participant + webapi
#   BENCH_FMSG_SSH_HOST/WAN_IFACE     capture host + interface
#   BENCH_FMSG_P3_ADDR/KEY[/API] ...  optional extra remote participants
#                                     (P3..P5) for p>2 and -fwd scenarios
#
# The scenario logic is shared with the lab driver via lib/fmsg-scenario.sh.

FMSG_BIN="$BENCH_ROOT/.bin/fmsg"
FMSG_ENV_FILE="$HOME/.config/fmsg-bench/fmsg.env"

DELIVERY_TIMEOUT="${DELIVERY_TIMEOUT:-300}"
POLL_SLEEP=0.5

P_ADDRS=("")
P_KEYS=("")
P_APIS=("")
FMSG_SSH_HOST=""
FMSG_WAN_IFACE=""
FMSG_LOCAL_IP=""
FMSG_REMOTE_CIDR_ARGS=""

cfg() {  # cfg <suffix> -> value from fmsg.env
  sed -n "s/^BENCH_FMSG_$1=//p" "$FMSG_ENV_FILE"
}

fmsg_p() {
  local idx="$1"
  shift
  FMSG_API_URL="${P_APIS[$idx]}" FMSG_API_KEY="${P_KEYS[$idx]}" "$FMSG_BIN" "$@"
}

driver_init() {
  require_cmd ssh jq go dig
  [ -f "$FMSG_ENV_FILE" ] || fail "missing $FMSG_ENV_FILE"

  if [ ! -x "$FMSG_BIN" ]; then
    log "Building fmsg CLI from $WORKSPACE_ROOT/fmsg-cli..."
    mkdir -p "$(dirname "$FMSG_BIN")"
    (cd "$WORKSPACE_ROOT/fmsg-cli" && go build -o "$FMSG_BIN" .)
  fi

  P_ADDRS=("" "$(cfg LOCAL_ADDR)" "$(cfg REMOTE_ADDR)")
  P_KEYS=("" "$(cfg LOCAL_KEY)" "$(cfg REMOTE_KEY)")
  P_APIS=("" "$(cfg LOCAL_API)" "$(cfg REMOTE_API)")
  [ -n "${P_ADDRS[1]}" ] && [ -n "${P_ADDRS[2]}" ] \
    || fail "BENCH_FMSG_LOCAL_ADDR/REMOTE_ADDR not set in $FMSG_ENV_FILE"

  # Optional extra remote participants for p>2 / -fwd scenarios.
  local i addr key api
  for i in 3 4 5; do
    addr="$(cfg "P${i}_ADDR")"
    [ -n "$addr" ] || break
    key="$(cfg "P${i}_KEY")"
    api="$(cfg "P${i}_API")"
    P_ADDRS+=("$addr")
    P_KEYS+=("$key")
    P_APIS+=("${api:-$(cfg REMOTE_API)}")
  done

  # Pin the API hostnames for the run so every fmsg-cli invocation skips
  # name resolution (see lib/dns-pin.sh).
  local -a api_hosts=()
  local u h
  for u in "${P_APIS[@]}"; do
    [ -n "$u" ] || continue
    h="${u#*://}"; h="${h%%[/:]*}"
    case " ${api_hosts[*]-} " in *" $h "*) ;; *) api_hosts+=("$h") ;; esac
  done
  dns_pin "${api_hosts[@]}"

  FMSG_SSH_HOST="$(cfg SSH_HOST)"
  FMSG_WAN_IFACE="$(cfg WAN_IFACE)"
  [ -n "$FMSG_SSH_HOST" ] && [ -n "$FMSG_WAN_IFACE" ] \
    || fail "BENCH_FMSG_SSH_HOST/WAN_IFACE not set in $FMSG_ENV_FILE"

  ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$FMSG_SSH_HOST" 'sudo -n tcpdump --version >/dev/null' \
    || fail "passwordless sudo tcpdump unavailable on $FMSG_SSH_HOST"
  FMSG_LOCAL_IP=$(ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$FMSG_SSH_HOST" \
    "ip -4 -o addr show $FMSG_WAN_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$FMSG_LOCAL_IP" ] || fail "could not determine $FMSG_SSH_HOST's IP on $FMSG_WAN_IFACE"

  # Restrict extraction to conversations with the remote fmsg hosts of
  # EVERY configured participant domain (excluding the local host's own),
  # so unrelated production traffic on port 4930 is excluded but
  # cross-domain scenarios keep all their conversations.
  local local_domain remote_domain ip seen_domains=" "
  local_domain="${P_ADDRS[1]##*@}"
  for i in $(seq 2 $(( ${#P_ADDRS[@]} - 1 ))); do
    remote_domain="${P_ADDRS[$i]##*@}"
    [ "$remote_domain" = "$local_domain" ] && continue
    case "$seen_domains" in *" $remote_domain "*) continue ;; esac
    seen_domains="$seen_domains$remote_domain "
    for ip in $(dig +tcp +short "fmsg.$remote_domain" A @8.8.8.8; dig +tcp +short "fmsg.$remote_domain" AAAA @8.8.8.8); do
      case "$ip" in
        *:*) FMSG_REMOTE_CIDR_ARGS="$FMSG_REMOTE_CIDR_ARGS --remote-cidr $ip/128" ;;
        *.*) FMSG_REMOTE_CIDR_ARGS="$FMSG_REMOTE_CIDR_ARGS --remote-cidr $ip/32" ;;
      esac
    done
  done
  [ -n "$FMSG_REMOTE_CIDR_ARGS" ] || fail "could not resolve any remote fmsg host"

  # Sanity: both webapis reachable with the configured keys.
  fmsg_p 1 whoami >/dev/null || fail "local fmsg webapi auth failed"
  fmsg_p 2 whoami >/dev/null || fail "remote fmsg webapi auth failed"
}

driver_capture_spec() {
  CAPTURE_IFACE="ssh:$FMSG_SSH_HOST:$FMSG_WAN_IFACE"
  CAPTURE_FILTER="tcp port 4930"
}

driver_extract_args() {
  echo "--port 4930 --local $FMSG_LOCAL_IP $FMSG_REMOTE_CIDR_ARGS"
}

driver_rep_gap() {
  sleep "${BENCH_FMSG_REP_GAP:-5}"
}

source "$BENCH_ROOT/lib/fmsg-scenario.sh"

swap_p3_p4() {
  local t
  t="${P_ADDRS[3]}"; P_ADDRS[3]="${P_ADDRS[4]}"; P_ADDRS[4]="$t"
  t="${P_KEYS[3]}";  P_KEYS[3]="${P_KEYS[4]}";   P_KEYS[4]="$t"
  t="${P_APIS[3]}";  P_APIS[3]="${P_APIS[4]}";   P_APIS[4]="$t"
}

driver_run_scenario() {
  local modifier="$5" rc swapped=false
  # Cross-domain scenarios want the third-domain participant in slot 3;
  # slot order is same-domain-first for the plain multi-recipient tests.
  if [ "$modifier" = "x" ] && [ "${#P_ADDRS[@]}" -ge 5 ] && [ "$3" -lt 4 ]; then
    swap_p3_p4
    swapped=true
  fi
  fmsg_scenario_run "$@"
  rc=$?
  [ "$swapped" = "true" ] && swap_p3_p4
  return $rc
}
