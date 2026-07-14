#!/usr/bin/env bash
# harden/harden-fail2ban.sh — configure fail2ban with managed sshd + apache-auth jails.
# Usage: sudo bash harden-fail2ban.sh [--dry-run] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

JAIL_DIR="/etc/fail2ban/jail.d"
SSHD_JAIL="${JAIL_DIR}/litesoup-sshd.local"
APACHE_JAIL="${JAIL_DIR}/litesoup-apache-auth.local"
APACHE_LOG_DIR="/var/log/apache2"

# Detect the active sshd Port from the FULL config chain, including
# /etc/ssh/sshd_config.d/*.conf drop-ins (where cloud-init / VPS
# providers commonly set a non-standard port). Must match the same
# function in harden-firewall.sh — if these diverge, the firewall
# opens one port while fail2ban watches a different one (= no SSH
# brute-force protection).
#
# Primary method: `sshd -T` (resolves the full include chain).
# Fallback: manual awk over /etc/ssh/sshd_config.
# Ultimate fallback: 22.
detect_ssh_port() {
  local port=""
  if command -v sshd &>/dev/null; then
    port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | tail -1)"
  fi
  if [ -z "${port}" ]; then
    local conf="/etc/ssh/sshd_config"
    if [ -r "${conf}" ]; then
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

usage() {
  cat <<'EOF'
litesoup harden-fail2ban — install + configure fail2ban for Ubuntu 24.04

Usage: sudo bash harden-fail2ban.sh [options]

Options:
  --dry-run   Print actions without executing
  --help      Show this help

Installs fail2ban (if missing) and writes two managed jails under
/etc/fail2ban/jail.d/:
  - litesoup-sshd.local         [sshd] — systemd backend, 3 retries / 1h ban
  - litesoup-apache-auth.local  [apache-auth] — apache2 error logs, 5 retries

The apache-auth jail is skipped (with a warning) if /var/log/apache2/ is
absent (Apache not installed).

Idempotent: jail files are only rewritten when content differs; fail2ban is
only reloaded when at least one file changed.
EOF
}

# write_jail_if_changed PATH CONTENT
# Writes CONTENT to PATH (mode 0644 root:root) only if it differs from the
# current file. Sets the global `changed` flag to 1 on write.
write_jail_if_changed() {
  local path="$1" content="$2"

  if [ "${DRY_RUN}" = "1" ]; then
    if [ -f "${path}" ] && printf '%s' "${content}" | cmp -s - "${path}"; then
      log_info "[DRYRUN] ${path} already up to date"
    else
      log_info "[DRYRUN] would write ${path} (mode 0644 root:root)"
      changed=1
    fi
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s' "${content}" > "${tmp}"
  if [ -f "${path}" ] && cmp -s "${tmp}" "${path}"; then
    log_info "fail2ban: ${path} already up to date"
    rm -f "${tmp}"
  else
    log_info "fail2ban: writing ${path}"
    install -m 0644 -o root -g root "${tmp}" "${path}"
    rm -f "${tmp}"
    changed=1
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

  # 1. Install fail2ban if the binary is missing.
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    log_info "fail2ban: installing package"
    run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get update -y
    run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
  else
    log_info "fail2ban: package already installed"
  fi

  # /etc/fail2ban/jail.d/ is created by the package; sanity-check.
  if [ "${DRY_RUN}" != "1" ] && [ ! -d "${JAIL_DIR}" ]; then
    log_error "fail2ban: ${JAIL_DIR} missing after install"
    exit 1
  fi

  local changed=0

  # 2. sshd jail — always managed. Port matches sshd_config so fail2ban
  #    actually watches the port sshd is listening on (not just `ssh` →
  #    /etc/services 22, which silently misses non-default ports).
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  log_info "fail2ban: sshd jail will watch port ${ssh_port}/tcp"
  local sshd_content
  sshd_content="$(cat <<EOF
# /etc/fail2ban/jail.d/litesoup-sshd.local — managed by litesoup harden-fail2ban.sh.
# Re-running harden-fail2ban.sh may overwrite this file.
[sshd]
enabled = true
port = ${ssh_port}
maxretry = 3
bantime = 3600
findtime = 600
backend = systemd
EOF
)"
  write_jail_if_changed "${SSHD_JAIL}" "${sshd_content}"$'\n'

  # 3. apache-auth jail — only if Apache log dir exists.
  local apache_skipped=0
  if [ -d "${APACHE_LOG_DIR}" ]; then
    local apache_content
    apache_content="$(cat <<'EOF'
# /etc/fail2ban/jail.d/litesoup-apache-auth.local — managed by litesoup harden-fail2ban.sh.
# Re-running harden-fail2ban.sh may overwrite this file.
[apache-auth]
enabled = true
port = http,https
logpath = /var/log/apache2/*error.log
maxretry = 5
bantime = 3600
EOF
)"
    write_jail_if_changed "${APACHE_JAIL}" "${apache_content}"$'\n'
  else
    apache_skipped=1
    log_warn "fail2ban: ${APACHE_LOG_DIR} not found — skipping apache-auth jail (Apache not installed?)"
  fi

  # 4. Enable + start fail2ban.
  run_or_dryrun systemctl enable --now fail2ban

  # 5. Reload only if any managed file changed.
  if [ "${changed}" = "1" ]; then
    run_or_dryrun systemctl reload fail2ban
  else
    log_info "fail2ban: no jail file changes — skipping reload"
  fi

  # 6. Smoke tests + final status (skipped in dry-run).
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: fail2ban-client status sshd"
    [ "${apache_skipped}" = "0" ] && log_info "[DRYRUN] would run: fail2ban-client status apache-auth"
    log_info "[DRYRUN] would run: fail2ban-client status"
    return 0
  fi

  # Give fail2ban a moment to register reloaded jails.
  local _i
  for _i in $(seq 1 10); do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! fail2ban-client status sshd; then
    log_error "fail2ban: sshd jail failed to load"
    exit 1
  fi
  log_info "fail2ban: sshd jail loaded"

  if [ "${apache_skipped}" = "0" ]; then
    if ! fail2ban-client status apache-auth; then
      log_error "fail2ban: apache-auth jail failed to load"
      exit 1
    fi
    log_info "fail2ban: apache-auth jail loaded"
  fi

  fail2ban-client status
}

main "$@"
