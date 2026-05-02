#!/usr/bin/env bash
# Acceptance run for Plan I.F (Redis + Memcached infrastructure +
# WP_CACHE_KEY_SALT injection). Spins an Ubuntu 24.04 systemd container,
# installs the stack, validates Redis + Memcached posture, creates two
# sites and verifies the per-site cache constants are injected and stable
# across re-runs.
#
# Re-runnable: nukes any prior litesoup-if container first.

set -Eeuo pipefail

LOG="${1:-/Users/khoipro/Projects/litesoup/test/acceptance-i-f.log}"
CTR="litesoup-if"
REPO="/Users/khoipro/Projects/litesoup"

exec >"${LOG}" 2>&1

echo "===================================================================="
echo "Plan I.F acceptance run -- $(date)"
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

docker exec "${CTR}" bash -lc 'apt-get update -qq && apt-get install -y curl ca-certificates software-properties-common gnupg lsb-release sudo iproute2 redis-tools >/dev/null'

echo
echo "[2] install-stack (default flags -- redis tier auto-detected from RAM)"
docker exec "${CTR}" bash -lc 'sudo bash /litesoup/install/install-stack.sh'

echo
echo "[3] verify redis + memcached running, configs correct"
docker exec "${CTR}" bash -lc '
  set -e
  systemctl is-active --quiet redis-server  && echo "  redis-server active"
  systemctl is-active --quiet memcached      && echo "  memcached active"

  test -f /etc/litesoup/redis.env             && echo "  /etc/litesoup/redis.env present"
  [ "$(stat -c "%a %U:%G" /etc/litesoup/redis.env)" = "640 root:root" ] && echo "  redis.env mode/owner OK (640 root:root)"
  grep -qE "^REDIS_PASSWORD=[A-Za-z0-9]{32}$" /etc/litesoup/redis.env   && echo "  REDIS_PASSWORD shape OK (32 alnum)"

  test -f /etc/redis/litesoup.conf            && echo "  /etc/redis/litesoup.conf present"
  grep -q "^bind 127.0.0.1 -::1$"             /etc/redis/litesoup.conf && echo "  bind 127.0.0.1 -::1 OK"
  grep -q "^protected-mode yes$"              /etc/redis/litesoup.conf && echo "  protected-mode yes OK"
  grep -qE "^requirepass [A-Za-z0-9]{32}$"    /etc/redis/litesoup.conf && echo "  requirepass set OK"
  grep -qE "^maxmemory [0-9]+(b|kb|mb|gb)?$"  /etc/redis/litesoup.conf && echo "  maxmemory set OK ($(awk "/^maxmemory / {print \$2}" /etc/redis/litesoup.conf))"
  grep -q "^maxmemory-policy allkeys-lru$"    /etc/redis/litesoup.conf && echo "  maxmemory-policy allkeys-lru OK"
  grep -qE "^[[:space:]]*include[[:space:]]+/etc/redis/litesoup\.conf[[:space:]]*$" /etc/redis/redis.conf && echo "  include directive in redis.conf OK"

  ss -ltn | awk "\$4 ~ /:6379\$/ {print \$4}" | while read -r addr; do
    case "${addr}" in
      127.0.0.1:6379|"[::1]:6379") ;;
      *) echo "FAIL: redis bound to non-loopback ${addr}"; exit 1 ;;
    esac
  done
  echo "  redis bound to loopback only OK"

  REDIS_PW="$(. /etc/litesoup/redis.env && printf "%s" "${REDIS_PASSWORD}")"
  redis-cli -a "${REDIS_PW}" --no-auth-warning ping | grep -q "^PONG$" && echo "  redis AUTH+PING OK"

  grep -q "^# >>> litesoup-managed" /etc/memcached.conf && echo "  memcached managed block present"
  grep -q "^-l 127.0.0.1$"          /etc/memcached.conf && echo "  memcached -l 127.0.0.1 OK"
  grep -q "^-U 0$"                  /etc/memcached.conf && echo "  memcached -U 0 (UDP off) OK"
  ss -ltn | awk "\$4 ~ /:11211\$/ {print \$4}" | while read -r addr; do
    case "${addr}" in
      127.0.0.1:11211|"[::1]:11211") ;;
      *) echo "FAIL: memcached bound to non-loopback ${addr}"; exit 1 ;;
    esac
  done
  echo "  memcached bound to loopback only OK"
  if ss -lun | awk "\$4 ~ /:11211\$/ {print \$4}" | grep -q .; then
    echo "FAIL: memcached UDP socket open"; exit 1
  fi
  echo "  memcached UDP off OK"
'

echo
echo "[4] site-create alpha-cache.test + beta-cache.test, verify per-site salts"
docker exec "${CTR}" bash -lc '
  set -e
  echo "127.0.0.1 alpha-cache.test" >> /etc/hosts
  echo "127.0.0.1 beta-cache.test"  >> /etc/hosts
  sudo bash /litesoup/site/site-create.sh --domain=alpha-cache.test
  sudo bash /litesoup/site/site-create.sh --domain=beta-cache.test

  WP1=/home/litesoup/webapps/alpha-cache.test
  WP2=/home/litesoup/webapps/beta-cache.test
  salt1="$(sudo -H -u litesoup wp --path="${WP1}" config get WP_CACHE_KEY_SALT --type=constant)"
  salt2="$(sudo -H -u litesoup wp --path="${WP2}" config get WP_CACHE_KEY_SALT --type=constant)"
  echo "  alpha salt: ${salt1}"
  echo "  beta  salt: ${salt2}"
  [[ "${salt1}" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: alpha salt bad shape"; exit 1; }
  [[ "${salt2}" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: beta salt bad shape"; exit 1; }
  [ "${salt1}" != "${salt2}" ]       || { echo "FAIL: salts collided"; exit 1; }
  echo "  per-site salts distinct + 64-char hex OK"

  for k in WP_REDIS_HOST WP_REDIS_PORT WP_REDIS_PASSWORD WP_REDIS_DATABASE; do
    v="$(sudo -H -u litesoup wp --path="${WP1}" config get "${k}" --type=constant)"
    echo "  alpha ${k} = ${v:0:8}..."
  done
  WP_REDIS_PW="$(sudo -H -u litesoup wp --path="${WP1}" config get WP_REDIS_PASSWORD --type=constant)"
  ENV_REDIS_PW="$(. /etc/litesoup/redis.env && printf "%s" "${REDIS_PASSWORD}")"
  [ "${WP_REDIS_PW}" = "${ENV_REDIS_PW}" ] && echo "  WP_REDIS_PASSWORD matches /etc/litesoup/redis.env OK"
'

echo
echo "[5] re-run site-create on alpha-cache.test, verify salt NOT rotated"
docker exec "${CTR}" bash -lc '
  set -e
  WP1=/home/litesoup/webapps/alpha-cache.test
  salt_before="$(sudo -H -u litesoup wp --path="${WP1}" config get WP_CACHE_KEY_SALT --type=constant)"
  sudo bash /litesoup/site/site-create.sh --domain=alpha-cache.test || true
  salt_after="$(sudo -H -u litesoup wp --path="${WP1}" config get WP_CACHE_KEY_SALT --type=constant)"
  [ "${salt_before}" = "${salt_after}" ] && echo "  salt unchanged on site-create re-run OK"
'

echo
echo "[6] re-run install-stack, verify redis password + configs unchanged"
docker exec "${CTR}" bash -lc '
  set -e
  PW_BEFORE="$(. /etc/litesoup/redis.env && printf "%s" "${REDIS_PASSWORD}")"
  REDIS_SUM_BEFORE="$(md5sum /etc/redis/litesoup.conf | cut -d" " -f1)"
  MC_SUM_BEFORE="$(md5sum /etc/memcached.conf | cut -d" " -f1)"
  sudo bash /litesoup/install/install-stack.sh
  PW_AFTER="$(. /etc/litesoup/redis.env && printf "%s" "${REDIS_PASSWORD}")"
  [ "${PW_BEFORE}" = "${PW_AFTER}" ] && echo "  redis password unchanged on re-run OK"
  [ "${REDIS_SUM_BEFORE}" = "$(md5sum /etc/redis/litesoup.conf | cut -d" " -f1)" ] && echo "  /etc/redis/litesoup.conf unchanged on re-run OK"
  [ "${MC_SUM_BEFORE}" = "$(md5sum /etc/memcached.conf | cut -d" " -f1)" ] && echo "  /etc/memcached.conf unchanged on re-run OK"
  cnt="$(grep -cE "^[[:space:]]*include[[:space:]]+/etc/redis/litesoup\.conf[[:space:]]*$" /etc/redis/redis.conf)"
  [ "${cnt}" = "1" ] && echo "  include directive count = 1 OK"
'

echo
echo "[7] --redis-maxmemory override flows through"
docker exec "${CTR}" bash -lc '
  set -e
  sudo bash /litesoup/install/install-stack.sh --redis-maxmemory=64mb
  grep -qE "^maxmemory 64mb$" /etc/redis/litesoup.conf && echo "  maxmemory now 64mb OK"
  redis-cli -a "$(. /etc/litesoup/redis.env && printf "%s" "${REDIS_PASSWORD}")" --no-auth-warning CONFIG GET maxmemory | grep -q "67108864" && echo "  redis CONFIG GET maxmemory == 64mb OK"
'

echo "===================================================================="
echo "ACCEPTANCE: PASS"
echo "Container: ${CTR} (left running for inspection -- docker rm -f ${CTR} to clean up)"
echo "===================================================================="
