#!/usr/bin/env bash
# Spins the systemd-enabled test container, copies the repo in (writable),
# and executes a named integration script under test/integration/.
#
# Uses plain `docker` (not docker compose) so it works identically on:
#   - macOS dev machines (Docker Desktop 20.10+ / OrbStack)
#   - GitHub Actions ubuntu-24.04 runners (Docker Engine 24+)
# without depending on Compose-version-specific keys like `cgroup: host`
# (which requires Compose >= 2.18).
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -lt 1 ]; then
  echo "usage: run-integration.sh <script-name> [<script-name> ...]" >&2
  echo "  Multiple scripts run sequentially in the SAME container -- one bring-up," >&2
  echo "  one apt install, one PPA fetch (matters for CloudPanel mirror politeness)." >&2
  exit 64
fi
IMG="litesoup-test:ubuntu2404-systemd"
NAME="litesoup-test"

cd "${REPO_ROOT}/test/docker"

# Wipe any prior container (ignore if absent)
docker rm -f "${NAME}" >/dev/null 2>&1 || true

# Build (cached after the first run)
docker build -t "${IMG}" -f Dockerfile.ubuntu2404-systemd .

# Run with the flags systemd-in-Docker requires.
# --cgroupns=host: systemd needs to see the host's cgroup tree
# -v /sys/fs/cgroup:rw: bind-mount cgroup fs (required on cgroup v2 hosts)
# --tmpfs /run, /run/lock, /tmp: systemd writes to these; tmpfs ensures they're writable + ephemeral
docker run -d \
  --name "${NAME}" \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "${IMG}" >/dev/null

# Wait up to 30s for systemd to be ready
for _ in $(seq 1 30); do
  state="$(docker exec "${NAME}" systemctl is-system-running 2>/dev/null || true)"
  if [[ "${state}" == "running" || "${state}" == "degraded" || "${state}" == "starting" ]]; then
    # 'starting' is acceptable; we re-probe in the next iteration unless stable
    if [[ "${state}" != "starting" ]]; then
      break
    fi
  fi
  sleep 1
done

# Sanity: container must still be running before we proceed
if ! docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null | grep -q true; then
  echo "ERROR: container ${NAME} exited before systemd was ready" >&2
  docker logs "${NAME}" 2>&1 | tail -50 >&2
  exit 1
fi

# Copy a writable repo snapshot into the container
docker exec "${NAME}" mkdir -p /opt/litesoup
docker cp "${REPO_ROOT}/." "${NAME}:/opt/litesoup/"

# Execute each integration script inside the SAME container in order. Stop
# at the first failure so a broken stage doesn't mask later regressions
# behind cascading failures.
EXIT=0
for SCRIPT in "$@"; do
  echo "=== ${SCRIPT} ==="
  if ! docker exec -w /opt/litesoup "${NAME}" bash "test/integration/${SCRIPT}"; then
    EXIT=$?
    echo "=== FAILED in ${SCRIPT} (exit ${EXIT}) ==="
    break
  fi
done

# Cleanup
docker rm -f "${NAME}" >/dev/null 2>&1 || true
exit "${EXIT}"
