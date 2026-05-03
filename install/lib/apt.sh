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

# ensure_pkgs_optional PKG [PKG …] -- best-effort install. Packages not
# resolvable in any configured repo are logged as warnings and skipped
# (instead of failing the whole apt-get install). Use for extensions that
# are nice-to-have but not required for the stack to function -- e.g.
# php8.X-imagick / php8.X-redis when we're running off the CloudPanel
# mirror, which doesn't carry PECL extensions. apt_update_once is invoked
# so the apt-cache lookup sees fresh metadata.
ensure_pkgs_optional() {
  apt_update_once
  local -a available=() missing=()
  local pkg
  for pkg in "$@"; do
    if is_pkg_installed "${pkg}"; then continue; fi
    # `apt-cache show` returns 0 even for packages that are only referenced
    # as a dep name in another package's metadata (no actual installable
    # version). `apt-cache policy` returns "Candidate: (none)" in that case
    # AND for genuinely-missing packages -- so absence of "Candidate: (none)"
    # is the reliable installable check.
    if apt-cache policy "${pkg}" 2>/dev/null | grep -q 'Candidate: (none)'; then
      missing+=("${pkg}")
    elif apt-cache policy "${pkg}" 2>/dev/null | grep -qE '^[[:space:]]+Candidate:'; then
      available+=("${pkg}")
    else
      missing+=("${pkg}")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_warn "apt: optional packages not available in configured repos, skipping: ${missing[*]}"
  fi
  if [ "${#available[@]}" -gt 0 ]; then
    log_info "apt: installing optional packages: ${available[*]}"
    apt_install "${available[@]}"
  fi
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
    : # add-apt-repository wrote the launchpad-style .sources file at ${probe}
  else
    log_warn "apt: add-apt-repository failed for ${ppa}, attempting manual registration"
    if ! _ensure_ppa_manual "${ppa}" "${probe}"; then
      log_error "apt: add-apt-repository failed and no manual fallback available"
      cat "${err_log}" >&2
      return 1
    fi
  fi

  # Either branch above wrote a launchpad-style .sources file at ${probe}.
  # Verify the URI is actually reachable from here, and dispatch to a per-PPA
  # mirror (currently CloudPanel for ondrej/php) if not. This catches both:
  #   - networks where add-apt-repository succeeds but launchpadcontent.net
  #     is then unreachable (the original bug), AND
  #   - networks where add-apt-repository fails outright (CI here -- a
  #     network flake fetching launchpad metadata) and our manual fallback
  #     wrote a launchpad URL we still can't reach.
  if ! _ppa_reachable_or_fallback "${ppa}" "${probe}"; then
    log_error "apt: PPA ${ppa} added but unreachable, and no mirror fallback succeeded"
    return 1
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
# (packages.cloudpanel.io -- CloudPanel CE's CloudFront-backed mirror serving
# repackaged Sury PHP debs for Ubuntu noble/jammy + Debian). Add new cases
# here as more PPAs need mirror coverage.
#
# NOTE on sury.org: an earlier iteration of this fallback targeted
# packages.sury.org/php. That mirror only publishes Debian suites
# (bookworm, bullseye, trixie, resolute) -- it does NOT serve Ubuntu suites,
# verified by HEAD on /dists/noble/InRelease (Varnish returns 418). Do not
# resurrect sury.org as the Ubuntu fallback.
_ppa_fallback() {
  local ppa="$1" probe="$2"
  case "${ppa}" in
    ppa:ondrej/php) _ensure_repo_cloudpanel_php "${probe}" ;;
    *)
      log_error "apt: no mirror fallback configured for ${ppa}"
      return 1
      ;;
  esac
}

# Replace a launchpad-style ondrej/php sources file with the equivalent
# packages.cloudpanel.io entry. CloudPanel CE operates a CloudFront-backed
# apt mirror that repackages Sury's PHP builds for Ubuntu noble/jammy and
# Debian bookworm/bullseye/trixie. Packages are byte-equivalent to upstream
# Ondrej except for a +clp version suffix; service names, paths, and
# extension lists are identical, so php.sh / install-stack.sh need no
# changes.
#
# Tradeoffs (this is a temporary measure -- see issue #14):
#   + reachable from networks where ppa.launchpadcontent.net is blocked
#     (CI runners, DO Singapore, etc.)
#   + same package names, same install flow downstream
#   - third-party dependency we don't control; CloudPanel could change
#     URLs, key, or yank the mirror at any time. Pin the expected GPG
#     fingerprint so silent key rotation fails loudly.
#   - long-term posture is to self-host an aptly mirror of ppa:ondrej/php
#     and remove this fallback entirely.
_ensure_repo_cloudpanel_php() {
  local probe="$1"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would swap ${probe} to packages.cloudpanel.io"
    return 0
  fi

  # CloudPanel ships separate amd64 and arm64 CloudFront origins (signed by
  # the same key, identical package contents per arch).
  local arch origin
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  case "${arch}" in
    amd64) origin="d17k9fuiwb52nc.cloudfront.net" ;;
    arm64) origin="d2xpdm4jldf31f.cloudfront.net" ;;
    *)
      log_error "apt: cloudpanel mirror has no origin for arch '${arch}' (only amd64/arm64 supported)"
      return 1
      ;;
  esac

  local keyring="/usr/share/keyrings/cloudpanel-php.gpg"
  local fpr="4FFD41A7CB8F2CEA5F75E6CC1FD0B9CFEFC59AC9"
  local key_url="https://${origin}/key.gpg"
  local key_tmp
  key_tmp="$(mktemp /tmp/litesoup-clp-key.XXXXXX.asc)"
  # shellcheck disable=SC2064
  trap "rm -f '${key_tmp}'" RETURN

  if ! command -v curl >/dev/null 2>&1; then
    ensure_pkgs curl
  fi

  if ! curl -fsSL --max-time 30 "${key_url}" -o "${key_tmp}"; then
    log_error "apt: failed to fetch CloudPanel key from ${key_url}"
    return 1
  fi

  # Pin the fingerprint -- if CloudPanel rotates their key without warning,
  # we want to fail loudly instead of silently trusting a new signer.
  local got_fpr
  got_fpr="$(gpg --no-default-keyring --keyring /tmp/litesoup-clp-keyring.kbx \
                  --with-colons --import-options show-only --import "${key_tmp}" 2>/dev/null \
              | awk -F: '/^fpr:/ {print $10; exit}')"
  rm -f /tmp/litesoup-clp-keyring.kbx /tmp/litesoup-clp-keyring.kbx~ 2>/dev/null || true
  if [ "${got_fpr}" != "${fpr}" ]; then
    log_error "apt: CloudPanel key fingerprint mismatch (got '${got_fpr}', want '${fpr}')"
    log_error "apt: this may indicate a key rotation -- audit before extending trust"
    return 1
  fi

  gpg --dearmor < "${key_tmp}" > "${keyring}"
  chmod 0644 "${keyring}"

  local codename
  codename="$( . /etc/os-release && echo "${VERSION_CODENAME:-noble}" )"
  # CloudPanel publishes one component per PHP version. List all of the
  # versions we support (SUPPORTED_PHP_VERSIONS in php.sh) so any
  # subsequent --php-versions= choice resolves.
  cat > "${probe}" <<EOF
# Managed by litesoup install/lib/apt.sh -- cloudpanel.io mirror for ondrej/php.
# Same packages and versions as ppa:ondrej/php, served from a CloudFront CDN
# that's reachable when ppa.launchpadcontent.net is not. See issue #14.
Types: deb
URIs: https://${origin}/
Suites: ${codename}
Components: main php-8.0 php-8.1 php-8.2 php-8.3 php-8.4 php-8.5
Signed-By: ${keyring}
EOF
  log_info "apt: swapped ${probe} to ${origin} (suite=${codename}, arch=${arch})"

  if ! run_or_dryrun env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    log_error "apt: apt-get update failed after swapping to cloudpanel.io"
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
