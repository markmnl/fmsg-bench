#!/usr/bin/env bash
# Temporary DNS pinning for the duration of a bench run.
#
# Some resolvers stall for seconds when AAAA queries go unanswered (e.g. a
# router that silently drops them), adding a fixed multi-second cost to every
# fresh process that resolves a hostname — which is every fmsg-cli/python
# invocation the drivers make. Pinning the handful of API hostnames in
# /etc/hosts for the run removes name resolution from the equation entirely
# while keeping TLS certificate/SNI verification intact (unlike putting raw
# IPs in URLs).
#
#   dns_pin <hostname...>   resolve each name (A record) and add a marked
#                           block to /etc/hosts; registers an EXIT trap to
#                           remove it. Idempotent: an existing block (e.g.
#                           from a crashed run) is replaced.
#   dns_unpin               remove the marked block (also runs on EXIT).
#
# Editing /etc/hosts needs sudo: passwordless if available, otherwise an
# interactive prompt once at driver start (TTY runs only). If neither
# works, warns and continues with system DNS — pinning is an
# optimisation, never a hard requirement. (On very long runs the sudo
# credential may expire before exit; the leftover block is warned about
# and replaced by the next run.)

DNS_PIN_BEGIN="# >>> fmsg-bench dns pin (temporary, removed on run exit) >>>"
DNS_PIN_END="# <<< fmsg-bench dns pin <<<"
DNS_PIN_HOSTS_FILE="${DNS_PIN_HOSTS_FILE:-/etc/hosts}"

# Ensure a sudo credential is available: passwordless, or prompt when on
# a TTY. Returns 1 (with a warning) when neither is possible.
_dns_pin_sudo_ok() {
  sudo -n true 2>/dev/null && return 0
  if [ -t 0 ]; then
    log "dns-pin: sudo password needed to pin API hostnames in $DNS_PIN_HOSTS_FILE"
    sudo -v && return 0
  fi
  log "WARN: dns-pin: sudo unavailable — continuing with system DNS"
  return 1
}

dns_unpin() {
  grep -qF "$DNS_PIN_BEGIN" "$DNS_PIN_HOSTS_FILE" 2>/dev/null || return 0
  if sudo -n sed -i "\\%^$DNS_PIN_BEGIN\$%,\\%^$DNS_PIN_END\$%d" "$DNS_PIN_HOSTS_FILE" 2>/dev/null; then
    log "dns-pin: removed $DNS_PIN_HOSTS_FILE entries"
  else
    log "WARN: dns-pin: could not remove $DNS_PIN_HOSTS_FILE block (sudo expired?) — next run replaces it"
  fi
}

dns_pin() {
  [ $# -gt 0 ] || return 0
  _dns_pin_sudo_ok || return 0

  dns_unpin  # replace any stale block from a previous run

  local block="$DNS_PIN_BEGIN" host ip pinned=0
  for host in "$@"; do
    ip=$(dig +short +time=3 +tries=2 A "$host" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -n "$ip" ]; then
      block+=$'\n'"$ip $host"
      pinned=$((pinned + 1))
      log "dns-pin: $host -> $ip"
    else
      log "WARN: dns-pin: could not resolve $host — leaving it to system DNS"
    fi
  done
  block+=$'\n'"$DNS_PIN_END"

  if [ "$pinned" -eq 0 ]; then
    log "WARN: dns-pin: nothing resolved; $DNS_PIN_HOSTS_FILE unchanged"
    return 0
  fi

  printf '%s\n' "$block" | sudo -n tee -a "$DNS_PIN_HOSTS_FILE" >/dev/null \
    || { log "WARN: dns-pin: failed to write $DNS_PIN_HOSTS_FILE"; return 0; }
  trap dns_unpin EXIT
}
