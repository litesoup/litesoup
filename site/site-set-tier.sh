#!/usr/bin/env bash
# site/site-set-tier.sh -- change FPM pool sizing tier for a user+version.
# Usage: sudo bash site-set-tier.sh --user=NAME --version=X.Y --tier=TIER [--dry-run]
#
# Tier is per per-user+version pool, not per site -- multiple sites sharing
# the pool will all share the new tier after this runs. The pool conf is
# re-rendered and php<v>-fpm is reloaded. Idempotent: re-running with the
# current tier is a no-op (handled inside ensure_php_pool_for_user via the
# _php_pool_current_tier helper).

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

# Test hook (same pattern as the other site-* scripts).
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

USER_NAME=""
PHP_VERSION=""
POOL_TIER=""

usage() {
  cat <<'EOF'
litesoup site-set-tier -- change FPM pool sizing tier for a user+version

Usage: sudo bash site-set-tier.sh --user=NAME --version=X.Y --tier=TIER [--dry-run]
  --user=NAME    the system user that owns the pool
  --version=X.Y  the PHP version of the pool
  --tier=TIER    new tier: small | medium | large
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --user=*)    USER_NAME="${arg#*=}" ;;
      --version=*) PHP_VERSION="${arg#*=}" ;;
      --tier=*)    POOL_TIER="${arg#*=}" ;;
      --dry-run)   DRY_RUN=1 ;;
      --help|-h)   usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  [ -n "${USER_NAME}" ]   || { log_error "--user is required";    usage; exit 64; }
  [ -n "${PHP_VERSION}" ] || { log_error "--version is required"; usage; exit 64; }
  [ -n "${POOL_TIER}" ]   || { log_error "--tier is required";    usage; exit 64; }
  # Same regex as site-create.sh -- protects the python3 render in
  # ensure_php_pool_for_user from triple-quote injection via crafted usernames.
  if ! [[ "${USER_NAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "invalid user name: ${USER_NAME}"; exit 64
  fi
  validate_php_version "${PHP_VERSION}" \
    || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
  case "${POOL_TIER}" in
    small|medium|large) ;;
    *) log_error "--tier must be one of: small, medium, large (got '${POOL_TIER}')"; exit 64 ;;
  esac
}

main() {
  parse_args "$@"
  require_root

  log_info "site-set-tier: pool ${USER_NAME}-php${PHP_VERSION} -> tier ${POOL_TIER}"
  ensure_php_pool_for_user "${USER_NAME}" "${PHP_VERSION}" "${POOL_TIER}"
}

main "$@"
