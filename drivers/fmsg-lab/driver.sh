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

source "$BENCH_ROOT/lib/fmsg-scenario.sh"

driver_run_scenario() {
  fmsg_scenario_run "$@"
}
