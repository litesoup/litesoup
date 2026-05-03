#!/usr/bin/env bash
# audit/audit-performance.sh -- read-only performance-tuning audit.
#
# Compares the live server configuration of Apache (mpm_event), PHP-FPM
# per-pool sizing, OPcache, MariaDB, and Redis against the recommended
# values for the server's RAM tier (small/medium/large -- same mapping as
# install/lib/redis.sh::_redis_tier_for_ram). Per-tunable findings are
# emitted as a text table (default) or a single JSON document.
#
# This script never mutates configuration. It only queries running daemons
# and parses on-disk config. Designed to run as root (apache config parse,
# mariadb root creds, redis password file) but degrades gracefully when
# specific services are absent.
#
# Usage:
#   audit-performance.sh [--service=apache|php-fpm|opcache|mariadb|redis|all]
#                        [--format=text|json]
#                        [--dry-run]
#
# Exit codes:
#   0   all checked tunables OK
#   1   at least one WARN finding (>2x or <0.5x recommended)
#   2   at least one CRIT finding (e.g. service required but unreachable,
#       or dangerous prod misconfig like opcache.validate_timestamps=1)

# shellcheck source=../install/lib/common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# common.sh enables `set -Eeuo pipefail` and installs an ERR trap for us.
# shellcheck disable=SC1091
source "${REPO_ROOT}/install/lib/common.sh"

###############################################################################
# CLI parsing
###############################################################################

SERVICE="all"
FORMAT="text"
# DRY_RUN is honored by run_or_dryrun in common.sh; we also branch on it
# directly for the read-only queries this script issues.
: "${DRY_RUN:=0}"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "${arg}" in
    --service=*)  SERVICE="${arg#*=}" ;;
    --format=*)   FORMAT="${arg#*=}" ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage ;;
    *)            log_error "unknown argument: ${arg}"; exit 2 ;;
  esac
done

case "${SERVICE}" in
  apache|php-fpm|opcache|mariadb|redis|all) ;;
  *) log_error "--service must be one of: apache|php-fpm|opcache|mariadb|redis|all"; exit 2 ;;
esac

case "${FORMAT}" in
  text|json) ;;
  *) log_error "--format must be one of: text|json"; exit 2 ;;
esac

###############################################################################
# Findings accumulator
#
# Each finding is appended as a single line:
#   <service>|<tunable>|<current>|<recommended>|<status>|<note>
# We collect all findings in one array, then emit text or JSON at the end.
###############################################################################

FINDINGS=()
WORST_STATUS=0   # 0 OK, 1 WARN, 2 CRIT

_status_rank() {
  case "$1" in
    OK)   echo 0 ;;
    WARN) echo 1 ;;
    CRIT) echo 2 ;;
    *)    echo 0 ;;
  esac
}

# add_finding SERVICE TUNABLE CURRENT RECOMMENDED STATUS [NOTE]
add_finding() {
  local svc="$1" tun="$2" cur="$3" rec="$4" stat="$5" note="${6:-}"
  FINDINGS+=("${svc}|${tun}|${cur}|${rec}|${stat}|${note}")
  local r
  r="$(_status_rank "${stat}")"
  if [ "${r}" -gt "${WORST_STATUS}" ]; then
    WORST_STATUS="${r}"
  fi
}

###############################################################################
# RAM tier detection -- matches install/lib/redis.sh::_redis_tier_for_ram.
#   <2048 MiB    -> small
#   2048-8191    -> medium
#   >=8192       -> large
###############################################################################

_detect_ram_mb() {
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would query /proc/meminfo for MemTotal"
    echo 4096   # pretend medium for dry-run shape checks
    return
  fi
  local kb
  kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  echo $(( kb / 1024 ))
}

_tier_for_ram() {
  local mb="$1"
  if   [ "${mb}" -lt 2048 ]; then echo "small"
  elif [ "${mb}" -lt 8192 ]; then echo "medium"
  else                            echo "large"
  fi
}

RAM_MB="$(_detect_ram_mb)"
RAM_TIER="$(_tier_for_ram "${RAM_MB}")"
log_info "audit: detected ${RAM_MB} MiB RAM -> tier=${RAM_TIER}"

###############################################################################
# Helpers
###############################################################################

# _have CMD -- 0 if CMD is on PATH, 1 otherwise.
_have() { command -v "$1" >/dev/null 2>&1; }

# _drift NUM_CURRENT NUM_RECOMMENDED -- echo OK / WARN based on the
# >2x or <0.5x rule used throughout this audit. Inputs must be integers.
_drift() {
  local cur="$1" rec="$2"
  if [ "${rec}" -le 0 ]; then echo "OK"; return; fi
  # >2x recommended -> WARN (overprovisioned, may OOM under load)
  if [ "${cur}" -gt $(( rec * 2 )) ]; then echo "WARN"; return; fi
  # <0.5x recommended -> WARN (underprovisioned, will throttle)
  if [ "${cur}" -lt $(( rec / 2 )) ]; then echo "WARN"; return; fi
  echo "OK"
}

# _bytes_from_size SIZE_STR -- parse "256M", "2G", "512k", or a raw byte count
# into bytes. Echoes 0 on parse failure (caller decides if that's CRIT).
_bytes_from_size() {
  local s="${1:-0}"
  s="${s// /}"
  local num unit
  num="$(echo "${s}" | sed -E 's/^([0-9]+).*/\1/')"
  unit="$(echo "${s}" | sed -E 's/^[0-9]+([A-Za-z]*)$/\1/')"
  [ -z "${num}" ] && { echo 0; return; }
  case "${unit,,}" in
    ""|b)  echo "${num}" ;;
    k|kb)  echo $(( num * 1024 )) ;;
    m|mb)  echo $(( num * 1024 * 1024 )) ;;
    g|gb)  echo $(( num * 1024 * 1024 * 1024 )) ;;
    *)     echo 0 ;;
  esac
}

###############################################################################
# 1. Apache (mpm_event)
###############################################################################

audit_apache() {
  if ! _have apache2ctl; then
    log_warn "apache: apache2ctl not found, skipping"
    add_finding apache service "absent" "installed" CRIT "apache2ctl not on PATH"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would query apache2ctl -M and parse mpm_event config"
    add_finding apache MaxRequestWorkers "(dry-run)" "by-tier" OK ""
    return
  fi

  # Confirm mpm_event is the active MPM. Other MPMs use a different sizing model.
  local mpm
  mpm="$(apache2ctl -M 2>/dev/null | awk '/mpm_/ {print $1}' | head -1 || true)"
  if [ "${mpm}" != "mpm_event_module" ]; then
    add_finding apache mpm "${mpm:-none}" "mpm_event_module" WARN "audit recommendations assume mpm_event"
  fi

  # Pull the live merged config; a literal MPM block survives IfModule guards.
  local cfg
  cfg="$(apache2ctl -t -D DUMP_RUN_CFG 2>/dev/null || true)"
  # Fallback: parse mpm_event.conf directly. Recent Debian/Ubuntu install at
  # /etc/apache2/mods-available/mpm_event.conf and enable via mods-enabled.
  local mpm_conf="/etc/apache2/mods-enabled/mpm_event.conf"
  [ -f "${mpm_conf}" ] || mpm_conf="/etc/apache2/mods-available/mpm_event.conf"

  local mrw sl tpc
  mrw="$(grep -hiE '^[[:space:]]*MaxRequestWorkers' "${mpm_conf}" 2>/dev/null | tail -1 | awk '{print $2}')"
  sl="$(grep -hiE '^[[:space:]]*ServerLimit'        "${mpm_conf}" 2>/dev/null | tail -1 | awk '{print $2}')"
  tpc="$(grep -hiE '^[[:space:]]*ThreadsPerChild'    "${mpm_conf}" 2>/dev/null | tail -1 | awk '{print $2}')"
  mrw="${mrw:-0}"
  sl="${sl:-0}"
  tpc="${tpc:-0}"

  # Recommended per RAM tier. ThreadsPerChild is the apache default 25 across
  # tiers; tuning it doesn't move the workers ceiling much in mpm_event.
  local rec_mrw rec_sl rec_tpc
  case "${RAM_TIER}" in
    small)  rec_mrw=50;  rec_sl=2;  rec_tpc=25 ;;
    medium) rec_mrw=150; rec_sl=6;  rec_tpc=25 ;;
    large)  rec_mrw=400; rec_sl=16; rec_tpc=25 ;;
  esac

  add_finding apache MaxRequestWorkers "${mrw}" "${rec_mrw}" "$(_drift "${mrw}" "${rec_mrw}")" "RAM tier=${RAM_TIER}"
  add_finding apache ServerLimit        "${sl}"  "${rec_sl}"  "$(_drift "${sl}"  "${rec_sl}")"  ""
  add_finding apache ThreadsPerChild    "${tpc}" "${rec_tpc}" "$(_drift "${tpc}" "${rec_tpc}")" ""

  # Silence "cfg unused" warning when the literal-config fallback wins.
  [ -n "${cfg}" ] || true
}

###############################################################################
# 2. PHP-FPM per-pool (litesoup-* pools only)
#
# The litesoup convention (install/lib/php.sh) names per-user pools
# litesoup-php<version>-... in /etc/php/<v>/fpm/pool.d/. The recommended
# tier for a host comes from the same RAM mapping used everywhere else.
###############################################################################

audit_php_fpm() {
  local glob_dirs=(/etc/php/*/fpm/pool.d)
  if [ ! -d "${glob_dirs[0]}" ]; then
    log_warn "php-fpm: no /etc/php/*/fpm/pool.d directories found, skipping"
    add_finding php-fpm service "absent" "installed" WARN "no PHP-FPM pools on disk"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would scan /etc/php/*/fpm/pool.d/litesoup-*.conf"
    add_finding php-fpm pool.tier "(dry-run)" "${RAM_TIER}" OK ""
    return
  fi

  shopt -s nullglob
  local pool_files=(/etc/php/*/fpm/pool.d/litesoup-*.conf)
  shopt -u nullglob

  if [ "${#pool_files[@]}" -eq 0 ]; then
    add_finding php-fpm pools "0" ">=1" WARN "no litesoup-owned FPM pools found"
    return
  fi

  local pool
  for pool in "${pool_files[@]}"; do
    local pname pm_mode mc mr
    pname="$(basename "${pool}" .conf)"
    pm_mode="$(grep -E '^[[:space:]]*pm[[:space:]]*='              "${pool}" | tail -1 | awk -F'=' '{gsub(/ /,"",$2); print $2}')"
    mc="$(grep      -E '^[[:space:]]*pm\.max_children[[:space:]]*=' "${pool}" | tail -1 | awk -F'=' '{gsub(/ /,"",$2); print $2}')"
    mr="$(grep      -E '^[[:space:]]*pm\.max_requests[[:space:]]*=' "${pool}" | tail -1 | awk -F'=' '{gsub(/ /,"",$2); print $2}')"
    pm_mode="${pm_mode:-unknown}"
    mc="${mc:-0}"
    mr="${mr:-0}"

    # Recommended sizing taken straight from install/lib/php.sh::php_pool_tier_block.
    local rec_pm rec_mc rec_mr
    case "${RAM_TIER}" in
      small)  rec_pm=ondemand; rec_mc=5;  rec_mr=500  ;;
      medium) rec_pm=dynamic;  rec_mc=20; rec_mr=1000 ;;
      large)  rec_pm=dynamic;  rec_mc=50; rec_mr=2000 ;;
    esac

    # Detect the pool's *current* tier by max_children; matches
    # install/lib/php.sh::_php_pool_current_tier.
    local cur_tier
    case "${mc}" in
      5)  cur_tier=small ;;
      20) cur_tier=medium ;;
      50) cur_tier=large ;;
      *)  cur_tier=unknown ;;
    esac

    local tier_status="OK"
    if [ "${cur_tier}" = "unknown" ]; then
      tier_status="WARN"
    elif [ "${cur_tier}" != "${RAM_TIER}" ]; then
      tier_status="WARN"
    fi
    add_finding php-fpm "${pname}.tier"           "${cur_tier}" "${RAM_TIER}" "${tier_status}" "RAM tier expects ${RAM_TIER}"

    # Mode mismatch is a softer signal: an operator may pin ondemand on a
    # large box on purpose. WARN, not CRIT.
    local mode_status="OK"
    [ "${pm_mode}" = "${rec_pm}" ] || mode_status="WARN"
    add_finding php-fpm "${pname}.pm"             "${pm_mode}"  "${rec_pm}"   "${mode_status}" ""

    add_finding php-fpm "${pname}.max_children"   "${mc}"       "${rec_mc}"   "$(_drift "${mc}" "${rec_mc}")" ""
    add_finding php-fpm "${pname}.max_requests"   "${mr}"       "${rec_mr}"   "$(_drift "${mr}" "${rec_mr}")" ""
  done
}

###############################################################################
# 3. OPcache (per installed PHP version)
###############################################################################

audit_opcache() {
  shopt -s nullglob
  local php_dirs=(/etc/php/*/)
  shopt -u nullglob

  if [ "${#php_dirs[@]}" -eq 0 ]; then
    log_warn "opcache: no /etc/php/* directories found, skipping"
    add_finding opcache service "absent" "installed" WARN "no PHP versions on disk"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would query php<v> -i for opcache settings"
    add_finding opcache memory_consumption "(dry-run)" "by-tier" OK ""
    return
  fi

  local rec_mb
  case "${RAM_TIER}" in
    small)  rec_mb=128 ;;
    medium) rec_mb=256 ;;
    large)  rec_mb=512 ;;
  esac

  local d
  for d in "${php_dirs[@]}"; do
    local v
    v="$(basename "${d}")"
    # Skip non-version subdirs (e.g. "mods-available" if it ever appears here).
    [[ "${v}" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    local bin="/usr/bin/php${v}"
    if [ ! -x "${bin}" ]; then
      add_finding opcache "${v}.binary" "missing" "installed" WARN "no ${bin}"
      continue
    fi

    # Use the FPM SAPI's effective ini, not CLI: production OPcache lives
    # in the FPM process, not the CLI. -c points at the FPM ini dir.
    local ini_dir="/etc/php/${v}/fpm"
    local raw mc_mb maf vt
    raw="$("${bin}" -c "${ini_dir}" -r 'echo ini_get("opcache.memory_consumption"),"|",ini_get("opcache.max_accelerated_files"),"|",ini_get("opcache.validate_timestamps");' 2>/dev/null || echo "||")"
    mc_mb="$(echo "${raw}" | awk -F'|' '{print $1}')"
    maf="$(  echo "${raw}" | awk -F'|' '{print $2}')"
    vt="$(   echo "${raw}" | awk -F'|' '{print $3}')"
    mc_mb="${mc_mb:-0}"
    maf="${maf:-0}"
    vt="${vt:-1}"

    local mc_status="OK"
    if [ "${mc_mb}" -lt $(( rec_mb / 2 )) ]; then mc_status="WARN"; fi
    add_finding opcache "${v}.memory_consumption"     "${mc_mb}M"  "${rec_mb}M" "${mc_status}" "RAM tier=${RAM_TIER}"

    local maf_status="OK"
    if [ "${maf}" -lt 10000 ]; then maf_status="WARN"; fi
    add_finding opcache "${v}.max_accelerated_files"  "${maf}"     ">=10000"    "${maf_status}" ""

    # validate_timestamps=1 in prod re-stats every include on every request.
    # That's a measurable hit; CRIT so the audit fails noisily.
    local vt_status="OK"
    if [ "${vt}" = "1" ]; then vt_status="CRIT"; fi
    add_finding opcache "${v}.validate_timestamps"    "${vt}"      "0"          "${vt_status}" "1 = re-stat on every request"
  done
}

###############################################################################
# 4. MariaDB
###############################################################################

audit_mariadb() {
  if ! _have mysql; then
    log_warn "mariadb: mysql client not found, skipping"
    add_finding mariadb service "absent" "installed" WARN "mysql client not on PATH"
    return
  fi

  local creds="/root/.litesoup-mariadb-root"
  if [ ! -r "${creds}" ]; then
    add_finding mariadb credentials "missing" "${creds}" CRIT "litesoup root creds unreadable; skipping live query"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would query mariadb SHOW VARIABLES with --defaults-file=${creds}"
    add_finding mariadb innodb_buffer_pool_size "(dry-run)" "by-tier" OK ""
    return
  fi

  # Pull all four variables in one round-trip to keep the audit cheap.
  local out
  if ! out="$(mysql --defaults-file="${creds}" -N -B -e "
    SHOW VARIABLES WHERE Variable_name IN
      ('innodb_buffer_pool_size','max_connections','query_cache_type','tmp_table_size');
  " 2>/dev/null)"; then
    add_finding mariadb query "failed" "ok" CRIT "mysql client could not connect"
    return
  fi

  local ibps mc qct tts
  ibps="$(echo "${out}" | awk '$1=="innodb_buffer_pool_size"{print $2}')"
  mc="$(  echo "${out}" | awk '$1=="max_connections"        {print $2}')"
  qct="$( echo "${out}" | awk '$1=="query_cache_type"       {print $2}')"
  tts="$( echo "${out}" | awk '$1=="tmp_table_size"         {print $2}')"
  ibps="${ibps:-0}"
  mc="${mc:-0}"
  qct="${qct:-UNKNOWN}"
  tts="${tts:-0}"

  # Recommended innodb_buffer_pool_size per RAM tier. ~50-70% of RAM is the
  # standard DBA rule; values picked so a fresh install on each tier matches.
  local rec_ibps_bytes rec_label
  case "${RAM_TIER}" in
    small)  rec_ibps_bytes=$(( 512 * 1024 * 1024 ));            rec_label="512M" ;;
    medium) rec_ibps_bytes=$(( 2  * 1024 * 1024 * 1024 ));      rec_label="2G" ;;
    large)  rec_ibps_bytes=$(( 6  * 1024 * 1024 * 1024 ));      rec_label="6G" ;;
  esac

  add_finding mariadb innodb_buffer_pool_size "${ibps}" "${rec_ibps_bytes} (${rec_label})" \
    "$(_drift "${ibps}" "${rec_ibps_bytes}")" "~50-70% of RAM"

  # max_connections recommendations are a function of FPM workers, not RAM,
  # so the bands here are deliberately wide -- we only flag obvious extremes.
  local rec_mc=151
  add_finding mariadb max_connections "${mc}" "${rec_mc}" "$(_drift "${mc}" "${rec_mc}")" \
    "MariaDB default; raise only if FPM workers > 100"

  # query_cache_type is removed in MariaDB 10.5+ but the variable still
  # appears as OFF for compatibility. Anything other than OFF is suspect.
  local qct_status="OK"
  case "${qct}" in
    OFF|0) qct_status="OK" ;;
    *)     qct_status="WARN" ;;
  esac
  add_finding mariadb query_cache_type "${qct}" "OFF" "${qct_status}" "deprecated in MariaDB 10.x"

  local rec_tts=$(( 32 * 1024 * 1024 ))
  add_finding mariadb tmp_table_size "${tts}" "${rec_tts} (32M)" \
    "$(_drift "${tts}" "${rec_tts}")" ""
}

###############################################################################
# 5. Redis (Plan I.F)
###############################################################################

audit_redis() {
  if ! _have redis-cli; then
    log_warn "redis: redis-cli not found, skipping"
    add_finding redis service "absent" "installed" WARN "redis-cli not on PATH"
    return
  fi

  local env_file="/etc/litesoup/redis.env"
  if [ ! -r "${env_file}" ]; then
    add_finding redis credentials "missing" "${env_file}" WARN \
      "Plan I.F redis.env not present; redis may not be installed"
    return
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would source ${env_file} and query redis-cli CONFIG GET maxmemory"
    add_finding redis maxmemory "(dry-run)" "by-tier" OK ""
    return
  fi

  local pw
  # shellcheck source=/dev/null
  pw="$(. "${env_file}" && printf '%s' "${REDIS_PASSWORD:-}")"
  if [ -z "${pw}" ]; then
    add_finding redis credentials "empty" "REDIS_PASSWORD set" CRIT \
      "${env_file} has no REDIS_PASSWORD"
    return
  fi

  local raw
  if ! raw="$(redis-cli -a "${pw}" --no-auth-warning CONFIG GET maxmemory 2>/dev/null)"; then
    add_finding redis maxmemory "query-failed" "running" CRIT "redis-cli AUTH+CONFIG GET failed"
    return
  fi

  local cur_bytes
  cur_bytes="$(echo "${raw}" | awk 'NR==2 {print $0}')"
  cur_bytes="${cur_bytes:-0}"

  # Recommended maxmemory uses the same tier mapping as
  # install/lib/redis.sh::_redis_tier_for_ram.
  local rec_label rec_bytes
  case "${RAM_TIER}" in
    small)  rec_label="128mb"; rec_bytes="$(_bytes_from_size 128M)" ;;
    medium) rec_label="512mb"; rec_bytes="$(_bytes_from_size 512M)" ;;
    large)  rec_label="2gb";   rec_bytes="$(_bytes_from_size 2G)" ;;
  esac

  local status="OK"
  if [ "${cur_bytes}" = "0" ]; then
    # Unbounded redis on a shared host can OOM the box; loud finding.
    status="CRIT"
  else
    status="$(_drift "${cur_bytes}" "${rec_bytes}")"
  fi

  add_finding redis maxmemory "${cur_bytes}" "${rec_bytes} (${rec_label})" "${status}" \
    "RAM tier=${RAM_TIER}"
}

###############################################################################
# Dispatch
###############################################################################

case "${SERVICE}" in
  apache)   audit_apache ;;
  php-fpm)  audit_php_fpm ;;
  opcache)  audit_opcache ;;
  mariadb)  audit_mariadb ;;
  redis)    audit_redis ;;
  all)
    audit_apache
    audit_php_fpm
    audit_opcache
    audit_mariadb
    audit_redis
    ;;
esac

###############################################################################
# Output
###############################################################################

emit_text() {
  printf '\n'
  printf '%-9s | %-32s | %-24s | %-24s | %-4s | %s\n' \
    "Service" "Tunable" "Current" "Recommended" "Stat" "Note"
  printf -- '----------+----------------------------------+--------------------------+--------------------------+------+----------------------------------------\n'
  local row svc tun cur rec stat note
  for row in "${FINDINGS[@]}"; do
    IFS='|' read -r svc tun cur rec stat note <<<"${row}"
    printf '%-9s | %-32s | %-24s | %-24s | %-4s | %s\n' \
      "${svc}" "${tun}" "${cur}" "${rec}" "${stat}" "${note}"
  done
  printf '\n'
  printf 'RAM: %s MiB (tier=%s)   worst-status: %s\n' "${RAM_MB}" "${RAM_TIER}" \
    "$(case "${WORST_STATUS}" in 0) echo OK;; 1) echo WARN;; 2) echo CRIT;; esac)"
}

# Minimal hand-rolled JSON to avoid pulling in jq as a runtime dep.
# jq -R is nicer but we want this script to work on a freshly-installed
# host where the audit may run before jq lands.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//	/\\t}"
  s="${s//
/\\n}"
  printf '%s' "${s}"
}

emit_json() {
  local i=0 row svc tun cur rec stat note
  printf '{\n'
  printf '  "ram_mb": %s,\n' "${RAM_MB}"
  printf '  "ram_tier": "%s",\n' "${RAM_TIER}"
  printf '  "worst_status": "%s",\n' \
    "$(case "${WORST_STATUS}" in 0) echo OK;; 1) echo WARN;; 2) echo CRIT;; esac)"
  printf '  "findings": [\n'
  local n="${#FINDINGS[@]}"
  for row in "${FINDINGS[@]}"; do
    IFS='|' read -r svc tun cur rec stat note <<<"${row}"
    printf '    {"service":"%s","tunable":"%s","current":"%s","recommended":"%s","status":"%s","note":"%s"}' \
      "$(_json_escape "${svc}")" \
      "$(_json_escape "${tun}")" \
      "$(_json_escape "${cur}")" \
      "$(_json_escape "${rec}")" \
      "$(_json_escape "${stat}")" \
      "$(_json_escape "${note}")"
    i=$(( i + 1 ))
    if [ "${i}" -lt "${n}" ]; then printf ',\n'; else printf '\n'; fi
  done
  printf '  ]\n'
  printf '}\n'
}

case "${FORMAT}" in
  text) emit_text ;;
  json) emit_json ;;
esac

exit "${WORST_STATUS}"
