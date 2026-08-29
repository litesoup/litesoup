#!/usr/bin/env bash
# backup/backup-site.sh — per-site backup for litesoup.
#
# Creates a point-in-time backup of a site's files and/or database, stores
# it locally at /home/<user>/backups/<domain>/<timestamp>/, and optionally
# uploads to S3-compatible storage.
#
# Usage:
#   sudo bash backup/backup-site.sh --domain=example.com [options]
#
# Options:
#   --domain=DOMAIN   Required. Site domain.
#   --user=NAME       Site system user (auto-detected from vhost if omitted).
#   --dest=local|s3|all  Destination(s). Default: local.
#   --skip-files      Skip file archive (database-only).
#   --skip-db         Skip database dump (files-only).
#   --exclude=PATH    Additional exclude pattern (repeatable).
#   --keep=N          Local retention: keep N newest backups. Default: 7.
#   --dry-run         Preview without executing.
#   --help            Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/common.sh
source "${REPO_ROOT}/backup/lib/common.sh"
# shellcheck source=./lib/s3.sh
source "${REPO_ROOT}/backup/lib/s3.sh"

# ---- defaults --------------------------------------------------------------

DOMAIN=""
SITE_USER=""
DEST="local"
SKIP_FILES=0
SKIP_DB=0
KEEP=7
EXCLUDE=()

# ---- usage -----------------------------------------------------------------

usage() {
  cat <<'EOF'
litesoup backup-site — per-site backup

Usage: sudo bash backup/backup-site.sh --domain=DOMAIN [options]

Options:
  --domain=DOMAIN      Required. Site domain (e.g. example.com).
  --user=NAME          Site system user (auto-detected if omitted).
  --dest=local|s3|all  Where to store the backup. Default: local.
  --skip-files         Skip file archive (database-only backup).
  --skip-db            Skip database dump (files-only backup).
  --exclude=PATH       Exclude pattern when archiving files (repeatable).
  --keep=N             Keep N newest local backups. Default: 7.
  --dry-run            Preview without executing.
  --help, -h           Show this help.

Examples:
  sudo bash backup/backup-site.sh --domain=example.com
  sudo bash backup/backup-site.sh --domain=example.com --dest=all
  sudo bash backup/backup-site.sh --domain=example.com --skip-db --exclude=cache/
  sudo bash backup/backup-site.sh --domain=example.com --keep=30
EOF
}

# ---- arg parse -------------------------------------------------------------

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)       DOMAIN="${arg#*=}" ;;
      --user=*)         SITE_USER="${arg#*=}" ;;
      --dest=local)     DEST="local" ;;
      --dest=s3)        DEST="s3" ;;
      --dest=all)       DEST="all" ;;
      --skip-files)     SKIP_FILES=1 ;;
      --skip-db)        SKIP_DB=1 ;;
      --exclude=*)      EXCLUDE+=("${arg#*=}") ;;
      --keep=*)         KEEP="${arg#*=}" ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
}

# ---- validation ------------------------------------------------------------

validate() {
  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"
    usage
    exit 64
  fi
  backup_validate_name "${DOMAIN}" || exit 64

  if [ "${SKIP_FILES}" = "1" ] && [ "${SKIP_DB}" = "1" ]; then
    log_error "--skip-files and --skip-db cannot both be set (nothing to back up)"
    exit 64
  fi

  if [[ ! "${KEEP}" =~ ^[0-9]+$ ]] || [ "${KEEP}" -lt 1 ]; then
    log_error "--keep must be a positive integer (got: ${KEEP})"
    exit 64
  fi
}

# ---- main ------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root
  validate

  # Default compression is zstd — ensure the binary is present.
  backup_require_zstd

  # Acquire lock — prevent concurrent runs for the same domain
  local lockfile="/var/lock/litesoup-backup-${DOMAIN}.lock"
  exec 200>"${lockfile}"
  flock -n 200 || {
    log_error "backup: another backup is already running for ${DOMAIN} — skipping"
    exit 0
  }
  trap 'rm -f "${lockfile}"; exit' EXIT INT TERM

  local ts_start
  ts_start="$(date +%s)"
  log_info "backup: starting for ${DOMAIN}"

  # 1. Resolve site user (auto-detect if not provided)
  if [ -z "${SITE_USER}" ]; then
    SITE_USER="$(backup_site_user "${DOMAIN}")" || exit 1
  fi
  log_info "backup: site user = ${SITE_USER}"

  # 2. Create backup directory
  local ts
  ts="$(backup_timestamp)"
  local backup_base="/home/${SITE_USER}/backups/${DOMAIN}"
  local backup_dir="${backup_base}/${ts}"
  local files_archive="${backup_dir}/files"
  local db_dump="${backup_dir}/database.sql.zst"

  if [ "${DRY_RUN}" != "1" ]; then
    mkdir -p "${backup_dir}"
  fi
  log_info "backup: target = ${backup_dir}"

  # 3. Backup database
  if [ "${SKIP_DB}" != "1" ]; then
    local db_ts
    db_ts="$(date +%s)"
    timeout 300 bash -c "
REPO_ROOT='${REPO_ROOT}'
source \"\${REPO_ROOT}/backup/lib/common.sh\"
backup_dump_db '${DOMAIN}' '${backup_dir}'
" || {
      local db_ec=$?
      if [ "${db_ec}" -eq 124 ]; then
        notify_event "backup TIMEOUT: ${DOMAIN}" "Database dump timed out (>300s) for ${DOMAIN}"
        log_error "backup: DB dump TIMEOUT (>300s) for ${DOMAIN}"
      else
        notify_event "backup failed: ${DOMAIN}" "Database dump failed (exit ${db_ec}) for ${DOMAIN}"
        log_error "backup: DB dump FAILED (exit ${db_ec}) for ${DOMAIN}"
      fi
      exit 1
    }
    local db_elapsed=$(( $(date +%s) - db_ts ))
    log_info "backup: DB dump OK (${db_elapsed}s) for ${DOMAIN}"
    if [ "${DRY_RUN}" != "1" ]; then
      backup_verify_db "${db_dump}" || exit 1
    fi
  fi

  # 4. Backup files
  if [ "${SKIP_FILES}" != "1" ]; then
    local docroot
    docroot="$(backup_docroot "${DOMAIN}")" || exit 1
    # Apply CLI --exclude patterns via temp file
    local exclude_file=""
    if [ "${#EXCLUDE[@]}" -gt 0 ]; then
      exclude_file="$(mktemp /tmp/litesoup-backup-exclude.XXXXXX)"
      printf '%s\n' "${EXCLUDE[@]}" > "${exclude_file}"
      # Wire into backup_archive by copying to the global exclude location
      if [ "${DRY_RUN}" != "1" ]; then
        cp "${exclude_file}" "${backup_dir}/exclude.txt"
      fi
    fi
    local fs_ts
    fs_ts="$(date +%s)"
    timeout 600 bash -c "
REPO_ROOT='${REPO_ROOT}'
source \"\${REPO_ROOT}/backup/lib/common.sh\"
backup_archive '${docroot}' '${files_archive}'
" || {
      local fs_ec=$?
      rm -f "${exclude_file:-}"
      if [ "${fs_ec}" -eq 124 ]; then
        notify_event "backup TIMEOUT: ${DOMAIN}" "File archive timed out (>600s) for ${DOMAIN}"
        log_error "backup: file archive TIMEOUT (>600s) for ${DOMAIN}"
      else
        notify_event "backup failed: ${DOMAIN}" "File archive failed (exit ${fs_ec}) for ${DOMAIN}"
        log_error "backup: file archive FAILED (exit ${fs_ec}) for ${DOMAIN}"
      fi
      exit 1
    }
    local fs_elapsed=$(( $(date +%s) - fs_ts ))
    log_info "backup: file archive OK (${fs_elapsed}s) for ${DOMAIN}"
    if [ "${DRY_RUN}" != "1" ]; then
      backup_verify_archive "${files_archive}.tar.zst" || exit 1
    fi
    rm -f "${exclude_file:-}"
  fi

  # 5. Record backup metadata
  if [ "${DRY_RUN}" != "1" ]; then
    {
      printf 'domain=%s\n' "${DOMAIN}"
      printf 'user=%s\n' "${SITE_USER}"
      printf 'timestamp=%s\n' "${ts}"
      printf 'files=%s\n' "$([ "${SKIP_FILES}" = "1" ] && echo 0 || echo 1)"
      printf 'database=%s\n' "$([ "${SKIP_DB}" = "1" ] && echo 0 || echo 1)"
      printf 'size_bytes='
      du -sb "${backup_dir}" 2>/dev/null | awk '{print $1}' || echo 0
    } > "${backup_dir}/BACKUP_META"
    chmod 0600 "${backup_dir}/BACKUP_META"
    # Ensure backup dirs are owned by root (root-only access for security)
    chown -R root:root "${backup_base}" 2>/dev/null || true
  fi

  # 6. Upload to S3
  if [ "${DEST}" = "s3" ] || [ "${DEST}" = "all" ]; then
    log_info "backup: uploading to S3..."
    if [ "${SKIP_DB}" != "1" ]; then
      backup_s3_upload "${db_dump}" "${DOMAIN}/${ts}/database.sql.zst" || log_warn "backup: S3 upload of database failed"
    fi
    if [ "${SKIP_FILES}" != "1" ]; then
      backup_s3_upload "${files_archive}.tar.zst" "${DOMAIN}/${ts}/files.tar.zst" || log_warn "backup: S3 upload of files failed"
    fi
  fi

  # 7. Rotate local backups
  backup_rotate_local "${backup_base}" "${KEEP}"

  # 8. Summary
  local ts_end
  ts_end="$(date +%s)"
  local total_elapsed=$(( ts_end - ts_start ))
  local total_size
  total_size="$(backup_size_human "${backup_dir}" 2>/dev/null || echo "unknown")"
  log_info "backup: COMPLETE for ${DOMAIN} → ${backup_dir} (${total_size}, ${total_elapsed}s)"
  notify_event "backup complete: ${DOMAIN}" "Backup completed successfully.\n  Location: ${backup_dir}\n  Size: ${total_size}\n  Duration: ${total_elapsed}s"
}

main "$@"
