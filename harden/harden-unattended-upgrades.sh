#!/usr/bin/env bash
# harden/harden-unattended-upgrades.sh — enable security-only unattended-upgrades on Ubuntu 24.04.
# Idempotent: only writes managed apt.conf.d files when content differs.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

UU_OVERRIDE_FILE="/etc/apt/apt.conf.d/52litesoup-unattended"
UU_PERIODIC_FILE="/etc/apt/apt.conf.d/20auto-upgrades"

usage() {
  cat <<'EOF'
litesoup harden-unattended-upgrades — enable security-only auto-updates

Usage: sudo bash harden-unattended-upgrades.sh [options]

Options:
  --dry-run   Print actions without executing
  --help      Show this help

Installs unattended-upgrades + apt-listchanges, writes managed override
files at /etc/apt/apt.conf.d/52litesoup-unattended (allowed-origins,
no-reboot, blacklist-empty, remove-unused-deps) and
/etc/apt/apt.conf.d/20auto-upgrades (periodic timers), enables the
unattended-upgrades.service, and runs a dry-run smoke test.

Notes:
  - The managed override is numbered 52 so it lexically follows (and
    overrides) the package-default 50unattended-upgrades, which apt may
    overwrite on package upgrades.
  - To override these settings, create a higher-numbered file (e.g.
    /etc/apt/apt.conf.d/99local-unattended).
EOF
}

# Write ${1}=path with mode 0644 root:root only if content differs from ${2}=desired.
# Sets WROTE=1 when a write occurred. Honors DRY_RUN.
write_if_changed() {
  local path="$1" desired="$2"
  WROTE=0

  if [ "${DRY_RUN}" = "1" ]; then
    if [ -f "${path}" ] && printf '%s' "${desired}" | cmp -s - "${path}"; then
      log_info "[DRYRUN] ${path} already up to date"
    else
      log_info "[DRYRUN] would write ${path} (0644 root:root)"
      WROTE=1
    fi
    return 0
  fi

  if [ -f "${path}" ] && printf '%s' "${desired}" | cmp -s - "${path}"; then
    log_info "${path} already up to date"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s' "${desired}" > "${tmp}"
  install -m 0644 -o root -g root "${tmp}" "${path}"
  rm -f "${tmp}"
  log_info "wrote ${path}"
  WROTE=1
}

ensure_packages() {
  local missing=()
  local pkg
  for pkg in unattended-upgrades apt-listchanges; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("${pkg}")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log_info "packages already installed: unattended-upgrades apt-listchanges"
    return 0
  fi
  log_info "installing: ${missing[*]}"
  run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
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

  log_info "stage 1/5: packages"
  ensure_packages

  local override_desired periodic_desired
  override_desired="$(cat <<'EOF'
// Managed by litesoup harden/harden-unattended-upgrades.sh.
// Re-runs may overwrite. Edit a higher-numbered file to override.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF
)"

  periodic_desired="$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
)"

  local changed=0

  log_info "stage 2/5: override config (${UU_OVERRIDE_FILE})"
  write_if_changed "${UU_OVERRIDE_FILE}" "${override_desired}"
  [ "${WROTE}" = "1" ] && changed=1

  log_info "stage 3/5: periodic config (${UU_PERIODIC_FILE})"
  write_if_changed "${UU_PERIODIC_FILE}" "${periodic_desired}"
  [ "${WROTE}" = "1" ] && changed=1

  log_info "stage 4/5: enable + start unattended-upgrades.service"
  run_or_dryrun systemctl enable --now unattended-upgrades.service
  if [ "${changed}" = "1" ]; then
    run_or_dryrun systemctl restart unattended-upgrades.service
  fi

  log_info "stage 5/5: smoke test"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: unattended-upgrade --dry-run --debug | head -20"
    log_info "[DRYRUN] would print: systemctl is-enabled unattended-upgrades.service"
  else
    log_info "unattended-upgrade --dry-run --debug (first 20 lines):"
    unattended-upgrade --dry-run --debug 2>&1 | head -20 || true
    log_info "is-enabled: $(systemctl is-enabled unattended-upgrades.service 2>&1 || true)"
  fi

  log_info "litesoup harden-unattended-upgrades: COMPLETE"
}

main "$@"
