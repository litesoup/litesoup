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

# All FPM pool sizing tiers this installer knows about. Tier is a property of
# the per-user+version pool, not the site -- multiple sites sharing the same
# pool share the tier.
SUPPORTED_POOL_TIERS=(small medium large)

# validate_pool_tier TIER -- exits 0 if TIER is in SUPPORTED_POOL_TIERS,
# 1 otherwise. Caller is responsible for any user-facing error message.
validate_pool_tier() {
  local t="${1:?validate_pool_tier: tier required}"
  local s
  for s in "${SUPPORTED_POOL_TIERS[@]}"; do
    [ "${s}" = "${t}" ] && return 0
  done
  return 1
}

# php_pool_tier_block TIER -- echo the multi-line pm.* block for the requested
# tier, ready to substitute into the pool template's __TIER_BLOCK__ placeholder.
# All knobs are set together so a tier change re-tunes the whole pool.
php_pool_tier_block() {
  local t="${1:?tier required}"
  case "${t}" in
    small)
      # ondemand only honors max_children + max_requests + process_idle_timeout.
      # start_servers / min_spare_servers / max_spare_servers are dynamic-only;
      # including them under ondemand makes `php-fpm --test` reject the pool
      # config (caught by Plan I.C ship adversarial review).
      cat <<'EOF'
pm = ondemand
pm.max_children = 5
pm.max_requests = 500
pm.process_idle_timeout = 30s
EOF
      ;;
    medium)
      # dynamic ignores process_idle_timeout — drop it so the rendered conf
      # doesn't carry dead directives that confuse operators reading it.
      cat <<'EOF'
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 1000
EOF
      ;;
    large)
      cat <<'EOF'
pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 2000
EOF
      ;;
    *)
      log_error "php: unsupported pool tier ${t} (allowed: ${SUPPORTED_POOL_TIERS[*]})"
      return 1
      ;;
  esac
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

# ensure_php_fpm VERSION -- install PHP <VERSION> + extensions + FPM via Ondrej PPA,
# then disable the default www.conf pool so every site must run via a per-user
# pool. Idempotent.
ensure_php_fpm() {
  local v="${1:?ensure_php_fpm: version required}"
  validate_php_version "${v}" \
    || { log_error "php: unsupported version ${v} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; return 1; }

  ensure_ppa "ppa:ondrej/php" "/etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources" \
    || { log_error "php: cannot install ${v} without ondrej PPA"; return 1; }

  local pkgs=() ext
  for ext in "${PHP_EXTENSIONS[@]}"; do
    pkgs+=("php${v}-${ext}")
  done
  ensure_pkgs "${pkgs[@]}"

  # Default `php` CLI -> PHP_VERSION_DEFAULT (only set when installing it).
  if [ "${v}" = "${PHP_VERSION_DEFAULT}" ] && command -v update-alternatives >/dev/null 2>&1; then
    run_or_dryrun update-alternatives --set php "/usr/bin/php${v}"
  fi

  # Start FPM with its default www.conf pool first, then disable that pool.
  run_or_dryrun systemctl enable --now "php${v}-fpm"

  local default_pool="/etc/php/${v}/fpm/pool.d/www.conf"
  if [ -f "${default_pool}" ]; then
    run_or_dryrun mv "${default_pool}" "${default_pool}.disabled"
    run_or_dryrun systemctl reload "php${v}-fpm"
  fi
}

# DEPRECATED -- kept as a back-compat shim for v0.1.0 callers. Removed in v0.3.0.
ensure_php_82_fpm() {
  log_warn "ensure_php_82_fpm is deprecated; use ensure_php_fpm 8.2"
  ensure_php_fpm "8.2"
}

# Per-user FPM socket path. Pool key = <user>-php<version>.
php_fpm_socket_for_user() {
  local user="${1:?user required}" v="${2:-${PHP_VERSION_DEFAULT}}"
  echo "/run/php/${user}-php${v}-fpm.sock"
}

# ensure_php_pool_for_user USER VERSION -- create a per-user FPM pool for
# PHP <VERSION>, owned by USER, listening on /run/php/<USER>-php<VERSION>-fpm.sock.
# Idempotent. Validates that PHP <VERSION> is installed before writing the pool.
ensure_php_pool_for_user() {
  local user="${1:?user required}"
  local v="${2:?version required}"
  local tier="${3:-small}"
  validate_php_version "${v}" \
    || { log_error "php: unsupported version ${v}"; return 1; }
  validate_pool_tier "${tier}" \
    || { log_error "php: unsupported tier ${tier}"; return 1; }

  if [ "${DRY_RUN}" != "1" ] && [ ! -d "/etc/php/${v}/fpm/pool.d" ]; then
    log_error "php: php${v}-fpm is not installed (run install-stack with --php-versions including ${v})"
    return 1
  fi

  local pool="${user}-php${v}"
  local conf="/etc/php/${v}/fpm/pool.d/${pool}.conf"
  local socket
  socket="$(php_fpm_socket_for_user "${user}" "${v}")"
  local repo_root
  repo_root="$(_php_repo_root)"

  ensure_user "${user}"

  # Pre-create per-user PHP runtime dirs
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

  # Detect same-tier re-run as no-op; otherwise re-render.
  if [ -f "${conf}" ]; then
    local current_tier
    current_tier="$(_php_pool_current_tier "${conf}")"
    if [ "${current_tier}" = "${tier}" ]; then
      log_info "php: pool ${pool} already configured (tier=${tier})"
      return 0
    fi
    log_info "php: pool ${pool} retuning tier ${current_tier} -> ${tier}"
  else
    log_info "php: creating pool ${pool} (socket ${socket}, tier=${tier})"
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would render ${conf} from templates/php/pool.conf.tmpl (tier=${tier})"
    return 0
  fi

  local tier_block
  tier_block="$(php_pool_tier_block "${tier}")"

  # python3 for the multi-line __TIER_BLOCK__ substitution (sed with newlines
  # in the replacement is portability-fragile; python3 is in the baseline via
  # python3-certbot-apache from Plan I.D's install-stack stage 6).
  python3 -c "
tmpl = open('${repo_root}/templates/php/pool.conf.tmpl').read()
out = (tmpl
  .replace('__POOL_NAME__',   '''${pool}''')
  .replace('__USER__',        '''${user}''')
  .replace('__SOCKET__',      '''${socket}''')
  .replace('__PHP_VERSION__', '''${v}''')
  .replace('__TIER_BLOCK__',  '''${tier_block}''')
)
open('${conf}', 'w').write(out)
"

  # Capture --test stderr so the operator sees actual syntax errors instead
  # of a generic failure (same defense as I.D's adversarial-fix on certbot).
  local fpm_test_err
  fpm_test_err="$(mktemp)"
  if ! "/usr/sbin/php-fpm${v}" --test 2>"${fpm_test_err}"; then
    log_error "php: pool config test failed for php${v}-fpm"
    cat "${fpm_test_err}" >&2
    rm -f "${fpm_test_err}"
    return 1
  fi
  rm -f "${fpm_test_err}"

  run_or_dryrun systemctl reload "php${v}-fpm" \
    || run_or_dryrun systemctl restart "php${v}-fpm"
}

# _php_pool_current_tier CONF_PATH -- inspect a rendered pool conf and echo
# the tier name (small|medium|large) based on its pm.max_children value.
# Returns "unknown" for hand-edited or pre-tier pools.
_php_pool_current_tier() {
  local conf="${1:?conf path required}"
  local mc
  mc="$(grep -E '^pm\.max_children\s*=' "${conf}" 2>/dev/null | head -1 | awk -F'=' '{gsub(/ /,"",$2); print $2}')"
  case "${mc}" in
    5)  echo "small" ;;
    20) echo "medium" ;;
    50) echo "large" ;;
    *)  echo "unknown" ;;
  esac
}

# DEPRECATED -- kept as a back-compat shim for v0.1.0 callers. Removed in v0.3.0.
ensure_php_82_pool_for_user() {
  log_warn "ensure_php_82_pool_for_user is deprecated; use ensure_php_pool_for_user <user> 8.2"
  ensure_php_pool_for_user "${1}" "8.2"
}
