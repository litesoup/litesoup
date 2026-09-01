#!/usr/bin/env bash
# harden/ssh-guard.sh — boot-time SSH guard (issue #75 follow-up).
#
# Runs as a systemd oneshot (litesoup-ssh-guard.service) at every boot.
# Prevents the Ubuntu 24.04 socket-activation SSH lockout from silently
# recurring after a reboot or package upgrade:
#
#   1. MASK ssh.socket — unlike `disable`, masking symlinks the unit to
#      /dev/null so NO package script or reboot can re-enable it.
#   2. Ensure standalone ssh.service is enabled and running (it binds the
#      CONFIGURED port, not the default socket port).
#   3. Assert sshd is actually listening on the configured port; if not,
#      restart ssh and re-check.
#
# Idempotent and safe to run at any time. Best-effort: logs clearly but
# never blocks boot (a failed oneshot does not halt the machine).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

main() {
  # Ensure the privilege-separation dir exists before any `sshd -T` call
  # (issue #78). On a fresh socket-activated host /run/sshd (tmpfs) is absent
  # until sshd runs; without it sshd -T aborts.
  install -d -m 0755 -o root -g root /run/sshd 2>/dev/null || true

  # 1. Mask ssh.socket (prevents ANY re-enable, incl. package scripts/reboot).
  if [ -L /etc/systemd/system/ssh.socket ] \
      && [ "$(readlink /etc/systemd/system/ssh.socket)" = "/dev/null" ]; then
    log_info "ssh-guard: ssh.socket already masked"
  else
    log_info "ssh-guard: masking ssh.socket"
    systemctl mask --now ssh.socket 2>/dev/null || true
  fi

  # 2. Ensure standalone sshd is enabled + running.
  systemctl enable ssh.service 2>/dev/null || true
  if ! systemctl is-active --quiet ssh.service; then
    log_info "ssh-guard: starting ssh.service"
    systemctl start ssh.service 2>/dev/null || true
  fi

  # 3. Assert sshd is healthy on the configured port. Robust check (sg11
  #    incident): the port must be owned by ssh.service's MainPID with NO
  #    orphaned sshd. A naive `ss | grep sshd` passes falsely when an orphan
  #    holds the port while the service is failed — exactly the lockout we saw.
  local ssh_port
  ssh_port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | tail -1)" || true
  ssh_port="${ssh_port:-22}"

  if assert_ssh_healthy "${ssh_port}" "ssh"; then
    log_info "ssh-guard: ssh.service active and owns port ${ssh_port} (no orphans)"
    return 0
  fi

  # Unhealthy — kill any orphaned sshd holding the port, then restart cleanly.
  log_warn "ssh-guard: SSH unhealthy on port ${ssh_port} — cleaning up orphaned sshd"
  kill_orphans_on_port "${ssh_port}" "ssh"
  systemctl reset-failed ssh.service 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || true
  sleep 2

  if assert_ssh_healthy "${ssh_port}" "ssh"; then
    log_info "ssh-guard: ssh.service recovered on port ${ssh_port}"
  else
    log_error "ssh-guard: FAILED to bring sshd up on port ${ssh_port} — investigate"
  fi
}

main "$@"