#!/usr/bin/env bash
# Runs install-stack.sh end-to-end inside container, then asserts services
# and the default per-user pool layout.
set -Eeuo pipefail
trap 'echo "FAIL @ ${BASH_SOURCE##*/}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
cd /opt/litesoup

bash install/install-stack.sh

echo "[chk] post-install assertions"
systemctl is-active --quiet apache2
systemctl is-active --quiet php8.2-fpm
systemctl is-active --quiet mariadb

# Default Ubuntu pool is disabled
[ ! -f /etc/php/8.2/fpm/pool.d/www.conf ]
[ -f /etc/php/8.2/fpm/pool.d/www.conf.disabled ]

# Default site user provisioned with correct home perms
id litesoup >/dev/null
[ "$(stat -c '%a %U:%G' /home/litesoup)" = "711 litesoup:litesoup" ]
[ -d /home/litesoup/webapps ]

# Per-user pool socket present
[ -S /run/php/litesoup-php8.2-fpm.sock ]
[ -f /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf ]

# Hardening assertions (from previous fixes)
grep -q 'disable_functions' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
grep -q 'expose_php\] = off' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
if grep -E 'open_basedir.*[^a-z]/tmp/' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf; then
  echo "FAIL: /tmp/ leaked into open_basedir" >&2
  exit 1
fi

# wp-cli installed
[ -x /usr/local/bin/wp ]

# MariaDB secure
mysqladmin --defaults-file=/root/.litesoup-mariadb-root ping | grep -q 'mysqld is alive'

# --- Plan I.F: redis + memcached infrastructure ---

# Services up
systemctl is-active --quiet redis-server
systemctl is-active --quiet memcached

# Redis password file present with correct mode/owner
[ -f /etc/litesoup/redis.env ]
[ "$(stat -c '%a %U:%G' /etc/litesoup/redis.env)" = "640 root:root" ]
grep -qE '^REDIS_PASSWORD=[A-Za-z0-9]{32}$' /etc/litesoup/redis.env

# Redis override config wired in
[ -f /etc/redis/litesoup.conf ]
grep -qE '^bind 127\.0\.0\.1 -::1$'        /etc/redis/litesoup.conf
grep -qE '^protected-mode yes$'             /etc/redis/litesoup.conf
grep -qE '^requirepass [A-Za-z0-9]{32}$'    /etc/redis/litesoup.conf
grep -qE '^maxmemory [0-9]+(b|kb|mb|gb)?$'  /etc/redis/litesoup.conf
grep -qE '^maxmemory-policy allkeys-lru$'   /etc/redis/litesoup.conf
grep -qE "^[[:space:]]*include[[:space:]]+/etc/redis/litesoup\.conf[[:space:]]*$" /etc/redis/redis.conf

# Redis listening only on loopback (no external bind)
ss -ltn | awk '$4 ~ /:6379$/ {print $4}' | while read -r addr; do
  case "${addr}" in
    127.0.0.1:6379|"[::1]:6379") ;;
    *) echo "FAIL: redis bound to non-loopback ${addr}" >&2; exit 1 ;;
  esac
done

# AUTH+PING with the persisted password
REDIS_PW="$(. /etc/litesoup/redis.env && printf '%s' "${REDIS_PASSWORD}")"
redis-cli -a "${REDIS_PW}" --no-auth-warning ping | grep -q '^PONG$'

# Effective maxmemory matches what we wrote (Redis normalizes the value to bytes)
expected_max="$(awk '/^maxmemory / {print $2}' /etc/redis/litesoup.conf)"
[ -n "${expected_max}" ]

# Memcached managed block present + reachable
grep -q '^# >>> litesoup-managed' /etc/memcached.conf
grep -q '^-l 127\.0\.0\.1$'       /etc/memcached.conf
grep -q '^-U 0$'                  /etc/memcached.conf
ss -ltn | awk '$4 ~ /:11211$/ {print $4}' | while read -r addr; do
  case "${addr}" in
    127.0.0.1:11211|"[::1]:11211") ;;
    *) echo "FAIL: memcached bound to non-loopback ${addr}" >&2; exit 1 ;;
  esac
done
# Memcached UDP is OFF (no listening UDP socket on 11211)
if ss -lun | awk '$4 ~ /:11211$/ {print $4}' | grep -q .; then
  echo "FAIL: memcached UDP socket is open on 11211" >&2
  exit 1
fi
# version probe
printf 'version\r\nquit\r\n' | timeout 2 bash -c 'cat >/dev/tcp/127.0.0.1/11211' >/dev/null

# Snapshot Redis password + override-conf checksum to verify a re-run preserves them
REDIS_PW_BEFORE="${REDIS_PW}"
OVERRIDE_SUM_BEFORE="$(md5sum /etc/redis/litesoup.conf | cut -d' ' -f1)"
MEMCACHED_SUM_BEFORE="$(md5sum /etc/memcached.conf | cut -d' ' -f1)"

# Re-run to verify idempotency (no duplicate-pool errors, no useradd retries,
# Redis password NOT rotated, managed include line not duplicated, memcached
# block converged)
bash install/install-stack.sh

REDIS_PW_AFTER="$(. /etc/litesoup/redis.env && printf '%s' "${REDIS_PASSWORD}")"
[ "${REDIS_PW_BEFORE}" = "${REDIS_PW_AFTER}" ] || { echo "FAIL: redis password rotated on re-run" >&2; exit 1; }
[ "${OVERRIDE_SUM_BEFORE}" = "$(md5sum /etc/redis/litesoup.conf | cut -d' ' -f1)" ] \
  || { echo "FAIL: /etc/redis/litesoup.conf changed on re-run" >&2; exit 1; }
[ "${MEMCACHED_SUM_BEFORE}" = "$(md5sum /etc/memcached.conf | cut -d' ' -f1)" ] \
  || { echo "FAIL: /etc/memcached.conf changed on re-run" >&2; exit 1; }

# Include line should appear at most once after the second run
include_count="$(grep -cE "^[[:space:]]*include[[:space:]]+/etc/redis/litesoup\.conf[[:space:]]*$" /etc/redis/redis.conf || true)"
[ "${include_count}" = "1" ] || { echo "FAIL: include line count = ${include_count} (want 1)" >&2; exit 1; }

# --redis-maxmemory override flows through (third run with explicit value)
bash install/install-stack.sh --redis-maxmemory=64mb
grep -qE '^maxmemory 64mb$' /etc/redis/litesoup.conf

echo "01_install_stack: PASS"
