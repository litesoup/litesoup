#!/usr/bin/env bash
# backup/lib/common.sh — shared backup helpers for backup-*.sh scripts.
#
# Imports:
#   install/lib/common.sh   (run_or_dryrun, log_*, require_root)
#   install/lib/notify.sh   (notify_event)
#
# Provides:
#   backup_site_user     DOMAIN → SITE_USER   (via /etc/litesoup/vhost/*.conf)
#   backup_docroot       DOMAIN → path        (via /etc/litesoup/vhost/*.conf)
#   backup_timestamp     → "YYYY-MM-DD_HHMMSS"
#   backup_archive       SRCDIR DEST          → tar.gz
#   backup_dump_db       DOMAIN DEST          → .sql
#   backup_rotate_local  BACKUP_DIR KEEP      → prune excess dirs
#   backup_size_human    PATH                 → "123M" / "1.2G"
#   backup_validate_name DOMAIN               → safe string (alphanum + dots)

[ -n "${LITESOUP_BACKUP_COMMON_SH:-}" ] && return 0
LITESOUP_BACKUP_COMMON_SH=1

# Source the core helpers we depend on. We dynamically resolve REPO_ROOT
# because backup scripts set SCRIPT_DIR before sourcing us.
: "${REPO_ROOT:?backup/lib/common.sh: REPO_ROOT must be set by the calling script}"
# shellcheck source=../../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../../install/lib/notify.sh
source "${REPO_ROOT}/install/lib/notify.sh"

# Root is required for all backup operations (file ownership, DB access).
# Call require_root at the start of each backup script's main() — we
# define it here via common.sh but don't invoke it at source time so
# unit tests can source this file without running as root.

BACKUP_VHOST_DIR="/etc/litesoup/vhost"

# ---- helpers ---------------------------------------------------------------

# backup_timestamp → "YYYY-MM-DD_HHMMSS"
backup_timestamp() {
  date -u +"%Y-%m-%d_%H%M%S"
}

# backup_validate_name DOMAIN — ensure the domain is safe for use in paths.
# Returns 0 if valid, 1 if invalid (prints error to stderr).
backup_validate_name() {
  local name="${1:?backup_validate_name: domain required}"
  if [[ ! "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    log_error "backup: invalid domain name: '${name}'"
    return 1
  fi
}

# ---- site discovery (via Apache vhost config) ------------------------------
#
# litesoup site-create.sh writes vhost configs to /etc/litesoup/vhost/<domain>.conf
# with lines like:
#   SITE_USER=litesoup
#   DOCROOT=/home/litesoup/webapps/example.com

backup_site_user() {
  local domain="${1:?backup_site_user: domain required}"
  local conf="${BACKUP_VHOST_DIR}/${domain}.conf"
  if [ ! -f "${conf}" ]; then
    log_error "backup: vhost config not found for '${domain}' (expected ${conf})"
    return 1
  fi
  grep -oP '^SITE_USER=\K.*' "${conf}" 2>/dev/null | head -1 || {
    log_error "backup: cannot determine SITE_USER from ${conf}"
    return 1
  }
}

backup_docroot() {
  local domain="${1:?backup_docroot: domain required}"
  local conf="${BACKUP_VHOST_DIR}/${domain}.conf"
  if [ ! -f "${conf}" ]; then
    log_error "backup: vhost config not found for '${domain}' (expected ${conf})"
    return 1
  fi
  grep -oP '^DOCROOT=\K.*' "${conf}" 2>/dev/null | head -1 || {
    log_error "backup: cannot determine DOCROOT from ${conf}"
    return 1
  }
}

# ---- file archive ----------------------------------------------------------

# backup_archive SRCDIR DEST — creates SRCDIR/DEST.tar.gz
# Skips patterns listed in a global exclude file if present.
backup_archive() {
  local srcdir="${1:?backup_archive: srcdir required}"
  local dest="${2:?backup_archive: dest required}"
  local name
  name="$(basename "${dest}")"

  if [ ! -d "${srcdir}" ]; then
    log_error "backup: source directory not found: ${srcdir}"
    return 1
  fi

  log_info "backup: archiving ${srcdir} → ${dest}.tar.gz"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would tar -czf ${dest}.tar.gz -C $(dirname "${srcdir}") $(basename "${srcdir}")"
    return 0
  fi

  local exclude_opts=()
  if [ -f "${REPO_ROOT}/backup/backup-exclude-global.txt" ]; then
    while IFS= read -r line; do
      # Skip blank lines and comments
      case "${line}" in
        ''|\#*) continue ;;
        *) exclude_opts+=(--exclude="${line}") ;;
      esac
    done < "${REPO_ROOT}/backup/backup-exclude-global.txt"
  fi

  tar -czf "${dest}.tar.gz" \
    "${exclude_opts[@]}" \
    -C "$(dirname "${srcdir}")" \
    "$(basename "${srcdir}")" 2>/dev/null
  log_info "backup: archive created ($(backup_size_human "${dest}.tar.gz"))"
}

# ---- database dump ---------------------------------------------------------

# backup_dump_db DOMAIN DEST — uses wp-cli to export the site's database.
# DEST/database.sql is created with mode 0600 owned by root.
# Discovers docroot via backup_docroot(), then runs:
#   sudo -u SITE_USER wp --path=DOCROOT db export DEST/database.sql
backup_dump_db() {
  local domain="${1:?backup_dump_db: domain required}"
  local dest_dir="${2:?backup_dump_db: dest_dir required}"

  local user docroot
  user="$(backup_site_user "${domain}")" || return 1
  docroot="$(backup_docroot "${domain}")" || return 1

  if [ ! -d "${docroot}" ]; then
    log_error "backup: docroot not found: ${docroot} (site may not be fully provisioned)"
    return 1
  fi

  log_info "backup: dumping database for ${domain} → ${dest_dir}/database.sql"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: sudo -u ${user} wp --path=${docroot} db export ${dest_dir}/database.sql"
    return 0
  fi

  mkdir -p "${dest_dir}"
  sudo -H -u "${user}" wp --path="${docroot}" db export "${dest_dir}/database.sql" 2>/dev/null || {
    log_error "backup: wp db export failed for ${domain}"
    return 1
  }
  chmod 0600 "${dest_dir}/database.sql"
  log_info "backup: database exported ($(backup_size_human "${dest_dir}/database.sql"))"
}

# ---- local rotation --------------------------------------------------------

# backup_rotate_local BACKUP_DIR KEEP — keeps the KEEP most recent
# subdirectories, removes the rest. Sorted alphabetically (YYYY-MM-DD_HHMMSS
# format sorts correctly as string).
backup_rotate_local() {
  local backup_dir="${1:?backup_rotate_local: backup_dir required}"
  local keep="${2:-7}"

  if [ ! -d "${backup_dir}" ]; then
    return 0  # nothing to rotate
  fi

  local -a dirs
  mapfile -t dirs < <(find "${backup_dir}" -maxdepth 1 -type d ! -name "$(basename "${backup_dir}")" -printf '%f\n' | sort -r 2>/dev/null || true)

  if [ "${#dirs[@]}" -le "${keep}" ]; then
    return 0  # fewer dirs than keep limit
  fi

  local to_remove=("${dirs[@]:${keep}}")
  log_info "backup: rotating local backups — keeping ${keep}, removing ${#to_remove[@]}"

  if [ "${DRY_RUN}" = "1" ]; then
    for d in "${to_remove[@]}"; do
      log_info "[DRYRUN] would rm -rf ${backup_dir}/${d}"
    done
    return 0
  fi

  for d in "${to_remove[@]}"; do
    rm -rf "${backup_dir:?}/${d}"
    log_info "backup: removed old backup ${backup_dir}/${d}"
  done
}

# ---- display helpers -------------------------------------------------------

backup_size_human() {
  local path="${1:?backup_size_human: path required}"
  if [ ! -e "${path}" ]; then
    printf '0B'
    return 0
  fi
  local bytes
  bytes="$(stat -f%z "${path}" 2>/dev/null || stat -c%s "${path}" 2>/dev/null || echo 0)"
  if [ "${bytes}" -lt 1024 ]; then
    printf '%d B' "${bytes}"
  elif [ "${bytes}" -lt 1048576 ]; then
    printf '%.0f KB' "$((bytes / 1024))"
  elif [ "${bytes}" -lt 1073741824 ]; then
    printf '%.1f MB' "$(echo "scale=1; ${bytes} / 1048576" | bc 2>/dev/null || echo 0)"
  else
    printf '%.1f GB' "$(echo "scale=1; ${bytes} / 1073741824" | bc 2>/dev/null || echo 0)"
  fi
}
