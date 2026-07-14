#!/usr/bin/env bash
# backup/backup-list.sh — list existing backups for a litesoup site.
#
# Usage:
#   sudo bash backup/backup-list.sh --domain=example.com [--s3]
#
# Options:
#   --domain=DOMAIN   Required. Site domain.
#   --user=NAME       Site system user (auto-detected if omitted).
#   --s3              Also list remote backups on S3.
#   --dry-run         No-op (just shows what would be done).
#   --help            Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/common.sh
source "${REPO_ROOT}/backup/lib/common.sh"
# shellcheck source=./lib/s3.sh
source "${REPO_ROOT}/backup/lib/s3.sh"

DOMAIN=""
SITE_USER=""
SHOW_S3=0

usage() {
  cat <<'EOF'
litesoup backup-list — list site backups

Usage: sudo bash backup/backup-list.sh --domain=DOMAIN [options]

Options:
  --domain=DOMAIN      Required. Site domain.
  --user=NAME          Site system user (auto-detected if omitted).
  --s3                 Also list remote backups on S3.
  --help, -h           Show this help.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*) DOMAIN="${arg#*=}" ;;
      --user=*)    SITE_USER="${arg#*=}" ;;
      --s3)       SHOW_S3=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done

  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"
    usage
    exit 64
  fi
  backup_validate_name "${DOMAIN}" || exit 64
  require_root

  if [ -z "${SITE_USER}" ]; then
    SITE_USER="$(backup_site_user "${DOMAIN}")" || exit 1
  fi

  local backup_base="/home/${SITE_USER}/backups/${DOMAIN}"

  echo "═══ Local backups for ${DOMAIN} ═══"
  if [ ! -d "${backup_base}" ]; then
    echo "  (no local backups found at ${backup_base})"
  else
    printf '  %-22s %10s  %s\n' "TIMESTAMP" "SIZE" "CONTENTS"
    local dir
    for dir in $(find "${backup_base}" -maxdepth 1 -type d ! -name "$(basename "${backup_base}")" -printf '%f\n' | sort -r 2>/dev/null); do
      local size
      size="$(backup_size_human "${backup_base}/${dir}" 2>/dev/null || echo "?")"
      local contents=""
      [ -f "${backup_base}/${dir}/database.sql" ] && contents="${contents} DB"
      [ -f "${backup_base}/${dir}/files.tar.gz" ] && contents="${contents} files"
      [ -z "${contents}" ] && contents=" (empty)"
      printf '  %-22s %10s  %s\n' "${dir}" "${size}" "${contents}"
    done
  fi

  if [ "${SHOW_S3}" = "1" ]; then
    echo ""
    echo "═══ S3 backups for ${DOMAIN} ═══"
    local s3_results
    s3_results="$(backup_s3_list "${DOMAIN}/" 2>/dev/null || true)"
    if [ -z "${s3_results}" ]; then
      echo "  (no remote backups found)"
    else
      echo "${s3_results}"
    fi
  fi
}

main "$@"
