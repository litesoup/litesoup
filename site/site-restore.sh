#!/usr/bin/env bash
# site/site-restore.sh — restore a litesoup site from a backup.
#
# The full-featured restore entrypoint (superset of backup/backup-restore.sh).
# Restores a site's database + data (uploads/storage) — and optionally code —
# from a backup taken by backup/backup-site.sh, sourced from local disk or S3,
# onto either the currently-running app (--target=override) or a freshly
# provisioned app (--target=new).
#
# Usage:
#   sudo bash site-restore.sh --domain=example.com [options]
#
# Options:
#   --source=local|s3      Where backups live. Default: local.
#   --target=override|new  Restore destination. Default: override.
#   --domain=DOMAIN        Site domain to restore (the SOURCE site's domain;
#                          for override this is the running app's domain).
#   --name=SLUG            For --target=new: new app slug (default: derived
#                          from --new-domain).
#   --new-domain=DOMAIN    For --target=new: new site's domain (default: --domain).
#   --from=TIMESTAMP       Specific backup timestamp; default: most recent.
#   --user=NAME            Site system user (auto-detected if omitted).
#   --framework=FRAMEWORK  wordpress|laravel|generic (default: auto-detect).
#   --git-repo=URL         For --target=new: git repo holding the code.
#   --git-branch=BRANCH    For --target=new: branch/tag/SHA (default: repo default).
#   --old-url=URL          URL to search-replace from (default: https://<source domain>).
#   --php=X.Y              For --target=new: PHP version (default: 8.2).
#   --tier=TIER            For --target=new: FPM pool tier (default: medium).
#   --tls=MODE             For --target=new: letsencrypt|self-signed|none.
#   --email=ADDR           For --target=new when --tls=letsencrypt.
#   --build                For --target=new Laravel: run composer/npm build.
#   --skip-files           Skip data-file restore (database-only).
#   --skip-db              Skip database restore (files-only).
#   --dry-run              Preview without executing.
#   --help                 Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export LITESOUP_REPO_ROOT="${REPO_ROOT}"

# shellcheck source=../backup/lib/common.sh
source "${REPO_ROOT}/backup/lib/common.sh"
# shellcheck source=../backup/lib/s3.sh
source "${REPO_ROOT}/backup/lib/s3.sh"
# shellcheck source=../install/lib/mariadb.sh
source "${REPO_ROOT}/install/lib/mariadb.sh"
# shellcheck source=../install/lib/php.sh
source "${REPO_ROOT}/install/lib/php.sh"

# Test hook: bats can replace functions that need real root / a real system by
# sourcing a stub file (e.g. a no-op `main` so the script can be sourced purely
# for its helper functions). Requires TWO explicit env vars to defend against
# attacker-controlled environments where only LITESOUP_TEST_STUBS might be set.
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

# ---- defaults --------------------------------------------------------------

SOURCE="local"
TARGET="override"
DOMAIN=""
SITE_NAME=""
NEW_DOMAIN=""
FROM=""
SITE_USER=""
FRAMEWORK=""
GIT_REPO=""
GIT_BRANCH=""
OLD_URL=""
OLD_URL_EXPLICIT=0
PHP_VERSION="${PHP_VERSION_DEFAULT}"
POOL_TIER="medium"
TLS_MODE="none"
TLS_EMAIL=""
DO_BUILD=0
SKIP_FILES=0
SKIP_DB=0

WORKDIR=""

# ---- usage -----------------------------------------------------------------

usage() {
  cat <<'EOF'
litesoup site-restore — restore a site from a backup

Usage: sudo bash site-restore.sh --domain=DOMAIN [options]

Options:
  --source=local|s3      Backup source. Default: local.
  --target=override|new  Restore destination. Default: override.
  --domain=DOMAIN        Source site domain (required).
  --name=SLUG            For --target=new: new app slug (default: from --new-domain).
  --new-domain=DOMAIN    For --target=new: new site domain (default: --domain).
  --from=TIMESTAMP       Restore a specific backup timestamp (default: newest).
  --user=NAME            Site system user (auto-detected if omitted).
  --framework=FRAMEWORK  wordpress|laravel|generic (default: auto-detect).
  --git-repo=URL         For --target=new: git repo holding the code.
  --git-branch=BRANCH    For --target=new: branch/tag/SHA.
  --old-url=URL          URL to search-replace from (default: https://<source domain>).
  --php=X.Y              For --target=new: PHP version (default: 8.2).
  --tier=TIER            For --target=new: FPM pool tier (default: medium).
  --tls=MODE             For --target=new: letsencrypt|self-signed|none.
  --email=ADDR           For --target=new when --tls=letsencrypt.
  --build                For --target=new Laravel: run composer/npm build.
  --skip-files           Skip data-file restore (database-only).
  --skip-db              Skip database restore (files-only).
  --dry-run              Preview without executing.
  --help, -h             Show this help.

Examples:
  # Restore the newest local backup onto the running app
  sudo bash site-restore.sh --domain=example.com

  # Restore a specific backup from S3 onto the running app
  sudo bash site-restore.sh --domain=example.com --source=s3 --from=2026-07-14_120000

  # Restore into a brand-new app (new domain + git code), search-replacing URLs
  sudo bash site-restore.sh --domain=example.com --target=new \
    --new-domain=staging.example.com --git-repo=git@github.com:org/repo.git \
    --tls=letsencrypt --email=ops@example.com
EOF
}

# ---- arg parse -------------------------------------------------------------

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --source=*)       SOURCE="${arg#*=}" ;;
      --target=*)       TARGET="${arg#*=}" ;;
      --domain=*)       DOMAIN="${arg#*=}" ;;
      --name=*)         SITE_NAME="${arg#*=}" ;;
      --new-domain=*)   NEW_DOMAIN="${arg#*=}" ;;
      --from=*)         FROM="${arg#*=}" ;;
      --user=*)         SITE_USER="${arg#*=}" ;;
      --framework=*)    FRAMEWORK="${arg#*=}" ;;
      --git-repo=*)     GIT_REPO="${arg#*=}" ;;
      --git-branch=*)   GIT_BRANCH="${arg#*=}" ;;
      --old-url=*)      OLD_URL="${arg#*=}"; OLD_URL_EXPLICIT=1 ;;
      --php=*)          PHP_VERSION="${arg#*=}" ;;
      --tier=*)         POOL_TIER="${arg#*=}" ;;
      --tls=*)          TLS_MODE="${arg#*=}" ;;
      --email=*)        TLS_EMAIL="${arg#*=}" ;;
      --build)          DO_BUILD=1 ;;
      --skip-files)     SKIP_FILES=1 ;;
      --skip-db)        SKIP_DB=1 ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
}

# ---- validation ------------------------------------------------------------

validate() {
  case "${SOURCE}" in
    local|s3) ;;
    *) log_error "--source must be one of: local, s3 (got '${SOURCE}')"; exit 64 ;;
  esac
  case "${TARGET}" in
    override|new) ;;
    *) log_error "--target must be one of: override, new (got '${TARGET}')"; exit 64 ;;
  esac

  [ -n "${DOMAIN}" ] || { log_error "--domain is required"; usage; exit 64; }
  backup_validate_name "${DOMAIN}" || exit 64

  if [ -n "${FRAMEWORK}" ]; then
    case "${FRAMEWORK}" in
      wordpress|laravel|generic) ;;
      *) log_error "--framework must be one of: wordpress, laravel, generic (got '${FRAMEWORK}')"; exit 64 ;;
    esac
  fi

  if [ "${SKIP_FILES}" = "1" ] && [ "${SKIP_DB}" = "1" ]; then
    log_error "--skip-files and --skip-db cannot both be set (nothing to restore)"
    exit 64
  fi

  if [ -n "${GIT_REPO}" ] && ! [[ "${GIT_REPO}" =~ ^(https?://|git@) ]]; then
    log_error "--git-repo must start with https://, http://, or git@ (got '${GIT_REPO}')"; exit 64
  fi
  if [ -n "${GIT_BRANCH}" ] && ! [[ "${GIT_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    log_error "invalid --git-branch: ${GIT_BRANCH}"; exit 64
  fi

  if [ "${TARGET}" = "new" ]; then
    if [ -z "${NEW_DOMAIN}" ]; then
      NEW_DOMAIN="${DOMAIN}"
    fi
    if ! [[ "${NEW_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
      log_error "invalid --new-domain: ${NEW_DOMAIN}"; exit 64
    fi
    if [ -z "${SITE_NAME}" ]; then
      SITE_NAME="$(printf '%s' "${NEW_DOMAIN}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-//;s/-*$//')"
    fi
    if ! [[ "${SITE_NAME}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      log_error "invalid name: ${SITE_NAME} (must be a stable app slug)"; exit 64
    fi
    validate_php_version "${PHP_VERSION}" \
      || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
    case "${POOL_TIER}" in
      small|medium|large) ;;
      *) log_error "--tier must be one of: small, medium, large (got '${POOL_TIER}')"; exit 64 ;;
    esac
    case "${TLS_MODE}" in
      letsencrypt|self-signed|none) ;;
      *) log_error "--tls must be one of: letsencrypt, self-signed, none (got '${TLS_MODE}')"; exit 64 ;;
    esac
    if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
      log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
    fi
  fi
}

# ---- helpers ---------------------------------------------------------------

# db_ident_for — derive a DB identifier from a site slug (matches site-create.sh).
db_ident_for() {
  local s="$1"
  echo "wp_$(echo "${s}" | tr -c 'a-zA-Z0-9' '_' | cut -c1-29)"
}

# detect_framework DOCROOT — sniff wordpress / laravel / generic from a docroot.
detect_framework() {
  local docroot="${1:?detect_framework: docroot required}"
  if [ -f "${docroot}/wp-config.php" ]; then
    echo "wordpress"
  elif [ -f "${docroot}/artisan" ]; then
    echo "laravel"
  else
    echo "generic"
  fi
}

# find_backup_base — locate the local backup dir for a domain.
# Prints the base dir (e.g. /home/<user>/backups/<domain>) or returns 1.
find_backup_base() {
  if [ -n "${SITE_USER}" ] && [ -d "/home/${SITE_USER}/backups/${DOMAIN}" ]; then
    echo "/home/${SITE_USER}/backups/${DOMAIN}"
    return 0
  fi
  local d
  for d in /home/*/backups/"${DOMAIN}"; do
    if [ -d "${d}" ]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

# select_backup_dir BASE — pick the backup timestamp dir to restore.
# Honors --from; otherwise newest (YYYY-MM-DD_HHMMSS sorts lexically).
select_backup_dir() {
  local base="${1:?select_backup_dir: base required}"
  if [ -n "${FROM}" ]; then
    if [ ! -d "${base}/${FROM}" ]; then
      log_error "restore: backup not found: ${base}/${FROM}"
      log_error "restore: available backups:"
      find "${base}" -maxdepth 1 -type d ! -name "$(basename "${base}")" -printf '%f\n' | head -10
      exit 1
    fi
    echo "${base}/${FROM}"
    return 0
  fi
  local newest
  newest="$(find "${base}" -maxdepth 1 -type d ! -name "$(basename "${base}")" -printf '%f\n' | sort -r | head -1)"
  if [ -z "${newest}" ]; then
    log_error "restore: no backups found at ${base}"
    exit 1
  fi
  echo "${base}/${newest}"
}

# stage_extract ARCHIVE WORKDIR — extract a files.tar.zst into WORKDIR and
# print the path of the single top-level docroot directory it contains.
stage_extract() {
  local archive="${1:?stage_extract: archive required}"
  local workdir="${2:?stage_extract: workdir required}"
  mkdir -p "${workdir}"
  tar --zstd -xf "${archive}" -C "${workdir}"
  find "${workdir}" -mindepth 1 -maxdepth 1 -type d | head -1
}

# get_wp_db_name DOCROOT — read DB_NAME from wp-config.php.
get_wp_db_name() {
  local docroot="${1:?get_wp_db_name: docroot required}"
  grep -oP "define\([[:space:]]*'DB_NAME',[[:space:]]*'\K[^']+" "${docroot}/wp-config.php" 2>/dev/null | head -1 || true
}

# get_laravel_db_name DOCROOT — read DB_DATABASE from .env.
get_laravel_db_name() {
  local docroot="${1:?get_laravel_db_name: docroot required}"
  grep -oP '^DB_DATABASE=\K.*' "${docroot}/.env" 2>/dev/null | head -1 || true
}

# detect_table_prefix_from_zst DUMP_ZST — sniff the WP table prefix from a
# zstd-compressed SQL dump. Returns the prefix WITHOUT trailing underscore
# (e.g. "wprg"), or "wp" if undetectable.
detect_table_prefix_from_zst() {
  local dump_zst="${1:?detect_table_prefix_from_zst: dump_zst required}"
  local pfx
  pfx="$(zstd -dc "${dump_zst}" 2>/dev/null | grep -oE 'CREATE TABLE `[^`]+_' | head -1 | sed 's/CREATE TABLE `//;s/_$//')"
  printf '%s' "${pfx:-wp}"
}

# set_wp_table_prefix DOCROOT PREFIX — set $table_prefix in wp-config.php.
set_wp_table_prefix() {
  local docroot="${1:?set_wp_table_prefix: docroot required}"
  local prefix="${2:?set_wp_table_prefix: prefix required}"
  local cfg="${docroot}/wp-config.php"
  [ -f "${cfg}" ] || { log_warn "restore: no wp-config.php to patch table_prefix"; return 0; }
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would set \$table_prefix = '${prefix}_' in ${cfg}"
    return 0
  fi
  sed -i "s/^\$table_prefix = .*;/\$table_prefix = \"${prefix}_\";/" "${cfg}"
  log_info "restore: set \$table_prefix = '${prefix}_' in ${cfg}"
}

# backup_current_db DOCROOT USER OUTPATH — safety dump of the current DB before
# a destructive override restore.
backup_current_db() {
  local docroot="${1:?backup_current_db: docroot required}"
  local user="${2:?backup_current_db: user required}"
  local outpath="${3:?backup_current_db: outpath required}"
  mkdir -p "$(dirname "${outpath}")"
  log_info "restore: backing up CURRENT database before destructive restore → ${outpath}"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would dump current DB to ${outpath}"
    return 0
  fi
  sudo -H -u "${user}" wp --path="${docroot}" db export - 2>/dev/null | zstd -8 > "${outpath}" \
    || log_warn "restore: could not back up current DB (continuing anyway)"
  chmod 0600 "${outpath}" 2>/dev/null || true
}

# restore_data_files STAGED_DOCROOT TARGET_DOCROOT USER FRAMEWORK — copy the
# site's data (uploads / storage) from the staged archive into the target.
restore_data_files() {
  local staged="${1:?restore_data_files: staged required}"
  local target="${2:?restore_data_files: target required}"
  local user="${3:?restore_data_files: user required}"
  local framework="${4:?restore_data_files: framework required}"

  local src="" dst=""
  case "${framework}" in
    wordpress) src="${staged}/wp-content/uploads"; dst="${target}/wp-content/uploads" ;;
    laravel)   src="${staged}/storage/app";        dst="${target}/storage/app" ;;
    *)         log_info "restore: generic framework — no data dir to restore"; return 0 ;;
  esac

  if [ ! -d "${src}" ]; then
    log_warn "restore: no data dir in backup (${src}) — skipping data restore"
    return 0
  fi

  log_info "restore: restoring data ${src} → ${dst}"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would cp -a ${src}/. ${dst}/ && chown -R ${user}:${user} ${dst}"
    return 0
  fi
  mkdir -p "${dst}"
  cp -a "${src}/." "${dst}/"
  chown -R "${user}:${user}" "${dst}"
  log_info "restore: data restored"
}

# import_db_override DUMP_ZST DOCROOT USER FRAMEWORK — import a DB dump into the
# currently-running app's database (used by --target=override).
import_db_override() {
  local dump_zst="${1:?import_db_override: dump_zst required}"
  local docroot="${2:?import_db_override: docroot required}"
  local user="${3:?import_db_override: user required}"
  local framework="${4:?import_db_override: framework required}"

  log_info "restore: importing database for ${DOMAIN}..."
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would import ${dump_zst} into the ${DOMAIN} database"
    return 0
  fi

  if [ "${framework}" = "wordpress" ]; then
    zstd -dc "${dump_zst}" 2>/dev/null | sudo -H -u "${user}" wp --path="${docroot}" db import - 2>/dev/null || {
      log_error "restore: wp db import failed for ${DOMAIN}"
      exit 1
    }
  else
    local db_name
    db_name="$(get_laravel_db_name "${docroot}")"
    if [ -z "${db_name}" ]; then
      log_error "restore: cannot determine DB_DATABASE from ${docroot}/.env"
      exit 1
    fi
    zstd -dc "${dump_zst}" 2>/dev/null | mariadb "${db_name}" 2>/dev/null || {
      log_error "restore: mariadb import failed for ${db_name}"
      exit 1
    }
  fi
  log_info "restore: database imported"
}

# laravel_search_replace DOCROOT OLD NEW — best-effort URL search-replace across
# all text columns of a Laravel DB. Non-fatal.
laravel_search_replace() {
  local docroot="${1:?laravel_search_replace: docroot required}"
  local old="${2:?laravel_search_replace: old required}"
  local new="${3:?laravel_search_replace: new required}"
  local db_name
  db_name="$(get_laravel_db_name "${docroot}")"
  [ -n "${db_name}" ] || { log_warn "restore: cannot resolve DB_DATABASE for search-replace"; return 0; }

  log_info "restore: search-replacing '${old}' → '${new}' in ${db_name}..."
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would search-replace '${old}' → '${new}' across ${db_name} text columns"
    return 0
  fi

  local table col
  while IFS= read -r table; do
    [ -n "${table}" ] || continue
    while IFS= read -r col; do
      [ -n "${col}" ] || continue
      mariadb "${db_name}" -e \
        "UPDATE \`${table}\` SET \`${col}\` = REPLACE(\`${col}\`, '${old}', '${new}') WHERE \`${col}\` LIKE '%${old}%';" \
        2>/dev/null || true
    done < <(mariadb "${db_name}" -N -e \
      "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='${db_name}' AND TABLE_NAME='${table}' AND DATA_TYPE IN ('varchar','text','longtext','mediumtext','char');" 2>/dev/null || true)
  done < <(mariadb "${db_name}" -N -e "SHOW TABLES;" 2>/dev/null || true)
  log_info "restore: search-replace complete"
}

# write_laravel_env DOCROOT USER DB_NAME DB_USER DB_PASS APP_URL — write a
# minimal .env for a Laravel app (preserving APP_KEY if one exists).
write_laravel_env() {
  local docroot="${1:?write_laravel_env: docroot required}"
  local user="${2:?write_laravel_env: user required}"
  local db_name="${3:?write_laravel_env: db_name required}"
  local db_user="${4:?write_laravel_env: db_user required}"
  local db_pass="${5:?write_laravel_env: db_pass required}"
  local app_url="${6:?write_laravel_env: app_url required}"

  local app_key=""
  if [ -f "${docroot}/.env" ]; then
    app_key="$(grep -oP '^APP_KEY=\K.*' "${docroot}/.env" | head -1 || true)"
  fi
  [ -n "${app_key}" ] || app_key="base64:$(openssl rand -base64 32)"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would write ${docroot}/.env with DB creds + APP_URL=${app_url}"
    return 0
  fi

  cat > "${docroot}/.env" <<EOF
APP_NAME=Litesoup
APP_ENV=production
APP_KEY=${app_key}
APP_DEBUG=false
APP_URL=${app_url}
LOG_CHANNEL=stack
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${db_name}
DB_USERNAME=${db_user}
DB_PASSWORD=${db_pass}
SESSION_DRIVER=database
CACHE_DRIVER=database
QUEUE_CONNECTION=database
EOF
  chown "${user}:${user}" "${docroot}/.env"
  chmod 0640 "${docroot}/.env"
  log_info "restore: wrote ${docroot}/.env"
}

# create_db_with_known_creds SLUG — (re)create a DB + user with a fresh known
# password. Sets DB_NAME/DB_USER/DB_PASS globals.
DB_NAME=""
DB_USER=""
DB_PASS=""
create_db_with_known_creds() {
  local slug="${1:?create_db_with_known_creds: slug required}"
  DB_NAME="$(db_ident_for "${slug}")"
  DB_USER="${DB_NAME}"
  DB_PASS="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
  [ "${#DB_PASS}" -eq 24 ] || { log_error "restore: failed to generate 24-char DB password"; exit 1; }

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would (re)create db ${DB_NAME} and user ${DB_USER}"
    return 0
  fi
  mariadb_root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  log_info "restore: database ${DB_NAME} ready"
}

# import_db_new DUMP_ZST DB_NAME — import a zstd DB dump into a named DB.
import_db_new() {
  local dump_zst="${1:?import_db_new: dump_zst required}"
  local db_name="${2:?import_db_new: db_name required}"
  log_info "restore: importing database into ${db_name}..."
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would import ${dump_zst} into ${db_name}"
    return 0
  fi
  zstd -dc "${dump_zst}" 2>/dev/null | mariadb "${db_name}" 2>/dev/null || {
    log_error "restore: DB import failed into ${db_name}"
    exit 1
  }
  log_info "restore: database imported"
}

# verify_restore DOCROOT USER FRAMEWORK CHECK_DOMAIN — post-restore self-check:
# table count > 0 and origin returns HTTP 2xx/3xx.
verify_restore() {
  local docroot="${1:?verify_restore: docroot required}"
  local user="${2:?verify_restore: user required}"
  local framework="${3:?verify_restore: framework required}"
  local check_domain="${4:?verify_restore: check_domain required}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would verify table count + curl ${check_domain}"
    return 0
  fi

  log_info "restore: verifying..."
  local tables=0
  if [ "${framework}" = "wordpress" ]; then
    tables="$(sudo -H -u "${user}" wp --path="${docroot}" db query "SHOW TABLES;" 2>/dev/null | wc -l || true)"
  else
    local db_name
    db_name="$(get_laravel_db_name "${docroot}")"
    [ -n "${db_name}" ] && tables="$(mariadb "${db_name}" -N -e "SHOW TABLES;" 2>/dev/null | wc -l || true)"
  fi
  tables="${tables:-0}"
  if [ "${tables}" -lt 1 ]; then
    log_warn "restore: VERIFY FAILED — 0 tables found in database"
  else
    log_info "restore: VERIFY OK — ${tables} tables in database"
  fi

  local code
  code="$(curl -sk -o /dev/null -w "%{http_code}" "https://${check_domain}/" 2>/dev/null || echo 000)"
  if [ "${code}" -ge 200 ] && [ "${code}" -lt 400 ]; then
    log_info "restore: VERIFY OK — https://${check_domain}/ returned HTTP ${code}"
  else
    log_warn "restore: VERIFY — https://${check_domain}/ returned HTTP ${code} (may need DNS/TLS)"
  fi
}

# ---- S3 source -------------------------------------------------------------

# s3_resolve_backup WORKDIR — download the chosen backup from S3 into WORKDIR.
# Populates BACKUP_DIR. Chooses --from if given, else the newest timestamp dir.
s3_resolve_backup() {
  local workdir="${1:?s3_resolve_backup: workdir required}"
  backup_s3_ensure || { log_error "restore: S3 not configured (${BACKUP_S3_CONF})"; exit 1; }

  local listing
  listing="$(backup_s3_list "${DOMAIN}/" 2>/dev/null || true)"

  # Keys look like: backups/<domain>/<timestamp>/database.sql.zst (or files.tar.zst)
  # Extract distinct timestamp dirs, newest first.
  local ts
  ts="$(printf '%s\n' "${listing}" | awk '{print $2}' | grep -oE "/${DOMAIN}/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}/" | sed -E "s#.*/${DOMAIN}/([0-9_-]+)/#\1#" | sort -u | sort -r | head -1)"
  if [ -z "${ts}" ]; then
    log_error "restore: no S3 backups found for ${DOMAIN}"
    exit 1
  fi
  if [ -n "${FROM}" ]; then
    if ! printf '%s\n' "${listing}" | grep -q "/${DOMAIN}/${FROM}/"; then
      log_error "restore: S3 backup not found: ${FROM} for ${DOMAIN}"
      exit 1
    fi
    ts="${FROM}"
  fi

  mkdir -p "${workdir}/${ts}"
  local key_db key_files
  key_db="$(printf '%s\n' "${listing}" | awk '{print $2}' | grep "/${DOMAIN}/${ts}/database.sql.zst" | head -1)"
  key_files="$(printf '%s\n' "${listing}" | awk '{print $2}' | grep "/${DOMAIN}/${ts}/files.tar.zst" | head -1)"

  if [ "${SKIP_DB}" != "1" ]; then
    [ -n "${key_db}" ] || { log_error "restore: database.sql.zst not found in S3 backup ${ts}"; exit 1; }
    backup_s3_download "${key_db}" "${workdir}/${ts}/database.sql.zst" || exit 1
  fi
  if [ "${SKIP_FILES}" != "1" ]; then
    [ -n "${key_files}" ] || { log_error "restore: files.tar.zst not found in S3 backup ${ts}"; exit 1; }
    backup_s3_download "${key_files}" "${workdir}/${ts}/files.tar.zst" || exit 1
  fi

  BACKUP_DIR="${workdir}/${ts}"
  log_info "restore: using S3 backup ${ts} (${BACKUP_DIR})"
}

# ---- target: override ------------------------------------------------------

restore_override() {
  log_info "restore: TARGET=override — restoring onto the running ${DOMAIN} app"

  # Resolve the running app's user + docroot from vhost metadata.
  if [ -z "${SITE_USER}" ]; then
    SITE_USER="$(backup_site_user "${DOMAIN}")" || exit 1
  fi
  local docroot
  docroot="$(backup_docroot "${DOMAIN}")" || exit 1
  log_info "restore: target docroot = ${docroot} (user ${SITE_USER})"

  [ -n "${FRAMEWORK}" ] || FRAMEWORK="$(detect_framework "${docroot}")"
  log_info "restore: framework = ${FRAMEWORK}"

  # Destructive safety: snapshot the current DB first.
  if [ "${SKIP_DB}" != "1" ]; then
    backup_current_db "${docroot}" "${SITE_USER}" \
      "/var/backups/litesoup/pre-restore-${DOMAIN}-$(date -u +%Y%m%d_%H%M%S).sql.zst"
  fi

  # Restore database.
  if [ "${SKIP_DB}" != "1" ]; then
    backup_verify_db "${BACKUP_DIR}/database.sql.zst" || exit 1
    import_db_override "${BACKUP_DIR}/database.sql.zst" "${docroot}" "${SITE_USER}" "${FRAMEWORK}"
  fi

  # Restore data files (uploads/storage).
  if [ "${SKIP_FILES}" != "1" ]; then
    backup_verify_archive "${BACKUP_DIR}/files.tar.zst" || exit 1
    local staged
    staged="$(stage_extract "${BACKUP_DIR}/files.tar.zst" "${WORKDIR}/stage-override")"
    restore_data_files "${staged}" "${docroot}" "${SITE_USER}" "${FRAMEWORK}"
  fi

  # Flush caches.
  if [ "${DRY_RUN}" != "1" ] && [ "${FRAMEWORK}" = "wordpress" ]; then
    log_info "restore: flushing caches..."
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" cache flush 2>/dev/null || true
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" eval "do_action('litespeed_purge_all');" 2>/dev/null || true
  fi

  verify_restore "${docroot}" "${SITE_USER}" "${FRAMEWORK}" "${DOMAIN}"
  log_info "restore: COMPLETE (override) for ${DOMAIN}"
}

# ---- target: new (WordPress, git) -----------------------------------------

restore_new_wp_git() {
  log_info "restore: TARGET=new (wordpress, git) — provisioning ${NEW_DOMAIN} as ${SITE_NAME}"

  # Decompress the DB dump for site-import.sh (expects .sql or .sql.gz).
  local tmp_sql="${WORKDIR}/database.sql"
  if [ "${DRY_RUN}" != "1" ]; then
    zstd -dc "${BACKUP_DIR}/database.sql.zst" > "${tmp_sql}"
  fi

  # site-import.sh provisions DB + clones code + imports dump + generates
  # wp-config (correct DB creds) + search-replaces + fixes ownership.
  local -a imp_args=(
    --name="${SITE_NAME}"
    --domain="${NEW_DOMAIN}"
    --git-repo="${GIT_REPO}"
    --db-dump="${tmp_sql}"
    --old-url="${OLD_URL}"
    --php="${PHP_VERSION}"
    --tier="${POOL_TIER}"
    --tls="${TLS_MODE}"
    --user="${SITE_USER:-litesoup}"
  )
  [ -n "${GIT_BRANCH}" ] && imp_args+=(--git-branch="${GIT_BRANCH}")
  [ -n "${TLS_EMAIL}" ] && imp_args+=(--email="${TLS_EMAIL}")
  [ "${DRY_RUN}" = "1" ] && imp_args+=(--dry-run)

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: bash site/site-import.sh ${imp_args[*]}"
  else
    bash "${REPO_ROOT}/site/site-import.sh" "${imp_args[@]}"
  fi

  # Restore uploads from the backup archive into the freshly cloned app.
  if [ "${SKIP_FILES}" != "1" ]; then
    backup_verify_archive "${BACKUP_DIR}/files.tar.zst" || exit 1
    local staged
    staged="$(stage_extract "${BACKUP_DIR}/files.tar.zst" "${WORKDIR}/stage-new")"
    local new_docroot="/home/${SITE_USER:-litesoup}/webapps/${SITE_NAME}"
    restore_data_files "${staged}" "${new_docroot}" "${SITE_USER:-litesoup}" "wordpress"
  fi

  verify_restore "/home/${SITE_USER:-litesoup}/webapps/${SITE_NAME}" \
    "${SITE_USER:-litesoup}" "wordpress" "${NEW_DOMAIN}"
  log_info "restore: COMPLETE (new) for ${NEW_DOMAIN}"
}

# ---- target: new (generic inline path: git or archive) --------------------

restore_new_inline() {
  local framework="${1:?restore_new_inline: framework required}"
  log_info "restore: TARGET=new (${framework}) — provisioning ${NEW_DOMAIN} as ${SITE_NAME}"

  local user="${SITE_USER:-litesoup}"
  local new_docroot="/home/${user}/webapps/${SITE_NAME}"

  # Provision docroot + vhost + TLS + PHP pool via site-create.sh. This also
  # creates a DB (we recreate it below with known creds) and, for laravel,
  # runs key:generate + storage:link.
  local -a cr_args=(
    --name="${SITE_NAME}"
    --domain="${NEW_DOMAIN}"
    --framework="${framework}"
    --php="${PHP_VERSION}"
    --tier="${POOL_TIER}"
    --tls="${TLS_MODE}"
    --user="${user}"
  )
  [ -n "${GIT_REPO}" ] && cr_args+=(--git-repo="${GIT_REPO}")
  [ -n "${GIT_BRANCH}" ] && cr_args+=(--git-branch="${GIT_BRANCH}")
  [ -n "${TLS_EMAIL}" ] && cr_args+=(--email="${TLS_EMAIL}")
  [ "${DRY_RUN}" = "1" ] && cr_args+=(--dry-run)

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: bash site/site-create.sh ${cr_args[*]}"
  else
    bash "${REPO_ROOT}/site/site-create.sh" "${cr_args[@]}"
  fi

  # Without a git repo, the code must come from the backup archive itself.
  # Stage the archive, then copy it into the freshly provisioned docroot —
  # preserving the wp-config.php / .env that site-create just generated (those
  # carry the correct DB creds for the new app).
  if [ -z "${GIT_REPO}" ] && [ "${SKIP_FILES}" != "1" ]; then
    backup_verify_archive "${BACKUP_DIR}/files.tar.zst" || exit 1
    log_info "restore: no --git-repo — copying full files archive into ${new_docroot}"
    local staged fresh_conf=""
    staged="$(stage_extract "${BACKUP_DIR}/files.tar.zst" "${WORKDIR}/stage-full")"
    if [ -f "${new_docroot}/wp-config.php" ]; then
      fresh_conf="${WORKDIR}/fresh-wp-config.php"
      cp "${new_docroot}/wp-config.php" "${fresh_conf}"
    fi
    if [ "${DRY_RUN}" != "1" ]; then
      cp -a "${staged}/." "${new_docroot}/"
      # Restore the fresh config so DB creds stay correct for the new app.
      if [ -n "${fresh_conf}" ]; then
        cp "${fresh_conf}" "${new_docroot}/wp-config.php"
      fi
      chown -R "${user}:${user}" "${new_docroot}"
    fi
  fi

  # Restore the database.
  if [ "${SKIP_DB}" != "1" ]; then
    backup_verify_db "${BACKUP_DIR}/database.sql.zst" || exit 1
    if [ "${framework}" = "wordpress" ]; then
      # Import into the DB site-create already provisioned, via wp-cli (reads
      # the freshly restored wp-config.php which carries the correct creds).
      import_db_override "${BACKUP_DIR}/database.sql.zst" "${new_docroot}" "${user}" "wordpress"
    else
      create_db_with_known_creds "${SITE_NAME}"
      import_db_new "${BACKUP_DIR}/database.sql.zst" "${DB_NAME}"
    fi
  fi

  if [ "${framework}" = "laravel" ]; then
    write_laravel_env "${new_docroot}" "${user}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" \
      "https://${NEW_DOMAIN}"
    # Restore storage/app data (git path: archive supplies it; no-git: already extracted).
    if [ "${SKIP_FILES}" != "1" ] && [ -n "${GIT_REPO}" ]; then
      backup_verify_archive "${BACKUP_DIR}/files.tar.zst" || exit 1
      local staged
      staged="$(stage_extract "${BACKUP_DIR}/files.tar.zst" "${WORKDIR}/stage-new")"
      restore_data_files "${staged}" "${new_docroot}" "${user}" "laravel"
    fi
    # Search-replace URLs.
    if [ -n "${OLD_URL}" ] && [ "${OLD_URL}" != "https://${NEW_DOMAIN}" ]; then
      laravel_search_replace "${new_docroot}" "${OLD_URL}" "https://${NEW_DOMAIN}"
    fi
    # Optional composer/npm build.
    if [ "${DO_BUILD}" = "1" ] && [ "${DRY_RUN}" != "1" ]; then
      log_info "restore: running composer/npm build in ${new_docroot}"
      if [ -f "${new_docroot}/composer.lock" ]; then
        sudo -H -u "${user}" composer install --no-interaction --working-dir="${new_docroot}" 2>/dev/null || log_warn "restore: composer install failed (non-fatal)"
      fi
      if [ -f "${new_docroot}/package.json" ]; then
        sudo -H -u "${user}" bash -c "cd '${new_docroot}' && (npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund 2>/dev/null) && npm run build 2>/dev/null" \
          || log_warn "restore: npm build failed (non-fatal)"
      fi
    fi
    chown -R "${user}:${user}" "${new_docroot}"
  elif [ "${framework}" = "wordpress" ]; then
    # Match wp-config table_prefix to the imported DB (site-create defaults to
    # wp_, but the backup may use a custom prefix).
    if [ "${SKIP_DB}" != "1" ]; then
      local pfx
      pfx="$(detect_table_prefix_from_zst "${BACKUP_DIR}/database.sql.zst")"
      set_wp_table_prefix "${new_docroot}" "${pfx}"
    fi
    # Search-replace the domain.
    if [ -n "${OLD_URL}" ] && [ "${OLD_URL}" != "https://${NEW_DOMAIN}" ] && [ "${DRY_RUN}" != "1" ]; then
      log_info "restore: search-replacing '${OLD_URL}' → https://${NEW_DOMAIN}"
      sudo -H -u "${user}" wp --path="${new_docroot}" search-replace \
        "${OLD_URL}" "https://${NEW_DOMAIN}" --all-tables --precise 2>/dev/null \
        || log_warn "restore: search-replace had warnings (check wp-cli output)"
    fi
    # Flush caches.
    if [ "${DRY_RUN}" != "1" ]; then
      sudo -H -u "${user}" wp --path="${new_docroot}" cache flush 2>/dev/null || true
      sudo -H -u "${user}" wp --path="${new_docroot}" rewrite flush 2>/dev/null || true
    fi
  fi

  verify_restore "${new_docroot}" "${user}" "${framework}" "${NEW_DOMAIN}"
  log_info "restore: COMPLETE (new) for ${NEW_DOMAIN}"
}

# ---- main ------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root
  validate

  backup_require_zstd

  log_info "restore: ${DOMAIN} source=${SOURCE} target=${TARGET}"

  WORKDIR="$(mktemp -d /tmp/litesoup-restore.XXXXXX)"
  trap 'rm -rf "${WORKDIR}"' EXIT INT TERM

  # Default old-url from the source domain (or BACKUP_META when present).
  if [ -z "${OLD_URL}" ] && [ -f "${BACKUP_DIR}/BACKUP_META" ]; then
    local meta_domain
    meta_domain="$(grep -oP '^domain=\K.*' "${BACKUP_DIR}/BACKUP_META" | head -1 || true)"
    [ -n "${meta_domain}" ] && OLD_URL="https://${meta_domain}"
  fi
  [ -n "${OLD_URL}" ] || OLD_URL="https://${DOMAIN}"
  [ "${OLD_URL_EXPLICIT}" = "1" ] && log_info "restore: search-replace source = ${OLD_URL}"

  # 1. Resolve the backup (local or S3) → BACKUP_DIR.
  if [ "${SOURCE}" = "s3" ]; then
    s3_resolve_backup "${WORKDIR}"
  else
    local base
    base="$(find_backup_base)" || {
      log_error "restore: no local backups found for ${DOMAIN} under /home/*/backups/"
      exit 1
    }
    BACKUP_DIR="$(select_backup_dir "${base}")"
    log_info "restore: using local backup ${BACKUP_DIR}"
  fi

  # 2. Dispatch on target.
  case "${TARGET}" in
    override)
      restore_override
      ;;
    new)
      # Detect framework from the backup's files archive when not forced.
      if [ -z "${FRAMEWORK}" ] && [ "${SKIP_FILES}" != "1" ]; then
        local staged
        staged="$(stage_extract "${BACKUP_DIR}/files.tar.zst" "${WORKDIR}/stage-detect")"
        FRAMEWORK="$(detect_framework "${staged}")"
        log_info "restore: auto-detected framework = ${FRAMEWORK}"
      fi
      [ -n "${FRAMEWORK}" ] || FRAMEWORK="wordpress"

      if [ "${FRAMEWORK}" = "wordpress" ] && [ -n "${GIT_REPO}" ]; then
        restore_new_wp_git
      else
        restore_new_inline "${FRAMEWORK}"
      fi
      ;;
  esac
}

main "$@"