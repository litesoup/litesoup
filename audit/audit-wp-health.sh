#!/usr/bin/env bash
# audit/audit-wp-health.sh -- read-only WordPress site health audit.
# Probes WP core version, plugins, DB connection, disk, permissions, TLS
# expiry, and error log size. Modifies nothing; reports human-readable
# summary + exit code (0=healthy, 1=warnings, 2=critical/script error).
#
# Usage:
#   sudo bash audit-wp-health.sh                        # all sites under /home/*/webapps/
#   sudo bash audit-wp-health.sh --domain=example.com   # single site
#   sudo bash audit-wp-health.sh --user=alice           # owner of the site (default: auto-detect)
#   sudo bash audit-wp-health.sh --dry-run              # list discovered sites only, do not probe
#
# Notes:
#   * Requires root (uses sudo -H -u <SITE_USER> wp ... per site).
#   * Discovery glob: /home/<user>/webapps/<domain>/wp-config.php
#   * TLS expiry is checked against the live cert presented on :443 for the
#     domain; sites with no vhost or DNS pointing elsewhere get a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"

# --- Config / thresholds -----------------------------------------------------

WEBROOT_PARENT="/home"
WP_BIN="${WP_BIN:-wp}"

# Disk usage warn threshold (MB) for a single site directory.
DISK_WARN_MB="${DISK_WARN_MB:-5120}"     # 5 GiB
# Error log size warn threshold (MB).
ERRLOG_WARN_MB="${ERRLOG_WARN_MB:-50}"
# TLS expiry warn / critical thresholds (days).
TLS_WARN_DAYS="${TLS_WARN_DAYS:-30}"
TLS_CRIT_DAYS="${TLS_CRIT_DAYS:-7}"

# --- Args --------------------------------------------------------------------

DOMAIN=""
SITE_USER=""

usage() {
  cat <<'EOF'
litesoup audit-wp-health -- read-only WordPress site health audit

Usage: sudo bash audit-wp-health.sh [--domain=DOMAIN] [--user=NAME] [--dry-run]

  --domain=DOMAIN  Audit only this site (default: every site under /home/*/webapps/).
  --user=NAME      System user that owns the docroot (default: auto-detected from path).
                   Required when --domain is given AND multiple users own a site
                   with the same domain (rare; first match wins otherwise).
  --dry-run        List the sites that would be audited and exit; probe nothing.

Exit codes:
  0  all probed sites healthy
  1  one or more sites raised warnings (non-fatal: outdated plugin, big error log, etc.)
  2  one or more sites critical (DB unreachable, cert expired, wp-cli missing) OR
     script-level error (no sites found, bad arguments, no root).
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*) DOMAIN="${arg#*=}" ;;
      --user=*)   SITE_USER="${arg#*=}" ;;
      --dry-run)  DRY_RUN=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  if [ -n "${DOMAIN}" ] && ! [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid domain: ${DOMAIN}"; exit 64
  fi
  if [ -n "${SITE_USER}" ] && ! [[ "${SITE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "invalid user name: ${SITE_USER}"; exit 64
  fi
}

# --- Discovery ---------------------------------------------------------------

# Populate TARGETS as "<user>\t<domain>\t<docroot>" lines.
discover_sites() {
  local user_dir name path
  shopt -s nullglob
  TARGETS=()
  for user_dir in "${WEBROOT_PARENT}"/*/webapps/; do
    local owner
    owner="$(basename "$(dirname "${user_dir}")")"
    if [ -n "${SITE_USER}" ] && [ "${owner}" != "${SITE_USER}" ]; then
      continue
    fi
    for path in "${user_dir}"*/; do
      name="$(basename "${path}")"
      [ -n "${DOMAIN}" ] && [ "${name}" != "${DOMAIN}" ] && continue
      [ -f "${path}wp-config.php" ] || continue
      TARGETS+=("${owner}"$'\t'"${name}"$'\t'"${path%/}")
    done
  done
  shopt -u nullglob
}

# --- Per-check helpers -------------------------------------------------------

# Echo "OK" / "WARN: ..." / "CRIT: ..." -- caller decides aggregation.

_wp() {
  # Run wp-cli as the site owner. Args: <user> <docroot> <wp args...>
  local owner="$1" docroot="$2"
  shift 2
  sudo -H -u "${owner}" "${WP_BIN}" --path="${docroot}" --skip-plugins --skip-themes "$@" 2>/dev/null
}

check_wp_core() {
  local owner="$1" docroot="$2" cur latest
  cur="$(_wp "${owner}" "${docroot}" core version || true)"
  if [ -z "${cur}" ]; then
    echo "CRIT: wp core version failed (wp-cli or DB issue)"
    return
  fi
  # `wp core check-update` exits 0 with empty output when up-to-date, otherwise
  # prints a table. --field=version --format=csv gives just the available version.
  latest="$(_wp "${owner}" "${docroot}" core check-update --field=version --format=csv 2>/dev/null \
            | head -n1 || true)"
  if [ -n "${latest}" ]; then
    echo "WARN: wp ${cur} (update available: ${latest})"
  else
    echo "OK: wp ${cur} (current)"
  fi
}

check_plugins() {
  local owner="$1" docroot="$2" total outdated
  total="$(_wp "${owner}" "${docroot}" plugin list --format=count || true)"
  outdated="$(_wp "${owner}" "${docroot}" plugin list --update=available --format=count || true)"
  total="${total:-?}"
  outdated="${outdated:-0}"
  if [ "${outdated}" != "0" ] && [ "${outdated}" != "?" ]; then
    echo "WARN: plugins ${total} (${outdated} outdated)"
  else
    echo "OK: plugins ${total} (none outdated)"
  fi
}

check_db() {
  local owner="$1" docroot="$2" out size_mb
  if ! out="$(_wp "${owner}" "${docroot}" db check 2>&1)"; then
    echo "CRIT: db check failed (${out:0:80})"
    return
  fi
  # `wp db size --size_format=mb` prints a single number on stdout.
  size_mb="$(_wp "${owner}" "${docroot}" db size --size_format=mb 2>/dev/null \
             | tr -dc '0-9.' || true)"
  size_mb="${size_mb:-?}"
  echo "OK: db reachable (${size_mb} MB)"
}

check_disk() {
  local docroot="$1" used_kb used_mb
  used_kb="$(du -sk "${docroot}" 2>/dev/null | awk '{print $1}')"
  used_kb="${used_kb:-0}"
  used_mb=$(( used_kb / 1024 ))
  if [ "${used_mb}" -ge "${DISK_WARN_MB}" ]; then
    echo "WARN: disk ${used_mb} MB (threshold ${DISK_WARN_MB} MB)"
  else
    echo "OK: disk ${used_mb} MB"
  fi
}

check_perms() {
  local owner="$1" docroot="$2" wpconfig owner_actual mode
  wpconfig="${docroot}/wp-config.php"
  if [ ! -f "${wpconfig}" ]; then
    echo "CRIT: wp-config.php missing"
    return
  fi
  owner_actual="$(stat -c '%U' "${wpconfig}" 2>/dev/null || stat -f '%Su' "${wpconfig}" 2>/dev/null || echo "?")"
  mode="$(stat -c '%a' "${wpconfig}" 2>/dev/null || stat -f '%Lp' "${wpconfig}" 2>/dev/null || echo "?")"
  if [ "${owner_actual}" != "${owner}" ]; then
    echo "WARN: wp-config.php owner ${owner_actual} != site user ${owner}"
    return
  fi
  # Anything world-readable on wp-config.php is a warning -- contains DB creds.
  if [ "${mode}" != "?" ] && [ "$(( 8#${mode} & 0004 ))" -ne 0 ]; then
    echo "WARN: wp-config.php mode ${mode} is world-readable"
    return
  fi
  echo "OK: perms (owner=${owner_actual}, wp-config mode=${mode})"
}

check_tls() {
  local domain="$1" expiry epoch_now epoch_exp days_left
  if ! command -v openssl >/dev/null 2>&1; then
    echo "WARN: openssl not installed; skipping TLS check"
    return
  fi
  # 5s connect timeout; if no listener / wrong host, openssl returns non-zero.
  expiry="$(echo | timeout 5 openssl s_client -servername "${domain}" \
             -connect "${domain}:443" 2>/dev/null \
             | openssl x509 -noout -enddate 2>/dev/null \
             | sed -n 's/^notAfter=//p')"
  if [ -z "${expiry}" ]; then
    echo "WARN: no TLS cert reachable on ${domain}:443"
    return
  fi
  epoch_now="$(date -u +%s)"
  epoch_exp="$(date -u -d "${expiry}" +%s 2>/dev/null \
               || date -u -j -f "%b %e %T %Y %Z" "${expiry}" +%s 2>/dev/null \
               || echo "")"
  if [ -z "${epoch_exp}" ]; then
    echo "WARN: TLS cert expiry unparseable (${expiry})"
    return
  fi
  days_left=$(( (epoch_exp - epoch_now) / 86400 ))
  if [ "${days_left}" -le "${TLS_CRIT_DAYS}" ]; then
    echo "CRIT: TLS expires in ${days_left}d"
  elif [ "${days_left}" -le "${TLS_WARN_DAYS}" ]; then
    echo "WARN: TLS expires in ${days_left}d"
  else
    echo "OK: TLS valid (${days_left}d left)"
  fi
}

check_error_log() {
  local docroot="$1" log size_mb total=0 found=0
  # Common WP / Apache / nginx error log locations under the site dir.
  for log in \
    "${docroot}/error_log" \
    "${docroot}/wp-content/debug.log" \
    "${docroot}/logs/error.log" \
    "${docroot}/logs/php-error.log"
  do
    if [ -f "${log}" ]; then
      found=1
      size_mb=$(( $(stat -c '%s' "${log}" 2>/dev/null || stat -f '%z' "${log}" 2>/dev/null || echo 0) / 1024 / 1024 ))
      total=$(( total + size_mb ))
    fi
  done
  if [ "${found}" -eq 0 ]; then
    echo "OK: no error log present"
    return
  fi
  if [ "${total}" -ge "${ERRLOG_WARN_MB}" ]; then
    echo "WARN: error log ${total} MB (threshold ${ERRLOG_WARN_MB} MB)"
  else
    echo "OK: error log ${total} MB"
  fi
}

# --- Per-site driver ---------------------------------------------------------

# Echo a summary block for one site. Updates SITE_STATUS to the worst level
# seen ("OK" -> "WARN" -> "CRIT").
audit_one() {
  local owner="$1" domain="$2" docroot="$3"
  local line
  SITE_STATUS="OK"

  printf '\n--- %s (user=%s, docroot=%s) ---\n' "${domain}" "${owner}" "${docroot}"

  # Pre-flight: wp-cli must be on PATH for the site user.
  if ! sudo -H -u "${owner}" sh -c "command -v ${WP_BIN}" >/dev/null 2>&1; then
    printf '  CRIT: wp-cli (%s) not found for user %s\n' "${WP_BIN}" "${owner}"
    SITE_STATUS="CRIT"
    return
  fi

  for line in \
    "core:$(check_wp_core "${owner}" "${docroot}")" \
    "plugins:$(check_plugins "${owner}" "${docroot}")" \
    "db:$(check_db "${owner}" "${docroot}")" \
    "disk:$(check_disk "${docroot}")" \
    "perms:$(check_perms "${owner}" "${docroot}")" \
    "tls:$(check_tls "${domain}")" \
    "errlog:$(check_error_log "${docroot}")"
  do
    printf '  %s\n' "${line}"
    case "${line#*:}" in
      CRIT*) SITE_STATUS="CRIT" ;;
      WARN*) [ "${SITE_STATUS}" != "CRIT" ] && SITE_STATUS="WARN" ;;
    esac
  done

  printf '  -> %s\n' "${SITE_STATUS}"
}

# --- main --------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root

  log_info "audit-wp-health: scanning ${WEBROOT_PARENT}/*/webapps/"
  discover_sites

  if [ "${#TARGETS[@]}" -eq 0 ]; then
    if [ -n "${DOMAIN}" ]; then
      log_error "no WordPress site matching --domain=${DOMAIN} found"
    else
      log_error "no WordPress sites found under ${WEBROOT_PARENT}/*/webapps/"
    fi
    exit 2
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "audit-wp-health: dry-run, listing ${#TARGETS[@]} site(s):"
    local entry owner domain docroot
    for entry in "${TARGETS[@]}"; do
      IFS=$'\t' read -r owner domain docroot <<<"${entry}"
      printf '  %s\t%s\t%s\n' "${owner}" "${domain}" "${docroot}"
    done
    exit 0
  fi

  local entry owner domain docroot
  local n_ok=0 n_warn=0 n_crit=0
  for entry in "${TARGETS[@]}"; do
    IFS=$'\t' read -r owner domain docroot <<<"${entry}"
    audit_one "${owner}" "${domain}" "${docroot}"
    case "${SITE_STATUS}" in
      OK)   n_ok=$((  n_ok   + 1 )) ;;
      WARN) n_warn=$(( n_warn + 1 )) ;;
      CRIT) n_crit=$(( n_crit + 1 )) ;;
    esac
  done

  printf '\n=== summary: %d ok, %d warn, %d crit (of %d sites) ===\n' \
    "${n_ok}" "${n_warn}" "${n_crit}" "${#TARGETS[@]}"

  if [ "${n_crit}" -gt 0 ]; then exit 2; fi
  if [ "${n_warn}" -gt 0 ]; then exit 1; fi
  exit 0
}

main "$@"
