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
  --skip-hardening            Skip stages 9-11 (firewall, fail2ban,
                              unattended-upgrades). Use for dev VMs or
                              when host-managed elsewhere.
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
  local skip_hardening=0
  for arg in "$@"; do
    case "${arg}" in
      --php-versions=*)    php_versions_csv="${arg#*=}" ;;
      --redis-maxmemory=*) redis_maxmemory="${arg#*=}" ;;
      --skip-hardening)    skip_hardening=1 ;;
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

  # Stage count: without --skip-hardening, composer (9) + node (10) + hardening/stages 11-18 run.
  # With --skip-hardening, stages 9-12 run (composer + node + install scripts + litesoup-cli).
  local total_stages=18
  [ "${skip_hardening}" = "1" ] && total_stages=12

  log_info "stage 1/${total_stages}: apache"
  ensure_apache

  log_info "stage 2/${total_stages}: php (versions: ${php_versions[*]})"
  for v in "${php_versions[@]}"; do
    log_info "  -> php ${v}"
    ensure_php_fpm "${v}"
  done

  log_info "stage 3/${total_stages}: default site owner (${DEFAULT_SITE_USER}) + per-user pool(s)"
  ensure_user "${DEFAULT_SITE_USER}"
  for _pv in "${php_versions[@]}"; do
    log_info "  -> pool ${DEFAULT_SITE_USER} @ php ${_pv}"
    ensure_php_pool_for_user "${DEFAULT_SITE_USER}" "${_pv}"
  done

  log_info "stage 4/${total_stages}: mariadb"
  ensure_mariadb

  log_info "stage 5/${total_stages}: wp-cli"
  ensure_wp_cli

  log_info "stage 6/${total_stages}: certbot (LE auto-renewal)"
  ensure_certbot

  log_info "stage 7/${total_stages}: redis"
  ensure_redis "${redis_maxmemory}"

  log_info "stage 8/${total_stages}: memcached"
  ensure_memcached

  log_info "stage 9/${total_stages}: composer"
  if ! command -v composer &>/dev/null; then
    run_or_dryrun apt_install composer
  else
    log_info "  -> composer already installed"
  fi

  log_info "stage 10/${total_stages}: node.js + npm"
  if ! command -v node &>/dev/null; then
    # Nodesource setup for Node.js 22.x LTS
    if [ "${DRY_RUN:-0}" != "1" ]; then
      if ! command -v node &>/dev/null; then
        apt_install ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
          | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
          > /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq && apt_install nodejs
      fi
    else
      log_info "  [dry-run] would install nodejs from nodesource"
    fi
  else
    log_info "  -> node $(node --version 2>/dev/null || echo 'unknown') already installed"
  fi

  # Define paths used by both hardening install stage and backup stage.
  # Must be declared before the skip_hardening if/else since repo_root is
  # needed by the backup stage (which runs after hardening, regardless of
  # whether hardening was skipped).
  local litesoup_lib=/usr/lib/litesoup
  local repo_root="${SCRIPT_DIR}/.."

  if [ "${skip_hardening}" = "1" ]; then
    log_info "litesoup install-stack: hardening stages skipped via --skip-hardening"
  else
    # Hardening stages must run AFTER services are up: harden-fail2ban watches
    # /var/log/apache2/*error.log which only exists once Apache is installed
    # (stage 1). harden-firewall opens 80/443 — fine to do before or after
    # Apache, but doing it after keeps "services first, lock down second"
    # ordering consistent with traditional sysadmin practice.
    local harden_dir="${SCRIPT_DIR}/../harden"

    log_info "stage 11/${total_stages}: harden-firewall (ufw)"
    run_or_dryrun bash "${harden_dir}/harden-firewall.sh"

  log_info "stage 12/${total_stages}: harden-fail2ban"
  run_or_dryrun bash "${harden_dir}/harden-fail2ban.sh"

  log_info "stage 13/${total_stages}: harden-unattended-upgrades"
  run_or_dryrun bash "${harden_dir}/harden-unattended-upgrades.sh"

  # Hardening stages 14-16 added in v0.7.0. CRITICAL: harden-ssh disables
  # PasswordAuthentication. If you bootstrap a host via password-only SSH
  # (e.g., fresh DO droplet's root password), running install-stack will
  # lock you out on next session. Always set up an SSH key BEFORE running
  # install-stack on a new host. The script writes /etc/ssh/sshd_config.d/
  # so you can re-enable password auth via a higher-numbered file if you
  # explicitly want it (see /etc/ssh/sshd_config.d/52-litesoup-harden.conf).
  log_info "stage 14/${total_stages}: harden-ssh (always-safe defaults; --no-password-auth / --no-root-login are opt-in)"
  run_or_dryrun bash "${harden_dir}/harden-ssh.sh"

  log_info "stage 15/${total_stages}: harden-apache (ServerTokens, headers, mod_status local-only)"
  run_or_dryrun bash "${harden_dir}/harden-apache.sh"

  log_info "stage 16/${total_stages}: harden-php (php.ini hardening per version)"
  run_or_dryrun bash "${harden_dir}/harden-php.sh"

  fi  # end of skip_hardening else block

  log_info "stage 17/${total_stages}: install scripts to /usr/lib/litesoup"
  run_or_dryrun install -d -m 0755 "${litesoup_lib}"
  for dir in install site harden audit; do
    run_or_dryrun install -d -m 0755 "${litesoup_lib}/${dir}"
    if [ "${DRY_RUN:-0}" != "1" ]; then
      find "${repo_root}/${dir}" -maxdepth 1 -name "*.sh" \
        -exec install -m 0755 {} "${litesoup_lib}/${dir}/" \;
    else
      log_info "  [dry-run] would install ${dir}/*.sh → ${litesoup_lib}/${dir}/"
    fi
  done
  # install/lib/ is sourced by audit + site scripts via REPO_ROOT/install/lib/
  if [ "${DRY_RUN:-0}" != "1" ]; then
    install -d -m 0755 "${litesoup_lib}/install/lib"
    find "${repo_root}/install/lib" -maxdepth 1 -name "*.sh" \
      -exec install -m 0644 {} "${litesoup_lib}/install/lib/" \;
  else
    log_info "  [dry-run] would install install/lib/*.sh → ${litesoup_lib}/install/lib/"
  fi
  # templates/ is required by site scripts (_vhost_render.sh, ensure_php_pool_for_user)
  if [ "${DRY_RUN:-0}" != "1" ]; then
    cp -r "${repo_root}/templates" "${litesoup_lib}/"
  else
    log_info "  [dry-run] would copy templates/ → ${litesoup_lib}/templates/"
  fi
  run_or_dryrun install -m 0644 "${repo_root}/VERSION" "${litesoup_lib}/VERSION"

  # Enable the 000-default catch-all vhost (serves 404 for IP/direct access).
  # Prevents fallback to the alphabetically-first named site when no
  # ServerName matches.
  if [ -f "${repo_root}/templates/apache/000-default.conf.tmpl" ]; then
    run_or_dryrun install -m 0644 \
      "${repo_root}/templates/apache/000-default.conf.tmpl" \
      "/etc/apache2/sites-available/000-default.conf"
    run_or_dryrun a2ensite 000-default.conf 2>/dev/null || true
  fi

  log_info "stage 18/${total_stages}: install litesoup-cli (optional)"
  local cli_install_url="https://raw.githubusercontent.com/litesoup/litesoup-cli/main/install.sh"
  if command -v curl &>/dev/null; then
    local _cli_tmp
    _cli_tmp="$(mktemp)"
    if curl -fsSL "${cli_install_url}" -o "${_cli_tmp}" 2>/dev/null; then
      run_or_dryrun bash "${_cli_tmp}" || true
    else
      log_info "litesoup-cli install script unavailable — skipping"
    fi
    rm -f "${_cli_tmp}"
  fi

  # Stage 19: install backup scripts + notify helper (no root access to
  # S3/email config needed — that's done by backup-install.sh when the
  # operator is ready).
  local backup_stage=$(( total_stages + 1 ))
  log_info "stage ${backup_stage}/${total_stages}: backup scripts + notification"
  local repo_backup="${repo_root}/backup"
  if [ -d "${repo_backup}" ]; then
    run_or_dryrun install -d -m 0755 "${litesoup_lib}/backup/lib"
    # shell scripts (entry points)
    for _f in "${repo_backup}"/*.sh; do
      run_or_dryrun install -m 0755 "${_f}" "${litesoup_lib}/backup/"
    done
    # lib scripts
    for _f in "${repo_backup}/lib/"*.sh; do
      run_or_dryrun install -m 0644 "${_f}" "${litesoup_lib}/backup/lib/"
    done
    # notify.sh (shared between install and backup)
    if [ -f "${repo_root}/install/lib/notify.sh" ]; then
      run_or_dryrun install -m 0644 "${repo_root}/install/lib/notify.sh" "${litesoup_lib}/install/lib/"
    fi
  else
    log_info "backup scripts not found (backup/ directory missing) - skipping"
  fi

  log_info "litesoup install-stack: COMPLETE"
}

main "$@"
