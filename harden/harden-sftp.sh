#!/usr/bin/env bash
# harden/harden-sftp.sh — enable SFTP chroot for an existing system user.
#
# Configures OpenSSH Match block with ForceCommand internal-sftp and
# ChrootDirectory, then fixes directory permissions for the chroot to
# work correctly (chroot root must be root-owned, subdirs user-writable).
#
# Usage: sudo bash harden-sftp.sh --user=<name> [--no-ssh] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

SFTP_USER=""
NO_SSH=0
OVERRIDE_FILE="/etc/ssh/sshd_config.d/52-litesoup-sftp-chroot.conf"

usage() {
  cat <<'EOF'
litesoup harden-sftp — enable SFTP chroot for a system user

Usage: sudo bash harden-sftp.sh --user=<name> [options]

Options:
  --user=<name>   System user to configure SFTP for (required)
  --no-ssh        Skip SSH key setup (only configure SFTP chroot)
  --dry-run       Print actions without executing
  --help, -h      Show this help

The SFTP chroot restricts the user to their home directory. The user
CANNOT:
  - cd outside /home/<user>
  - Run arbitrary commands (only SFTP operations)
  - Install packages or modify system files

The user CAN:
  - Upload/download files via SFTP
  - Manage files in /home/<user>/webapps/ (and subdirectories)
  - Use their assigned PHP-FPM pool (if any)

Requirements:
  - User must already exist on the system
  - SSH key should be added beforehand (or pass --no-ssh to skip)

Chroot directory permissions:
  SFTP chroot requires the chroot root (/home/<user>) to be owned by
  root:root with mode 0755. The user's writable directories (webapps/,
  .ssh/, etc.) are subdirectories owned by the user.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --user=*)   SFTP_USER="${arg#--user=}" ;;
      --no-ssh)   NO_SSH=1 ;;
      --dry-run)  DRY_RUN=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  if [ -z "${SFTP_USER}" ]; then
    log_error "--user is required"
    usage
    exit 64
  fi

  if ! id "${SFTP_USER}" >/dev/null 2>&1; then
    log_error "user ${SFTP_USER} does not exist"
    exit 1
  fi

  local home
  home="$(getent passwd "${SFTP_USER}" | cut -d: -f6)"

  # 1. Ensure home directory exists
  if [ ! -d "${home}" ]; then
    log_error "home directory ${home} not found for ${SFTP_USER}"
    exit 1
  fi

  # 2. Ensure .ssh/authorized_keys exists
  if [ "${NO_SSH}" != "1" ] && [ ! -f "${home}/.ssh/authorized_keys" ]; then
    log_info "harden-sftp: ${SFTP_USER} has no authorized_keys — creating empty file"
    run_or_dryrun install -d -m 0700 -o "${SFTP_USER}" -g "${SFTP_USER}" "${home}/.ssh"
    run_or_dryrun touch "${home}/.ssh/authorized_keys"
    run_or_dryrun chmod 0600 "${home}/.ssh/authorized_keys"
    run_or_dryrun chown "${SFTP_USER}:${SFTP_USER}" "${home}/.ssh/authorized_keys"
  fi

  # 3. Enable shell if it's nologin (SFTP needs a valid shell or ForceCommand)
  local current_shell
  current_shell="$(getent passwd "${SFTP_USER}" | cut -d: -f7)"
  if [ "${current_shell}" = "/usr/sbin/nologin" ] || [ "${current_shell}" = "/bin/false" ]; then
    # With ForceCommand internal-sftp, nologin is OK — but we need the
    # user to be able to authenticate. Keep nologin and rely on the
    # Match block's ForceCommand.
    log_info "harden-sftp: ${SFTP_USER} has ${current_shell} — OK, using ForceCommand"
  fi

  # 4. Write SSH Match block for SFTP chroot
  local desired
  desired="$(cat <<EOF
# /etc/ssh/sshd_config.d/52-litesoup-sftp-chroot.conf — managed by litesoup harden-sftp.sh
# SFTP-only chroot for user ${SFTP_USER}
Match User ${SFTP_USER}
  ForceCommand internal-sftp
  ChrootDirectory ${home}
  PermitTunnel no
  X11Forwarding no
  AllowAgentForwarding no
  PasswordAuthentication no
EOF
)"

  log_info "harden-sftp: configuring SFTP chroot for ${SFTP_USER} (${home})"

  if [ "${DRY_RUN}" != "1" ]; then
    local override_dir
    override_dir="$(dirname "${OVERRIDE_FILE}")"
    [ -d "${override_dir}" ] || { log_error "${override_dir} missing — is openssh-server installed?"; exit 1; }

    # Check if config already exists and is different
    if [ -f "${OVERRIDE_FILE}" ]; then
      local current
      current="$(cat "${OVERRIDE_FILE}")"
      if [ "${current}" = "${desired}" ]; then
        log_info "harden-sftp: SFTP config already up to date for ${SFTP_USER}"
      else
        log_info "harden-sftp: updating SFTP config (previous config had different content)"
        echo "${desired}" > "${OVERRIDE_FILE}"
        CHANGED=1
      fi
    else
      echo "${desired}" > "${OVERRIDE_FILE}"
      CHANGED=1
    fi

    chmod 0644 "${OVERRIDE_FILE}"

    # 5. Fix chroot directory permissions
    # The chroot root MUST be root-owned for chroot to work.
    # User's writable files go in subdirectories.
    if [ "$(stat -c '%U:%G' "${home}")" != "root:root" ]; then
      log_info "harden-sftp: fixing chroot root ownership (${home} → root:root)"
      chown root:root "${home}"
      chmod 0755 "${home}"
    fi
    # Ensure webapps/ is writable by user
    if [ -d "${home}/webapps" ] && [ "$(stat -c '%U:%G' "${home}/webapps")" != "${SFTP_USER}:${SFTP_USER}" ]; then
      chown "${SFTP_USER}:${SFTP_USER}" "${home}/webapps"
    fi
    # .ssh must be user-owned for key auth to work inside chroot
    if [ -d "${home}/.ssh" ] && [ "$(stat -c '%U' "${home}/.ssh")" != "${SFTP_USER}" ]; then
      chown -R "${SFTP_USER}:${SFTP_USER}" "${home}/.ssh"
    fi

    # Reload sshd if config changed
    if [ "${CHANGED:-0}" = "1" ]; then
      if sshd -t 2>/dev/null; then
        systemctl reload sshd
        log_info "harden-sftp: sshd reloaded"
      else
        log_error "harden-sftp: sshd configtest FAILED — review ${OVERRIDE_FILE}"
        exit 1
      fi
    fi
  fi

  log_info "harden-sftp: COMPLETE for ${SFTP_USER}"
  log_info "harden-sftp: SFTP access: sftp ${SFTP_USER}@<host>"
  log_info "harden-sftp: Chroot: ${home}"
  log_info "harden-sftp: Writable dirs: ${home}/webapps/ ${home}/.ssh/"
}

main "$@"
