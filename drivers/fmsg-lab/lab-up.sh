#!/usr/bin/env bash
# =============================================================
# Start the two-domain fmsg bench lab.
#
# Provenance: trimmed copy of the start section of
# fmsg-docker/test/run-tests.sh, plus docker-compose.bench.yml
# (poll interval / max message size / retry interval overrides).
# Keep the two in sync if run-tests.sh's startup changes.
#
# Stacks:
#   hairpin.local  webapi http://localhost:8181  fmsgd host-port 4931
#   example.com    webapi http://localhost:8182  fmsgd host-port 4932
# Container-to-container fmsg traffic crosses the "fmsg-test"
# bridge network on port 4930 (host-port mappings are irrelevant
# to the capture).
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

FMSG_DOCKER_ROOT="$WORKSPACE_ROOT/fmsg-docker"
[ -d "$FMSG_DOCKER_ROOT/compose" ] || fail "fmsg-docker not found at $FMSG_DOCKER_ROOT"
[ -n "$CTR" ] || fail "neither docker nor podman found"
require_cmd openssl curl

BENCH_COMPOSE="$SCRIPT_DIR/docker-compose.bench.yml"
COMPOSE_FILES=(-f docker-compose.yml -f ../test/docker-compose.test.yml -f "$BENCH_COMPOSE")

# ── Common env vars (mirrors run-tests.sh) ───────────────────
export PGPASSWORD=testpgpass
export FMSGD_WRITER_PGPASSWORD=testfmsgdwriter
export FMSGD_READER_PGPASSWORD=testfmsgdreader
export FMSGID_WRITER_PGPASSWORD=testfmsgidwriter
export FMSGID_READER_PGPASSWORD=testfmsgidreader
export FMSG_SKIP_DOMAIN_IP_CHECK=true
export FMSG_SKIP_AUTHORISED_IPS=true
export FMSG_API_TOKEN_ED25519_PRIVATE_KEY="${FMSG_API_TOKEN_ED25519_PRIVATE_KEY:-$(openssl rand -base64 32)}"
export FMSG_TLS_INSECURE_SKIP_VERIFY=true
export FMSGD_REF=${FMSGD_REF:-main}
export FMSGID_REF=${FMSGID_REF:-main}
export FMSG_WEBAPI_REF=${FMSG_WEBAPI_REF:-main}
# Busts the git-clone layer in the image builds so `main` is re-fetched.
# Pin it (e.g. CACHEBUST=0) to reuse cached images across lab restarts.
export CACHEBUST="${CACHEBUST:-$(date +%s)}"

# ── Shared network ───────────────────────────────────────────
if ! "$CTR" network inspect fmsg-test >/dev/null 2>&1; then
  log "Creating fmsg-test network..."
  "$CTR" network create fmsg-test
fi

# ── Self-signed TLS certificates (paths mounted by the test override)
TLS_DIR="$FMSG_DOCKER_ROOT/test/.tls"
if [ ! -f "$TLS_DIR/fmsg.hairpin.local.crt" ] || [ ! -f "$TLS_DIR/fmsg.example.com.crt" ]; then
  log "Generating self-signed TLS certificates..."
  mkdir -p "$TLS_DIR"
  for domain in hairpin.local example.com; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$TLS_DIR/fmsg.${domain}.key" \
      -out "$TLS_DIR/fmsg.${domain}.crt" \
      -days 30 -nodes \
      -subj "//CN=fmsg.${domain}" \
      -addext "subjectAltName=DNS:fmsg.${domain}"
  done
  chmod 644 "$TLS_DIR"/*.key
fi

# ── Start both stacks ────────────────────────────────────────
cd "$FMSG_DOCKER_ROOT/compose"

log "Starting hairpin.local stack..."
COMPOSE_PROJECT_NAME=hairpin \
FMSG_DOMAIN=hairpin.local \
FMSG_PORT=4931 \
FMSG_WEBAPI_HOST_PORT=8181 \
  "$CTR" compose "${COMPOSE_FILES[@]}" up -d --build --force-recreate --no-deps --wait

log "Starting example.com stack..."
COMPOSE_PROJECT_NAME=example \
FMSG_DOMAIN=example.com \
FMSG_PORT=4932 \
FMSG_WEBAPI_HOST_PORT=8182 \
  "$CTR" compose "${COMPOSE_FILES[@]}" up -d --build --force-recreate --wait

# ── Wait for webapi endpoints ────────────────────────────────
for port in 8181 8182; do
  log "Waiting for fmsg-webapi on port $port..."
  for i in $(seq 1 30); do
    if curl -s -o /dev/null --connect-timeout 2 "http://localhost:$port/" 2>/dev/null; then
      echo "    ready"
      break
    fi
    [ "$i" -eq 30 ] && fail "timed out waiting for port $port"
    sleep 2
  done
done

# ── Seed users ───────────────────────────────────────────────
log "Seeding users..."
"$CTR" exec -i hairpin-postgres-1 psql -U postgres < "$FMSG_DOCKER_ROOT/test/seed-hairpin.sql"
"$CTR" exec -i example-postgres-1 psql -U postgres < "$FMSG_DOCKER_ROOT/test/seed-example.sql"
"$CTR" exec -i example-postgres-1 psql -U postgres < "$SCRIPT_DIR/seed-bench.sql"

log "Bench lab is up."
echo "    hairpin.local webapi: http://localhost:8181"
echo "    example.com   webapi: http://localhost:8182"
echo "    Run './bench.sh fmsg <scenario ...>' from $BENCH_ROOT"
