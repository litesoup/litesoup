#!/usr/bin/env bash
# audit/audit-status.sh — single-line server health summary.
#
# Calls audit-system-metrics.sh --format=json and formats the output as a
# compact one-line status with Unicode warning/danger icons when thresholds
# are exceeded.
#
# Usage: sudo bash audit-status.sh [--watch=N] [--verbose] [--ascii] [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"

WATCH=0
VERBOSE=0
ASCII=0

# Thresholds (override via LITESOUP_WARN_* env vars)
WARN_LOAD_PER_CORE="${LITESOUP_WARN_LOAD_PER_CORE:-2.0}"
DANGER_LOAD_PER_CORE="${LITESOUP_DANGER_LOAD_PER_CORE:-4.0}"
WARN_RAM_PCT="${LITESOUP_WARN_RAM_PCT:-80}"
DANGER_RAM_PCT="${LITESOUP_DANGER_RAM_PCT:-95}"
WARN_DISK_PCT="${LITESOUP_WARN_DISK_PCT:-80}"
DANGER_DISK_PCT="${LITESOUP_DANGER_DISK_PCT:-95}"
WARN_SWAP_MB="${LITESOUP_WARN_SWAP_MB:-500}"
DANGER_SWAP_MB="${LITESOUP_DANGER_SWAP_MB:-2048}"
WARN_FPM_PCT="${LITESOUP_WARN_FPM_PCT:-80}"
WARN_CONNS="${LITESOUP_WARN_CONNS:-500}"

# Icons
if [ "${ASCII}" = "1" ]; then
  ICON_OK="[OK]"
  ICON_WARN="[!]"
  ICON_DANGER="[X]"
  ICON_FAIL="[--]"
else
  ICON_OK=""
  ICON_WARN="⚠️"
  ICON_DANGER="🚨"
  ICON_FAIL="❌"
fi

usage() {
  cat <<'EOF'
audit-status — single-line server health summary

Usage: bash audit-status.sh [options]

Options:
  --watch=N   Refresh every N seconds (Ctrl-C to stop)
  --verbose   Show additional detail (traffic, per-pool FPM, connections)
  --ascii     Use ASCII symbols instead of Unicode icons
  --help, -h  Show this help

Output format (single line):
  hostname | up Xd | CPU load | RAM X/Y | Disk X/Y | Sites N | alerts...

Thresholds (override via env vars):
  LITESOUP_WARN_LOAD_PER_CORE=2.0    LITESOUP_DANGER_LOAD_PER_CORE=4.0
  LITESOUP_WARN_RAM_PCT=80          LITESOUP_DANGER_RAM_PCT=95
  LITESOUP_WARN_DISK_PCT=80         LITESOUP_DANGER_DISK_PCT=95
  LITESOUP_WARN_SWAP_MB=500         LITESOUP_DANGER_SWAP_MB=2048
  LITESOUP_WARN_FPM_PCT=80
  LITESOUP_WARN_CONNS=500
EOF
}

# ---- helpers ----

_jv() { local v=${1:-null}; [ "${v}" = "null" ] && printf 'null' || printf '%s' "${v}"; }

_icon_for() {
  local val="$1" warn="$2" danger="$3"
  if awk "BEGIN{exit(!(${val} >= ${danger}))}" 2>/dev/null; then
    printf '%s' "${ICON_DANGER}"
  elif awk "BEGIN{exit(!(${val} >= ${warn}))}" 2>/dev/null; then
    printf '%s' "${ICON_WARN}"
  fi
}

_icon_bool() {
  local val="$1"
  [ "${val}" = "1" ] || [ "${val}" = "true" ] && printf '%s' "${ICON_FAIL}" || true
}

fmt_mb() {
  local kb="$1"
  if [ -z "${kb}" ] || [ "${kb}" = "null" ]; then echo "?"; return; fi
  awk "BEGIN{printf \"%.0f\", ${kb}/1024}"
}

fmt_gb() {
  local kb="$1"
  if [ -z "${kb}" ] || [ "${kb}" = "null" ]; then echo "?"; return; fi
  awk "BEGIN{printf \"%.1f\", ${kb}/1024/1024}"
}

fmt_pct() {
  local kb_used="$1" kb_total="$2"
  if [ -z "${kb_total}" ] || [ "${kb_total}" = "null" ] || [ "${kb_total}" = "0" ]; then echo "?"; return; fi
  awk "BEGIN{printf \"%.0f\", ${kb_used}/${kb_total}*100}"
}

fmt_uptime_days() {
  if [ ! -r /proc/uptime ]; then echo "?"; return; fi
  local up
  up="$(awk '{printf "%.0f", $1/86400}' /proc/uptime)"
  printf '%sd' "${up}"
}

# ---- main ----

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --watch=*)  WATCH="${arg#--watch=}" ;;
      --verbose)  VERBOSE=1 ;;
      --ascii)    ASCII=1 ;;
      --help|-h)  usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done

  local run=0
  while true; do
    [ "${run}" -gt 0 ] && sleep "${WATCH}"
    run=$((run + 1))
    [ "${WATCH}" -gt 0 ] && [ "${run}" -gt 1 ] && printf '\r' || printf '\n'

    # Collect metrics via JSON
    local json
    json="$(bash "${SCRIPT_DIR}/audit-system-metrics.sh" --format=json 2>/dev/null)" || {
      # Fallback if audit-system-metrics.sh doesn't support --format=json
      json='{"hostname":"unknown","cpu":{"cores":0,"load_1":0,"load_5":0,"load_15":0},"memory_kb":{"total":0,"used":0,"available":0,"swap_total":0,"swap_free":0},"disks":[],"network":{"interfaces":[]},"apache":{"installed":false},"php_fpm":{"versions":[],"pools":[]},"mariadb":{"installed":false},"redis":{"installed":false}}'
    }

    # Parse JSON with python3
    local line
    line="$(python3 -c "
import json, sys

d = json.loads('''${json}'''.strip())
warn_load = float('${WARN_LOAD_PER_CORE}')
danger_load = float('${DANGER_LOAD_PER_CORE}')
warn_ram = int('${WARN_RAM_PCT}')
danger_ram = int('${DANGER_RAM_PCT}')
warn_disk = int('${WARN_DISK_PCT}')
danger_disk = int('${DANGER_DISK_PCT}')
warn_swap = int('${WARN_SWAP_MB}')
danger_swap = int('${DANGER_SWAP_MB}')
warn_fpm = int('${WARN_FPM_PCT}')
warn_conns = int('${WARN_CONNS}')
verbose = ${VERBOSE}
ascii = ${ASCII}

parts = []

# Hostname
host = d.get('hostname', 'localhost')
parts.append(host)

# Uptime
try:
  with open('/proc/uptime') as f:
    up_secs = float(f.read().split()[0])
    parts.append(f'up {int(up_secs/86400)}d')
except:
  parts.append('up ?')

# CPU
cpu = d.get('cpu', {})
cores = cpu.get('cores', 0)
load1 = cpu.get('load_1', 0)
load_per_core = load1 / cores if cores > 0 else load1
if load_per_core >= danger_load:
  icon = '🚨' if not ascii else '[X]'
elif load_per_core >= warn_load:
  icon = '⚠️' if not ascii else '[!]'
else:
  icon = ''
parts.append(f'{icon}CPU {load1}')

# RAM
mem = d.get('memory_kb', {})
mem_total = int(mem.get('total', 0))
mem_used = int(mem.get('used', 0))
mem_avail = int(mem.get('available', 0))
if mem_total > 0:
  mem_used_gb = mem_used / 1024 / 1024
  mem_total_gb = mem_total / 1024 / 1024
  mem_pct = (mem_used / mem_total) * 100
  if mem_pct >= danger_ram:
    icon = '🚨' if not ascii else '[X]'
  elif mem_pct >= warn_ram:
    icon = '⚠️' if not ascii else '[!]'
  else:
    icon = ''
  parts.append(f'{icon}RAM {mem_used_gb:.1f}/{mem_total_gb:.1f}G')
else:
  parts.append('RAM ?')

# Swap
swap_total = int(mem.get('swap_total', 0))
swap_free = int(mem.get('swap_free', 0))
if swap_total > 0:
  swap_used_mb = (swap_total - swap_free) / 1024
  swap_total_mb = swap_total / 1024
  if swap_used_mb >= danger_swap:
    icon = '🚨' if not ascii else '[X]'
  elif swap_used_mb >= warn_swap:
    icon = '⚠️' if not ascii else '[!]'
  else:
    icon = ''
  parts.append(f'{icon}Swap {swap_used_mb:.0f}/{swap_total_mb:.0f}M')
elif verbose:
  parts.append('Swap 0')

# Disk (use highest %)
disks = d.get('disks', [])
max_disk_pct = 0
disk_str = ''
for disk in disks:
  pct = disk.get('use_pct', 0)
  if isinstance(pct, str) and pct.endswith('%'):
    pct = float(pct.rstrip('%'))
  elif isinstance(pct, (int, float)):
    pct = float(pct)
  else:
    continue
  if pct > max_disk_pct:
    max_disk_pct = pct
    sz_gb = int(disk.get('size_kb', 0)) / 1024 / 1024
    us_gb = int(disk.get('used_kb', 0)) / 1024 / 1024
    disk_str = f'{us_gb:.0f}/{sz_gb:.0f}G'

if max_disk_pct >= danger_disk:
  icon = '🚨' if not ascii else '[X]'
elif max_disk_pct >= warn_disk:
  icon = '⚠️' if not ascii else '[!]'
else:
  icon = ''
if disk_str:
  parts.append(f'{icon}Disk {disk_str}')

# Sites count
php_data = d.get('php_fpm', {})
pools = php_data.get('pools', [])
domains = len(pools)
parts.append(f'Sites {domains}')

# PHP versions
versions = php_data.get('versions', [])
if versions:
  parts.append(f'PHP {\",\".join(versions)}')

# FPM pool alerts
fpm_alerts = []
for pool in pools:
  active = pool.get('active', 0)
  # Estimate max_children from pool name convention — pools are small/medium/large
  tier_max = {'small': 5, 'medium': 20, 'large': 50}
  # Try to extract tier from pool name (username-phpX.Y format, can't derive tier)
  # Default to medium (20) as reasonable estimate
  max_ch = 20
  if active > 0 and max_ch > 0:
    pct = (active / max_ch) * 100
    if pct >= 80:
      fpm_alerts.append(f'FPM {pool.get(\"pool\",\"?\")} {pct:.0f}%')
if fpm_alerts and verbose:
  for a in fpm_alerts:
    parts.append(f'{a}')

# Connections
mariadb = d.get('mariadb', {})
conns = mariadb.get('threads_connected', 0) if mariadb.get('installed', False) else 0
# Apache connections
apache_busy = d.get('apache', {}).get('busy_workers', 0)
total_conns = 0
try:
  total_conns = int(conns) + int(apache_busy)
except:
  pass
if total_conns >= warn_conns:
  icon = '⚠️' if not ascii else '[!]'
  parts.append(f'{icon}Conn {total_conns}')

# Service status alerts
alerts = []
if d.get('mariadb', {}).get('installed') is False:
  pass  # not installed, skip
mariadb_conns = mariadb.get('threads_connected', 0) if mariadb.get('installed', False) else 0
if mariadb.get('installed', False) and mariadb_conns == 0 and mariadb.get('uptime', 0) > 0:
  alerts.append('MariaDB 0 conn')
if d.get('redis', {}).get('installed', False) and d['redis'].get('connected_clients', -1) == -1:
  alerts.append('Redis down')

# Traffic (verbose only)
if verbose:
  ifaces = d.get('network', {}).get('interfaces', [])
  for iface in ifaces:
    if iface.get('iface', '').startswith('eth') or iface.get('iface', '').startswith('ens'):
      rx = int(iface.get('rx_bytes', 0))
      tx = int(iface.get('tx_bytes', 0))
      parts.append(f'RX {rx/1024/1024:.0f}M TX {tx/1024/1024:.0f}M')
      break

# Append alerts
parts.extend(alerts)

print(' | '.join(parts))
" 2>&1)" || line="ERROR collecting metrics"

    printf '%s' "${line}"
    [ "${WATCH}" -le 0 ] && printf '\n' && break
  done
}

main "$@"
