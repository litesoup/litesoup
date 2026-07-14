#!/usr/bin/env bash
# site/site-import.sh — import an existing WordPress site into litesoup.
#
# Clones a Git repo, creates the database, imports a SQL dump, search-replaces
# URLs, generates wp-config.php, sets TLS, and fixes ownership.
#
# Usage:
#   sudo bash site-import.sh --domain=DOMAIN --git-repo=URL --db-dump=PATH \
#     --old-url=URL [options]
#
# Options:
#   --domain=DOMAIN      Required. Site domain (e.g. example.com).
#   --git-repo=URL       Required. Git repository URL.
#   --git-branch=BRANCH  Git branch/tag (default: repo default).
#   --db-dump=PATH       Required. Path to a .sql or .sql.gz database dump.
#   --old-url=URL        Required. The site's previous URL for search-replace.
#   --cdn-domain=DOMAIN  CDN domain for uploads (sets CDN_DOMAIN in wp-config).
#   --user=NAME          System user (default: litesoup; created if missing).
#   --php=X.Y            PHP version (default: 8.2).
#   --tier=TIER          FPM pool tier: small|medium|large (default: small).
#   --tls=MODE           TLS mode: letsencrypt|self-signed|none (default: none).
#   --email=ADDR         Required when --tls=letsencrypt.
#   --table-prefix=PFX   WordPress table prefix (default: auto-detect from dump).
#   --wp-salts-file=FILE Path to a file containing WordPress auth salts.
#   --skip-uploads       Don't import uploads directory (set CDN_DOMAIN instead).
#   --dry-run            Preview without executing.
#   --help               Show this help.

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
# shellcheck source=../install/lib/mariadb.sh
source "${REPO_ROOT}/install/lib/mariadb.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

# ── Test hook ─────────────────────────────────────────────────────────────────
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

# ── Defaults ──────────────────────────────────────────────────────────────────

DOMAIN=""
GIT_REPO=""
GIT_BRANCH=""
DB_DUMP=""
OLD_URL=""
CDN_DOMAIN=""
SITE_USER="${DEFAULT_SITE_USER}"
PHP_VERSION="${PHP_VERSION_DEFAULT}"
POOL_TIER="small"
TLS_MODE="none"
TLS_EMAIL=""
TABLE_PREFIX=""
WP_SALTS_FILE=""
SKIP_UPLOADS=0

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
litesoup site-import — import an existing WordPress site

Usage: sudo bash site-import.sh --domain=DOMAIN --git-repo=URL --db-dump=PATH \
                                --old-url=URL [options]

Required:
  --domain=DOMAIN      Site domain (e.g. example.com).
  --git-repo=URL       Git repository URL containing the site files.
  --db-dump=PATH       Path to a .sql or .sql.gz database dump.
  --old-url=URL        Previous site URL for search-replace.

Options:
  --git-branch=BRANCH  Git branch/tag/SHA (default: repo default).
  --cdn-domain=DOMAIN  CDN domain for uploads (sets CDN_DOMAIN in wp-config).
  --user=NAME          System user (default: litesoup).
  --php=X.Y            PHP version (default: 8.2).
  --tier=TIER          FPM pool tier: small|medium|large (default: small).
  --tls=MODE           TLS: letsencrypt|self-signed|none (default: none).
  --email=ADDR         Required when --tls=letsencrypt.
  --table-prefix=PFX   Table prefix (default: auto-detect from dump).
  --wp-salts-file=FILE File containing WordPress auth salts.
  --skip-uploads       Skip uploads directory; set CDN_DOMAIN instead.

Examples:
  sudo bash site-import.sh \
    --domain=example.com \
    --git-repo=git@github.com:org/repo.git \
    --db-dump=/tmp/site-db.sql.gz \
    --old-url=https://olddomain.com \
    --tls=letsencrypt --email=admin@example.com
EOF
}

# ── Arg parse ─────────────────────────────────────────────────────────────────

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)       DOMAIN="${arg#*=}" ;;
      --git-repo=*)     GIT_REPO="${arg#*=}" ;;
      --git-branch=*)   GIT_BRANCH="${arg#*=}" ;;
      --db-dump=*)      DB_DUMP="${arg#*=}" ;;
      --old-url=*)      OLD_URL="${arg#*=}" ;;
      --cdn-domain=*)   CDN_DOMAIN="${arg#*=}" ;;
      --user=*)         SITE_USER="${arg#*=}" ;;
      --php=*)          PHP_VERSION="${arg#*=}" ;;
      --tier=*)         POOL_TIER="${arg#*=}" ;;
      --tls=*)          TLS_MODE="${arg#*=}" ;;
      --email=*)        TLS_EMAIL="${arg#*=}" ;;
      --table-prefix=*) TABLE_PREFIX="${arg#*=}" ;;
      --wp-salts-file=*) WP_SALTS_FILE="${arg#*=}" ;;
      --skip-uploads)   SKIP_UPLOADS=1 ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
}

# ── Validation ────────────────────────────────────────────────────────────────

validate() {
  [ -n "${DOMAIN}" ]   || { log_error "--domain is required";     usage; exit 64; }
  [ -n "${GIT_REPO}" ] || { log_error "--git-repo is required";   usage; exit 64; }
  [ -n "${DB_DUMP}" ]  || { log_error "--db-dump is required";    usage; exit 64; }
  [ -n "${OLD_URL}" ]  || { log_error "--old-url is required";    usage; exit 64; }

  if ! [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid domain: ${DOMAIN}"; exit 64
  fi
  if ! [[ "${GIT_REPO}" =~ ^(https?://|git@) ]]; then
    log_error "--git-repo must start with https://, http://, or git@ (got '${GIT_REPO}')"; exit 64
  fi
  if [ -n "${GIT_BRANCH}" ] && ! [[ "${GIT_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    log_error "invalid --git-branch: ${GIT_BRANCH}"; exit 64
  fi

  if [ ! -f "${DB_DUMP}" ] && [ "${DRY_RUN}" = "0" ]; then
    log_error "db-dump not found: ${DB_DUMP}"; exit 64
  fi

  if [ -n "${WP_SALTS_FILE}" ] && [ ! -f "${WP_SALTS_FILE}" ]; then
    log_error "wp-salts-file not found: ${WP_SALTS_FILE}"; exit 64
  fi

  validate_php_version "${PHP_VERSION}" \
    || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }

  case "${POOL_TIER}" in
    small|medium|large) ;;
    *) log_error "--tier must be small, medium, or large (got '${POOL_TIER}')"; exit 64 ;;
  esac
  case "${TLS_MODE}" in
    letsencrypt|self-signed|none) ;;
    *) log_error "--tls must be letsencrypt, self-signed, or none (got '${TLS_MODE}')"; exit 64 ;;
  esac
  if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
    log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# db_ident_for — derive DB name from domain (same as site-create.sh).
db_ident_for() {
  local d="$1"
  echo "wp_$(echo "${d}" | tr '.-' '__' | cut -c1-29)"
}

# auto_detect_table_prefix — read the first few lines of a SQL dump to find
# the WordPress table prefix. Looks for `CREATE TABLE wp_*` patterns.
auto_detect_table_prefix() {
  local dump="$1"
  local prefix
  if [[ "${dump}" == *.gz ]]; then
    prefix="$(gunzip -c "${dump}" 2>/dev/null | grep -oE 'CREATE TABLE `[^`]+_' | head -1 | sed 's/CREATE TABLE `//;s/_$//')"
  else
    prefix="$(grep -oE 'CREATE TABLE `[^`]+_' "${dump}" | head -1 | sed 's/CREATE TABLE `//;s/_$//')"
  fi
  printf '%s_' "${prefix:-wp}"
}

# create_database — create MariaDB database + user (same pattern as site-create).
_import_db_name=""
_import_db_user=""
_import_db_pass=""
create_database() {
  local db user pw
  db="$(db_ident_for "${DOMAIN}")"
  user="${db}"
  pw="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
  [ "${#pw}" -eq 24 ] || { log_error "site-import: failed to generate 24-char DB password"; exit 1; }

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would create db ${db} and user ${user}"
    _import_db_name="${db}"; _import_db_user="${user}"; _import_db_pass="dryrun"
    return 0
  fi

  mariadb_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pw}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL
  _import_db_name="${db}"; _import_db_user="${user}"; _import_db_pass="${pw}"
  log_info "site-import: database ${db} ready"
}

# import_dump — import the SQL dump into the site's database.
import_dump() {
  local dump="$1" db="$2"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would import ${dump} into ${db}"
    return 0
  fi

  log_info "site-import: importing ${dump} into ${db}..."
  if [[ "${dump}" == *.gz ]]; then
    gunzip -c "${dump}" | mariadb "${db}" 2>/dev/null \
      || { log_error "site-import: SQL import failed"; exit 1; }
  else
    mariadb "${db}" < "${dump}" 2>/dev/null \
      || { log_error "site-import: SQL import failed"; exit 1; }
  fi
  log_info "site-import: database import complete"
}

# search_replace_url — use wp-cli to search-replace old URL with new domain.
# Must run AFTER wp-config.php is in place.
search_replace_url() {
  local docroot="$1" user="$2" old_url="$3" new_domain="$4"
  local new_url="https://${new_domain}"
  [ "${TLS_MODE}" = "none" ] && new_url="http://${new_domain}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would wp search-replace '${old_url}' '${new_url}' --all-tables --precise"
    return 0
  fi

  log_info "site-import: replacing URLs: ${old_url} → ${new_url}"
  sudo -H -u "${user}" wp --path="${docroot}" search-replace \
    "${old_url}" "${new_url}" \
    --all-tables --precise 2>/dev/null \
    || log_warn "site-import: URL replacement had warnings (check wp-cli output)"
  log_info "site-import: URL replacement complete"
}

# generate_wp_config — create wp-config.php with DB creds, salts, Redis constants.
generate_wp_config() {
  local docroot="$1" user="$2" db_name="$3" db_user="$4" db_pass="$5" prefix="$6"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would generate wp-config.php in ${docroot}"
    return 0
  fi

  # If the repo already has wp-config.php, skip creation but inject cache constants.
  if [ -f "${docroot}/wp-config.php" ]; then
    log_info "site-import: wp-config.php already present — injecting cache constants"
    _inject_cache_constants "${docroot}" "${user}"
    return 0
  fi

  log_info "site-import: generating wp-config.php..."
  sudo -H -u "${user}" wp --path="${docroot}" config create \
    --dbname="${db_name}" --dbuser="${db_user}" --dbpass="${db_pass}" \
    --dbhost="localhost" --dbprefix="${prefix}" --skip-check 2>/dev/null

  # Inject salts from file if provided
  if [ -n "${WP_SALTS_FILE}" ]; then
    log_info "site-import: injecting salts from ${WP_SALTS_FILE}..."
    # Remove the auto-generated salts first, then append from file
    sudo -H -u "${user}" wp --path="${docroot}" config delete AUTH_KEY 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete SECURE_AUTH_KEY 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete LOGGED_IN_KEY 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete NONCE_KEY 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete AUTH_SALT 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete SECURE_AUTH_SALT 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete LOGGED_IN_SALT 2>/dev/null || true
    sudo -H -u "${user}" wp --path="${docroot}" config delete NONCE_SALT 2>/dev/null || true
    # Append salts to wp-config.php
    cat "${WP_SALTS_FILE}" >> "${docroot}/wp-config.php"
  fi

  _inject_cache_constants "${docroot}" "${user}"
}

_inject_cache_constants() {
  local docroot="$1" user="$2"
  # Inject WP_CACHE_KEY_SALT
  local salt
  salt="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
  sudo -H -u "${user}" wp --path="${docroot}" config set \
    WP_CACHE_KEY_SALT "${salt}" --type=constant --add 2>/dev/null || true

  # Inject CDN_DOMAIN if provided
  if [ -n "${CDN_DOMAIN}" ]; then
    sudo -H -u "${user}" wp --path="${docroot}" config set \
      CDN_DOMAIN "${CDN_DOMAIN}" --type=constant --add 2>/dev/null || true
  fi

  # Inject Redis config if available
  if [ -r "${REDIS_ENV_FILE}" ]; then
    local rpwd
    rpwd="$(. "${REDIS_ENV_FILE}" && printf '%s' "${REDIS_PASSWORD:-}")"
    if [ -n "${rpwd}" ]; then
      sudo -H -u "${user}" wp --path="${docroot}" config set WP_REDIS_HOST "127.0.0.1" --type=constant --add 2>/dev/null || true
      sudo -H -u "${user}" wp --path="${docroot}" config set WP_REDIS_PORT "6379" --type=constant --add 2>/dev/null || true
      sudo -H -u "${user}" wp --path="${docroot}" config set WP_REDIS_PASSWORD "${rpwd}" --type=constant --add 2>/dev/null || true
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  require_root
  validate

  log_info "site-import: ${DOMAIN} (owner=${SITE_USER}, php=${PHP_VERSION}, tls=${TLS_MODE})"

  # 1. Create system user + PHP-FPM pool
  ensure_user "${SITE_USER}"
  ensure_php_pool_for_user "${SITE_USER}" "${PHP_VERSION}" "${POOL_TIER}"

  # 2. Create database
  create_database

  # 3. Create docroot
  local docroot="/home/${SITE_USER}/webapps/${DOMAIN}"
  local vhost_docroot="${docroot}"
  run_or_dryrun install -d -o "${SITE_USER}" -g "${SITE_USER}" -m 0755 "${docroot}"
  DOCROOT="${docroot}"
  VHOST_DOCROOT="${docroot}"

  # 4. Set up vhost + TLS
  if [ "${TLS_MODE}" = "letsencrypt" ]; then
    TLS_MODE="none" write_vhost
    certbot_obtain "${DOMAIN}" "${TLS_EMAIL}" "${docroot}" \
      || { log_error "site-import: LE failed for ${DOMAIN}"; exit 1; }
    write_vhost
  elif [ "${TLS_MODE}" = "self-signed" ]; then
    certbot_self_signed "${DOMAIN}"
    write_vhost
  else
    write_vhost
  fi

  # 5. Clone git repo
  DOCROOT="${docroot}"
  if [ -d "${docroot}/.git" ]; then
    log_info "site-import: repo already cloned — pulling latest"
    sudo -H -u "${SITE_USER}" git -C "${docroot}" pull --ff-only
  else
    local branch_args=()
    [ -n "${GIT_BRANCH}" ] && branch_args=(--branch "${GIT_BRANCH}")
    sudo -H -u "${SITE_USER}" git clone "${branch_args[@]}" "${GIT_REPO}" "${docroot}"
  fi

  # 6. Initialize git submodules (if any)
  if [ -f "${docroot}/.gitmodules" ]; then
    sudo -H -u "${SITE_USER}" git -C "${docroot}" submodule update --init --recursive
  fi

  # 7. Handle uploads (skip if --skip-uploads)
  if [ "${SKIP_UPLOADS}" = "1" ] && [ -d "${docroot}/wp-content/uploads" ]; then
    log_info "site-import: --skip-uploads set, removing local uploads directory"
    if [ "${DRY_RUN}" != "1" ]; then
      rm -rf "${docroot}/wp-content/uploads"
      mkdir -p "${docroot}/wp-content/uploads"
      chown "${SITE_USER}:${SITE_USER}" "${docroot}/wp-content/uploads"
    fi
  fi

  # 8. Import database
  local detected_prefix
  if [ -z "${TABLE_PREFIX}" ]; then
    detected_prefix="$(auto_detect_table_prefix "${DB_DUMP}")"
    log_info "site-import: auto-detected table prefix: ${detected_prefix}"
  else
    detected_prefix="${TABLE_PREFIX}"
  fi
  import_dump "${DB_DUMP}" "${_import_db_name}"

  # 9. Generate wp-config.php (AFTER DB import so we can search-replace)
  generate_wp_config "${docroot}" "${SITE_USER}" \
    "${_import_db_name}" "${_import_db_user}" "${_import_db_pass}" \
    "${detected_prefix}"

  # 10. Search-replace old URLs
  search_replace_url "${docroot}" "${SITE_USER}" "${OLD_URL}" "${DOMAIN}"

  # 11. Write .htaccess if missing
  if [ ! -f "${docroot}/.htaccess" ]; then
    sudo -H -u "${SITE_USER}" tee "${docroot}/.htaccess" >/dev/null <<'HTACCESS'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS
  fi

  # 12. Fix ownership
  chown -R "${SITE_USER}:${SITE_USER}" "${docroot}"

  # 13. Flush caches
  if [ "${DRY_RUN}" != "1" ]; then
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" cache flush 2>/dev/null || true
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" rewrite flush 2>/dev/null || true
  fi

  log_info "site-import: COMPLETE for ${DOMAIN}"
  log_info "site-import: docroot = ${docroot}"
  log_info "site-import: db      = ${_import_db_name} (user: ${_import_db_user})"
  log_info "site-import: visit   = https://${DOMAIN}/wp-admin/ (unless TLS=none)"
}

main "$@"
