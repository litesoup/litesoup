#!/usr/bin/env bash
# install/lib/apt.sh — idempotent apt and PPA helpers.

[ -n "${LITESOUP_APT_SH:-}" ] && return 0
LITESOUP_APT_SH=1

_APT_UPDATED=0

apt_update_once() {
  if [ "${_APT_UPDATED}" = "1" ]; then return 0; fi
  run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  _APT_UPDATED=1
}

apt_install() {
  apt_update_once
  run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

is_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"
}

ensure_pkgs() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! is_pkg_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log_info "apt: all packages already installed (${*})"
    return 0
  fi
  log_info "apt: installing missing packages: ${missing[*]}"
  apt_install "${missing[@]}"
}

ensure_ppa() {
  local ppa="$1"   # e.g. ppa:ondrej/php
  local probe="$2" # e.g. /etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources
  if [ -e "${probe}" ]; then
    log_info "apt: PPA ${ppa} already added (${probe} exists)"
    return 0
  fi
  ensure_pkgs software-properties-common
  log_info "apt: adding PPA ${ppa}"
  run_or_dryrun add-apt-repository -y "${ppa}"
  _APT_UPDATED=0   # force re-update on next call
}
