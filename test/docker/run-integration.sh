#!/usr/bin/env bash
# Spins the systemd-enabled test container, copies the repo in (writable),
# and executes a named integration script under test/integration/.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${1:?usage: run-integration.sh <integration-script-name>}"
SERVICE="litesoup"

cd "${REPO_ROOT}/test/docker"

docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d --build

# Wait for systemd to be ready (max 30s)
for _ in $(seq 1 30); do
  if docker compose exec -T "${SERVICE}" systemctl is-system-running --wait >/dev/null 2>&1 \
     || docker compose exec -T "${SERVICE}" systemctl is-system-running 2>/dev/null \
        | grep -Eq 'running|degraded'; then
    break
  fi
  sleep 1
done

# Copy a writable repo snapshot into the container
docker compose exec -T "${SERVICE}" mkdir -p /opt/litesoup
docker cp "${REPO_ROOT}/." "$(docker compose ps -q ${SERVICE}):/opt/litesoup/"

# Execute the integration script inside the container
docker compose exec -T -w /opt/litesoup "${SERVICE}" \
  bash "test/integration/${SCRIPT}"

EXIT=$?
docker compose down --remove-orphans >/dev/null 2>&1 || true
exit "${EXIT}"
