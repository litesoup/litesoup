#!/usr/bin/env bash
# backup/backup-restore.sh — restore a site from a litesoup backup.
#
# Restores files and/or database from a backup directory created by
# backup/backup-site.sh. Supports selecting a specific backup timestamp
# or restoring the most recent one.
#
# Usage:
#   sudo bash backup/backup-restore.sh --domain=example.com [options]
#
# Options:
#   --domain=DOMAIN   Required. Site domain.
#   --user=NAME       Site system user (auto-detected if omitted).
#   --from=TIMESTAMP  Specific backup timestamp (e.g. 2026-07-14_120000).
#                     Default: most recent backup.
#   --skip-files      Skip file restore (database-only).
#   --skip-db         Skip database restore (files-only).
#   --dry-run         Preview without executing.
#   --help            Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/common.sh
source "${REPO_ROOT}/backup/lib/common.sh"

# ---- defaults --------------------------------------------------------------

DOMAIN=""
SITE_USER=""
FROM=""
SKIP_FILES=0
SKIP_DB=0

# ---- usage -----------------------------------------------------------------

usage() {
  cat <<'EOF'
litesoup backup-restore — restore a site from backup

Usage: sudo bash backup/backup-restore.sh --domain=DOMAIN [options]

Options:
  --domain=DOMAIN      Required. Site domain.
  --user=NAME          Site system user (auto-detected if omitted).
  --from=TIMESTAMP     Restore from a specific backup timestamp.
                       Default: most recent backup.
  --skip-files         Skip file restore (database-only).
  --skip-db            Skip database restore (files-only).
  --dry-run            Preview without executing.
  --help, -h           Show this help.

Examples:
  sudo bash backup/backup-restore.sh --domain=example.com
  sudo bash backup/backup-restore.sh --domain=example.com --from=2026-07-14_120000
  sudo bash backup/backup-restore.sh --domain=example.com --skip-db
EOF
}

# ---- arg parse -------------------------------------------------------------

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)       DOMAIN="${arg#*=}" ;;
      --user=*)         SITE_USER="${arg#*=}" ;;
      --from=*)         FROM="${arg#*=}" ;;
      --skip-files)     SKIP_FILES=1 ;;
      --skip-db)        SKIP_DB=1 ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
}

# ---- main ------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root

  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"
    usage
    exit 64
  fi
  backup_validate_name "${DOMAIN}" || exit 64

  if [ "${SKIP_FILES}" = "1" ] && [ "${SKIP_DB}" = "1" ]; then
    log_error "--skip-files and --skip-db cannot both be set"
    exit 64
  fi

  # 1. Resolve site user
  if [ -z "${SITE_USER}" ]; then
    SITE_USER="$(backup_site_user "${DOMAIN}")" || exit 1
  fi

  local backup_base="/home/${SITE_USER}/backups/${DOMAIN}"
  if [ ! -d "${backup_base}" ]; then
    log_error "restore: no backups found at ${backup_base}"
    exit 1
  fi

  # 2. Determine which backup to restore
  local restore_dir
  if [ -n "${FROM}" ]; then
    restore_dir="${backup_base}/${FROM}"
    if [ ! -d "${restore_dir}" ]; then
      log_error "restore: backup not found: ${restore_dir}"
      log_error "restore: available backups:"
      find "${backup_base}" -maxdepth 1 -type d ! -name "$(basename "${backup_base}")" -printf '%f\n' | head -10
      exit 1
    fi
  else
    # Pick the most recent (last alphabetically in YYYY-MM-DD_HHMMSS format)
    restore_dir="$(find "${backup_base}" -maxdepth 1 -type d ! -name "$(basename "${backup_base}")" -printf '%f\n' | sort -r | head -1)"
    if [ -z "${restore_dir}" ]; then
      log_error "restore: no backups found at ${backup_base}"
      exit 1
    fi
    restore_dir="${backup_base}/${restore_dir}"
  fi
  log_info "restore: restoring from ${restore_dir}"

  # 3. Resolve docroot
  local docroot
  docroot="$(backup_docroot "${DOMAIN}")" || exit 1
  log_info "restore: target docroot = ${docroot}"

  # 4. Restore files
  if [ "${SKIP_FILES}" != "1" ]; then
    local archive="${restore_dir}/files.tar.gz"
    if [ ! -f "${archive}" ]; then
      log_error "restore: file archive not found: ${archive}"
      log_error "restore: use --skip-files if restoring database only"
      exit 1
    fi
    log_info "restore: extracting files to ${docroot}..."

    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would tar -xzf ${archive} -C /"
      log_info "[DRYRUN] would chown -R ${SITE_USER}:${SITE_USER} ${docroot}"
    else
      # Archive was created with -C parent_dir basename, so extract from /
      # restores the full path: /home/<user>/webapps/<domain>/
      tar -xzf "${archive}" -C / 2>/dev/null || {
        log_error "restore: failed to extract files"
        exit 1
      }
      chown -R "${SITE_USER}:${SITE_USER}" "${docroot}"
      log_info "restore: files restored and ownership fixed"
    fi
  fi

  # 5. Restore database
  if [ "${SKIP_DB}" != "1" ]; then
    local sql_dump="${restore_dir}/database.sql"
    if [ ! -f "${sql_dump}" ]; then
      log_error "restore: database dump not found: ${sql_dump}"
      log_error "restore: use --skip-db if restoring files only"
      exit 1
    fi
    log_info "restore: importing database for ${DOMAIN}..."

    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would run: sudo -u ${SITE_USER} wp --path=${docroot} db import ${sql_dump}"
    else
      sudo -H -u "${SITE_USER}" wp --path="${docroot}" db import "${sql_dump}" 2>/dev/null || {
        log_error "restore: wp db import failed"
        log_error "restore: you may need to run: wp db import ${sql_dump} manually"
        exit 1
      }
      log_info "restore: database imported"
    fi
  fi

  # 6. Post-restore: flush cache
  if [ "${DRY_RUN}" != "1" ] && [ "${SKIP_DB}" != "1" ]; then
    log_info "restore: flushing cache..."
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" cache flush 2>/dev/null || true
    # Also flush LiteSpeed cache if the plugin is active
    sudo -H -u "${SITE_USER}" wp --path="${docroot}" eval "do_action('litespeed_purge_all');" 2>/dev/null || true
    log_info "restore: cache flushed"
  fi

  log_info "restore: COMPLETE for ${DOMAIN} from ${restore_dir}"
}

main "$@"
