#!/usr/bin/env bash
# Acceptance run for Plan I.D (TLS / Let's Encrypt).
# Runs end-to-end inside an Ubuntu 24.04 systemd container, captures all output.
# Re-runnable: nukes any prior litesoup-id container first.
#
# Validates the --tls=self-signed path end-to-end (HTTPS 200 + HTTP 301 redirect)
# plus the existing multi-PHP behavior. The --tls=letsencrypt path needs a real
# public hostname pointing at the test box; reviewer should run that on a real
# Ubuntu host (sg10.codetot.org / VPS / Multipass) -- see test/acceptance-i-d.md.

set -Eeuo pipefail

LOG="${1:-/Users/khoipro/Projects/litesoup/test/acceptance-i-d.log}"
CTR="litesoup-id"
REPO="/Users/khoipro/Projects/litesoup"

exec >"${LOG}" 2>&1

echo "===================================================================="
echo "Plan I.D acceptance run — $(date)"
echo "===================================================================="

# --- 0. cleanup any prior container ---
echo "[0] cleanup prior container"
docker rm -f "${CTR}" >/dev/null 2>&1 || true

# --- 1. bring up systemd container ---
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

docker exec "${CTR}" bash -lc 'apt-get update -qq && apt-get install -y curl ca-certificates software-properties-common gnupg lsb-release sudo >/dev/null'

# --- 2. install stack with two PHP versions + certbot (stage 6) ---
echo
echo "[2] install-stack --php-versions=8.2,8.4 (includes certbot stage 6)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh --php-versions=8.2,8.4'

# --- 3. verify FPM services + default pool disabled + certbot installed ---
echo
echo "[3] verify FPM services + disabled default pools + certbot + http2"
docker exec "${CTR}" bash -lc '
  set -e
  systemctl is-active php8.2-fpm
  systemctl is-active php8.4-fpm
  # Accept either www.conf.disabled (Ubuntu PPA) or default.conf.disabled
  # (CloudPanel mirror) -- whichever the installer disabled.
  ls /etc/php/8.2/fpm/pool.d/ | grep -qE "\.conf\.disabled$" && echo "  vendor pool disabled OK for 8.2"
  ls /etc/php/8.4/fpm/pool.d/ | grep -qE "\.conf\.disabled$" && echo "  vendor pool disabled OK for 8.4"
  test -S /run/php/litesoup-php8.2-fpm.sock && echo "  litesoup-php8.2 socket OK"
  command -v certbot >/dev/null && echo "  certbot installed"
  systemctl is-enabled certbot.timer >/dev/null && echo "  certbot.timer enabled"
  apache2ctl -M 2>/dev/null | grep -q http2 && echo "  apache mod_http2 enabled"
'

# --- 4. create two sites at different PHP versions, alpha with self-signed TLS ---
echo
echo "[4a] site-create alpha.test --php=8.2 --tls=self-signed"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=alpha.test --php=8.2 --tls=self-signed'

echo
echo "[4b] site-create beta.test --php=8.4 --tls=none (back-compat path)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-create.sh --domain=beta.test --php=8.4'

echo
echo "[4c] confirm beta socket + alpha self-signed cert artifacts"
docker exec "${CTR}" bash -lc '
  set -e
  test -S /run/php/litesoup-php8.4-fpm.sock && echo "  litesoup-php8.4 socket OK"
  test -f /etc/litesoup/ssl/alpha.test/fullchain.pem && echo "  alpha self-signed fullchain OK"
  test -f /etc/litesoup/ssl/alpha.test/privkey.pem   && echo "  alpha self-signed privkey OK"
  stat -c "%a" /etc/litesoup/ssl/alpha.test/privkey.pem | grep -q "^600$" && echo "  privkey.pem mode 0600 OK"
  test -L /etc/apache2/sites-enabled/alpha.test.conf && echo "  alpha vhost enabled"
  grep -q "VirtualHost \*:443" /etc/apache2/sites-available/alpha.test.conf && echo "  alpha :443 block present"
  ! grep -q "VirtualHost \*:443" /etc/apache2/sites-available/beta.test.conf && echo "  beta :443 block absent (correct, tls=none)"
'

# --- 5. curl phpinfo on both sites, confirm distinct PHP versions ---
echo
echo "[5a] curl info.php — confirm distinct PHP versions"
docker exec "${CTR}" bash -lc '
  set -e
  echo "<?php phpinfo(INFO_GENERAL);" | sudo -u litesoup tee /home/litesoup/webapps/alpha.test/info.php >/dev/null
  cp /home/litesoup/webapps/alpha.test/info.php /home/litesoup/webapps/beta.test/info.php
  ALPHA_VER=$(curl -k -s -H "Host: alpha.test" https://127.0.0.1/info.php | grep -oE "PHP Version => 8\.[0-9]+" | head -1)
  BETA_VER=$(curl    -s -H "Host: beta.test"  http://127.0.0.1/info.php  | grep -oE "PHP Version => 8\.[0-9]+" | head -1)
  echo "  alpha.test (HTTPS) reports: ${ALPHA_VER}"
  echo "  beta.test  (HTTP)  reports: ${BETA_VER}"
  [ "${ALPHA_VER}" = "PHP Version => 8.2" ] || { echo "FAIL: alpha expected 8.2"; exit 1; }
  [ "${BETA_VER}"  = "PHP Version => 8.4" ] || { echo "FAIL: beta expected 8.4"; exit 1; }
  echo "  PASS — versions distinct and correct"
'

# --- 5b. curl HTTPS install screen on alpha (200 with self-signed cert) ---
echo
echo "[5b] curl https://alpha.test/wp-admin/install.php (self-signed, expect 200)"
docker exec "${CTR}" bash -lc '
  set -e
  HTTPS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Host: alpha.test" https://127.0.0.1/wp-admin/install.php)
  echo "  alpha HTTPS install screen: HTTP ${HTTPS_CODE}"
  [ "${HTTPS_CODE}" = "200" ] || { echo "FAIL: expected 200"; exit 1; }
'

# --- 5c. HTTP -> HTTPS 301 redirect on alpha (TLS active) ---
echo
echo "[5c] curl http://alpha.test (TLS active, expect 301 redirect to https)"
docker exec "${CTR}" bash -lc '
  set -e
  HEADERS=$(curl -s -o /dev/null -D - -H "Host: alpha.test" http://127.0.0.1/wp-admin/install.php)
  STATUS=$(echo "${HEADERS}" | head -1 | tr -d "\r")
  LOCATION=$(echo "${HEADERS}" | grep -i "^Location:" | head -1 | tr -d "\r")
  echo "  status:   ${STATUS}"
  echo "  ${LOCATION}"
  echo "${STATUS}" | grep -q "301" || { echo "FAIL: expected 301"; exit 1; }
  echo "${LOCATION}" | grep -qi "^Location: https://" || { echo "FAIL: redirect not to https"; exit 1; }
'

# --- 5d. HTTP-only beta still serves on port 80 (back-compat) ---
echo
echo "[5d] curl http://beta.test (back-compat, expect 200 not 301)"
docker exec "${CTR}" bash -lc '
  set -e
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: beta.test" http://127.0.0.1/wp-admin/install.php)
  echo "  beta HTTP install screen: HTTP ${HTTP_CODE}"
  [ "${HTTP_CODE}" = "200" ] || { echo "FAIL: expected 200 (back-compat HTTP-only)"; exit 1; }
'

# --- 6. WP install screen on both ---
echo
echo "[6] curl WordPress install screen"
docker exec "${CTR}" bash -lc '
  set -e
  curl -k -s -H "Host: alpha.test" https://127.0.0.1/wp-admin/install.php | grep -q "WordPress" && echo "  alpha WP install screen OK (HTTPS)"
  curl    -s -H "Host: beta.test"  http://127.0.0.1/wp-admin/install.php  | grep -q "WordPress" && echo "  beta  WP install screen OK (HTTP)"
'

# --- 7. site-set-tls — flip beta from HTTP to self-signed HTTPS retroactively ---
echo
echo "[7] site-set-tls beta.test --tls=self-signed (retroactive TLS upgrade)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/site/site-set-tls.sh --domain=beta.test --tls=self-signed'

echo
echo "[7b] confirm beta now has HTTPS + cert artifacts + 301 redirect"
docker exec "${CTR}" bash -lc '
  set -e
  test -f /etc/litesoup/ssl/beta.test/fullchain.pem && echo "  beta self-signed fullchain OK"
  grep -q "VirtualHost \*:443" /etc/apache2/sites-available/beta.test.conf && echo "  beta :443 block present after upgrade"
  HTTPS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Host: beta.test" https://127.0.0.1/wp-admin/install.php)
  echo "  beta HTTPS install screen: HTTP ${HTTPS_CODE}"
  [ "${HTTPS_CODE}" = "200" ] || { echo "FAIL: expected 200 after upgrade"; exit 1; }
  STATUS=$(curl -s -o /dev/null -D - -H "Host: beta.test" http://127.0.0.1/wp-admin/install.php | head -1 | tr -d "\r")
  echo "  beta HTTP redirect: ${STATUS}"
  echo "${STATUS}" | grep -q "301" || { echo "FAIL: expected 301 after upgrade"; exit 1; }
'

# --- 8. idempotency re-run ---
echo
echo "[8] idempotency: re-run install-stack --php-versions=8.2,8.4"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh --php-versions=8.2,8.4' \
  | tee /tmp/idempotency-out.txt >/dev/null
docker exec "${CTR}" bash -lc 'cat /tmp/idempotency-out.txt'
echo

# --- 9. summary ---
echo "===================================================================="
echo "ACCEPTANCE: PASS"
echo "Container: ${CTR} (left running for inspection — docker rm -f ${CTR} to clean up)"
echo "===================================================================="
