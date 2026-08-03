#!/usr/bin/env bash
# site/site-delete.sh — remove a site created by site-create.sh.
# Removes the docroot under /home/<user>/webapps/<domain>/ and the Apache vhost.
# Does NOT delete the system user or the per-user FPM pool (other sites may share them).
# Usage:
#   sudo bash site-delete.sh --domain=example.test [--user=NAME] [--purge-db] [--dry-run]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/users.sh
source "${REPO_ROOT}/install/lib/users.sh"
# shellcheck source=../install/lib/mariadb.sh
source "${REPO_ROOT}/install/lib/mariadb.sh"
# shellcheck source=../install/lib/certbot.sh
source "${REPO_ROOT}/install/lib/certbot.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

DOMAIN=""
SITE_NAME_ARG=""
SITE_USER="${DEFAULT_SITE_USER}"
PURGE_DB=0

usage() {
  cat <<'EOF'
litesoup site-delete — remove a site

Usage: sudo bash site-delete.sh (--name=APP | --domain=D) [--user=NAME] [--purge-db] [--dry-run]
  --name=APP    application slug of the site (preferred; docroot resolved from metadata)
  --domain=D    domain of the existing site (backward-compat alias)
  --user=NAME   System user that owns the docroot (default: litesoup)
  --purge-db    Also drop the database and DB user (destructive)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --name=*)    SITE_NAME_ARG="${arg#*=}" ;;
      --domain=*)  DOMAIN="${arg#*=}" ;;
      --user=*)    SITE_USER="${arg#*=}" ;;
      --purge-db)  PURGE_DB=1 ;;
      --dry-run)   DRY_RUN=1 ;;
      --help|-h)   usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  if [ -n "${SITE_NAME_ARG}" ] && [ -z "${DOMAIN}" ]; then
    DOMAIN="$(resolve_name_to_domain "${SITE_NAME_ARG}" 2>/dev/null || true)"
    if [ -z "${DOMAIN}" ]; then
      log_error "--name=${SITE_NAME_ARG}: no site with that app name found"; usage; exit 64
    fi
  fi
  [ -n "${DOMAIN}" ] || { log_error "--domain required (or --name)"; exit 64; }
}

db_ident_for() {
  local s="$1"
  echo "wp_$(echo "${s}" | tr -c 'a-zA-Z0-9' '_' | cut -c1-29)"
}

main() {
  parse_args "$@"
  require_root

  local vhost docroot db
  vhost="/etc/apache2/sites-available/${DOMAIN}.conf"
  # The docroot is derived from the app SITE_NAME (stable slug), not the domain
  # (network property). Fall back to the domain for pre --name sites.
  local app_name="${SITE_NAME_ARG}"
  if [ -z "${app_name}" ]; then
    app_name="$(awk -F= -v k=SITE_NAME '$1==k {print $2; exit}' "/etc/litesoup/vhost/${DOMAIN}.conf" 2>/dev/null || true)"
  fi
  [ -n "${app_name}" ] || app_name="${DOMAIN}"
  docroot="${DOCROOT:-/home/${SITE_USER}/webapps/${app_name}}"
  if [ -f "/etc/litesoup/vhost/${DOMAIN}.conf" ]; then
    local meta_docroot
    meta_docroot="$(awk -F= -v k=DOCROOT '$1==k {print $2; exit}' "/etc/litesoup/vhost/${DOMAIN}.conf" 2>/dev/null || true)"
    [ -n "${meta_docroot}" ] && docroot="${meta_docroot}"
  fi
  db="$(db_ident_for "${app_name}")"

  if [ -L "/etc/apache2/sites-enabled/${DOMAIN}.conf" ]; then
    run_or_dryrun a2dissite "${DOMAIN}.conf"
  fi
  [ -f "${vhost}" ]   && run_or_dryrun rm -f "${vhost}"
  [ -d "${docroot}" ] && run_or_dryrun rm -rf "${docroot}"
  # Best-effort cert revoke + cleanup. Safe on sites that never had TLS
  # (certbot_revoke is a no-op when /etc/letsencrypt/live/<domain> is absent
  # and just rm -rf's the empty self-signed dir).
  certbot_revoke "${DOMAIN}"
  run_or_dryrun rm -f "/etc/litesoup/vhost/${DOMAIN}.conf"
  run_or_dryrun systemctl reload apache2

  if [ "${PURGE_DB}" = "1" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would DROP DATABASE ${db} and DROP USER ${db}@localhost"
    else
      mariadb_root <<SQL
DROP DATABASE IF EXISTS \`${db}\`;
DROP USER IF EXISTS '${db}'@'localhost';
FLUSH PRIVILEGES;
SQL
    fi
  else
    log_warn "site-delete: kept database ${db} (use --purge-db to drop)"
  fi

  log_info "site-delete: ${DOMAIN} removed (name=${app_name}, user ${SITE_USER} and per-user FPM pool kept)"
}

main "$@"
