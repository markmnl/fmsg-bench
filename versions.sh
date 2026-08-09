#!/usr/bin/env bash
# Record software versions for the white paper's appendix so runs can be
# replicated. Writes results/versions.txt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

OUT="$RESULTS_DIR/versions.txt"
mkdir -p "$RESULTS_DIR"

{
  echo "recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $(uname -srmo)"
  echo ""
  echo "## workspace repos"
  for repo in fmsg-spec fmsgd fmsg-webapi fmsgid fmsg-cli fmsg-docker fmsg-bench; do
    dir="$WORKSPACE_ROOT/$repo"
    if [ -d "$dir/.git" ]; then
      echo "$repo: $(git -C "$dir" rev-parse --short HEAD) ($(git -C "$dir" log -1 --format=%cs))"
    elif [ -d "$dir" ]; then
      echo "$repo: (not a git checkout)"
    fi
  done
  echo ""
  echo "## tools"
  docker --version 2>/dev/null || true
  docker compose version 2>/dev/null | head -1 || true
  tcpdump --version 2>&1 | head -1 || true
  tshark -v 2>/dev/null | head -1 || true
  go version 2>/dev/null || true
  python3 --version 2>/dev/null || true
  jq --version 2>/dev/null || true
  echo ""
  echo "## payloads"
  if [ -f "$PAYLOADS_DIR/checksums.txt" ]; then
    cat "$PAYLOADS_DIR/checksums.txt"
  else
    echo "(payloads not generated yet)"
  fi
} > "$OUT"

echo "==> wrote $OUT"
cat "$OUT"
