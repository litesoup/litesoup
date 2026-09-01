#!/usr/bin/env bash
# install/lib/common.sh — shared helpers. Source with `source`, do not execute.
#
# IMPORTANT: sourcing this file enables `set -Eeuo pipefail` and installs an
# ERR trap that exits the calling shell on any uncaught error. Any script that
# sources this opts into fail-fast semantics intentionally.

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
    printf '%s [DRYRUN]' "$(_ts)" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "must run as root (use sudo)"
    exit 1
  fi
}

# --- SSH orphaned-sshd detection helpers -----------------------------------
# Guard against the "orphaned sshd holds the port while ssh.service is failed"
# failure (sg11 incident 2026-09-01): a stale sshd detached from systemd keeps
# the SSH port bound and resets every handshake, while `ss -tlnp | grep sshd`
# still matches it — so naive "is something listening?" checks pass falsely.

# ssh_service_mainpid [SVC] — echo the systemd MainPID of the ssh service ("" if none).
ssh_service_mainpid() {
  local svc="${1:-ssh}"
  systemctl show "${svc}.service" -p MainPID --value 2>/dev/null || true
}

# sshd_orphans_on_port PORT [SVC] — echo PIDs listening on PORT that are NOT the
# service MainPID (i.e. orphaned sshd). Empty output = no orphans.
sshd_orphans_on_port() {
  local port="$1" svc="${2:-ssh}" mainpid p
  mainpid="$(ssh_service_mainpid "${svc}")"
  for p in $(ss -tlnpH "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u); do
    if [ -z "${mainpid}" ] || [ "${p}" != "${mainpid}" ]; then
      printf '%s\n' "${p}"
    fi
  done
}

# assert_ssh_healthy PORT [SVC] — 0 if the service is active AND every listener on
# PORT is the service MainPID (no orphans). Non-zero otherwise. Safe in `if`.
assert_ssh_healthy() {
  local port="$1" svc="${2:-ssh}" mainpid
  if ! systemctl is-active --quiet "${svc}.service"; then
    log_warn "ssh-guard: ${svc}.service is NOT active"
    return 1
  fi
  mainpid="$(ssh_service_mainpid "${svc}")"
  if [ -z "${mainpid}" ]; then
    log_warn "ssh-guard: ${svc}.service has no MainPID"
    return 1
  fi
  if ! ss -tlnpH "sport = :${port}" 2>/dev/null | grep -q "pid=${mainpid}"; then
    log_warn "ssh-guard: port ${port} is NOT owned by ${svc}.service MainPID ${mainpid}"
    return 1
  fi
  local orphans
  orphans="$(sshd_orphans_on_port "${port}" "${svc}")"
  if [ -n "${orphans}" ]; then
    log_warn "ssh-guard: orphaned sshd on port ${port}: ${orphans//$'\n'/ }"
    return 1
  fi
  return 0
}

# kill_orphans_on_port PORT [SVC] — SIGTERM then SIGKILL any sshd on PORT that is
# not the service MainPID. Best-effort; never touches the healthy MainPID.
kill_orphans_on_port() {
  local port="$1" svc="${2:-ssh}" mainpid p
  mainpid="$(ssh_service_mainpid "${svc}")"
  for p in $(sshd_orphans_on_port "${port}" "${svc}"); do
    log_warn "ssh-guard: killing orphaned sshd PID ${p} on port ${port}"
    kill "${p}" 2>/dev/null || true
    sleep 1
    if kill -0 "${p}" 2>/dev/null; then
      kill -9 "${p}" 2>/dev/null || true
      sleep 1
    fi
  done
}

# Trap handler: print where we failed.
_on_err() {
  local rc=$? line=${1:-?}
  log_error "failed at line ${line} (exit ${rc})"
  exit "${rc}"
}
trap '_on_err ${LINENO}' ERR
