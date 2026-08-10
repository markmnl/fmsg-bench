#!/usr/bin/env bash
# Tear down the two-domain fmsg bench lab (mirrors run-tests.sh cleanup).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

FMSG_DOCKER_ROOT="$WORKSPACE_ROOT/fmsg-docker"
BENCH_COMPOSE="$SCRIPT_DIR/docker-compose.bench.yml"

cd "$FMSG_DOCKER_ROOT/compose"

COMPOSE_PROJECT_NAME=hairpin FMSG_DOMAIN=hairpin.local FMSG_WEBAPI_HOST_PORT=8181 \
  "$CTR" compose -f docker-compose.yml -f ../test/docker-compose.test.yml -f "$BENCH_COMPOSE" down -v 2>/dev/null || true

COMPOSE_PROJECT_NAME=example FMSG_DOMAIN=example.com FMSG_WEBAPI_HOST_PORT=8182 \
  "$CTR" compose -f docker-compose.yml -f ../test/docker-compose.test.yml -f "$BENCH_COMPOSE" down -v 2>/dev/null || true

"$CTR" network rm fmsg-test 2>/dev/null || true
rm -rf "$FMSG_DOCKER_ROOT/test/.tls"
rm -f "$STATE_DIR/fmsg-keys.env"

echo "==> Bench lab torn down."
