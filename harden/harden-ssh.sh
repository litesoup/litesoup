#!/usr/bin/env bash
# harden/harden-ssh.sh — write a managed sshd hardening override and reload ssh.
# Usage: sudo bash harden-ssh.sh [--no-password-auth] [--no-root-login] [--dry-run] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

OVERRIDE_FILE="/etc/ssh/sshd_config.d/52-litesoup-harden.conf"
# Initialize at top: under `set -u` (enabled by common.sh) `${CHANGED}` would
# crash the script before main() ever sets it. Read defensively as ${CHANGED:-0}.
CHANGED=0
NO_PASSWORD_AUTH=0
NO_ROOT_LOGIN=0

usage() {
  cat <<'EOF'
litesoup harden-ssh — write managed sshd hardening override for Ubuntu 24.04

Usage: sudo bash harden-ssh.sh [options]

Options:
  --no-password-auth  ALSO disable password authentication (key-only SSH).
                      OPT-IN -- not in defaults. Make sure your operators
                      have working SSH keys before enabling, or you will
                      lock everyone out on next session.
  --no-root-login     ALSO disable direct root SSH login. OPT-IN -- not in
                      defaults. Many litesoup deployments run install-stack
                      AS root over SSH; enabling this without first setting
                      up a non-root operator with sudo will lock you out.
  --dry-run           Print actions without executing
  --help, -h          Show this help

Always-applied defaults (always safe):
  MaxAuthTries 3              # brute-force mitigation
  ClientAliveInterval 300     # idle session reaping
  ClientAliveCountMax 2
  X11Forwarding no            # almost no one uses this; surface reduction
  AllowAgentForwarding no     # avoids agent-forwarding attacks
  PermitEmptyPasswords no     # zero-password is never the answer

Opt-in extras (only added when the matching flag is passed):
  PasswordAuthentication no   # requires --no-password-auth
  PermitRootLogin no          # requires --no-root-login

Behavior:
  1. Render desired sshd hardening directives based on flags.
  2. Write them to /etc/ssh/sshd_config.d/52-litesoup-harden.conf
     (mode 0644 root:root) only when content differs. The 52- prefix
     ensures we override any 50-cloud-init / 50-default present.
  3. Validate the FULL include chain via `sshd -t`. If validation fails,
     revert our write so sshd is never left in a broken state.
  4. Reload (NOT restart) ssh.service when content changed and validates.
     Reload preserves the active SSH session; restart would drop it.
  5. Print active hardening directives across /etc/ssh/sshd_config.d/*.conf.

Notes:
  - Does NOT manage `Port` — that is harden-firewall.sh's concern.
  - Does NOT touch /etc/ssh/sshd_config (package-managed; rewritten on apt
    upgrades). The override file is the supported extension point.
  - To go stricter than the opt-in flags allow (e.g., per-user AllowUsers
    rules, KbdInteractiveAuthentication off, ChallengeResponseAuthentication
    off), write a higher-numbered file like 99-local-strict.conf yourself.

Idempotent: re-runs detect existing identical content and skip the reload.
EOF
}

# write_override_if_changed PATH CONTENT
# Writes CONTENT to PATH (mode 0644 root:root) only if it differs from the
# current file. Sets the global `CHANGED` flag to 1 on (real or dry-run) write.
write_override_if_changed() {
  local path="$1" content="$2"

  if [ "${DRY_RUN}" = "1" ]; then
    if [ -f "${path}" ] && printf '%s' "${content}" | cmp -s - "${path}"; then
      log_info "[DRYRUN] ${path} already up to date"
    else
      log_info "[DRYRUN] would write ${path} (mode 0644 root:root)"
      CHANGED=1
    fi
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s' "${content}" > "${tmp}"
  if [ -f "${path}" ] && cmp -s "${tmp}" "${path}"; then
    log_info "harden-ssh: ${path} already up to date"
    rm -f "${tmp}"
  else
    log_info "harden-ssh: writing ${path}"
    install -m 0644 -o root -g root "${tmp}" "${path}"
    rm -f "${tmp}"
    CHANGED=1
  fi
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --no-password-auth) NO_PASSWORD_AUTH=1 ;;
      --no-root-login)    NO_ROOT_LOGIN=1 ;;
      --dry-run)          DRY_RUN=1 ;;
      --help|-h)          usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  # Sanity-check the drop-in dir. On Ubuntu 24.04 this exists out of the box;
  # if it is missing the package is broken or we are not on Ubuntu and the
  # main sshd_config will not Include our file anyway.
  local override_dir
  override_dir="$(dirname "${OVERRIDE_FILE}")"
  if [ "${DRY_RUN}" != "1" ] && [ ! -d "${override_dir}" ]; then
    log_error "harden-ssh: ${override_dir} missing — is openssh-server installed?"
    exit 1
  fi

  # 1. Render desired override content. Heredoc gives us REAL newlines; using
  #    a double-quoted "...\n..." string would write the literal two-character
  #    sequence `\n` and produce an invalid sshd_config.
  #
  #    Always-safe defaults are baked in. The two policy-dependent directives
  #    (PermitRootLogin, PasswordAuthentication) are appended only when the
  #    matching opt-in flag is passed. This avoids locking out operators who
  #    bootstrap with password SSH or run install-stack as root.
  local desired
  desired="$(cat <<'EOF'
# /etc/ssh/sshd_config.d/52-litesoup-harden.conf — managed by litesoup harden-ssh.sh.
# Re-running harden-ssh.sh may overwrite this file. The 52- numeric prefix
# ensures these directives override any 50-* drop-in shipped by the distro.
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
EOF
)"
  if [ "${NO_PASSWORD_AUTH}" = "1" ]; then
    desired="${desired}"$'\n'"PasswordAuthentication no"
    log_info "harden-ssh: --no-password-auth set, will add PasswordAuthentication no"
  fi
  if [ "${NO_ROOT_LOGIN}" = "1" ]; then
    desired="${desired}"$'\n'"PermitRootLogin no"
    log_info "harden-ssh: --no-root-login set, will add PermitRootLogin no"
  fi
  # Trailing newline so the file ends cleanly (POSIX text-file convention,
  # and avoids a `cmp -s` mismatch against a file that already has one).
  desired="${desired}"$'\n'

  # 2. Snapshot the current file (if any) BEFORE writing, so we can revert on
  #    sshd validation failure.
  local backup=""
  if [ "${DRY_RUN}" != "1" ] && [ -f "${OVERRIDE_FILE}" ]; then
    backup="$(mktemp)"
    cp -p "${OVERRIDE_FILE}" "${backup}"
  fi

  # 3. Write (only if changed).
  write_override_if_changed "${OVERRIDE_FILE}" "${desired}"

  # 4. Validate AFTER write — `sshd -t` reads the full include chain so it
  #    actually exercises our new override. Validating BEFORE the write would
  #    only test the pre-existing config.
  #
  #    On real systems we always validate, even if CHANGED=0, as a cheap
  #    safety net (catches corruption from out-of-band edits to OTHER drop-ins
  #    before we trigger a reload).
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: sshd -t"
  else
    if ! sshd -t 2>/tmp/litesoup-sshd-t.err; then
      log_error "harden-ssh: 'sshd -t' validation FAILED — reverting ${OVERRIDE_FILE}"
      log_error "harden-ssh: sshd -t output:"
      sed 's/^/  /' /tmp/litesoup-sshd-t.err >&2 || true
      rm -f /tmp/litesoup-sshd-t.err
      if [ -n "${backup}" ]; then
        # Had a prior version — restore it byte-for-byte.
        log_info "harden-ssh: restoring previous ${OVERRIDE_FILE} from backup"
        install -m 0644 -o root -g root "${backup}" "${OVERRIDE_FILE}"
        rm -f "${backup}"
      else
        # No prior version — remove the bad file we just wrote so nothing
        # broken lingers in the include chain.
        log_info "harden-ssh: removing newly written ${OVERRIDE_FILE} (no prior version to restore)"
        rm -f "${OVERRIDE_FILE}"
      fi
      # Re-validate post-revert. If THIS fails, the broken config is not
      # something we wrote; surface that loudly but still exit non-zero.
      if ! sshd -t; then
        log_error "harden-ssh: sshd -t still failing after revert — pre-existing config is broken"
      fi
      exit 1
    fi
    rm -f /tmp/litesoup-sshd-t.err
    log_info "harden-ssh: sshd -t validation ok"
    # NOTE: backup is intentionally NOT cleaned up here. We keep it until
    # AFTER the reload health check (step 5b), so a runtime reload failure
    # can still be rolled back.
  fi

  # 5. Reload only if we changed something. NEVER restart — that would drop
  #    the operator's current SSH session. Service name on Ubuntu 24.04 is
  #    `ssh.service` (not sshd.service).
  if [ "${CHANGED:-0}" = "1" ]; then
    run_or_dryrun systemctl reload ssh

    # 5b. POST-RELOAD HEALTH CHECK (issue #50). `sshd -t` validates syntax
    #     but `systemctl reload ssh` can still fail at runtime — sshd may
    #     silently fail during re-exec on some OpenSSH / Ubuntu combos,
    #     leaving port 22 with "Connection refused".  Poll up to 6 seconds
    #     for the listener to come back.
    if [ "${DRY_RUN}" != "1" ]; then
      local ssh_port=22
      if [ -n "${SSH_CONNECTION:-}" ]; then
        # Port we are actually connected on — best signal.
        ssh_port="$(echo "${SSH_CONNECTION}" | awk '{print $4}')"
      else
        # Fallback: read the effective configured port.
        ssh_port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | tail -1)"
        ssh_port="${ssh_port:-22}"
      fi
      local poll_ok=0
      local i
      for i in 1 2 3; do
        sleep 2
        if pgrep -x sshd >/dev/null 2>&1 && \
           ss -tlnp 2>/dev/null | grep -qE ":${ssh_port}\b"; then
          poll_ok=1
          break
        fi
      done
      if [ "${poll_ok}" != "1" ]; then
        log_error "harden-ssh: HEALTH CHECK FAILED — sshd not listening on port ${ssh_port} after reload"
        log_error "harden-ssh: Reverting ${OVERRIDE_FILE} and restarting sshd..."
        if [ -n "${backup:-}" ]; then
          install -m 0644 -o root -g root "${backup}" "${OVERRIDE_FILE}"
          rm -f "${backup}"
        else
          rm -f "${OVERRIDE_FILE}"
        fi
        # Force restart — will terminate this session, but the original
        # config is restored so the admin can reconnect.
        systemctl restart ssh 2>/dev/null || true
        log_error "harden-ssh: sshd restarted with original config. Reconnect via SSH."
        exit 1
      fi
      log_info "harden-ssh: health check ok — sshd listening on port ${ssh_port}"
      # Reload succeeded — safe to discard the backup now.
      [ -n "${backup:-}" ] && rm -f "${backup}"
    fi
  else
    log_info "harden-ssh: no override changes — skipping reload"
    # No reload happened — clean up the backup we kept for the health check.
    [ -n "${backup:-}" ] && rm -f "${backup}"
  fi

  # 6. Print active hardening directives (skipped in dry-run since the file
  #    we would have written is not actually on disk).
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would print active hardening directives"
    return 0
  fi

  log_info "harden-ssh: active hardening directives across sshd_config.d/*.conf:"
  grep -hE '^(PermitRootLogin|PasswordAuthentication|MaxAuthTries|X11Forwarding|AllowAgentForwarding|PermitEmptyPasswords|ClientAlive)' \
    /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sort -u || true
}

main "$@"
