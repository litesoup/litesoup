#!/usr/bin/env bash
# audit/audit-wp-vulnerabilities.sh -- audit WordPress sites for known CVEs.
#
# For each WordPress site found under /home/<user>/webapps/<domain>/, enumerate
# installed plugins / themes (and optionally core) via wp-cli, then cross-
# reference each component against the free WPVulnerability.net API. Reports
# matched vulnerabilities with CVE id, CVSS score, and severity.
#
# This is a READ-ONLY audit -- it never mutates a site. --dry-run still runs the
# script end-to-end but skips outbound API calls (logs "[DRYRUN] would query
# API" instead) so it is safe to invoke from CI / cron without external network.
#
# Data source
#   The WPVulnerability.net public API (https://www.wpvulnerability.net) is
#   used. It is anonymous, rate-limited per source IP, and requires no API key.
#
#   No WPSCAN_API_TOKEN is read or required. If you want to switch to the
#   WPScan / wpvulndb.com API in the future, follow the litesoup secret-file
#   pattern: store it in /etc/litesoup/wpscan.env (mode 0640 root:root) the
#   same way /etc/litesoup/redis.env holds REDIS_PASSWORD, and source it from
#   this script as root before dropping privileges.
#
# Usage:
#   sudo bash audit/audit-wp-vulnerabilities.sh                      # all sites
#   sudo bash audit/audit-wp-vulnerabilities.sh --domain=example.com
#   sudo bash audit/audit-wp-vulnerabilities.sh --domain=example.com --user=alice
#   sudo bash audit/audit-wp-vulnerabilities.sh --format=json
#   sudo bash audit/audit-wp-vulnerabilities.sh --dry-run
#
# Options:
#   --domain=DOMAIN   Audit only this site (default: every WP site under
#                     /home/*/webapps/<domain>/)
#   --user=NAME       System user that owns the site (default: derived from
#                     /home/<user>/webapps/<domain>/ path)
#   --format=text|json  Output format (default: text)
#   --plugins-only    Only check plugins
#   --themes-only     Only check themes
#   --include-core    Also check WordPress core version
#   --dry-run         Skip outbound API calls (still enumerates components)
#   --help, -h        Print this help and exit
#
# Exit codes:
#   0  no vulnerabilities found across audited sites
#   1  one or more vulnerabilities found
#   64 invalid arguments
#   65 no WordPress sites found / site not a WordPress install

# shellcheck source-path=SCRIPTDIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------

DOMAIN=""
SITE_USER=""
FORMAT="text"
CHECK_PLUGINS=1
CHECK_THEMES=1
CHECK_CORE=0

API_BASE="https://www.wpvulnerability.net"

# Aggregated state across all audited sites.
TOTAL_VULNS=0
CRITICAL_VULNS=0
HIGH_VULNS=0
# Each entry: site|type|slug|version|name|cve|cvss|severity|unfixed
VULN_ENTRIES=()
# Each entry is a JSON object string.
JSON_ENTRIES=()

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)     DOMAIN="${arg#*=}" ;;
      --user=*)       SITE_USER="${arg#*=}" ;;
      --format=*)     FORMAT="${arg#*=}" ;;
      --plugins-only) CHECK_THEMES=0 ;;
      --themes-only)  CHECK_PLUGINS=0 ;;
      --include-core) CHECK_CORE=1 ;;
      --dry-run)      DRY_RUN=1 ;;
      --help|-h)      usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage >&2; exit 64 ;;
    esac
  done
  export DRY_RUN

  case "${FORMAT}" in
    text|json) ;;
    *) log_error "--format must be one of: text, json (got '${FORMAT}')"; exit 64 ;;
  esac
  if [ -n "${DOMAIN}" ] && ! [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid domain: ${DOMAIN}"; exit 64
  fi
  if [ -n "${SITE_USER}" ] && ! [[ "${SITE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "invalid user name: ${SITE_USER}"; exit 64
  fi
}

# ---------------------------------------------------------------------------
# Site discovery
# ---------------------------------------------------------------------------

# Echoes one "user|domain|docroot" tuple per discovered WordPress site.
discover_sites() {
  local user_dir user webapp domain docroot
  shopt -s nullglob
  for user_dir in /home/*/; do
    user="$(basename "${user_dir}")"
    [ -d "${user_dir}webapps" ] || continue
    if [ -n "${SITE_USER}" ] && [ "${user}" != "${SITE_USER}" ]; then
      continue
    fi
    for webapp in "${user_dir}webapps/"*/; do
      domain="$(basename "${webapp}")"
      if [ -n "${DOMAIN}" ] && [ "${domain}" != "${DOMAIN}" ]; then
        continue
      fi
      docroot="${webapp%/}"
      [ -f "${docroot}/wp-config.php" ] || continue
      printf '%s|%s|%s\n' "${user}" "${domain}" "${docroot}"
    done
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Version-comparison helpers (preserved from source)
# ---------------------------------------------------------------------------

# Echoes 0 if a<b, 1 if a==b, 2 if a>b.
version_compare() {
  local a="$1" b="$2"
  if [ "${a}" = "${b}" ]; then echo 1; return; fi

  local IFS='.'
  local va vb max i na nb
  read -ra va <<< "${a}"
  read -ra vb <<< "${b}"
  max=${#va[@]}
  [ ${#vb[@]} -gt "${max}" ] && max=${#vb[@]}
  for ((i=0; i<max; i++)); do
    na="${va[i]:-0}"
    nb="${vb[i]:-0}"
    na="${na%%[!0-9]*}"; na="${na:-0}"
    nb="${nb%%[!0-9]*}"; nb="${nb:-0}"
    if [ "${na}" -lt "${nb}" ] 2>/dev/null; then echo 0; return; fi
    if [ "${na}" -gt "${nb}" ] 2>/dev/null; then echo 2; return; fi
  done
  echo 1
}

# is_affected installed_version max_version max_operator unfixed
is_affected() {
  local installed="$1" max_ver="$2" max_op="$3" unfixed="$4"
  if [ "${unfixed}" = "1" ]; then echo 1; return; fi
  [ -z "${max_ver}" ] && { echo 0; return; }
  local cmp
  cmp="$(version_compare "${installed}" "${max_ver}")"
  case "${max_op}" in
    lt) [ "${cmp}" -eq 0 ] && echo 1 || echo 0 ;;
    le) [ "${cmp}" -le 1 ] && echo 1 || echo 0 ;;
    *)  echo 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Vulnerability lookup
# ---------------------------------------------------------------------------

# check_component plugin|theme|core slug version
# Echoes one "uuid|name|max_ver|max_op|unfixed|cve|cvss|severity" line per vuln.
# Honours DRY_RUN: emits a [DRYRUN] log to stderr and returns no rows.
check_component() {
  local comp_type="$1" slug="$2" version="$3" endpoint
  case "${comp_type}" in
    plugin) endpoint="${API_BASE}/plugin/${slug}/" ;;
    theme)  endpoint="${API_BASE}/theme/${slug}/" ;;
    core)   endpoint="${API_BASE}/core/${version}/" ;;
    *)      log_error "check_component: unknown type '${comp_type}'"; return ;;
  esac

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would query API ${endpoint}"
    return 0
  fi

  local response
  response="$(curl -fsSL --connect-timeout 5 --max-time 10 "${endpoint}" 2>/dev/null || true)"
  [ -z "${response}" ] && return 0

  command -v python3 >/dev/null 2>&1 || {
    log_warn "audit: python3 not available -- cannot parse API response for ${comp_type} ${slug}"
    return 0
  }

  AUDIT_API_RESPONSE="${response}" python3 <<'PY'
import json, os
try:
    data = json.loads(os.environ.get('AUDIT_API_RESPONSE', ''))
except Exception:
    raise SystemExit(0)
inner = data.get('data') or {}
vulns = inner.get('vulnerability') or []
for v in vulns:
    op = v.get('operator') or {}
    max_ver = op.get('max_version') or ''
    max_op = op.get('max_operator') or ''
    unfixed = op.get('unfixed') or '0'
    cve = ''
    for s in (v.get('source') or []):
        sid = s.get('id', '')
        if sid.startswith('CVE-'):
            cve = sid
            break
    cvss = ''
    severity = ''
    impact = v.get('impact') or {}
    for key in ('cvss3', 'cvss'):
        score_obj = impact.get(key)
        if score_obj and score_obj.get('score'):
            cvss = score_obj['score']
            severity = score_obj.get('severity', '') or ''
            break
    print('|'.join([
        v.get('uuid', '') or '',
        v.get('name', '') or '',
        max_ver,
        max_op,
        str(unfixed),
        cve,
        str(cvss),
        severity,
    ]))
PY
}

# ---------------------------------------------------------------------------
# Per-component recording
# ---------------------------------------------------------------------------

# record_vuln site type slug version vuln_line
record_vuln() {
  local site="$1" comp_type="$2" slug="$3" version="$4" line="$5"
  local uuid name max_ver max_op unfixed cve cvss severity affected sev_upper
  IFS='|' read -r uuid name max_ver max_op unfixed cve cvss severity <<< "${line}"
  [ -z "${uuid}" ] && return 0

  affected="$(is_affected "${version}" "${max_ver}" "${max_op}" "${unfixed}")"
  [ "${affected}" = "1" ] || return 0

  TOTAL_VULNS=$((TOTAL_VULNS + 1))
  sev_upper="$(printf '%s' "${severity}" | tr '[:lower:]' '[:upper:]')"
  case "${sev_upper}" in
    CRITICAL) CRITICAL_VULNS=$((CRITICAL_VULNS + 1)) ;;
    HIGH)     HIGH_VULNS=$((HIGH_VULNS + 1)) ;;
  esac
  VULN_ENTRIES+=("${site}|${comp_type}|${slug}|${version}|${name}|${cve}|${cvss}|${severity}|${unfixed}")

  local unfixed_json
  if [ "${unfixed}" = "1" ]; then unfixed_json="true"; else unfixed_json="false"; fi
  # JSON-escape the human-readable name (only quote and backslash are realistic
  # hazards in WPVulnerability payloads; everything else is ASCII-printable).
  local name_esc
  name_esc="${name//\\/\\\\}"
  name_esc="${name_esc//\"/\\\"}"
  JSON_ENTRIES+=("{\"site\":\"${site}\",\"type\":\"${comp_type}\",\"slug\":\"${slug}\",\"version\":\"${version}\",\"vuln\":\"${name_esc}\",\"cve\":\"${cve}\",\"cvss\":\"${cvss}\",\"severity\":\"${severity}\",\"unfixed\":${unfixed_json}}")
}

# ---------------------------------------------------------------------------
# Site audit
# ---------------------------------------------------------------------------

# wp_as_user user docroot ...args
wp_as_user() {
  local user="$1" docroot="$2"
  shift 2
  if [ "$(id -un)" = "${user}" ]; then
    wp --path="${docroot}" "$@"
  else
    sudo -H -u "${user}" wp --path="${docroot}" "$@"
  fi
}

# audit_site user domain docroot
audit_site() {
  local user="$1" domain="$2" docroot="$3"
  local site="${domain}"

  [ "${FORMAT}" = "text" ] && log_info "audit: ${site} (user=${user}, docroot=${docroot})"

  if [ "${CHECK_CORE}" = "1" ]; then
    local wp_ver
    wp_ver="$(grep -oE "\\\$wp_version[[:space:]]*=[[:space:]]*'[^']+'" \
                "${docroot}/wp-includes/version.php" 2>/dev/null \
                | head -1 | sed -E "s/.*'([^']+)'/\1/")" || true
    if [ -n "${wp_ver}" ]; then
      [ "${FORMAT}" = "text" ] && log_info "audit: ${site}: checking core ${wp_ver}"
      while IFS= read -r line; do
        [ -z "${line}" ] && continue
        record_vuln "${site}" "core" "wordpress" "${wp_ver}" "${line}"
      done < <(check_component "core" "" "${wp_ver}")
    fi
  fi

  if [ "${CHECK_PLUGINS}" = "1" ]; then
    local plugin_json plugin_list
    plugin_json="$(wp_as_user "${user}" "${docroot}" plugin list \
                     --fields=name,version,status --format=json 2>/dev/null || echo '[]')"
    plugin_list="$(printf '%s' "${plugin_json}" | python3 -c '
import json, sys
try:
    for p in json.loads(sys.stdin.read()):
        print(f"{p.get(\"name\",\"\")}|{p.get(\"version\",\"\")}|{p.get(\"status\",\"\")}")
except Exception:
    pass
' 2>/dev/null || true)"

    while IFS='|' read -r slug version _status; do
      [ -z "${slug}" ] && continue
      [ -z "${version}" ] && continue
      while IFS= read -r line; do
        [ -z "${line}" ] && continue
        record_vuln "${site}" "plugin" "${slug}" "${version}" "${line}"
      done < <(check_component "plugin" "${slug}" "${version}")
    done <<< "${plugin_list}"
  fi

  if [ "${CHECK_THEMES}" = "1" ]; then
    local theme_json theme_list
    theme_json="$(wp_as_user "${user}" "${docroot}" theme list \
                    --fields=name,version,status --format=json 2>/dev/null || echo '[]')"
    theme_list="$(printf '%s' "${theme_json}" | python3 -c '
import json, sys
try:
    for t in json.loads(sys.stdin.read()):
        print(f"{t.get(\"name\",\"\")}|{t.get(\"version\",\"\")}|{t.get(\"status\",\"\")}")
except Exception:
    pass
' 2>/dev/null || true)"

    while IFS='|' read -r slug version _status; do
      [ -z "${slug}" ] && continue
      [ -z "${version}" ] && continue
      while IFS= read -r line; do
        [ -z "${line}" ] && continue
        record_vuln "${site}" "theme" "${slug}" "${version}" "${line}"
      done < <(check_component "theme" "${slug}" "${version}")
    done <<< "${theme_list}"
  fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_text_report() {
  printf '\n'
  if [ "${TOTAL_VULNS}" -eq 0 ]; then
    log_info "audit: no known vulnerabilities found"
    return 0
  fi
  log_warn "audit: found ${TOTAL_VULNS} vulnerabilit$([ "${TOTAL_VULNS}" -eq 1 ] && echo y || echo ies) (critical=${CRITICAL_VULNS}, high=${HIGH_VULNS})"
  local entry site comp_type slug version name cve cvss severity unfixed sev_upper
  for entry in "${VULN_ENTRIES[@]}"; do
    IFS='|' read -r site comp_type slug version name cve cvss severity unfixed <<< "${entry}"
    sev_upper="$(printf '%s' "${severity}" | tr '[:lower:]' '[:upper:]')"
    [ -z "${sev_upper}" ] && sev_upper="UNKNOWN"
    printf '  [%s] %s %s/%s (%s)\n' \
      "${sev_upper}" "${site}" "${comp_type}" "${slug}" "${version}"
    [ -n "${cve}" ]  && printf '      cve:  %s\n' "${cve}"
    [ -n "${cvss}" ] && printf '      cvss: %s\n' "${cvss}"
    printf '      name: %s\n' "${name}"
    [ "${unfixed}" = "1" ] && printf '      note: no fix available upstream\n'
  done
}

emit_json_report() {
  local out="[" first=1 entry
  for entry in "${JSON_ENTRIES[@]+"${JSON_ENTRIES[@]}"}"; do
    if [ "${first}" = "1" ]; then first=0; else out="${out},"; fi
    out="${out}${entry}"
  done
  out="${out}]"
  printf '{"summary":{"total":%d,"critical":%d,"high":%d},"findings":%s}\n' \
    "${TOTAL_VULNS}" "${CRITICAL_VULNS}" "${HIGH_VULNS}" "${out}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  require_root

  if ! command -v wp >/dev/null 2>&1; then
    log_error "audit: wp-cli not found in PATH (install via install/install-stack.sh)"
    exit 1
  fi

  local sites
  sites="$(discover_sites || true)"
  if [ -z "${sites}" ]; then
    if [ -n "${DOMAIN}" ]; then
      log_error "audit: no WordPress site found for domain=${DOMAIN}${SITE_USER:+ user=${SITE_USER}}"
    else
      log_error "audit: no WordPress sites found under /home/*/webapps/"
    fi
    exit 65
  fi

  local user domain docroot
  while IFS='|' read -r user domain docroot; do
    [ -z "${domain}" ] && continue
    audit_site "${user}" "${domain}" "${docroot}"
  done <<< "${sites}"

  case "${FORMAT}" in
    text) emit_text_report ;;
    json) emit_json_report ;;
  esac

  [ "${TOTAL_VULNS}" -eq 0 ] || exit 1
}

main "$@"
