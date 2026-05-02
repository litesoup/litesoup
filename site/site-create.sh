#!/usr/bin/env bash
# site/site-create.sh -- create a WordPress site (Plan I.A: PHP 8.2 only).
# Sites live at /home/<user>/webapps/<domain>/, owned by <user>:<user>.
# PHP runs in the per-user FPM pool (created on demand).
# Usage:
#   sudo bash site-create.sh --domain=example.test [--user=NAME] [--dry-run]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export LITESOUP_REPO_ROOT="${REPO_ROOT}"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/apt.sh
source "${REPO_ROOT}/install/lib/apt.sh"
# shellcheck source=../install/lib/users.sh
source "${REPO_ROOT}/install/lib/users.sh"
# shellcheck source=../install/lib/php.sh
source "${REPO_ROOT}/install/lib/php.sh"
# shellcheck source=../install/lib/mariadb.sh
source "${REPO_ROOT}/install/lib/mariadb.sh"
# shellcheck source=../install/lib/certbot.sh
source "${REPO_ROOT}/install/lib/certbot.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

# Test hook: bats can replace functions that need real root / a real system by
# sourcing a stub file. Requires TWO explicit env vars to defend against
# attacker-controlled environments where only LITESOUP_TEST_STUBS might be set
# (the second var is intentionally undocumented outside this file -- production
# users never set it).
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

DOMAIN=""
SITE_USER="${DEFAULT_SITE_USER}"
PHP_VERSION="${PHP_VERSION_DEFAULT}"
TLS_MODE="none"
TLS_EMAIL=""

usage() {
  cat <<'EOF'
litesoup site-create -- provision a WordPress site

Usage: sudo bash site-create.sh --domain=DOMAIN [--user=NAME] [--php=X.Y] \
                                [--tls=letsencrypt|self-signed|none] [--email=ADDR] \
                                [--dry-run]
  --user=NAME    System user that will own the docroot and run PHP-FPM
                 (default: litesoup; created if missing)
  --php=X.Y      PHP version for this site (default: PHP_VERSION_DEFAULT)
  --tls=MODE     TLS mode (default: none -- v0.2 back-compat).
                 letsencrypt: real LE cert via HTTP-01 (requires --email)
                 self-signed: openssl-generated cert at /etc/litesoup/ssl/<d>/
                 none:        HTTP only
  --email=ADDR   Required when --tls=letsencrypt; LE expiry notices go here
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*) DOMAIN="${arg#*=}" ;;
      --user=*)   SITE_USER="${arg#*=}" ;;
      --php=*)    PHP_VERSION="${arg#*=}" ;;
      --tls=*)    TLS_MODE="${arg#*=}" ;;
      --email=*)  TLS_EMAIL="${arg#*=}" ;;
      --dry-run)  DRY_RUN=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"; usage; exit 64
  fi
  if ! [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid domain: ${DOMAIN}"; exit 64
  fi
  if ! [[ "${SITE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "invalid user name: ${SITE_USER}"; exit 64
  fi
  validate_php_version "${PHP_VERSION}" \
    || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
  case "${TLS_MODE}" in
    letsencrypt|self-signed|none) ;;
    *) log_error "--tls must be one of: letsencrypt, self-signed, none (got '${TLS_MODE}')"; exit 64 ;;
  esac
  if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
    log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
  fi
}

# Derive a DB identifier from the domain (mariadb name limit = 64; we stay short).
db_ident_for() {
  local d="$1"
  echo "wp_$(echo "${d}" | tr '.-' '__' | cut -c1-29)"
}

create_database() {
  local db user pw
  db="$(db_ident_for "${DOMAIN}")"
  user="${db}"
  # Generate a 24-char alphanumeric password. Three quirks bundled in here:
  #   1. LC_ALL=C: BSD tr (macOS) emits "Illegal byte sequence" on binary
  #      input under UTF-8 locale; GNU tr is unaffected.
  #   2. set +o pipefail: head -c 24 closes the pipe before tr finishes
  #      reading /dev/urandom, which makes tr exit 141 (SIGPIPE) under the
  #      script's pipefail. Scope the disable to the subshell so the rest of
  #      the script keeps pipefail.
  #   3. Length check: defend against truncation; we want a real 24-char
  #      password, never a passwordless MariaDB user from a silent failure.
  pw="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
  [ "${#pw}" -eq 24 ] || { log_error "site-create: failed to generate 24-char DB password (got '${#pw}' chars)"; exit 1; }

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would create db ${db} and user ${user}"
    DB_NAME="${db}"; DB_USER="${user}"; DB_PASS="dryrun"
    return 0
  fi

  mariadb_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  DB_NAME="${db}"; DB_USER="${user}"; DB_PASS="${pw}"
}

create_docroot() {
  local docroot="/home/${SITE_USER}/webapps/${DOMAIN}"
  run_or_dryrun install -d -o "${SITE_USER}" -g "${SITE_USER}" -m 0755 "${docroot}"
  DOCROOT="${docroot}"
}

download_wordpress() {
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would wp core download into ${DOCROOT} as ${SITE_USER}"
    return 0
  fi
  sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" core download --skip-content
  sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" config create \
    --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" \
    --dbhost="localhost" --dbprefix="wp_" --skip-check
}

main() {
  parse_args "$@"
  require_root

  log_info "site-create: ${DOMAIN} (owner=${SITE_USER}, php=${PHP_VERSION}, tls=${TLS_MODE})"
  ensure_user "${SITE_USER}"
  ensure_php_pool_for_user "${SITE_USER}" "${PHP_VERSION}"
  create_database
  create_docroot

  # For LE we MUST have the HTTP-only vhost up first so the HTTP-01 challenge
  # under /.well-known/acme-challenge/ can be served. For self-signed we can
  # generate the cert before any vhost work.
  if [ "${TLS_MODE}" = "letsencrypt" ]; then
    TLS_MODE="none" write_vhost          # render HTTP-only vhost first
    certbot_obtain "${DOMAIN}" "${TLS_EMAIL}" "${DOCROOT}" \
      || { log_error "site-create: LE failed for ${DOMAIN}; site exists with HTTP only. Run site-set-tls --tls=self-signed if you need TLS now."; exit 1; }
    write_vhost                           # re-render with HTTPS block
  elif [ "${TLS_MODE}" = "self-signed" ]; then
    certbot_self_signed "${DOMAIN}"
    write_vhost
  else
    write_vhost                           # tls=none, HTTP only
  fi

  download_wordpress

  local scheme="http"
  [ "${TLS_MODE}" != "none" ] && scheme="https"
  log_info "site-create: ${DOMAIN} -> ${scheme}://${DOMAIN}/wp-admin/install.php"
  log_info "site-create: docroot ${DOCROOT}"
  log_info "site-create: php ${PHP_VERSION} (socket $(php_fpm_socket_for_user "${SITE_USER}" "${PHP_VERSION}"))"
  log_info "site-create: tls ${TLS_MODE}"
}

main "$@"
