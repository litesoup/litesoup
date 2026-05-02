#!/usr/bin/env bash
# site/site-set-php.sh -- change the PHP version of an existing site.
# Usage: sudo bash site-set-php.sh --domain=DOMAIN --php=X.Y [--dry-run]
#
# Looks up the site's owner / docroot / TLS mode from its existing Apache
# vhost, ensures the per-user pool exists for the new PHP version (creates
# it if first site for owner+new-version), re-renders the vhost so its FPM
# SetHandler points at the new socket, runs apache configtest + reload.
# TLS mode is preserved (auto-detected from the existing vhost). No DB /
# docroot / WP changes.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export LITESOUP_REPO_ROOT="${REPO_ROOT}"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/users.sh
source "${REPO_ROOT}/install/lib/users.sh"
# shellcheck source=../install/lib/php.sh
source "${REPO_ROOT}/install/lib/php.sh"
# shellcheck source=../install/lib/certbot.sh
source "${REPO_ROOT}/install/lib/certbot.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

# Test hook (same pattern as site-create.sh / site-set-tls.sh).
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

DOMAIN=""
PHP_VERSION=""
TLS_MODE="none"          # populated by detect_tls_mode below

usage() {
  cat <<'EOF'
litesoup site-set-php -- change PHP version of an existing site

Usage: sudo bash site-set-php.sh --domain=DOMAIN --php=X.Y [--dry-run]
  --domain=D  domain of the existing site
  --php=X.Y   new PHP version (must be installed by install-stack)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)  DOMAIN="${arg#*=}" ;;
      --php=*)     PHP_VERSION="${arg#*=}" ;;
      --dry-run)   DRY_RUN=1 ;;
      --help|-h)   usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  [ -n "${DOMAIN}" ]      || { log_error "--domain is required"; usage; exit 64; }
  [ -n "${PHP_VERSION}" ] || { log_error "--php is required";    usage; exit 64; }
  validate_php_version "${PHP_VERSION}" \
    || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
}

# Detect TLS mode from the existing vhost. If the vhost has a `<VirtualHost
# *:443>` block AND its SSLCertificateFile points under /etc/letsencrypt/, the
# mode is letsencrypt; if it points under /etc/litesoup/ssl/ the mode is
# self-signed; otherwise none.
detect_tls_mode() {
  local vhost="/etc/apache2/sites-available/${DOMAIN}.conf"
  [ -f "${vhost}" ] || { TLS_MODE="none"; return 0; }
  if ! grep -q '<VirtualHost \*:443>' "${vhost}"; then
    TLS_MODE="none"; return 0
  fi
  if grep -qE 'SSLCertificateFile\s+/etc/letsencrypt/' "${vhost}"; then
    TLS_MODE="letsencrypt"
  elif grep -qE 'SSLCertificateFile\s+/etc/litesoup/ssl/' "${vhost}"; then
    TLS_MODE="self-signed"
  else
    TLS_MODE="none"
  fi
}

main() {
  parse_args "$@"
  require_root

  local owner
  owner="$(existing_site_owner "${DOMAIN}" 2>/dev/null || true)"
  if [ -z "${owner}" ]; then
    log_error "site ${DOMAIN} does not exist (no /etc/apache2/sites-available/${DOMAIN}.conf)"
    exit 1
  fi

  SITE_USER="${owner}"
  # shellcheck disable=SC2034  # consumed by write_vhost via scope
  DOCROOT="$(existing_site_docroot "${DOMAIN}")"
  detect_tls_mode

  local old_php
  old_php="$(existing_site_php "${DOMAIN}")"

  # Detect the tier of the OLD pool so we forward it to the new-version pool.
  # Without this, every site-set-php silently downgrades the new pool to small
  # (the default), losing any operator-set medium/large sizing on the old pool.
  local old_pool_conf="/etc/php/${old_php}/fpm/pool.d/${SITE_USER}-php${old_php}.conf"
  local tier="small"
  if [ -f "${old_pool_conf}" ]; then
    local detected
    detected="$(_php_pool_current_tier "${old_pool_conf}")"
    case "${detected}" in
      small|medium|large) tier="${detected}" ;;
      *) tier="small" ;;
    esac
  fi

  log_info "site-set-php: ${DOMAIN} (owner=${SITE_USER}, ${old_php} -> ${PHP_VERSION}, tier=${tier}, tls=${TLS_MODE})"

  if [ "${old_php}" = "${PHP_VERSION}" ]; then
    log_info "site-set-php: site is already on PHP ${PHP_VERSION} -- nothing to do"
    exit 0
  fi

  ensure_php_pool_for_user "${SITE_USER}" "${PHP_VERSION}" "${tier}" \
    || { log_error "site-set-php: failed to ensure pool for ${SITE_USER}/${PHP_VERSION}"; exit 1; }

  write_vhost
  log_info "site-set-php: ${DOMAIN} now serving PHP ${PHP_VERSION} (tier ${tier} carried over from PHP ${old_php} pool)"
  log_info "site-set-php: NOTE old pool ${SITE_USER}-php${old_php} is no longer wired to this site; if no other sites use it, run \`site-set-tier --user=${SITE_USER} --version=${old_php} --tier=small\` to shrink it, or leave it for sites that may still need it"
}

main "$@"
