#!/usr/bin/env bash
# Acceptance run for Plan I.B (multi-version PHP).
# Runs end-to-end inside an Ubuntu 24.04 systemd container, captures all output.
# Re-runnable: nukes any prior litesoup-ib container first.

set -Eeuo pipefail

LOG="${1:-/Users/khoipro/Projects/litesoup/test/acceptance-i-b.log}"
CTR="litesoup-ib"
REPO="/Users/khoipro/Projects/litesoup"

exec >"${LOG}" 2>&1

echo "===================================================================="
echo "Plan I.B acceptance run — $(date)"
echo "===================================================================="

# --- 0. cleanup any prior container ---
echo "[0] cleanup prior container"
docker rm -f "${CTR}" >/dev/null 2>&1 || true

# --- 1. bring up systemd container ---
# Use geerlingguy/docker-ubuntu2404-ansible -- has systemd, sudo, python preinstalled.
# Pre-built for systemd-in-docker via cgroup v2 mounts.
IMAGE="geerlingguy/docker-ubuntu2404-ansible:latest"

echo "[1] pull + start ${IMAGE}"
docker pull "${IMAGE}" >/dev/null
docker run -d --name "${CTR}" --privileged \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "${REPO}:/litesoup" -w /litesoup \
  "${IMAGE}"

# wait for systemd to settle
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if docker exec "${CTR}" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded|starting'; then
    echo "  systemd ready (try ${i})"
    break
  fi
  sleep 1
done

# image has python/ansible preinstalled but we still need apt update + curl
docker exec "${CTR}" bash -lc 'apt-get update -qq && apt-get install -y curl ca-certificates software-properties-common gnupg lsb-release sudo >/dev/null'

# --- 2. install stack with two PHP versions ---
echo
echo "[2] install-stack --php-versions=8.2,8.4"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh --php-versions=8.2,8.4'

# --- 3. verify FPM services + default pool disabled ---
echo
echo "[3] verify FPM services + disabled default pools"
docker exec "${CTR}" bash -lc '
  set -e
  systemctl is-active php8.2-fpm
  systemctl is-active php8.4-fpm
  test -f /etc/php/8.2/fpm/pool.d/www.conf.disabled && echo "  www.conf.disabled OK for 8.2"
  test -f /etc/php/8.4/fpm/pool.d/www.conf.disabled && echo "  www.conf.disabled OK for 8.4"
  test -S /run/php/litesoup-php8.2-fpm.sock && echo "  litesoup-php8.2 socket OK"
'

# --- 4. create two sites at different PHP versions ---
echo
echo "[4a] site-create alpha.test --php=8.2"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=alpha.test --php=8.2'

echo
echo "[4b] site-create beta.test  --php=8.4"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=beta.test --php=8.4'

echo
echo "[4c] confirm beta socket created"
docker exec "${CTR}" bash -lc 'test -S /run/php/litesoup-php8.4-fpm.sock && echo "  litesoup-php8.4 socket OK"'

# --- 5. add /etc/hosts entries + verify per-site PHP version ---
echo
echo "[5] curl info.php on each site, confirm distinct PHP versions"
docker exec "${CTR}" bash -lc '
  set -e
  echo "<?php phpinfo(INFO_GENERAL);" | sudo -u litesoup tee /home/litesoup/webapps/alpha.test/info.php >/dev/null
  cp /home/litesoup/webapps/alpha.test/info.php /home/litesoup/webapps/beta.test/info.php
  ALPHA_VER=$(curl -s -H "Host: alpha.test" http://127.0.0.1/info.php | grep -oE "PHP Version => 8\.[0-9]+" | head -1)
  BETA_VER=$(curl -s -H "Host: beta.test"  http://127.0.0.1/info.php | grep -oE "PHP Version => 8\.[0-9]+" | head -1)
  echo "  alpha.test reports: ${ALPHA_VER}"
  echo "  beta.test  reports: ${BETA_VER}"
  [ "${ALPHA_VER}" = "PHP Version => 8.2" ] || { echo "FAIL: alpha expected 8.2"; exit 1; }
  [ "${BETA_VER}"  = "PHP Version => 8.4" ] || { echo "FAIL: beta expected 8.4"; exit 1; }
  echo "  PASS — versions distinct and correct"
'

# --- 6. WP install screen ---
echo
echo "[6] curl WordPress install screen"
docker exec "${CTR}" bash -lc '
  set -e
  curl -s -H "Host: alpha.test" http://127.0.0.1/wp-admin/install.php | grep -q "WordPress" && echo "  alpha WP install screen OK"
  curl -s -H "Host: beta.test"  http://127.0.0.1/wp-admin/install.php | grep -q "WordPress" && echo "  beta  WP install screen OK"
'

# --- 7. idempotency re-run ---
echo
echo "[7] idempotency: re-run install-stack --php-versions=8.2,8.4"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh --php-versions=8.2,8.4' \
  | tee /tmp/idempotency-out.txt >/dev/null
docker exec "${CTR}" bash -lc 'cat /tmp/idempotency-out.txt'
echo

# --- 8. summary ---
echo "===================================================================="
echo "ACCEPTANCE: PASS"
echo "Container: ${CTR} (left running for inspection — docker rm -f ${CTR} to clean up)"
echo "===================================================================="
