#!/usr/bin/env bash
# site/site-set-tls.sh -- retroactively set TLS on an existing site.
# Usage: sudo bash site-set-tls.sh --domain=DOMAIN --tls=MODE [--email=ADDR] [--dry-run]
#
# Looks up the existing site's owner / php-version / docroot from its Apache
# vhost, then re-runs cert provisioning + vhost rewrite. No DB / docroot / WP
# changes -- just TLS.

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

# Test hook (same pattern as site-create.sh): bats can replace functions that
# need real root / a real system by sourcing a stub file. Requires TWO explicit
# env vars to defend against attacker-controlled environments.
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

DOMAIN=""
TLS_MODE=""
TLS_EMAIL=""

usage() {
  cat <<'EOF'
litesoup site-set-tls -- retroactively set TLS on an existing site

Usage: sudo bash site-set-tls.sh --domain=DOMAIN --tls=MODE [--email=ADDR] [--dry-run]
  --tls=MODE     letsencrypt | self-signed | none
  --email=ADDR   required when --tls=letsencrypt
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*) DOMAIN="${arg#*=}" ;;
      --tls=*)    TLS_MODE="${arg#*=}" ;;
      --email=*)  TLS_EMAIL="${arg#*=}" ;;
      --dry-run)  DRY_RUN=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  [ -n "${DOMAIN}" ]   || { log_error "--domain is required"; usage; exit 64; }
  [ -n "${TLS_MODE}" ] || { log_error "--tls is required";    usage; exit 64; }
  case "${TLS_MODE}" in
    letsencrypt|self-signed|none) ;;
    *) log_error "--tls must be one of: letsencrypt, self-signed, none"; exit 64 ;;
  esac
  if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
    log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
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
  PHP_VERSION="$(existing_site_php "${DOMAIN}")"
  DOCROOT="$(existing_site_docroot "${DOMAIN}")"

  log_info "site-set-tls: ${DOMAIN} (owner=${SITE_USER}, php=${PHP_VERSION}, tls=${TLS_MODE})"

  if [ "${TLS_MODE}" = "letsencrypt" ]; then
    certbot_obtain "${DOMAIN}" "${TLS_EMAIL}" "${DOCROOT}" \
      || { log_error "site-set-tls: LE failed for ${DOMAIN}"; exit 1; }
  elif [ "${TLS_MODE}" = "self-signed" ]; then
    certbot_self_signed "${DOMAIN}"
  fi

  write_vhost
  log_info "site-set-tls: done."
}

main "$@"
