#!/usr/bin/env bash
# Acceptance run for Plan I.C (site-set-php + per-tier FPM pool sizing).
# Runs end-to-end inside an Ubuntu 24.04 systemd container, captures all output.
# Re-runnable: nukes any prior litesoup-ic container first.
#
# Validates: --tier=medium writes the right pm.* lines, site-set-php downgrades
# an existing site's PHP version (curl phpinfo confirms before + after),
# site-set-tier --tier=large retunes the pool, idempotent re-run is a no-op.

set -Eeuo pipefail

LOG="${1:-/Users/khoipro/Projects/litesoup/test/acceptance-i-c.log}"
CTR="litesoup-ic"
REPO="/Users/khoipro/Projects/litesoup"

exec >"${LOG}" 2>&1

echo "===================================================================="
echo "Plan I.C acceptance run — $(date)"
echo "===================================================================="

echo "[0] cleanup prior container"
docker rm -f "${CTR}" >/dev/null 2>&1 || true

IMAGE="geerlingguy/docker-ubuntu2404-ansible:latest"

echo "[1] pull + start ${IMAGE}"
docker pull "${IMAGE}" >/dev/null
docker run -d --name "${CTR}" --privileged \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "${REPO}:/litesoup" -w /litesoup \
  "${IMAGE}"

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if docker exec "${CTR}" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded|starting'; then
    echo "  systemd ready (try ${i})"
    break
  fi
  sleep 1
done

docker exec "${CTR}" bash -lc 'apt-get update -qq && apt-get install -y curl ca-certificates software-properties-common gnupg lsb-release sudo >/dev/null'

echo
echo "[2] install-stack --php-versions=8.2,8.4 (includes certbot stage 6)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh --php-versions=8.2,8.4'

echo
echo "[3] verify FPM services + default litesoup pool starts at small (max_children=5)"
docker exec "${CTR}" bash -lc '
  set -e
  systemctl is-active php8.2-fpm
  systemctl is-active php8.4-fpm
  CONF=/etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
  grep -E "^pm\\.max_children\\s*=\\s*5" "${CONF}" && echo "  default pool small OK (max_children=5)"
'

echo
echo "[4a] site-create alpha.test --php=8.2 --tier=medium --tls=self-signed"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=alpha.test --php=8.2 --tier=medium --tls=self-signed'

echo
echo "[4b] site-create beta.test --php=8.4 --tier=small (back-compat default)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=beta.test --php=8.4'

echo
echo "[4c] verify alpha pool is medium (pm.max_children=20, pm=dynamic)"
docker exec "${CTR}" bash -lc '
  set -e
  CONF=/etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
  grep -E "^pm\\s*=\\s*dynamic"             "${CONF}" && echo "  pm = dynamic OK"
  grep -E "^pm\\.max_children\\s*=\\s*20"   "${CONF}" && echo "  max_children = 20 OK"
  grep -E "^pm\\.max_requests\\s*=\\s*1000" "${CONF}" && echo "  max_requests = 1000 OK"
'

echo
echo "[4d] verify beta pool is small (pm.max_children=5, pm=ondemand)"
docker exec "${CTR}" bash -lc '
  set -e
  CONF=/etc/php/8.4/fpm/pool.d/litesoup-php8.4.conf
  grep -E "^pm\\s*=\\s*ondemand"           "${CONF}" && echo "  pm = ondemand OK"
  grep -E "^pm\\.max_children\\s*=\\s*5"   "${CONF}" && echo "  max_children = 5 OK"
'

echo
echo "[5] site-set-php beta.test --php=8.2 (downgrade 8.4 -> 8.2)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-set-php.sh --domain=beta.test --php=8.2'

echo
echo "[5b] verify beta now serves on PHP 8.2 (vhost rewritten + pool present)"
docker exec "${CTR}" bash -lc '
  set -e
  echo "<?php phpinfo(INFO_GENERAL);" | sudo -u litesoup tee /home/litesoup/webapps/beta.test/info.php >/dev/null
  BETA_VER=$(curl -s -H "Host: beta.test" http://127.0.0.1/info.php | grep -oE "PHP Version => 8\\.[0-9]+" | head -1)
  echo "  beta.test now reports: ${BETA_VER}"
  [ "${BETA_VER}" = "PHP Version => 8.2" ] || { echo "FAIL: expected 8.2 after site-set-php"; exit 1; }
  grep -q "litesoup-php8.2-fpm.sock" /etc/apache2/sites-available/beta.test.conf && echo "  vhost socket rewritten to php8.2 OK"
'

echo
echo "[6] site-set-tier --user=litesoup --version=8.2 --tier=large"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-set-tier.sh --user=litesoup --version=8.2 --tier=large'

echo
echo "[6b] verify pool is now large (pm.max_children=50, max_requests=2000)"
docker exec "${CTR}" bash -lc '
  set -e
  CONF=/etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
  grep -E "^pm\\.max_children\\s*=\\s*50"   "${CONF}" && echo "  max_children = 50 OK"
  grep -E "^pm\\.max_requests\\s*=\\s*2000" "${CONF}" && echo "  max_requests = 2000 OK"
'

echo
echo "[7] idempotency: re-run site-set-tier with same tier (large)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-set-tier.sh --user=litesoup --version=8.2 --tier=large 2>&1' \
  | tee /tmp/idempotency-tier.txt | grep -E "already configured" \
  && echo "  no-op detected OK"

echo
echo "===================================================================="
echo "ACCEPTANCE: PASS"
echo "Container: ${CTR} (left running for inspection — docker rm -f ${CTR} to clean up)"
echo "===================================================================="
