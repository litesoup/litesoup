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

DOMAIN=""
SITE_USER="${DEFAULT_SITE_USER}"

usage() {
  cat <<'EOF'
litesoup site-create -- provision a WordPress site

Usage: sudo bash site-create.sh --domain=DOMAIN [--user=NAME] [--dry-run]
  --user=NAME   System user that will own the docroot and run PHP-FPM
                (default: litesoup; created if missing)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*) DOMAIN="${arg#*=}" ;;
      --user=*)   SITE_USER="${arg#*=}" ;;
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
  pw="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"

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

write_vhost() {
  local socket vhost
  socket="$(php_fpm_socket_for_user "${SITE_USER}" 8.2)"
  vhost="/etc/apache2/sites-available/${DOMAIN}.conf"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would render vhost ${vhost} (socket=${socket})"
    return 0
  fi
  sed -e "s|__DOMAIN__|${DOMAIN}|g" \
      -e "s|__DOCROOT__|${DOCROOT}|g" \
      -e "s|__FPM_SOCKET__|${socket}|g" \
      "${REPO_ROOT}/templates/apache/vhost.conf.tmpl" >"${vhost}"
  a2ensite "${DOMAIN}.conf" >/dev/null
  systemctl reload apache2
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

  log_info "site-create: ${DOMAIN} (owner=${SITE_USER})"
  ensure_user "${SITE_USER}"
  ensure_php_82_pool_for_user "${SITE_USER}"
  create_database
  create_docroot
  write_vhost
  download_wordpress

  log_info "site-create: ${DOMAIN} -> http://${DOMAIN}/wp-admin/install.php"
  log_info "site-create: docroot ${DOCROOT}"
}

main "$@"
