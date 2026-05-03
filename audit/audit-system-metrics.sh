#!/usr/bin/env bash
# audit/audit-system-metrics.sh — read-only system + service metrics audit.
# Emits a human table by default or a single JSON object with --format=json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"

FORMAT="text"
WATCH=0

usage() {
  cat <<'EOF'
audit-system-metrics — read-only system + service metrics

Usage: bash audit-system-metrics.sh [options]

Options:
  --format=text|json   Output format (default: text)
  --watch=N            Refresh every N seconds (Ctrl-C to stop)
  --dry-run            Print intended queries without running them
  --help               Show this help

Collects: load, CPU cores, %iowait, memory + swap, per-mount disk + inode
          usage, per-interface tx/rx, TCP/UDP socket counts, Apache workers
          (if mod_status enabled), PHP-FPM pools (per installed version),
          MariaDB conn + slow-query count, Redis INFO (auth via
          /etc/litesoup/redis.env when present).

Read-only — never mutates system state.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --format=text|--format=json) FORMAT="${arg#--format=}" ;;
    --format=*)
      log_error "unknown format: ${arg#--format=} (want text|json)"
      exit 2
      ;;
    --watch=*)
      WATCH="${arg#--watch=}"
      if ! [[ "${WATCH}" =~ ^[0-9]+$ ]] || [ "${WATCH}" -lt 1 ]; then
        log_error "--watch=N requires a positive integer"
        exit 2
      fi
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      log_error "unknown argument: ${arg}"
      usage >&2
      exit 2
      ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────

# Quote a string for inline JSON output (escapes \ and ").
_jq_str() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "${s}"
}

# Emit a JSON value — number passthrough if numeric, else quoted, "null" if empty.
_jv() {
  local v="${1-}"
  if [ -z "${v}" ]; then
    printf 'null'
  elif [[ "${v}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "${v}"
  else
    _jq_str "${v}"
  fi
}

_dryrun_note() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '%s [DRYRUN] would query %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2
  fi
}

# ── Collectors ──────────────────────────────────────────────────────────────

collect_cpu() {
  _dryrun_note "/proc/loadavg, /proc/stat, nproc"
  CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "")
  if [ -r /proc/loadavg ]; then
    read -r LOAD_1 LOAD_5 LOAD_15 _ < /proc/loadavg
  else
    LOAD_1=""; LOAD_5=""; LOAD_15=""
  fi
  # %iowait via two /proc/stat samples 1s apart.
  CPU_IOWAIT=""
  if [ -r /proc/stat ]; then
    local a b
    a=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    sleep 1
    b=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    CPU_IOWAIT=$(awk -v a="${a}" -v b="${b}" '
      BEGIN {
        n=split(a,A," "); split(b,B," ");
        ta=0; tb=0;
        for (i=1;i<=n;i++) { ta+=A[i]; tb+=B[i] }
        dt=tb-ta; di=B[5]-A[5];
        if (dt>0) printf "%.2f", (di/dt)*100; else printf ""
      }')
  fi
}

collect_mem() {
  _dryrun_note "/proc/meminfo"
  if [ ! -r /proc/meminfo ]; then
    MEM_TOTAL_KB=""; MEM_FREE_KB=""; MEM_AVAIL_KB=""; MEM_BUFFERS_KB=""
    MEM_CACHED_KB=""; SWAP_TOTAL_KB=""; SWAP_FREE_KB=""
    return
  fi
  MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  MEM_FREE_KB=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
  MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  MEM_BUFFERS_KB=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
  MEM_CACHED_KB=$(awk '/^Cached:/{print $2}' /proc/meminfo)
  SWAP_TOTAL_KB=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  SWAP_FREE_KB=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  MEM_USED_KB=""
  if [ -n "${MEM_TOTAL_KB}" ] && [ -n "${MEM_AVAIL_KB}" ]; then
    MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
  fi
}

# Populates DISK_ROWS as lines: "mount|fstype|size_kb|used_kb|avail_kb|use_pct|inode_pct|alert"
collect_disk() {
  _dryrun_note "df -PT, df -PTi"
  DISK_ROWS=()
  local size_lines inode_lines
  size_lines=$(df -PT -k 2>/dev/null | tail -n +2 || true)
  inode_lines=$(df -PTi 2>/dev/null | tail -n +2 || true)
  [ -z "${size_lines}" ] && return
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    # Filter pseudo filesystems.
    local fstype mount
    fstype=$(awk '{print $2}' <<<"${line}")
    mount=$(awk '{print $7}' <<<"${line}")
    case "${fstype}" in
      tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|cgroup2|autofs|debugfs|tracefs|fuse.snapfuse|fuse.gvfsd-fuse) continue ;;
    esac
    [ -z "${mount}" ] && continue
    local size_kb used_kb avail_kb use_pct inode_pct alert
    size_kb=$(awk '{print $3}' <<<"${line}")
    used_kb=$(awk '{print $4}' <<<"${line}")
    avail_kb=$(awk '{print $5}' <<<"${line}")
    use_pct=$(awk '{gsub("%","",$6); print $6}' <<<"${line}")
    inode_pct=$(awk -v m="${mount}" '$7==m {gsub("%","",$6); print $6; exit}' <<<"${inode_lines}")
    alert=""
    if [[ "${use_pct}" =~ ^[0-9]+$ ]] && [ "${use_pct}" -gt 85 ]; then
      alert="HIGH"
    fi
    DISK_ROWS+=("${mount}|${fstype}|${size_kb}|${used_kb}|${avail_kb}|${use_pct}|${inode_pct:-}|${alert}")
  done <<< "${size_lines}"
}

# Populates NET_ROWS: "iface|rx_bytes|tx_bytes"; also TCP_COUNT, UDP_COUNT.
collect_net() {
  _dryrun_note "/proc/net/dev, /proc/net/tcp{,6}, /proc/net/udp{,6}"
  NET_ROWS=()
  if [ -r /proc/net/dev ]; then
    local line iface rx tx
    while IFS= read -r line; do
      [[ "${line}" == *:* ]] || continue
      iface=$(awk -F: '{gsub(/ /,"",$1); print $1}' <<<"${line}")
      [ "${iface}" = "lo" ] && continue
      rx=$(awk -F: '{print $2}' <<<"${line}" | awk '{print $1}')
      tx=$(awk -F: '{print $2}' <<<"${line}" | awk '{print $9}')
      NET_ROWS+=("${iface}|${rx}|${tx}")
    done < /proc/net/dev
  fi
  TCP_COUNT=0
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "${f}" ] || continue
    TCP_COUNT=$(( TCP_COUNT + $(($(wc -l < "${f}") - 1)) ))
  done
  UDP_COUNT=0
  for f in /proc/net/udp /proc/net/udp6; do
    [ -r "${f}" ] || continue
    UDP_COUNT=$(( UDP_COUNT + $(($(wc -l < "${f}") - 1)) ))
  done
}

# Apache: master pid, busy/idle workers, requests/sec via /server-status?auto.
collect_apache() {
  APACHE_INSTALLED=false
  APACHE_BUSY=""; APACHE_IDLE=""; APACHE_REQ_PER_SEC=""; APACHE_TOTAL_ACCESSES=""
  command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1 || return 0
  APACHE_INSTALLED=true
  _dryrun_note "http://127.0.0.1/server-status?auto"
  [ "${DRY_RUN}" = "1" ] && return 0
  local body
  body=$(curl -fsS --max-time 3 "http://127.0.0.1/server-status?auto" 2>/dev/null || true)
  [ -z "${body}" ] && return 0
  APACHE_BUSY=$(awk -F: '/^BusyWorkers:/{gsub(/ /,"",$2); print $2}' <<<"${body}")
  APACHE_IDLE=$(awk -F: '/^IdleWorkers:/{gsub(/ /,"",$2); print $2}' <<<"${body}")
  APACHE_REQ_PER_SEC=$(awk -F: '/^ReqPerSec:/{gsub(/ /,"",$2); print $2}' <<<"${body}")
  APACHE_TOTAL_ACCESSES=$(awk -F: '/^Total Accesses:/{gsub(/ /,"",$2); print $2}' <<<"${body}")
}

# PHP-FPM: discover installed versions; populate PHP_ROWS as
# "version|pool|state|active|idle|listen".
collect_php_fpm() {
  PHP_ROWS=()
  PHP_VERSIONS=()
  local v
  for v in 8.0 8.1 8.2 8.3 8.4 8.5 7.4; do
    [ -d "/etc/php/${v}/fpm" ] || continue
    PHP_VERSIONS+=("${v}")
  done
  [ ${#PHP_VERSIONS[@]} -eq 0 ] && return 0
  _dryrun_note "php-fpm -t per version + /run/php/*.sock listings"
  for v in "${PHP_VERSIONS[@]}"; do
    local pooldir="/etc/php/${v}/fpm/pool.d"
    [ -d "${pooldir}" ] || continue
    local conf pool listen state active idle sock
    for conf in "${pooldir}"/*.conf; do
      [ -f "${conf}" ] || continue
      pool=$(awk '/^\[/{gsub(/[][]/,"",$0); print; exit}' "${conf}")
      [ -z "${pool}" ] && continue
      listen=$(awk -F= '/^[[:space:]]*listen[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "${conf}")
      state="unknown"; active=""; idle=""
      if [ -n "${listen}" ]; then
        sock="${listen#unix:}"
        if [ -S "${sock}" ] || [ -S "/run/php/${pool}.sock" ] || [[ "${listen}" == *:* ]]; then
          state="listening"
        fi
      fi
      # Try the pool's own status path if exposed; default /status.
      if [ "${DRY_RUN}" != "1" ] && [ -S "${listen#unix:}" ] && command -v cgi-fcgi >/dev/null 2>&1; then
        local status
        status=$(SCRIPT_NAME=/status SCRIPT_FILENAME=/status REQUEST_METHOD=GET \
          cgi-fcgi -bind -connect "${listen#unix:}" 2>/dev/null || true)
        active=$(awk -F: '/^active processes:/{gsub(/ /,"",$2); print $2}' <<<"${status}")
        idle=$(awk -F: '/^idle processes:/{gsub(/ /,"",$2); print $2}' <<<"${status}")
      fi
      PHP_ROWS+=("${v}|${pool}|${state}|${active:-}|${idle:-}|${listen:-}")
    done
  done
}

# MariaDB: connection count + slow-query count from log (last hour, best effort).
collect_mariadb() {
  MARIADB_INSTALLED=false
  MARIADB_CONNS=""; MARIADB_SLOW_LASTHOUR=""; MARIADB_UPTIME=""
  command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || return 0
  MARIADB_INSTALLED=true
  _dryrun_note "mariadb -e 'SHOW STATUS' + slow query log scan"
  [ "${DRY_RUN}" = "1" ] && return 0
  local cli
  cli=$(command -v mariadb 2>/dev/null || command -v mysql)
  local out
  # Use Unix socket auth as root if possible; otherwise rely on user .my.cnf.
  out=$("${cli}" --protocol=socket -N -B -e \
    "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Uptime','Slow_queries');" \
    2>/dev/null || true)
  if [ -n "${out}" ]; then
    MARIADB_CONNS=$(awk '$1=="Threads_connected"{print $2}' <<<"${out}")
    MARIADB_UPTIME=$(awk '$1=="Uptime"{print $2}' <<<"${out}")
  fi
  # Slow query log scan (last hour) — only if log is readable.
  local slow_log="/var/log/mysql/mariadb-slow.log"
  [ -r "${slow_log}" ] || slow_log="/var/log/mysql/slow.log"
  if [ -r "${slow_log}" ]; then
    MARIADB_SLOW_LASTHOUR=$(awk -v cutoff="$(date -d '1 hour ago' +%s 2>/dev/null || date -v-1H +%s 2>/dev/null)" '
      /^# Time:/ {
        ts = $3 " " $4
        cmd = "date -d \"" ts "\" +%s 2>/dev/null"
        cmd | getline t
        close(cmd)
        if (t >= cutoff) c++
      }
      END { print c+0 }' "${slow_log}" 2>/dev/null || true)
  fi
}

# Redis: AUTH via /etc/litesoup/redis.env if present, else unauth.
collect_redis() {
  REDIS_INSTALLED=false
  REDIS_USED_MEM=""; REDIS_USED_MEM_PEAK=""; REDIS_CLIENTS=""; REDIS_VERSION=""
  command -v redis-cli >/dev/null 2>&1 || return 0
  REDIS_INSTALLED=true
  _dryrun_note "redis-cli INFO (auth via /etc/litesoup/redis.env if present)"
  [ "${DRY_RUN}" = "1" ] && return 0
  local pw=""
  if [ -r /etc/litesoup/redis.env ]; then
    # shellcheck disable=SC1091
    pw="$(. /etc/litesoup/redis.env && printf '%s' "${REDIS_PASSWORD:-}")"
  fi
  local info
  if [ -n "${pw}" ]; then
    info=$(redis-cli -a "${pw}" --no-auth-warning INFO 2>/dev/null || true)
  else
    info=$(redis-cli INFO 2>/dev/null || true)
  fi
  [ -z "${info}" ] && return 0
  REDIS_VERSION=$(awk -F: '/^redis_version:/{gsub(/\r/,"",$2); print $2}' <<<"${info}")
  REDIS_USED_MEM=$(awk -F: '/^used_memory:/{gsub(/\r/,"",$2); print $2}' <<<"${info}")
  REDIS_USED_MEM_PEAK=$(awk -F: '/^used_memory_peak:/{gsub(/\r/,"",$2); print $2}' <<<"${info}")
  REDIS_CLIENTS=$(awk -F: '/^connected_clients:/{gsub(/\r/,"",$2); print $2}' <<<"${info}")
}

# ── Renderers ───────────────────────────────────────────────────────────────

render_text() {
  local kb_to_mb='function kb2mb(k){return (k=="" ? "-" : sprintf("%.0f", k/1024))}'
  printf '── audit-system-metrics @ %s — %s ──\n' "$(_ts)" "$(hostname -f 2>/dev/null || hostname)"

  printf '\n[CPU]\n'
  printf '  cores=%s  load1=%s  load5=%s  load15=%s  iowait=%s%%\n' \
    "${CPU_CORES:-?}" "${LOAD_1:-?}" "${LOAD_5:-?}" "${LOAD_15:-?}" "${CPU_IOWAIT:-?}"

  printf '\n[Memory MiB]\n'
  awk -v t="${MEM_TOTAL_KB}" -v u="${MEM_USED_KB}" -v f="${MEM_FREE_KB}" \
      -v a="${MEM_AVAIL_KB}" -v b="${MEM_BUFFERS_KB}" -v c="${MEM_CACHED_KB}" \
      -v st="${SWAP_TOTAL_KB}" -v sf="${SWAP_FREE_KB}" \
      "BEGIN { ${kb_to_mb}
        printf \"  total=%s  used=%s  free=%s  avail=%s  buffers=%s  cached=%s  swap=%s/%s\n\",
          kb2mb(t), kb2mb(u), kb2mb(f), kb2mb(a), kb2mb(b), kb2mb(c),
          (st==\"\"||st==0?\"0\":kb2mb(st-sf)), kb2mb(st)
      }"

  printf '\n[Disk] (alert if use%%>85)\n'
  printf '  %-24s %-10s %8s %8s %8s %5s %5s %s\n' MOUNT FSTYPE SIZE_M USED_M AVAIL_M USE% INO% ALERT
  local row
  for row in "${DISK_ROWS[@]:-}"; do
    [ -z "${row}" ] && continue
    IFS='|' read -r mnt fst sz us av up ip al <<<"${row}"
    awk -v m="${mnt}" -v f="${fst}" -v s="${sz}" -v u="${us}" -v a="${av}" \
        -v up="${up}" -v ip="${ip}" -v al="${al}" \
        "BEGIN { ${kb_to_mb}
          printf \"  %-24s %-10s %8s %8s %8s %5s%% %4s%% %s\n\",
            m, f, kb2mb(s), kb2mb(u), kb2mb(a), up, (ip==\"\"?\"-\":ip), al
        }"
  done

  printf '\n[Network] tcp_sockets=%s  udp_sockets=%s\n' "${TCP_COUNT}" "${UDP_COUNT}"
  printf '  %-12s %16s %16s\n' IFACE RX_BYTES TX_BYTES
  for row in "${NET_ROWS[@]:-}"; do
    [ -z "${row}" ] && continue
    IFS='|' read -r ifc rx tx <<<"${row}"
    printf '  %-12s %16s %16s\n' "${ifc}" "${rx}" "${tx}"
  done

  printf '\n[Apache]\n'
  if [ "${APACHE_INSTALLED}" = true ]; then
    printf '  installed=yes  busy=%s  idle=%s  req/s=%s  total_accesses=%s\n' \
      "${APACHE_BUSY:-?}" "${APACHE_IDLE:-?}" "${APACHE_REQ_PER_SEC:-?}" "${APACHE_TOTAL_ACCESSES:-?}"
    [ -z "${APACHE_BUSY}" ] && printf '  (mod_status not enabled or /server-status not reachable on 127.0.0.1)\n'
  else
    printf '  installed=no\n'
  fi

  printf '\n[PHP-FPM]\n'
  if [ ${#PHP_VERSIONS[@]} -eq 0 ]; then
    printf '  no /etc/php/X.Y/fpm directories found\n'
  else
    printf '  versions=%s\n' "${PHP_VERSIONS[*]}"
    printf '  %-5s %-24s %-10s %6s %6s %s\n' VER POOL STATE ACTIVE IDLE LISTEN
    for row in "${PHP_ROWS[@]:-}"; do
      [ -z "${row}" ] && continue
      IFS='|' read -r v pool st ac id lis <<<"${row}"
      printf '  %-5s %-24s %-10s %6s %6s %s\n' "${v}" "${pool}" "${st}" "${ac:--}" "${id:--}" "${lis:--}"
    done
  fi

  printf '\n[MariaDB]\n'
  if [ "${MARIADB_INSTALLED}" = true ]; then
    printf '  installed=yes  threads_connected=%s  uptime=%s  slow_queries_last_hour=%s\n' \
      "${MARIADB_CONNS:-?}" "${MARIADB_UPTIME:-?}" "${MARIADB_SLOW_LASTHOUR:-?}"
    [ -z "${MARIADB_CONNS}" ] && printf '  (no socket auth — run as root or configure /root/.my.cnf)\n'
  else
    printf '  installed=no\n'
  fi

  printf '\n[Redis]\n'
  if [ "${REDIS_INSTALLED}" = true ]; then
    printf '  installed=yes  version=%s  used_memory=%s  used_memory_peak=%s  connected_clients=%s\n' \
      "${REDIS_VERSION:-?}" "${REDIS_USED_MEM:-?}" "${REDIS_USED_MEM_PEAK:-?}" "${REDIS_CLIENTS:-?}"
    [ -z "${REDIS_USED_MEM}" ] && printf '  (INFO failed — check /etc/litesoup/redis.env or redis-server status)\n'
  else
    printf '  installed=no\n'
  fi
}

render_json() {
  local first=1 row v pool st ac id lis ifc rx tx mnt fst sz us av up ip al

  printf '{'
  printf '"reported_at":%s' "$(_jq_str "$(_ts)")"
  printf ',"hostname":%s' "$(_jq_str "$(hostname -f 2>/dev/null || hostname)")"

  printf ',"cpu":{'
  printf '"cores":%s' "$(_jv "${CPU_CORES}")"
  printf ',"load_1":%s' "$(_jv "${LOAD_1}")"
  printf ',"load_5":%s' "$(_jv "${LOAD_5}")"
  printf ',"load_15":%s' "$(_jv "${LOAD_15}")"
  printf ',"iowait_pct":%s' "$(_jv "${CPU_IOWAIT}")"
  printf '}'

  printf ',"memory_kb":{'
  printf '"total":%s'      "$(_jv "${MEM_TOTAL_KB}")"
  printf ',"used":%s'      "$(_jv "${MEM_USED_KB}")"
  printf ',"free":%s'      "$(_jv "${MEM_FREE_KB}")"
  printf ',"available":%s' "$(_jv "${MEM_AVAIL_KB}")"
  printf ',"buffers":%s'   "$(_jv "${MEM_BUFFERS_KB}")"
  printf ',"cached":%s'    "$(_jv "${MEM_CACHED_KB}")"
  printf ',"swap_total":%s' "$(_jv "${SWAP_TOTAL_KB}")"
  printf ',"swap_free":%s'  "$(_jv "${SWAP_FREE_KB}")"
  printf '}'

  printf ',"disks":['
  first=1
  for row in "${DISK_ROWS[@]:-}"; do
    [ -z "${row}" ] && continue
    IFS='|' read -r mnt fst sz us av up ip al <<<"${row}"
    [ "${first}" -eq 0 ] && printf ','
    first=0
    printf '{"mount":%s,"fstype":%s,"size_kb":%s,"used_kb":%s,"avail_kb":%s,"use_pct":%s,"inode_pct":%s,"alert":%s}' \
      "$(_jq_str "${mnt}")" "$(_jq_str "${fst}")" "$(_jv "${sz}")" "$(_jv "${us}")" \
      "$(_jv "${av}")" "$(_jv "${up}")" "$(_jv "${ip}")" "$([ -n "${al}" ] && _jq_str "${al}" || printf 'null')"
  done
  printf ']'

  printf ',"network":{"tcp_sockets":%s,"udp_sockets":%s,"interfaces":[' \
    "$(_jv "${TCP_COUNT}")" "$(_jv "${UDP_COUNT}")"
  first=1
  for row in "${NET_ROWS[@]:-}"; do
    [ -z "${row}" ] && continue
    IFS='|' read -r ifc rx tx <<<"${row}"
    [ "${first}" -eq 0 ] && printf ','
    first=0
    printf '{"iface":%s,"rx_bytes":%s,"tx_bytes":%s}' \
      "$(_jq_str "${ifc}")" "$(_jv "${rx}")" "$(_jv "${tx}")"
  done
  printf ']}'

  printf ',"apache":{"installed":%s,"busy_workers":%s,"idle_workers":%s,"req_per_sec":%s,"total_accesses":%s}' \
    "$([ "${APACHE_INSTALLED}" = true ] && printf 'true' || printf 'false')" \
    "$(_jv "${APACHE_BUSY}")" "$(_jv "${APACHE_IDLE}")" \
    "$(_jv "${APACHE_REQ_PER_SEC}")" "$(_jv "${APACHE_TOTAL_ACCESSES}")"

  printf ',"php_fpm":{"versions":['
  first=1
  for v in "${PHP_VERSIONS[@]:-}"; do
    [ -z "${v}" ] && continue
    [ "${first}" -eq 0 ] && printf ','
    first=0
    printf '%s' "$(_jq_str "${v}")"
  done
  printf '],"pools":['
  first=1
  for row in "${PHP_ROWS[@]:-}"; do
    [ -z "${row}" ] && continue
    IFS='|' read -r v pool st ac id lis <<<"${row}"
    [ "${first}" -eq 0 ] && printf ','
    first=0
    printf '{"version":%s,"pool":%s,"state":%s,"active":%s,"idle":%s,"listen":%s}' \
      "$(_jq_str "${v}")" "$(_jq_str "${pool}")" "$(_jq_str "${st}")" \
      "$(_jv "${ac}")" "$(_jv "${id}")" "$(_jq_str "${lis}")"
  done
  printf ']}'

  printf ',"mariadb":{"installed":%s,"threads_connected":%s,"uptime":%s,"slow_queries_last_hour":%s}' \
    "$([ "${MARIADB_INSTALLED}" = true ] && printf 'true' || printf 'false')" \
    "$(_jv "${MARIADB_CONNS}")" "$(_jv "${MARIADB_UPTIME}")" "$(_jv "${MARIADB_SLOW_LASTHOUR}")"

  printf ',"redis":{"installed":%s,"version":%s,"used_memory":%s,"used_memory_peak":%s,"connected_clients":%s}' \
    "$([ "${REDIS_INSTALLED}" = true ] && printf 'true' || printf 'false')" \
    "$(_jq_str "${REDIS_VERSION}")" \
    "$(_jv "${REDIS_USED_MEM}")" "$(_jv "${REDIS_USED_MEM_PEAK}")" "$(_jv "${REDIS_CLIENTS}")"

  printf '}\n'
}

# ── Main loop ───────────────────────────────────────────────────────────────

run_once() {
  collect_cpu
  collect_mem
  collect_disk
  collect_net
  collect_apache
  collect_php_fpm
  collect_mariadb
  collect_redis
  case "${FORMAT}" in
    json) render_json ;;
    text) render_text ;;
  esac
}

if [ "${WATCH}" -gt 0 ]; then
  while true; do
    if [ "${FORMAT}" = "text" ]; then
      clear 2>/dev/null || true
    fi
    run_once
    sleep "${WATCH}"
  done
else
  run_once
fi
