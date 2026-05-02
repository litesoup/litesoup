#!/usr/bin/env bash
# install/install-stack.sh — Plan I.A entry point.
# Usage:
#   sudo bash install-stack.sh [--dry-run] [--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/distro.sh
source "${LIB_DIR}/distro.sh"
# shellcheck source=lib/apt.sh
source "${LIB_DIR}/apt.sh"
# shellcheck source=lib/users.sh
source "${LIB_DIR}/users.sh"
# shellcheck source=lib/apache.sh
source "${LIB_DIR}/apache.sh"
# shellcheck source=lib/php.sh
source "${LIB_DIR}/php.sh"
# shellcheck source=lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=lib/wp_cli.sh
source "${LIB_DIR}/wp_cli.sh"
# shellcheck source=lib/certbot.sh
source "${LIB_DIR}/certbot.sh"
# shellcheck source=lib/redis.sh
source "${LIB_DIR}/redis.sh"
# shellcheck source=lib/memcached.sh
source "${LIB_DIR}/memcached.sh"

usage() {
  cat <<'EOF'
litesoup install-stack — MVP WordPress stack for Ubuntu 24.04

Usage: sudo bash install-stack.sh [options]

Options:
  --php-versions=X.Y[,X.Y…]   PHP versions to install side-by-side
                              (default: 8.2,8.3,8.4; allowed: 8.0–8.5)
  --redis-maxmemory=SIZE      Override Redis maxmemory (e.g. 256mb, 1gb).
                              Default: auto from system RAM tier
                              (<2G→128mb, 2–8G→512mb, ≥8G→2gb).
  --dry-run                   Print actions without executing
  --help                      Show this help

Installs: Apache (mpm_event + http2), one PHP-FPM pool per requested version
          (Ondrej PPA, per-user pools), MariaDB, wp-cli, certbot for HTTPS,
          Redis (localhost + requirepass + RAM-tiered maxmemory), and
          Memcached (localhost, UDP off). Sites get HTTPS via
          `site-create.sh --tls=letsencrypt --email=ADDR` and pick up
          Redis credentials automatically (see docs/caching.md).
          Provisions the default site owner `litesoup` at
          /home/litesoup/webapps/ with a per-user pool at
          PHP_VERSION_DEFAULT (8.2).
EOF
}

main() {
  local arg
  local php_versions_csv=""
  local redis_maxmemory=""
  for arg in "$@"; do
    case "${arg}" in
      --php-versions=*)    php_versions_csv="${arg#*=}" ;;
      --redis-maxmemory=*) redis_maxmemory="${arg#*=}" ;;
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  # Validate --redis-maxmemory shape if supplied (digits + optional unit suffix).
  if [ -n "${redis_maxmemory}" ] \
      && ! [[ "${redis_maxmemory}" =~ ^[0-9]+(b|k|kb|m|mb|g|gb)?$ ]]; then
    log_error "--redis-maxmemory: malformed: '${redis_maxmemory}' (expected e.g. 256mb, 1gb, or bytes)"
    exit 64
  fi

  # Default version set if --php-versions not supplied.
  local -a php_versions
  if [ -z "${php_versions_csv}" ]; then
    # --php-versions with no argument (empty string after =) is an error.
    # Only default when --php-versions was never passed at all.
    local saw_flag=0
    for arg in "$@"; do
      case "${arg}" in --php-versions=*) saw_flag=1 ;; esac
    done
    if [ "${saw_flag}" = "1" ]; then
      log_error "--php-versions: empty or malformed: '${php_versions_csv}'"; exit 64
    fi
    php_versions=(8.2 8.3 8.4)
  else
    if ! [[ "${php_versions_csv}" =~ ^[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+)*$ ]]; then
      log_error "--php-versions: empty or malformed: '${php_versions_csv}'"; exit 64
    fi
    IFS=',' read -r -a php_versions <<<"${php_versions_csv}"
  fi

  # Validate every requested version against SUPPORTED_PHP_VERSIONS.
  local v
  for v in "${php_versions[@]}"; do
    validate_php_version "${v}" \
      || { log_error "unsupported PHP version: ${v} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
  done

  # PHP_VERSION_DEFAULT must be in the install set.
  local default_in_set=0
  for v in "${php_versions[@]}"; do
    [ "${v}" = "${PHP_VERSION_DEFAULT}" ] && default_in_set=1
  done
  if [ "${default_in_set}" = "0" ]; then
    log_error "--php-versions must include the default PHP version (${PHP_VERSION_DEFAULT})"; exit 64
  fi

  require_root
  require_ubuntu_2404

  log_info "stage 1/8: apache"
  ensure_apache

  log_info "stage 2/8: php (versions: ${php_versions[*]})"
  for v in "${php_versions[@]}"; do
    log_info "  -> php ${v}"
    ensure_php_fpm "${v}"
  done

  log_info "stage 3/8: default site owner (${DEFAULT_SITE_USER}) + per-user pool @ ${PHP_VERSION_DEFAULT}"
  ensure_user "${DEFAULT_SITE_USER}"
  ensure_php_pool_for_user "${DEFAULT_SITE_USER}" "${PHP_VERSION_DEFAULT}"

  log_info "stage 4/8: mariadb"
  ensure_mariadb

  log_info "stage 5/8: wp-cli"
  ensure_wp_cli

  log_info "stage 6/8: certbot (LE auto-renewal)"
  ensure_certbot

  log_info "stage 7/8: redis"
  ensure_redis "${redis_maxmemory}"

  log_info "stage 8/8: memcached"
  ensure_memcached

  log_info "litesoup install-stack: COMPLETE"
}

main "$@"
