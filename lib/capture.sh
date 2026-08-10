#!/usr/bin/env bash
# Packet-capture helpers. One tcpdump per repetition, SIGINT to flush.
#
# Interface resolution handles docker (bridge br-<network-id>) and podman
# (NetworkInterface, including rootless where the bridge lives inside the
# rootless netns and tcpdump must run via `podman unshare --rootless-netns`).
# Override detection entirely with BENCH_CAPTURE_IFACE.

CAPTURE_PID=""
CAPTURE_PCAP=""
CAPTURE_ROOTLESS=false

# Resolve the host interface for a container network.
# Prints "rootless:<iface>" when the iface only exists in the rootless netns.
resolve_network_iface() {
  local network="$1"
  local id iface

  if [ -n "${BENCH_CAPTURE_IFACE:-}" ]; then
    echo "$BENCH_CAPTURE_IFACE"
    return
  fi

  if id=$(docker network inspect -f '{{.Id}}' "$network" 2>/dev/null) && [ -n "$id" ]; then
    iface="br-${id:0:12}"
    if [ -e "/sys/class/net/$iface" ]; then
      echo "$iface"
      return
    fi
  fi

  if command -v podman >/dev/null 2>&1; then
    iface=$(podman network inspect "$network" --format '{{.NetworkInterface}}' 2>/dev/null || true)
    if [ -n "$iface" ]; then
      if [ -e "/sys/class/net/$iface" ]; then
        echo "$iface"
      else
        echo "rootless:$iface"
      fi
      return
    fi
  fi

  echo "ERROR: cannot resolve capture interface for network '$network'." >&2
  echo "       Set BENCH_CAPTURE_IFACE explicitly." >&2
  return 1
}

# start_capture <iface|rootless:iface|ssh:host:iface> <bpf-filter> <pcap-path>
#
# ssh:<host>:<iface> streams tcpdump from a remote host (passwordless
# sudo required there) back into the local pcap — used for the email
# capture on the mailcow host without changing anything on it.
start_capture() {
  local iface="$1"
  local filter="$2"
  local pcap="$3"

  mkdir -p "$(dirname "$pcap")"
  rm -f "$pcap"
  CAPTURE_PCAP="$pcap"
  CAPTURE_ROOTLESS=false
  CAPTURE_SSH_HOST=""
  CAPTURE_SSH_IFACE=""

  if [[ "$iface" == ssh:* ]]; then
    CAPTURE_SSH_HOST="$(cut -d: -f2 <<<"$iface")"
    CAPTURE_SSH_IFACE="$(cut -d: -f3 <<<"$iface")"
    CAPTURE_SSH_FILTER="$filter"
    ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$CAPTURE_SSH_HOST" \
      "sudo -n tcpdump -i $CAPTURE_SSH_IFACE -s 0 -U -w - $filter" \
      > "$pcap" 2>"$pcap.tcpdump.log" &
  elif [[ "$iface" == rootless:* ]]; then
    CAPTURE_ROOTLESS=true
    iface="${iface#rootless:}"
    # -Z root: inside the user namespace "root" is the invoking user, so
    # this keeps the pcap writable/owned sanely instead of tcpdump
    # dropping to a subuid that cannot create files in results/.
    podman unshare --rootless-netns \
      tcpdump -i "$iface" -s 0 -U -Z root -w "$pcap" $filter \
      >/dev/null 2>"$pcap.tcpdump.log" &
  elif [ "$(id -u)" = "0" ]; then
    tcpdump -i "$iface" -s 0 -U -Z root -w "$pcap" $filter \
      >/dev/null 2>"$pcap.tcpdump.log" &
  else
    sudo -n tcpdump -i "$iface" -s 0 -U -Z root -w "$pcap" $filter \
      >/dev/null 2>"$pcap.tcpdump.log" &
  fi
  CAPTURE_PID=$!

  # Wait for tcpdump to actually be capturing before the scenario starts
  # (remote ssh+sudo startup can take several seconds under load).
  local i
  for i in $(seq 1 200); do
    [ -s "$pcap" ] && break
    if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
      echo "ERROR: tcpdump exited early:" >&2
      cat "$pcap.tcpdump.log" >&2
      return 1
    fi
    sleep 0.1
  done
  if [ ! -s "$pcap" ]; then
    echo "ERROR: capture failed to start within 20s (no pcap header)" >&2
    kill "$CAPTURE_PID" 2>/dev/null || true
    return 1
  fi
}

stop_capture() {
  [ -n "$CAPTURE_PID" ] || return 0

  if [ -n "$CAPTURE_SSH_HOST" ]; then
    # Match the full command incl. filter so concurrent captures on the
    # same remote interface (different campaigns) don't kill each other.
    ssh -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$CAPTURE_SSH_HOST" \
      "sudo -n pkill -INT -f 'tcpdump -i $CAPTURE_SSH_IFACE -s 0 -U -w - $CAPTURE_SSH_FILTER'" 2>/dev/null || true
  elif [ "$CAPTURE_ROOTLESS" = "true" ]; then
    # Signal the tcpdump child directly: SIGINT to the podman-unshare
    # wrapper may not propagate. (-U packet-buffering means nothing is
    # lost either way.)
    pkill -INT -f -- "tcpdump.*-w $CAPTURE_PCAP" 2>/dev/null || kill -INT "$CAPTURE_PID" 2>/dev/null || true
  elif [ "$(id -u)" != "0" ]; then
    # tcpdump runs under sudo; signal it via sudo too.
    sudo -n kill -INT "$CAPTURE_PID" 2>/dev/null || kill -INT "$CAPTURE_PID" 2>/dev/null || true
  else
    kill -INT "$CAPTURE_PID" 2>/dev/null || true
  fi
  wait "$CAPTURE_PID" 2>/dev/null || true
  CAPTURE_PID=""

  # Root-owned pcaps are unreadable by the analysis step.
  if [ -n "$CAPTURE_PCAP" ] && [ -e "$CAPTURE_PCAP" ] && [ ! -r "$CAPTURE_PCAP" ]; then
    sudo -n chown "$(id -u):$(id -g)" "$CAPTURE_PCAP" 2>/dev/null || true
  fi
  rm -f "$CAPTURE_PCAP.tcpdump.log"
  CAPTURE_PCAP=""
}
