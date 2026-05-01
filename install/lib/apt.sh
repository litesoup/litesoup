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
  ensure_pkgs software-properties-common gnupg
  log_info "apt: adding PPA ${ppa}"

  # Try add-apt-repository first; if Launchpad API is unreachable (504),
  # fall back to manual PPA registration with direct key import.
  local err_log
  err_log="$(mktemp /tmp/litesoup-ppa-err.XXXXXX.log)"
  # shellcheck disable=SC2064
  trap "rm -f '${err_log}'" RETURN
  if ! run_or_dryrun add-apt-repository -y "${ppa}" 2>"${err_log}"; then
    if grep -q '504\|Gateway Time-out\|timed out' "${err_log}" 2>/dev/null; then
      log_info "apt: Launchpad API unreachable, registering PPA manually"
      _ensure_ppa_manual "${ppa}" "${probe}"
    else
      log_error "apt: add-apt-repository failed for ${ppa}"
      cat "${err_log}" >&2
      return 1
    fi
  fi
  _APT_UPDATED=0   # force re-update on next call
}

# Manual PPA registration (fallback when Launchpad API is unreachable).
# Extracts owner/name from ppa:owner/name format, imports the signing key
# from keyserver, and writes a deb822 .sources file.
_ensure_ppa_manual() {
  local ppa="$1" probe="$2"
  # ppa:ondrej/php -> owner=ondrej, name=php
  local owner="${ppa#ppa:}"; owner="${owner%%/*}"
  local name="${ppa#*/}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would install GPG key for ${owner}/ppa"
    return 0
  fi

  local keyring="/usr/share/keyrings/${owner}-ppa.gpg"
  case "${owner}/${name}" in
    ondrej/php)
      local fpr="14AA40EC0831756756D7F66C4F4EA0AAE5267A6C"
      gpg --batch --no-tty --keyserver keyserver.ubuntu.com --recv-keys "${fpr}" 2>/dev/null || \
      gpg --batch --no-tty --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${fpr}"
      if ! gpg --list-keys "${fpr}" >/dev/null 2>&1; then
        log_error "apt: failed to import ondrej/php signing key ${fpr}"
        return 1
      fi
      gpg --export --armor "${fpr}" | gpg --dearmor -o "${keyring}"
      ;;
    *)
      log_error "apt: no manual key mapping for PPA ${ppa}"
      return 1
      ;;
  esac

  local repo_url="https://ppa.launchpadcontent.net/${owner}/${name}/ubuntu"
  local codename
  codename="$( . /etc/os-release && echo "${VERSION_CODENAME:-noble}" )"
  cat > "${probe}" <<EOF
Types: deb
URIs: ${repo_url}
Suites: ${codename}
Components: main
Signed-By: ${keyring}
EOF
  log_info "apt: manually registered PPA ${ppa} at ${probe}"
}
