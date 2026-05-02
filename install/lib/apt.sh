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

  # Two failure modes we have to handle separately:
  #
  #   (1) add-apt-repository itself fails (Launchpad API down, IPv6 connect
  #       error, DNS, slow CI mirror). Fall through to the manual-registration
  #       path that imports the PPA key from a keyserver and writes a
  #       launchpad-style sources file.
  #
  #   (2) add-apt-repository succeeds (writes a deb822 sources file) but the
  #       URI it points at is unreachable from here -- e.g. the GitHub Actions
  #       runners and DO Singapore VPSes that can't reach
  #       ppa.launchpadcontent.net. apt-get update reports "Failed to fetch"
  #       for our URI, and the next apt-get install dies with "Unable to
  #       locate package php8.2-fpm" because the PPA package list never made
  #       it into the cache. _ppa_reachable_or_fallback handles this by
  #       probing apt-get update and, if our URI failed, swapping in a
  #       per-PPA mirror (currently only ondrej/php -> packages.sury.org).
  local err_log
  err_log="$(mktemp /tmp/litesoup-ppa-err.XXXXXX.log)"
  # shellcheck disable=SC2064
  trap "rm -f '${err_log}'" RETURN

  if run_or_dryrun add-apt-repository -y "${ppa}" 2>"${err_log}"; then
    if ! _ppa_reachable_or_fallback "${ppa}" "${probe}"; then
      log_error "apt: PPA ${ppa} added but unreachable, and no mirror fallback succeeded"
      return 1
    fi
  else
    log_warn "apt: add-apt-repository failed for ${ppa}, attempting manual registration"
    if ! _ensure_ppa_manual "${ppa}" "${probe}"; then
      log_error "apt: add-apt-repository failed and no manual fallback available"
      cat "${err_log}" >&2
      return 1
    fi
    _APT_UPDATED=0   # manual path didn't update; force refresh on next call
  fi
}

# After add-apt-repository succeeds, verify the new sources URI is actually
# reachable. apt-get update returns 0 even when individual sources fail to
# fetch (failures show up as "Err:" / "W:" lines on stderr), so we capture
# stderr and grep specifically for our URI to avoid false positives from
# unrelated sources errors. Returns 0 if either the primary URI is reachable
# OR the per-PPA mirror fallback succeeded.
_ppa_reachable_or_fallback() {
  local ppa="$1" probe="$2"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would probe ${probe} reachability"
    return 0
  fi

  local sources_uri
  sources_uri="$(awk '/^URIs:/ {print $2; exit}' "${probe}" 2>/dev/null || true)"
  if [ -z "${sources_uri}" ]; then
    log_warn "apt: ${probe} has no URIs: directive (stub or malformed); attempting fallback"
    _ppa_fallback "${ppa}" "${probe}"
    return $?
  fi

  local update_log
  update_log="$(mktemp /tmp/litesoup-aptupdate.XXXXXX.log)"
  # shellcheck disable=SC2064
  trap "rm -f '${update_log}'" RETURN

  env DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>"${update_log}" || true
  cat "${update_log}" >&2  # surface for ops visibility

  if grep -F -- "${sources_uri}" "${update_log}" \
       | grep -qE "(Failed to fetch|Could not connect|Connection timed out|Temporary failure resolving|503|504)"; then
    log_warn "apt: PPA ${ppa} unreachable at ${sources_uri}, attempting mirror fallback"
    _ppa_fallback "${ppa}" "${probe}"
    return $?
  fi

  _APT_UPDATED=1
  return 0
}

# Per-PPA mirror dispatcher. Currently only ondrej/php has a mirror fallback
# (packages.sury.org -- Ondrej's own CDN-fronted mirror serving the same
# packages as the launchpad PPA). Add new cases here as more PPAs need
# mirror coverage.
_ppa_fallback() {
  local ppa="$1" probe="$2"
  case "${ppa}" in
    ppa:ondrej/php) _ensure_repo_sury_php "${probe}" ;;
    *)
      log_error "apt: no mirror fallback configured for ${ppa}"
      return 1
      ;;
  esac
}

# Replace a launchpad-style ondrej/php sources file with the equivalent
# packages.sury.org entry. Same packages, same versions; sury.org is
# Ondrej's CDN-fronted mirror that reaches networks where
# ppa.launchpadcontent.net is blocked or rate-limited (CI runners, DO
# Singapore, etc.). Sury's signing key is distinct from the launchpad PPA
# key (fpr 15058500A0235D97F5D10063B188E2B695BD4743) and ships at the
# stable URL https://packages.sury.org/php/apt.gpg.
_ensure_repo_sury_php() {
  local probe="$1"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would swap ${probe} to packages.sury.org/php"
    return 0
  fi

  local keyring="/usr/share/keyrings/sury-php.gpg"
  local fpr="15058500A0235D97F5D10063B188E2B695BD4743"

  # Prefer the canonical key URL on packages.sury.org (Sury's documented
  # install path). Fall back to keyserver only if curl is unavailable or
  # sury.org is unreachable too.
  if command -v curl >/dev/null 2>&1 \
     && curl -fsSL --max-time 15 https://packages.sury.org/php/apt.gpg \
              -o "${keyring}" 2>/dev/null \
     && gpg --no-default-keyring --keyring "${keyring}" --list-keys "${fpr}" >/dev/null 2>&1; then
    log_info "apt: imported sury.org signing key from packages.sury.org"
  else
    log_warn "apt: direct sury.org key fetch failed, trying keyserver"
    if ! gpg --batch --no-tty --keyserver keyserver.ubuntu.com --recv-keys "${fpr}" 2>/dev/null; then
      gpg --batch --no-tty --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${fpr}" \
        || { log_error "apt: failed to import sury.org signing key ${fpr}"; return 1; }
    fi
    if ! gpg --list-keys "${fpr}" >/dev/null 2>&1; then
      log_error "apt: sury.org key import succeeded but key not found: ${fpr}"
      return 1
    fi
    gpg --export --armor "${fpr}" | gpg --dearmor -o "${keyring}"
  fi

  local codename
  codename="$( . /etc/os-release && echo "${VERSION_CODENAME:-noble}" )"
  cat > "${probe}" <<EOF
# Managed by litesoup install/lib/apt.sh -- sury.org fallback for ondrej/php.
# Same packages and versions, served from a CDN reachable when launchpad is not.
Types: deb
URIs: https://packages.sury.org/php/
Suites: ${codename}
Components: main
Signed-By: ${keyring}
EOF
  log_info "apt: swapped ${probe} to packages.sury.org/php (suite=${codename})"

  if ! run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    log_error "apt: apt-get update failed after swapping to sury.org"
    return 1
  fi
  _APT_UPDATED=1
  return 0
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
