#!/usr/bin/env bash
# harden/harden-user.sh — configure litesoup system user for SSH access.
#
# Enables shell access, sets up SSH authorized_keys, configures passwordless
# sudo, and optionally locks root SSH. Run after install-stack.sh.
#
# Usage: sudo bash harden-user.sh [--ssh-key="ssh-ed25519 AAA..."] [--lock-root] [--help]
#
# The litesoup user already exists (created by install-stack.sh stage 3).
# This script upgrades it from a daemon-only user to an operator user that
# can SSH in and run litesoup CLI via sudo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

SSH_KEY=""
LOCK_ROOT=0
LITESOUP_HOME="/home/litesoup"

usage() {
  cat <<'EOF'
litesoup harden-user — configure litesoup user as an SSH operator

Usage: sudo bash harden-user.sh [options]

Options:
  --ssh-key="ssh-ed25519 AAAA..."   SSH public key to authorize for litesoup user.
                                     Can be passed multiple times for multiple keys.
  --lock-root                        Disable direct root SSH login (PermitRootLogin no)
                                     and move SSH authorized_keys to litesoup user.
  --dry-run                          Print actions without executing.
  --help, -h                         Show this help.

The litesoup user already exists as a PHP-FPM pool user. This script:
  1. Gives litesoup a shell (/bin/bash)
  2. Creates ~litesoup/.ssh/authorized_keys
  3. Grants passwordless sudo
  4. Optionally locks root SSH and copies root's authorized_keys to litesoup

To add a key after initial setup:
  echo "ssh-ed25519 AAAA..." | sudo tee -a /home/litesoup/.ssh/authorized_keys
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --ssh-key=*) SSH_KEY="${arg#--ssh-key=}" ;;
      --lock-root) LOCK_ROOT=1 ;;
      --dry-run)   DRY_RUN=1 ;;
      --help|-h)   usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  # 1. Enable shell for litesoup user
  local current_shell
  current_shell="$(getent passwd litesoup | cut -d: -f7)"
  if [ "${current_shell}" != "/bin/bash" ]; then
    run_or_dryrun usermod -s /bin/bash litesoup
    log_info "harden-user: litesoup shell changed from ${current_shell} to /bin/bash"
  else
    log_info "harden-user: litesoup already has /bin/bash shell"
  fi

  # 2. Create SSH directory and authorized_keys
  run_or_dryrun install -d -m 0700 -o litesoup -g litesoup "${LITESOUP_HOME}/.ssh"

  if [ -n "${SSH_KEY}" ]; then
    # Write the provided key
    run_or_dryrun bash -c "echo '${SSH_KEY}' >> '${LITESOUP_HOME}/.ssh/authorized_keys'"
    run_or_dryrun chmod 0600 "${LITESOUP_HOME}/.ssh/authorized_keys"
    run_or_dryrun chown litesoup:litesoup "${LITESOUP_HOME}/.ssh/authorized_keys"
    log_info "harden-user: SSH key added to ${LITESOUP_HOME}/.ssh/authorized_keys"
  elif [ -f /root/.ssh/authorized_keys ]; then
    # Copy root's keys as fallback
    run_or_dryrun cp /root/.ssh/authorized_keys "${LITESOUP_HOME}/.ssh/authorized_keys"
    run_or_dryrun chmod 0600 "${LITESOUP_HOME}/.ssh/authorized_keys"
    run_or_dryrun chown litesoup:litesoup "${LITESOUP_HOME}/.ssh/authorized_keys"
    log_info "harden-user: copied root SSH keys to litesoup user"
  else
    log_info "harden-user: no SSH key provided and root has no authorized_keys"
    log_info "harden-user: add keys later via: echo 'key' | sudo tee -a ${LITESOUP_HOME}/.ssh/authorized_keys"
  fi

  # 3. Set up passwordless sudo
  if [ ! -f /etc/sudoers.d/litesoup ]; then
    run_or_dryrun bash -c "echo 'litesoup ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/litesoup"
    run_or_dryrun chmod 0440 /etc/sudoers.d/litesoup
    log_info "harden-user: passwordless sudo configured for litesoup"
  else
    log_info "harden-user: sudo already configured for litesoup"
  fi

  # 4. Optionally lock root SSH
  if [ "${LOCK_ROOT}" = "1" ]; then
    if [ ! -f /etc/ssh/sshd_config.d/52-litesoup-harden.conf ]; then
      log_info "harden-user: running harden-ssh.sh --no-root-login --no-password-auth first..."
      run_or_dryrun bash "${SCRIPT_DIR}/harden-ssh.sh" --no-root-login --no-password-auth
    elif ! grep -q 'PermitRootLogin no' /etc/ssh/sshd_config.d/52-litesoup-harden.conf; then
      log_info "harden-user: root login still enabled — re-running harden-ssh with --no-root-login"
      run_or_dryrun bash "${SCRIPT_DIR}/harden-ssh.sh" --no-root-login
    else
      log_info "harden-user: root SSH already disabled"
    fi
    log_info "harden-user: SSH as root is now disabled. Use: ssh litesoup@<server>"
  fi

  log_info "harden-user: COMPLETE"
  log_info "harden-user: SSH as litesoup@<host> (sudo for litesoup CLI)"
}

main "$@"
