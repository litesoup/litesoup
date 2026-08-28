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
  0. MASK Ubuntu 24.04 socket-activated SSH (ssh.socket) and switch to
     standalone sshd, which binds the CONFIG port. Masking (not just
     disabling) makes it impossible for a package upgrade or reboot to
     re-enable the socket. Also installs a boot-time systemd guard
     (litesoup-ssh-guard.service) that re-asserts the mask + standalone
     sshd at every boot, so the lockout cannot silently recur. Runs on
     every invocation (idempotent). MUST happen before harden-firewall.sh
     so the port the firewall opens is the one sshd actually listens on.
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

# install_ssh_guard — install the boot-time SSH guard (issue #75 follow-up).
# Copies harden/ssh-guard.sh to the installed lib dir and wires up a systemd
# oneshot (litesoup-ssh-guard.service) that runs at every boot to re-mask
# ssh.socket and assert sshd is listening on the configured port. This is what
# makes the socket-activation lockout non-recurring: even if a package upgrade
# recreates ssh.socket, the guard re-masks it on the next boot.
install_ssh_guard() {
  local guard_src="${SCRIPT_DIR}/ssh-guard.sh"
  local guard_dst="/usr/lib/litesoup/harden/ssh-guard.sh"
  local unit="/etc/systemd/system/litesoup-ssh-guard.service"

  # Copy the guard script to the installed lib dir (idempotent). When running
  # from the installed location, src == dst and the copy is skipped.
  if [ -f "${guard_src}" ] && [ "${guard_src}" != "${guard_dst}" ]; then
    install -d -m 0755 "$(dirname "${guard_dst}")"
    install -m 0755 "${guard_src}" "${guard_dst}"
  elif [ ! -f "${guard_dst}" ]; then
    log_warn "harden-ssh: ssh-guard.sh not found (${guard_src}) — skipping boot-time guard"
    return 0
  fi

  cat > "${unit}" <<UNITEOF
[Unit]
Description=LiteSoup SSH boot guard — mask ssh.socket, assert sshd on configured port
After=network.target ssh.service
ConditionPathExists=/etc/ssh/sshd_config

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${guard_dst}

[Install]
WantedBy=multi-user.target
UNITEOF

  systemctl daemon-reload
  systemctl enable litesoup-ssh-guard.service >/dev/null 2>&1 || true
  log_info "harden-ssh: boot-time SSH guard installed (${unit})"
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

  # Ensure the privilege-separation directory exists (issue #78). On a fresh
  # socket-activated Ubuntu 24.04 host, /run/sshd (a tmpfs) is empty/absent
  # until sshd actually runs. Without it, `sshd -t` / `sshd -T` abort with
  # "Missing privilege separation directory: /run/sshd", which made harden-ssh
  # fail validation, revert, and exit — leaving SSH down on every port.
  install -d -m 0755 -o root -g root /run/sshd 2>/dev/null || true

  # Sanity-check the drop-in dir. On Ubuntu 24.04 this exists out of the box;
  # if it is missing the package is broken or we are not on Ubuntu and the
  # main sshd_config will not Include our file anyway.
  local override_dir
  override_dir="$(dirname "${OVERRIDE_FILE}")"
  if [ "${DRY_RUN}" != "1" ] && [ ! -d "${override_dir}" ]; then
    log_error "harden-ssh: ${override_dir} missing — is openssh-server installed?"
    exit 1
  fi

  # Determine the effective SSH port ONCE, up front. Used by the socket-
  # activation check below and the post-reload health check. The port we are
  # actually connected on is the strongest signal; otherwise fall back to the
  # effective configured port (`sshd -T` resolves the full include chain).
  local ssh_port=22
  if [ -n "${SSH_CONNECTION:-}" ]; then
    ssh_port="$(echo "${SSH_CONNECTION}" | awk '{print $4}')"
  else
    ssh_port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | tail -1)"
    ssh_port="${ssh_port:-22}"
  fi

  # 0. SOCKET ACTIVATION CHECK (issue #58, #75). Ubuntu 24.04 ships
  #    socket-activated SSH by default: `ssh.socket` binds the DEFAULT port and
  #    spawns sshd on demand — regardless of the `Port` directive in the sshd
  #    config chain. If a non-standard port is configured via a drop-in, the
  #    socket still owns the default port while nothing listens on the config
  #    port. A default-deny firewall (harden-firewall.sh) then opens the config
  #    port and blocks the socket port → operator is locked out.
  #
  #    Fix: MASK ssh.socket (not just disable) and switch to traditional
  #    standalone sshd (ssh.service), which reads the config chain and binds the
  #    CONFIG port. Masking symlinks the unit to /dev/null so NO package script
  #    or reboot can re-enable it. This MUST run before any reload / health-check
  #    and before harden-firewall.sh, so the port the firewall opens is the one
  #    sshd actually listens on.
  #
  #    Check `is-enabled` (not just `is-active`): after a reboot the socket is
  #    ENABLED but inactive until a connection arrives, so an `is-active` test
  #    alone would miss it. Runs on EVERY invocation; masking is idempotent.
  if [ "${DRY_RUN}" != "1" ]; then
    local sock_state
    sock_state="$(systemctl is-enabled ssh.socket 2>/dev/null || echo unknown)"
    if [ "${sock_state}" != "masked" ]; then
      log_warn "harden-ssh: ssh.socket is '${sock_state}' (Ubuntu 24.04 socket-activated SSH)"
      log_warn "harden-ssh:    it binds the default port regardless of the Port directive."
      log_info "harden-ssh: switching to standalone sshd on port ${ssh_port}..."

      # TRANSITION ORDER MATTERS (issue #78). Masking ssh.socket BEFORE starting
      # ssh.service trips the ssh.service <-> ssh.socket dependency and the
      # standalone service fails to start ("Unit ssh.socket is masked") -> total
      # SSH lockout. Correct order:
      #   1. stop + disable the socket (it is the active listener),
      #   2. start standalone ssh.service (binds the CONFIG port),
      #   3. only THEN mask the socket so no package script / reboot can
      #      resurrect it. Masking an already-stopped socket is a no-op.
      systemctl stop ssh.socket 2>/dev/null || true
      systemctl disable ssh.socket 2>/dev/null || true

      local en_rc st_rc
      if ! systemctl enable ssh.service 2>/dev/null; then
        en_rc=$?
        log_error "harden-ssh: could not enable ssh.service (exit ${en_rc}) — restoring socket activation"
        systemctl enable --now ssh.socket 2>/dev/null || true
        exit 1
      fi
      if ! systemctl start ssh.service 2>/dev/null; then
        st_rc=$?
        log_error "harden-ssh: FAILED to start standalone ssh.service (exit ${st_rc})"
        log_error "harden-ssh: restoring ssh.socket so SSH is not lost"
        systemctl enable --now ssh.socket 2>/dev/null || true
        exit 1
      fi
      # sshd is now running standalone on the config port — mask the socket so
      # nothing can re-enable it (idempotent; --now on a stopped socket is a no-op).
      systemctl mask --now ssh.socket 2>/dev/null || true

      # Give sshd a moment to bind the config port, then verify. If the
      # configured port has no sshd listener after the transition, roll back to
      # socket activation rather than leave the operator locked out.
      if ! ss -tlnp 2>/dev/null | grep -qE ":${ssh_port}\b.*sshd"; then
        sleep 2
      fi
      if ss -tlnp 2>/dev/null | grep -qE ":${ssh_port}\b.*sshd"; then
        log_info "harden-ssh: sshd now owns port ${ssh_port} directly"
      else
        log_error "harden-ssh: sshd is NOT listening on port ${ssh_port} after transition"
        log_error "harden-ssh: restoring ssh.socket to avoid lockout"
        systemctl unmask ssh.socket 2>/dev/null || true
        systemctl enable --now ssh.socket 2>/dev/null || true
        exit 1
      fi
    fi
  fi

  # 0b. BOOT-TIME GUARD (issue #75 follow-up). `mask` survives reboot, but a
  #     package upgrade could theoretically recreate the socket. Install a
  #     systemd oneshot (litesoup-ssh-guard.service) that re-asserts the mask +
  #     standalone sshd at every boot, so the lockout cannot silently recur.
  if [ "${DRY_RUN}" != "1" ]; then
    install_ssh_guard
  else
    log_info "[DRYRUN] would install litesoup-ssh-guard.service + /usr/lib/litesoup/harden/ssh-guard.sh"
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

    # 5b. POST-RELOAD HEALTH CHECK (issue #50, #53). `sshd -t` validates syntax
    #     but `systemctl reload ssh` can still fail at runtime — sshd may
    #     silently fail during re-exec on some OpenSSH / Ubuntu combos,
    #     leaving port 22 with "Connection refused".  Poll up to 12 seconds
    #     for the listener to come back.
    #
    #     On busy systems (e.g. mid-install) the reload may take >6s for sshd
    #     to re-bind. If the sshd process is alive but port not bound yet,
    #     log a warning and proceed — the override IS written and will take
    #     effect on next sshd restart. Only revert if sshd died completely.
    if [ "${DRY_RUN}" != "1" ]; then
      local poll_ok=0
      local i
      for i in 1 2 3 4 5 6; do
        sleep 2
        if pgrep -x sshd >/dev/null 2>&1 && \
           ss -tlnp 2>/dev/null | grep -qE ":${ssh_port}\b"; then
          poll_ok=1
          break
        fi
      done
      if [ "${poll_ok}" != "1" ]; then
        # Distinguish timing issue (sshd process alive) from real failure.
        if pgrep -x sshd >/dev/null 2>&1; then
          log_warn "harden-ssh: sshd process alive but not yet listening on port ${ssh_port} after 12s"
          log_warn "harden-ssh: this is likely a transient timing issue (busy system)"
          log_warn "harden-ssh: override written — will take effect on next sshd restart/reload"
          log_warn "harden-ssh: run 'systemctl reload ssh' if hardening is not active"
        else
          log_error "harden-ssh: HEALTH CHECK FAILED — sshd process dead after reload"
          log_error "harden-ssh: Reverting ${OVERRIDE_FILE} and restarting sshd..."
          if [ -n "${backup:-}" ]; then
            install -m 0644 -o root -g root "${backup}" "${OVERRIDE_FILE}"
            rm -f "${backup}"
          else
            rm -f "${OVERRIDE_FILE}"
          fi
          systemctl restart ssh 2>/dev/null || true  # Force restart — will terminate this session, but the original config is restored so the admin can reconnect.
          log_error "harden-ssh: sshd restarted with original config. Reconnect via SSH."
          exit 1
        fi
      else
        log_info "harden-ssh: health check ok — sshd listening on port ${ssh_port}"
      fi
      # Reload succeeded (or process alive but slow) — discard backup.
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
