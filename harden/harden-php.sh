#!/usr/bin/env bash
# harden/harden-php.sh — global php.ini hardening for cli + fpm SAPIs across
# every installed PHP version. Complementary to install/lib/php.sh's per-pool
# template (open_basedir, disable_functions, expose_php=off live there per-user).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

PHP_BASE_DIR="/etc/php"
HARDEN_FILENAME="52-litesoup-harden.ini"
# Set by main, read by write_if_changed; per-FPM-version reload tracking lives
# in CHANGED_FPM_VERSIONS (indexed array of version strings — avoids `declare
# -A` so the script also `bash -n` parses on macOS bash 3.2 dev hosts).
CHANGED=0
CHANGED_FPM_VERSIONS=()

usage() {
  cat <<'EOF'
litesoup harden-php — global php.ini hardening for cli + fpm

Usage: sudo bash harden-php.sh [options]

Options:
  --dry-run   Print actions without executing
  --help      Show this help

For each installed PHP version under /etc/php/X.Y/, writes a managed conf
snippet to BOTH:
  /etc/php/X.Y/cli/conf.d/52-litesoup-harden.ini
  /etc/php/X.Y/fpm/conf.d/52-litesoup-harden.ini

Settings: expose_php=Off, allow_url_fopen=Off, allow_url_include=Off,
display_errors=Off, display_startup_errors=Off, log_errors=On,
session.cookie_httponly=1, session.cookie_secure=1, session.use_strict_mode=1.

The `52-` prefix sorts after the package's `50-default-*.ini` so our values
win. We never edit /etc/php/<v>/{cli,fpm}/php.ini directly (apt may overwrite
it on package upgrades).

Idempotent: each conf file is only rewritten when content differs, and only
FPM services whose conf actually changed get a `systemctl reload` (which
preserves running requests, unlike restart).

If a version has cli installed but no fpm/ tree (rare, cli-only install), the
fpm file is silently skipped. If php<v>-fpm exists but isn't active, the
reload is skipped with a warning.
EOF
}

# Desired conf body. Heredoc with single-quoted EOF -> literal newlines, no
# variable expansion. Trailing newline is part of the canonical content so
# `cmp -s` doesn't churn between runs that round-trip through editors.
harden_ini_content() {
  cat <<'EOF'
; Managed by litesoup harden/harden-php.sh.
; Re-runs may overwrite. Edit conf.d/99-local-*.ini to override.
expose_php = Off
allow_url_fopen = Off
allow_url_include = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
EOF
}

# write_if_changed PATH CONTENT
# Writes CONTENT to PATH (mode 0644 root:root) only if it differs from the
# current file. Sets CHANGED=1 on write. Honors DRY_RUN.
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
    log_info "php-harden: ${path} already up to date"
    rm -f "${tmp}"
  else
    log_info "php-harden: writing ${path}"
    install -m 0644 -o root -g root "${tmp}" "${path}"
    rm -f "${tmp}"
    CHANGED=1
  fi
}

# discover_versions -- echo each installed PHP version (one per line, sorted).
# Any directory under /etc/php/ named like X.Y is treated as installed.
discover_versions() {
  local d ver
  [ -d "${PHP_BASE_DIR}" ] || return 0
  for d in "${PHP_BASE_DIR}"/*/; do
    [ -d "${d}" ] || continue
    ver="${d%/}"
    ver="${ver##*/}"
    # Only X.Y dirs (skip stray names like "mods-available" if upstream ever
    # decides to put one at the top level — currently they don't, but defense
    # in depth is cheap).
    case "${ver}" in
      [0-9].[0-9]|[0-9].[0-9][0-9]) printf '%s\n' "${ver}" ;;
    esac
  done | sort -V
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

  local content
  content="$(harden_ini_content)"
  # Ensure trailing newline (heredoc gives us one, but be explicit).
  content="${content%$'\n'}"$'\n'

  # 1. Discover installed PHP versions.
  local versions=()
  if [ -d "${PHP_BASE_DIR}" ]; then
    while IFS= read -r v; do
      [ -n "${v}" ] && versions+=("${v}")
    done < <(discover_versions)
  fi

  if [ "${#versions[@]}" -eq 0 ]; then
    log_warn "php-harden: no PHP versions found under ${PHP_BASE_DIR} — nothing to do"
    exit 0
  fi

  log_info "php-harden: found PHP versions: ${versions[*]}"

  # 2. Per-version: write cli + fpm files, track FPM changes for selective reload.
  local v cli_dir fpm_dir cli_path fpm_path
  for v in "${versions[@]}"; do
    cli_dir="${PHP_BASE_DIR}/${v}/cli/conf.d"
    fpm_dir="${PHP_BASE_DIR}/${v}/fpm/conf.d"
    cli_path="${cli_dir}/${HARDEN_FILENAME}"
    fpm_path="${fpm_dir}/${HARDEN_FILENAME}"

    # CLI side: skip if conf.d is missing (would mean php<v>-cli isn't
    # installed; unusual since we discovered <v> but be safe).
    if [ -d "${cli_dir}" ] || [ "${DRY_RUN}" = "1" ]; then
      CHANGED=0
      write_if_changed "${cli_path}" "${content}"
    else
      log_warn "php-harden: ${cli_dir} not found — skipping cli for ${v}"
    fi

    # FPM side: silently skip if fpm/conf.d/ is absent (cli-only install).
    if [ -d "${fpm_dir}" ]; then
      CHANGED=0
      write_if_changed "${fpm_path}" "${content}"
      if [ "${CHANGED:-0}" = "1" ]; then
        CHANGED_FPM_VERSIONS+=("${v}")
      fi
    elif [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would skip fpm for ${v} if ${fpm_dir} is absent on target"
      # In dry-run we still pretend the write would happen so operators see
      # the full intended action set; track as changed for the reload report.
      CHANGED=0
      write_if_changed "${fpm_path}" "${content}"
      if [ "${CHANGED:-0}" = "1" ]; then
        CHANGED_FPM_VERSIONS+=("${v}")
      fi
    else
      log_info "php-harden: ${fpm_dir} not present — php${v}-fpm not installed, skipping fpm conf"
    fi
  done

  # 3. Reload only the FPM services whose conf actually changed AND that are
  # currently active. Reload (not restart) preserves in-flight requests.
  if [ "${#CHANGED_FPM_VERSIONS[@]}" -eq 0 ]; then
    log_info "php-harden: no FPM conf changes — no reloads needed"
  else
    local svc
    for v in "${CHANGED_FPM_VERSIONS[@]}"; do
      svc="php${v}-fpm"
      if [ "${DRY_RUN}" = "1" ]; then
        log_info "[DRYRUN] would check + reload ${svc} (conf changed)"
        run_or_dryrun systemctl reload "${svc}"
        continue
      fi
      if systemctl is-active --quiet "${svc}"; then
        log_info "php-harden: reloading ${svc} (conf changed)"
        run_or_dryrun systemctl reload "${svc}"
      else
        log_warn "php-harden: ${svc} is not active — skipping reload (start it manually after install)"
      fi
    done
  fi

  # 4. Print active hardening per version (skipped in dry-run; the binaries
  # may not even be installed on the dev host).
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would print 'php<v> -i | grep ...' for each version"
    return 0
  fi

  local bin
  for v in "${versions[@]}"; do
    bin="/usr/bin/php${v}"
    if [ ! -x "${bin}" ]; then
      log_warn "php-harden: ${bin} not executable — skipping post-state report for ${v}"
      continue
    fi
    log_info "php-harden: active settings for php${v}:"
    # `|| true` so a grep miss (no matching lines) doesn't trip set -e.
    "${bin}" -i 2>/dev/null \
      | grep -E '^(expose_php|allow_url_fopen|allow_url_include|display_errors|log_errors)' \
      || log_warn "php-harden: no matching directives in php${v} -i output"
  done
}

main "$@"
