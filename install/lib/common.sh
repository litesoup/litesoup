#!/usr/bin/env bash
# install/lib/common.sh — shared helpers. Source with `source`, do not execute.

# Idempotent guard: don't re-source.
[ -n "${LITESOUP_COMMON_SH:-}" ] && return 0
LITESOUP_COMMON_SH=1

set -Eeuo pipefail

: "${DRY_RUN:=0}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()  { printf '%s [INFO] %s\n'  "$(_ts)" "$*" >&2; }
log_warn()  { printf '%s [WARN] %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }

# Run a command unless DRY_RUN=1, in which case print the intended command.
run_or_dryrun() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '%s [DRYRUN] %s\n' "$(_ts)" "$*" >&2
    return 0
  fi
  "$@"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "must run as root (use sudo)"
    return 1
  fi
}

# Trap handler: print where we failed.
_on_err() {
  local rc=$? line=${1:-?}
  log_error "failed at line ${line} (exit ${rc})"
  exit "${rc}"
}
trap '_on_err ${LINENO}' ERR
