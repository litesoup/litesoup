#!/usr/bin/env bash
# install/lib/php.sh -- PHP 8.2 FPM via Ondrej PPA (single version for plan I.A;
# multi-version + per-site --php=X.Y comes in plan I.B). Provides a per-user
# pool helper so each site owner runs PHP under their own UID with open_basedir.
# Requires: install/lib/users.sh (ensure_user) sourced first.

[ -n "${LITESOUP_PHP_SH:-}" ] && return 0
LITESOUP_PHP_SH=1

PHP_VERSION_DEFAULT="8.2"

# All PHP versions this installer knows how to provision via Ondrej PPA.
# Plan I.B scope; expand here when a new release lands.
SUPPORTED_PHP_VERSIONS=(8.0 8.1 8.2 8.3 8.4 8.5)

# validate_php_version VERSION -- exits 0 if VERSION is in SUPPORTED_PHP_VERSIONS,
# 1 otherwise. Caller is responsible for any user-facing error message.
validate_php_version() {
  local v="${1:?validate_php_version: version required}"
  local s
  for s in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    [ "${s}" = "${v}" ] && return 0
  done
  return 1
}

PHP_EXTENSIONS=(
  fpm cli common opcache mysql mbstring xml curl gd zip intl bcmath soap imagick redis
)

# Resolve the litesoup repo root (works whether sourced from install-stack.sh or
# from site-create.sh). Allows test override via LITESOUP_REPO_ROOT.
_php_repo_root() {
  if [ -n "${LITESOUP_REPO_ROOT:-}" ]; then echo "${LITESOUP_REPO_ROOT}"; return; fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

ensure_php_82_fpm() {
  ensure_ppa "ppa:ondrej/php" "/etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources"

  local pkgs=()
  local ext
  for ext in "${PHP_EXTENSIONS[@]}"; do
    pkgs+=("php${PHP_VERSION_DEFAULT}-${ext}")
  done
  ensure_pkgs "${pkgs[@]}"

  # CLI default -> 8.2
  if command -v update-alternatives >/dev/null 2>&1; then
    run_or_dryrun update-alternatives --set php "/usr/bin/php${PHP_VERSION_DEFAULT}"
  fi

  # Start FPM with its default www.conf pool first, then immediately disable
  # the default pool -- every site must run as its owner via a per-user pool.
  # Renaming (rather than deleting) preserves the upstream copy for reference
  # and lets re-runs detect "already disabled".
  run_or_dryrun systemctl enable --now "php${PHP_VERSION_DEFAULT}-fpm"

  local default_pool="/etc/php/${PHP_VERSION_DEFAULT}/fpm/pool.d/www.conf"
  if [ -f "${default_pool}" ]; then
    run_or_dryrun mv "${default_pool}" "${default_pool}.disabled"
    run_or_dryrun systemctl reload "php${PHP_VERSION_DEFAULT}-fpm"
  fi
}

# Per-user FPM socket path. Pool key = <user>-php<version>.
php_fpm_socket_for_user() {
  local user="${1:?user required}" v="${2:-${PHP_VERSION_DEFAULT}}"
  echo "/run/php/${user}-php${v}-fpm.sock"
}

# Render and install a per-user FPM pool config, then reload php-fpm.
# Idempotent: re-running with the same user is a no-op.
ensure_php_82_pool_for_user() {
  local user="${1:?user required}"
  local v="${PHP_VERSION_DEFAULT}"
  local pool="${user}-php${v}"
  local conf="/etc/php/${v}/fpm/pool.d/${pool}.conf"
  local socket
  socket="$(php_fpm_socket_for_user "${user}" "${v}")"
  local repo_root
  repo_root="$(_php_repo_root)"

  ensure_user "${user}"

  # Pre-create per-user PHP runtime dirs (open_basedir will reject writes outside)
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would ensure /home/${user}/{.php_tmp,.php_sessions,.logs}"
  else
    local d
    for d in ".php_tmp" ".php_sessions" ".logs"; do
      if [ ! -d "/home/${user}/${d}" ]; then
        install -d -o "${user}" -g "${user}" -m 0700 "/home/${user}/${d}"
      fi
    done
  fi

  if [ -f "${conf}" ]; then
    log_info "php: pool ${pool} already configured"
    return 0
  fi

  log_info "php: creating pool ${pool} (socket ${socket})"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would render ${conf} from templates/php/pool.conf.tmpl"
  else
    sed -e "s|__POOL_NAME__|${pool}|g" \
        -e "s|__USER__|${user}|g" \
        -e "s|__SOCKET__|${socket}|g" \
        -e "s|__PHP_VERSION__|${v}|g" \
        "${repo_root}/templates/php/pool.conf.tmpl" >"${conf}"
  fi

  # Validate the new pool config before asking systemd to reload — fail fast
  # if the rendered template is broken.
  if [ "${DRY_RUN}" != "1" ]; then
    "/usr/sbin/php-fpm${v}" --test 2>/dev/null \
      || { log_error "php: pool config test failed for php${v}-fpm"; return 1; }
  fi
  run_or_dryrun systemctl reload "php${v}-fpm" \
    || run_or_dryrun systemctl restart "php${v}-fpm"
}
