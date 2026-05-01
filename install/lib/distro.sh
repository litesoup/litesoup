#!/usr/bin/env bash
# install/lib/distro.sh — distro detection.

[ -n "${LITESOUP_DISTRO_SH:-}" ] && return 0
LITESOUP_DISTRO_SH=1

: "${OS_RELEASE_PATH:=/etc/os-release}"

require_ubuntu_2404() {
  if [ ! -r "${OS_RELEASE_PATH}" ]; then
    log_error "${OS_RELEASE_PATH} not readable; cannot identify distro"
    return 1
  fi
  # shellcheck disable=SC1090
  ( . "${OS_RELEASE_PATH}"
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
      log_error "litesoup requires Ubuntu 24.04 (found ID=${ID:-?} VERSION_ID=${VERSION_ID:-?})"
      exit 1
    fi
  )
}
