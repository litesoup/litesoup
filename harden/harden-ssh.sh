#!/usr/bin/env bash
# harden/harden-ssh.sh — write a managed sshd hardening override and reload ssh.
# Usage: sudo bash harden-ssh.sh [--dry-run] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

OVERRIDE_FILE="/etc/ssh/sshd_config.d/52-litesoup-harden.conf"
# Initialize at top: under `set -u` (enabled by common.sh) `${CHANGED}` would
# crash the script before main() ever sets it. Read defensively as ${CHANGED:-0}.
CHANGED=0

usage() {
  cat <<'EOF'
litesoup harden-ssh — write managed sshd hardening override for Ubuntu 24.04

Usage: sudo bash harden-ssh.sh [options]

Options:
  --dry-run   Print actions without executing
  --help, -h  Show this help

Behavior:
  1. Render desired sshd hardening directives.
  2. Write them to /etc/ssh/sshd_config.d/52-litesoup-harden.conf
     (mode 0644 root:root) only when content differs. The 52- prefix
     ensures we override any 50-cloud-init / 50-default present.
  3. Validate the FULL include chain via `sshd -t`. If validation fails,
     revert our write so sshd is never left in a broken state.
  4. Reload (NOT restart) ssh.service when content changed and validates.
     Reload preserves the active SSH session; restart would drop it.
  5. Print active hardening directives across /etc/ssh/sshd_config.d/*.conf.

Managed directives (written verbatim, not merged):
  PermitRootLogin no
  PasswordAuthentication no
  MaxAuthTries 3
  ClientAliveInterval 300
  ClientAliveCountMax 2
  X11Forwarding no
  AllowAgentForwarding no
  PermitEmptyPasswords no

Notes:
  - Does NOT manage `Port` — that is harden-firewall.sh's concern.
  - Does NOT touch /etc/ssh/sshd_config (package-managed; rewritten on apt
    upgrades). The override file is the supported extension point.

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
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
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
  local desired
  desired="$(cat <<'EOF'
# /etc/ssh/sshd_config.d/52-litesoup-harden.conf — managed by litesoup harden-ssh.sh.
# Re-running harden-ssh.sh may overwrite this file. The 52- numeric prefix
# ensures these directives override any 50-* drop-in shipped by the distro.
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
EOF
)"
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
    [ -n "${backup}" ] && rm -f "${backup}"
  fi

  # 5. Reload only if we changed something. NEVER restart — that would drop
  #    the operator's current SSH session. Service name on Ubuntu 24.04 is
  #    `ssh.service` (not sshd.service).
  if [ "${CHANGED:-0}" = "1" ]; then
    run_or_dryrun systemctl reload ssh
  else
    log_info "harden-ssh: no override changes — skipping reload"
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
