#!/usr/bin/env bash
# site/site-user-list.sh — list all litesoup-managed system users.
#
# Shows users that have sites under /home/*/webapps/ along with their
# SSH/SFTP status, shell, and domain count.
#
# Usage: sudo bash site-user-list.sh [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

SORT_BY="user"

usage() {
  cat <<'EOF'
litesoup user list — list managed users

Usage: sudo bash site-user-list.sh [options]

Options:
  --help, -h  Show this help

Output columns:
  USER        System username
  SHELL       Login shell
  SSH KEY     Whether authorized_keys exists and has entries
  SFTP        Whether SFTP chroot is configured (Match block exists)
  DOMAINS     Number of site directories in webapps/
  HOME        Home directory path
EOF
}

main() {
  for arg in "$@"; do
    case "${arg}" in
      --help|-h) usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done

  require_root

  local header_printed=0
  local sftp_config="/etc/ssh/sshd_config.d/52-litesoup-sftp-chroot.conf"

  while IFS= read -r -d '' dir; do
    local user
    user="$(basename "${dir}")"
    local home="${dir}"
    local shell
    shell="$(getent passwd "${user}" 2>/dev/null | cut -d: -f7)"
    local webapps="${home}/webapps"

    # Only show users that either have webapps dir or are litesoup
    if [ "${user}" != "litesoup" ] && [ ! -d "${webapps}" ]; then
      continue
    fi

    if [ "${header_printed}" = "0" ]; then
      printf '%-20s %-18s %-8s %-6s %-7s %s\n' \
        "USER" "SHELL" "SSH KEY" "SFTP" "DOMAINS" "HOME"
      printf -- '----------------------------------------------------------------------------------------\n'
      header_printed=1
    fi

    # SSH key status
    local ssh_status="no"
    if [ -f "${home}/.ssh/authorized_keys" ] && [ -s "${home}/.ssh/authorized_keys" ]; then
      ssh_status="yes"
    elif [ -f "${home}/.ssh/authorized_keys" ]; then
      ssh_status="empty"
    fi

    # SFTP status
    local sftp_status="no"
    if [ -f "${sftp_config}" ] && grep -q "Match User ${user}\b" "${sftp_config}" 2>/dev/null; then
      sftp_status="yes"
    fi

    # Domain count
    local domain_count=0
    if [ -d "${webapps}" ]; then
      domain_count="$(find "${webapps}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
      domain_count="${domain_count##* }"  # trim whitespace
    fi

    printf '%-20s %-18s %-8s %-6s %-7s %s\n' \
      "${user}" \
      "${shell}" \
      "${ssh_status}" \
      "${sftp_status}" \
      "${domain_count}" \
      "${home}"
  done < <(find /home -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

main "$@"
