#!/usr/bin/env bash
# site/site-set-domain.sh -- change an existing site's domain WITHOUT touching
# the filesystem. The on-disk identity (docroot dir, DB name, cache keys, log
# files) is the stable app --name; the domain is a pure network property.
# Usage: sudo bash site-set-domain.sh --name=APP --new-domain=NEW [--tls=MODE --email=ADDR] [--dry-run]
#
# Changes ONLY:
#   - Apache vhost ServerName, log paths, TLS cert (re-issued for the new domain)
#   - WordPress DB via `wp search-replace`
# Does NOT touch filesystem directories, git remotes, backup paths, or log paths.
#
# The site is identified by --name (preferred) or --domain=OLD_DOMAIN (a
# backward-compat alias for sites created before the --name flag existed).

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

# Test hook (same pattern as the other site-* scripts).
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

SITE_NAME=""
DOMAIN=""               # original/old domain, resolved from --name or --domain
NEW_DOMAIN=""
TLS_MODE=""             # '' = preserve the old vhost's TLS mode
TLS_EMAIL=""

usage() {
  cat <<'EOF'
litesoup site-set-domain -- change an existing site's domain (ServerName + DB URLs only)

Usage: sudo bash site-set-domain.sh --name=APP --new-domain=NEW [--tls=MODE --email=ADDR] [--dry-run]

Identify the site by either:
  --name=APP        application slug (preferred). Resolved to its current domain.
  --domain=OLD      original domain (backward-compat alias for pre --name sites).

Change the domain:
  --new-domain=NEW  the new domain/ServerName

Optional TLS:
  --tls=MODE        letsencrypt | self-signed | none. Default: preserve the old
                    vhost's TLS mode (re-issue a cert for the new domain).
  --email=ADDR      required when --tls=letsencrypt

This does NOT move or rename files on disk. The docroot, DB, cache keys and
log files all keep their app-name-derived paths; only the network identity
(ServerName, TLS cert, and the site/URL in the WordPress DB) is updated.
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --name=*)         SITE_NAME="${arg#*=}" ;;
      --domain=*)       DOMAIN="${arg#*=}" ;;
      --new-domain=*)   NEW_DOMAIN="${arg#*=}" ;;
      --tls=*)          TLS_MODE="${arg#*=}" ;;
      --email=*)        TLS_EMAIL="${arg#*=}" ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  if [ -z "${SITE_NAME}" ] && [ -z "${DOMAIN}" ]; then
    log_error "one of --name=APP or --domain=OLD is required"; usage; exit 64
  fi
  if [ -z "${NEW_DOMAIN}" ]; then
    log_error "--new-domain=NEW is required"; usage; exit 64
  fi
  if ! [[ "${NEW_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid new domain: ${NEW_DOMAIN}"; exit 64
  fi
  if [ -n "${TLS_MODE}" ]; then
    case "${TLS_MODE}" in
      letsencrypt|self-signed|none) ;;
      *) log_error "--tls must be one of: letsencrypt, self-signed, none (got '${TLS_MODE}')"; exit 64 ;;
    esac
    if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
      log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
    fi
  fi
}

# Resolve the site identity (SITE_USER, DOCROOT, DOMAIN, SITE_NAME) from either
# --name or --domain, populating globals. Exits 1 if not found.
resolve_site() {
  local meta_file=""
  if [ -n "${SITE_NAME}" ]; then
    DOMAIN="$(resolve_name_to_domain "${SITE_NAME}" 2>/dev/null || true)"
    if [ -z "${DOMAIN}" ]; then
      log_error "site --name=${SITE_NAME} not found (no vhost metadata with SITE_NAME=${SITE_NAME})"
      exit 1
    fi
    meta_file="/etc/litesoup/vhost/${DOMAIN}.conf"
    DOCROOT="$(awk -F= -v k=DOCROOT '$1==k {print $2; exit}' "${meta_file}")"
    : "${DOCROOT:?metadata ${meta_file} missing DOCROOT}"
  else
    # --domain=OLD (backward compat). Derive SITE_NAME from the old vhost.
    local vhost
    vhost="$(_find_vhost "${DOMAIN}" 2>/dev/null || true)"
    if [ -z "${vhost}" ]; then
      log_error "site ${DOMAIN} does not exist (no /etc/apache2/sites-available/${DOMAIN}.conf)"
      exit 1
    fi
    meta_file="/etc/litesoup/vhost/${DOMAIN}.conf"
    local stored_name
    stored_name="$(awk -F= -v k=SITE_NAME '$1==k {print $2; exit}' "${meta_file}" 2>/dev/null || true)"
    SITE_NAME="${stored_name:-${DOMAIN}}"
    DOCROOT="$(existing_site_docroot "${DOMAIN}")"
  fi

  local owner
  owner="$(existing_site_owner "${DOMAIN}" 2>/dev/null || true)"
  if [ -z "${owner}" ]; then
    log_error "site ${DOMAIN} does not exist (no /etc/apache2/sites-available/${DOMAIN}.conf)"
    exit 1
  fi
  SITE_USER="${owner}"
  PHP_VERSION="$(existing_site_php "${DOMAIN}")"
  VHOST_DOCROOT="${DOCROOT}"

  # Preserve TLS mode from the old vhost unless the operator overrode it.
  if [ -z "${TLS_MODE}" ]; then
    local vh="/etc/apache2/sites-available/${DOMAIN}.conf"
    if [ -f "${vh}" ] && grep -q '<VirtualHost \*:443>' "${vh}"; then
      if grep -qE 'SSLCertificateFile\s+/etc/letsencrypt/' "${vh}"; then
        TLS_MODE="letsencrypt"
      elif grep -qE 'SSLCertificateFile\s+/etc/litesoup/ssl/' "${vh}"; then
        TLS_MODE="self-signed"
      else
        TLS_MODE="none"
      fi
    else
      TLS_MODE="none"
    fi
  fi
  log_info "site-set-domain: ${DOMAIN} -> ${NEW_DOMAIN} (name=${SITE_NAME}, owner=${SITE_USER}, tls=${TLS_MODE})"
}

main() {
  parse_args "$@"
  require_root
  resolve_site

  # 1. Re-issue the TLS cert for the new domain (LE needs webroot challenge).
  if [ "${TLS_MODE}" = "letsencrypt" ]; then
    certbot_obtain "${NEW_DOMAIN}" "${TLS_EMAIL}" "${DOCROOT}" \
      || { log_error "site-set-domain: LE failed for ${NEW_DOMAIN}; domain not switched. Re-run with --tls=self-signed or fix DNS first."; exit 1; }
  elif [ "${TLS_MODE}" = "self-signed" ]; then
    certbot_self_signed "${NEW_DOMAIN}"
  fi

  # 2. Rewrite the vhost under the new domain name (ServerName, log paths, cert).
  local old_domain="${DOMAIN}"
  DOMAIN="${NEW_DOMAIN}"
  write_vhost

  # 3. Disable the old-domain vhost (write_vhost already a2ensite'd the new one).
  if [ "${DRY_RUN}" != "1" ]; then
    if a2dissite "${old_domain}.conf" >/dev/null 2>&1; then
      log_info "site-set-domain: disabled old vhost ${old_domain}.conf"
    fi
    # Remove the old vhost config file (moved to the new name by write_vhost).
    rm -f "/etc/apache2/sites-available/${old_domain}.conf"
    rm -f "/etc/litesoup/vhost/${old_domain}.conf"
    systemctl reload apache2
  fi

  # 4. Update WordPress site/home URLs in the DB (only for wordpress framework).
  if [ -f "${DOCROOT}/wp-config.php" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would wp search-replace ${old_domain} -> ${NEW_DOMAIN} in ${DOCROOT}"
    else
      sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" search-replace \
        "${old_domain}" "${NEW_DOMAIN}" --all-tables-with-prefix --recurse-objects --skip-columns=guid \
        || log_warn "site-set-domain: wp search-replace had warnings (check URLs manually)"
    fi
  else
    log_info "site-set-domain: no wp-config.php -- skipping DB URL rewrite"
  fi

  # 5. Best-effort: revoke the old-domain cert now that nothing serves it.
  if [ "${TLS_MODE}" != "none" ]; then
    certbot_revoke "${old_domain}"
  fi

  log_info "site-set-domain: ${old_domain} -> ${NEW_DOMAIN} done (name=${SITE_NAME}, docroot=${DOCROOT})"
}

main "$@"
