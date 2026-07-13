#!/usr/bin/env bash
# harden/harden-apache.sh — write managed Apache 2.4 hardening conf snippets.
# Usage: sudo bash harden-apache.sh [--dry-run] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

CONF_AVAIL_DIR="/etc/apache2/conf-available"
HARDEN_CONF="${CONF_AVAIL_DIR}/52-litesoup-harden.conf"
STATUS_CONF="${CONF_AVAIL_DIR}/52-litesoup-mod-status.conf"

# Set-u crash defense: write_if_changed bumps this; main() reads it.
CHANGED=0

usage() {
  cat <<'EOF'
litesoup harden-apache — write managed Apache 2.4 hardening snippets

Usage: sudo bash harden-apache.sh [options]

Options:
  --dry-run   Print actions without executing
  --help      Show this help

Writes two managed conf snippets to /etc/apache2/conf-available/ and
enables them with a2enconf:

  52-litesoup-harden.conf       — ServerTokens Prod, ServerSignature Off,
                                  TraceEnable Off, plus security headers
                                  (X-Content-Type-Options, X-Frame-Options,
                                  Referrer-Policy) wrapped in
                                  <IfModule mod_headers.c>.

  52-litesoup-mod-status.conf   — restricts /server-status to localhost
                                  via Require local (only takes effect if
                                  mod_status is loaded).

Also disables mod_info if currently enabled. Validates the resulting
config with `apache2ctl configtest` before reloading. Reload only fires
if at least one managed file changed (or mod_info was just disabled) AND
configtest passes.

This script never edits /etc/apache2/apache2.conf (apt-managed). Override
any directive by adding a conf-available/99-local-*.conf and
`a2enconf 99-local-*` — Apache loads conf-enabled snippets in lexical
order so 99- beats 52-.
EOF
}

# write_if_changed PATH CONTENT
# Writes CONTENT to PATH (mode 0644 root:root) only if it differs from the
# current file. Bumps the global CHANGED flag to 1 on write. Honors DRY_RUN.
write_if_changed() {
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
    log_info "apache-harden: ${path} already up to date"
    rm -f "${tmp}"
  else
    log_info "apache-harden: writing ${path}"
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

  # apache2 must be installed for any of this to make sense.
  if ! command -v apache2ctl >/dev/null 2>&1; then
    log_error "apache-harden: apache2ctl not found — install apache2 first (run install-stack.sh)"
    exit 1
  fi

  if [ "${DRY_RUN}" != "1" ] && [ ! -d "${CONF_AVAIL_DIR}" ]; then
    log_error "apache-harden: ${CONF_AVAIL_DIR} missing — is apache2 installed?"
    exit 1
  fi

  # 1. Managed conf: hide version banner + security headers.
  local harden_content
  harden_content="$(cat <<'EOF'
# Managed by litesoup harden/harden-apache.sh.
# Re-runs may overwrite. Edit conf-available/99-local-* to override.

ServerName 127.0.0.1
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# Security headers (require mod_headers — enabled by install/lib/apache.sh)
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
EOF
)"
  write_if_changed "${HARDEN_CONF}" "${harden_content}"$'\n'

  # 2. Managed conf: lock down mod_status to localhost.
  local status_content
  status_content="$(cat <<'EOF'
# Managed by litesoup harden/harden-apache.sh.
# If mod_status is enabled, restrict /server-status to localhost.
<IfModule mod_status.c>
    <Location "/server-status">
        Require local
    </Location>
</IfModule>
EOF
)"
  write_if_changed "${STATUS_CONF}" "${status_content}"$'\n'

  # 3. Enable both conf snippets (a2enconf is idempotent — symlinks).
  run_or_dryrun a2enconf 52-litesoup-harden 52-litesoup-mod-status

  # 4. Disable mod_info if currently loaded. a2dismod returns non-zero when
  #    the module isn't enabled — || true keeps `set -e` happy. Detect first
  #    so we only mark CHANGED when something actually happened.
  if [ "${DRY_RUN}" = "1" ]; then
    if apache2ctl -M 2>/dev/null | grep -q '\binfo_module\b'; then
      log_info "[DRYRUN] would run: a2dismod info"
      CHANGED=1
    else
      log_info "[DRYRUN] mod_info already disabled"
    fi
  else
    if apache2ctl -M 2>/dev/null | grep -q '\binfo_module\b'; then
      log_info "apache-harden: disabling mod_info"
      a2dismod info || true
      CHANGED=1
    else
      log_info "apache-harden: mod_info already disabled"
    fi
  fi

  # 5. Validate the full config BEFORE reload — apache would refuse to
  #    reload anyway, but an explicit check gives a clearer error message
  #    and stops us from claiming success when the syntax is broken.
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: apache2ctl configtest"
  else
    if ! apache2ctl configtest 2>&1; then
      log_error "apache-harden: apache2ctl configtest FAILED — refusing to reload"
      log_error "apache-harden: review ${HARDEN_CONF} and ${STATUS_CONF}"
      exit 1
    fi
    log_info "apache-harden: configtest ok"
  fi

  # 6. Reload only if something changed (and configtest passed).
  if [ "${CHANGED}" = "1" ]; then
    # reload (not restart) keeps existing connections alive.
    run_or_dryrun systemctl reload apache2
  else
    log_info "apache-harden: no changes — skipping reload"
  fi

  # 7. Show active hardening state for the operator.
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would print module state: apache2ctl -M | grep headers/status/info"
    return 0
  fi

  log_info "apache-harden: module state (headers/status/info):"
  apache2ctl -M 2>/dev/null | grep -E '(headers|status|info)_module' || \
    log_info "apache-harden: (none of headers/status/info loaded)"
}

main "$@"
