#!/usr/bin/env bash
# install/lib/redis.sh — Redis 7.x with localhost-only binding, requirepass,
# and RAM-tier-sized maxmemory.
#
# The Redis password is generated once and persisted to /etc/litesoup/redis.env
# (mode 0640 root:root). site-create.sh reads it as root before dropping into
# the per-site user via sudo, then injects WP_REDIS_PASSWORD into wp-config.php.

[ -n "${LITESOUP_REDIS_SH:-}" ] && return 0
LITESOUP_REDIS_SH=1

LITESOUP_ETC_DIR="/etc/litesoup"
REDIS_ENV_FILE="${LITESOUP_ETC_DIR}/redis.env"
REDIS_BASE_CONF="/etc/redis/redis.conf"
REDIS_OVERRIDE_CONF="/etc/redis/litesoup.conf"

_redis_gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }

# Map total system RAM (MiB) → (tier, default maxmemory).
# Echoes "tier maxmemory" on stdout.
_redis_tier_for_ram() {
  local mem_mb="$1"
  if [ "${mem_mb}" -lt 2048 ]; then
    echo "small 128mb"
  elif [ "${mem_mb}" -lt 8192 ]; then
    echo "medium 512mb"
  else
    echo "large 2gb"
  fi
}

# ensure_redis [maxmemory_override]
#   maxmemory_override -- e.g. "256mb", "1gb". If empty, auto-tier from RAM.
ensure_redis() {
  local override="${1:-}"

  ensure_pkgs redis-server

  # /etc/litesoup/ holds litesoup-managed runtime state files.
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would ensure ${LITESOUP_ETC_DIR}/ exists (mode 0755 root:root)"
  else
    install -d -m 0755 -o root -g root "${LITESOUP_ETC_DIR}"
  fi

  # 1. Resolve / generate the Redis password.
  local pw=""
  if [ -f "${REDIS_ENV_FILE}" ]; then
    log_info "redis: reusing existing password (${REDIS_ENV_FILE})"
    # shellcheck disable=SC1090
    pw="$(. "${REDIS_ENV_FILE}" && printf '%s' "${REDIS_PASSWORD:-}")"
    if [ -z "${pw}" ]; then
      log_error "redis: ${REDIS_ENV_FILE} exists but REDIS_PASSWORD is empty"
      return 1
    fi
  else
    pw="$(_redis_gen_pw)"
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would generate password and write ${REDIS_ENV_FILE} (0640 root:root)"
    else
      log_info "redis: generating password and writing ${REDIS_ENV_FILE}"
      umask 077
      printf 'REDIS_PASSWORD=%s\n' "${pw}" > "${REDIS_ENV_FILE}"
      chmod 0640 "${REDIS_ENV_FILE}"
      chown root:root "${REDIS_ENV_FILE}"
    fi
  fi

  # 2. Determine maxmemory: explicit override wins over RAM tier.
  local maxmem tier
  if [ -n "${override}" ]; then
    maxmem="${override}"
    tier="override"
  else
    local mem_kb mem_mb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    mem_mb=$(( mem_kb / 1024 ))
    read -r tier maxmem < <(_redis_tier_for_ram "${mem_mb}")
    log_info "redis: detected ${mem_mb}MB RAM → tier=${tier} maxmemory=${maxmem}"
  fi

  # 3. Render desired override config.
  local desired
  desired="$(cat <<EOF
# /etc/redis/litesoup.conf — managed by litesoup install-stack.sh.
# Re-running install-stack.sh may overwrite this file. Edit redis.conf for
# changes you want to persist outside litesoup.
bind 127.0.0.1 -::1
protected-mode yes
requirepass ${pw}
maxmemory ${maxmem}
maxmemory-policy allkeys-lru
EOF
)"

  local changed=0

  # 4. Write override only if content changed.
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would write ${REDIS_OVERRIDE_CONF} (tier=${tier} maxmemory=${maxmem})"
    changed=1
  else
    local current=""
    [ -f "${REDIS_OVERRIDE_CONF}" ] && current="$(cat "${REDIS_OVERRIDE_CONF}")"
    if [ "${current}" != "${desired}" ]; then
      log_info "redis: writing ${REDIS_OVERRIDE_CONF} (tier=${tier} maxmemory=${maxmem})"
      umask 077
      printf '%s\n' "${desired}" > "${REDIS_OVERRIDE_CONF}"
      chmod 0640 "${REDIS_OVERRIDE_CONF}"
      chown root:redis "${REDIS_OVERRIDE_CONF}"
      changed=1
    else
      log_info "redis: ${REDIS_OVERRIDE_CONF} already up to date"
    fi
  fi

  # 5. Ensure base redis.conf includes our override (last include wins).
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would ensure 'include ${REDIS_OVERRIDE_CONF}' in ${REDIS_BASE_CONF}"
  else
    if ! grep -qE "^[[:space:]]*include[[:space:]]+${REDIS_OVERRIDE_CONF}[[:space:]]*$" "${REDIS_BASE_CONF}"; then
      log_info "redis: appending include directive to ${REDIS_BASE_CONF}"
      printf '\n# litesoup-managed override include\ninclude %s\n' "${REDIS_OVERRIDE_CONF}" >> "${REDIS_BASE_CONF}"
      changed=1
    fi
  fi

  # 6. Enable + start; restart only if config changed.
  run_or_dryrun systemctl enable --now redis-server
  if [ "${changed}" = "1" ]; then
    run_or_dryrun systemctl restart redis-server
  fi

  # 7. Smoke test (skipped in dry-run): AUTH + PING via the new password.
  if [ "${DRY_RUN}" != "1" ]; then
    local _x
    for _x in $(seq 1 15); do
      if redis-cli -a "${pw}" --no-auth-warning ping 2>/dev/null | grep -q '^PONG$'; then
        log_info "redis: AUTH+PING ok"
        return 0
      fi
      sleep 1
    done
    log_error "redis: AUTH+PING failed within 15s after restart"
    return 1
  fi
}
