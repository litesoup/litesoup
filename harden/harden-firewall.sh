#!/usr/bin/env bash
# harden/harden-firewall.sh -- configure ufw on Ubuntu 24.04: deny incoming,
# allow outgoing, allow sshd's actual port + 80/tcp + 443/tcp, then enable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"

usage() {
  cat <<EOF
litesoup harden-firewall -- configure ufw (deny in, allow out, ssh+80+443)

Usage: sudo bash harden-firewall.sh [--dry-run] [--help]

Options:
  --dry-run   Print actions without executing
  --help, -h  Show this help

Behavior:
  1. apt install ufw if missing
  2. Default policies: deny incoming, allow outgoing
  3. Allow SSH on the actual sshd port (parsed from /etc/ssh/sshd_config,
     default 22), plus 80/tcp + 443/tcp
  4. Enable ufw with --force (skips interactive prompt; otherwise hangs)
  5. Print 'ufw status numbered'

Idempotent: re-runs report 'already configured' and apply no changes.
EOF
}

# Detect the active sshd Port from the FULL config chain, including
# /etc/ssh/sshd_config.d/*.conf drop-ins (where cloud-init / VPS
# providers commonly set a non-standard port).
#
# Primary method: `sshd -T` — outputs the effective configuration
# after resolving Includes, so it naturally yields the last-wins port
# across the entire chain.
# Fallback: manual awk over /etc/ssh/sshd_config (covers systems where
# sshd is not yet installed when detect_ssh_port is called, though in
# practice this runs after Apache stage ensures openssh-server is present).
# Ultimate fallback: 22.
detect_ssh_port() {
  local port=""
  if command -v sshd &>/dev/null; then
    # sshd -T reads the full config chain (including sshd_config.d/*.conf)
    # and outputs effective directives. Grep for the last `port N` line.
    port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | tail -1)"
  fi
  if [ -z "${port}" ]; then
    local conf="/etc/ssh/sshd_config"
    if [ -r "${conf}" ]; then
      # Strip leading whitespace, drop comment lines, match `Port <num>`,
      # take the last hit.
      port="$(awk '
        /^[[:space:]]*#/ { next }
        {
          sub(/^[[:space:]]+/, "")
          if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2
        }
        END { if (last != "") print last }
      ' "${conf}")"
    fi
  fi
  printf '%s' "${port:-22}"
}

# Returns 0 if a rule for the given "port/proto" appears in `ufw status` output.
# We match the "To" column at start-of-line tolerantly (numbered or plain
# `ufw status` both produce a `<port>/<proto>` token in column 1 / 2).
ufw_rule_present() {
  local status="$1" needle="$2"
  # Accept either "22/tcp" or "22 (v6)" style; the spec only adds tcp rules so
  # we only need to look for "<port>/tcp" tokens.
  printf '%s\n' "${status}" | grep -qE "(^|[[:space:]])${needle}([[:space:]]|$)"
}

# Returns 0 if `ufw status` shows "Status: active".
ufw_is_active() {
  local status="$1"
  printf '%s\n' "${status}" | grep -qE '^Status:[[:space:]]+active'
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run)  DRY_RUN=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  # 1. Ensure ufw is installed.
  if ! command -v ufw >/dev/null 2>&1; then
    log_info "harden-firewall: installing ufw"
    run_or_dryrun apt-get update
    run_or_dryrun apt-get install -y ufw
  else
    log_info "harden-firewall: ufw already installed"
  fi

  # 2. Detect ssh port BEFORE anything else -- locking ourselves out is the
  #    worst failure mode. If sshd_config is missing or unreadable we fall back
  #    to 22.
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  log_info "harden-firewall: ssh port = ${ssh_port}"

  # 3. Inspect current state. If ufw isn't installed yet (dry-run before
  #    install completes), `ufw status` won't run -- treat as inactive/empty.
  local status=""
  if command -v ufw >/dev/null 2>&1 && [ "${DRY_RUN}" != "1" ]; then
    status="$(ufw status 2>/dev/null || true)"
  elif command -v ufw >/dev/null 2>&1; then
    # Dry-run with ufw already installed: still safe to read state.
    status="$(ufw status 2>/dev/null || true)"
  fi

  local need_changes=0
  if ! ufw_is_active "${status}"; then
    need_changes=1
  else
    if ! ufw_rule_present "${status}" "${ssh_port}/tcp"; then need_changes=1; fi
    if ! ufw_rule_present "${status}" "80/tcp";          then need_changes=1; fi
    if ! ufw_rule_present "${status}" "443/tcp";         then need_changes=1; fi
  fi

  if [ "${need_changes}" = "0" ]; then
    log_info "harden-firewall: already configured (no changes)"
    # Still print final status so operators see what's live.
    if [ "${DRY_RUN}" != "1" ]; then
      ufw status numbered || true
    fi
    return 0
  fi

  # 4. Default policies. ufw is idempotent here -- re-asserting is cheap and
  #    self-healing.
  run_or_dryrun ufw default deny incoming
  run_or_dryrun ufw default allow outgoing

  # 5. Allow rules BEFORE enabling. Order matters: if `ufw enable` runs first
  #    on a remote box without an SSH allow rule in place, the active SSH
  #    session is killed by the new default-deny policy.
  run_or_dryrun ufw allow "${ssh_port}/tcp"
  run_or_dryrun ufw allow 80/tcp
  run_or_dryrun ufw allow 443/tcp

  # 6. Enable. `--force` is REQUIRED -- bare `ufw enable` prompts
  #    "Command may disrupt existing ssh connections. Proceed (y|n)?" and
  #    hangs forever in non-interactive contexts (cloud-init, ssh -T, CI).
  run_or_dryrun ufw --force enable

  # 7. Reload to make sure the kernel-level state matches what we just wrote.
  run_or_dryrun ufw reload

  # 8. Final status for the operator.
  if [ "${DRY_RUN}" != "1" ]; then
    ufw status numbered || true
  else
    log_info "[DRYRUN] would print 'ufw status numbered'"
  fi

  log_info "harden-firewall: COMPLETE (ssh=${ssh_port}/tcp, http=80/tcp, https=443/tcp)"
}

main "$@"
