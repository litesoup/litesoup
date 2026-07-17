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
      json='{"hostname":"unknown","cpu":{"cores":0,"load_1":0},"memory_kb":{"total":0,"used":0,"swap_total":0,"swap_free":0},"disks":[],"network":{"interfaces":[]},"apache":{"installed":false},"php_fpm":{"versions":[],"pools":[]},"mariadb":{"installed":false},"redis":{"installed":false}}'
    }

    # Parse JSON with python3 via stdin
    local py_script py_out
    py_script="$(mktemp /tmp/litesoup-status.XXXXXX.py)"
    # Export thresholds as env vars for Python to read
    export WARN_LOAD_PER_CORE DANGER_LOAD_PER_CORE
    export WARN_RAM_PCT DANGER_RAM_PCT
    export WARN_DISK_PCT DANGER_DISK_PCT
    export WARN_SWAP_MB DANGER_SWAP_MB
    export WARN_CONNS
    export VERBOSE ASCII
    cat > "${py_script}" << 'PYEOF'
import json, sys, os

d = json.load(sys.stdin)
wl = float(os.environ.get('WARN_LOAD_PER_CORE', '2.0'))
dl = float(os.environ.get('DANGER_LOAD_PER_CORE', '4.0'))
wr = int(os.environ.get('WARN_RAM_PCT', '80'))
dr = int(os.environ.get('DANGER_RAM_PCT', '95'))
wdsk = int(os.environ.get('WARN_DISK_PCT', '80'))
ddsk = int(os.environ.get('DANGER_DISK_PCT', '95'))
ws = int(os.environ.get('WARN_SWAP_MB', '500'))
ds = int(os.environ.get('DANGER_SWAP_MB', '2048'))
wc = int(os.environ.get('WARN_CONNS', '500'))
vb = int(os.environ.get('VERBOSE', '0'))
ac = int(os.environ.get('ASCII', '0'))

W = chr(0x26a0)+chr(0xfe0f) if not ac else '[!]'
D = chr(0x1f6a8) if not ac else '[X]'

p = []
p.append(d.get('hostname','?'))
try:
  with open('/proc/uptime') as f:
    s = float(f.read().split()[0])
    p.append('up %dd' % int(s/86400))
except:
  p.append('up ?')

c = d.get('cpu',{})
co = c.get('cores',0) or 1
l1 = c.get('load_1',0)
lp = l1/co
ic = D if lp >= dl else (W if lp >= wl else '')
p.append('%sCPU %s' % (ic, l1))

m = d.get('memory_kb',{})
mt = int(m.get('total',0))
mu = int(m.get('used',0))
if mt>0:
  mp = (mu/mt)*100
  ic = D if mp >= dr else (W if mp >= wr else '')
  p.append('%sRAM %.1f/%.1fG' % (ic, mu/1024/1024, mt/1024/1024))
st = int(m.get('swap_total',0))
sf = int(m.get('swap_free',0))
if st>0:
  su = (st-sf)/1024
  ic = D if su >= ds else (W if su >= ws else '')
  p.append('%sSwap %.0f/%.0fM' % (ic, su, st/1024))

dsks = d.get('disks',[])
mdp = 0
ds = ''
for disk in dsks:
  pct = disk.get('use_pct',0)
  if isinstance(pct,(int,float)) and pct > mdp:
    mdp = pct
    ds = '%.0f/%.0fG' % (int(disk.get('used_kb',0))/1024/1024, int(disk.get('size_kb',0))/1024/1024)
ic = D if mdp >= ddsk else (W if mdp >= wdsk else '')
if ds: p.append('%sDisk %s' % (ic, ds))

fp = d.get('php_fpm',{})
p.append('Sites %d' % len(fp.get('pools',[])))
vs = fp.get('versions',[])
if vs: p.append('PHP %s' % ','.join(vs))

md = d.get('mariadb',{})
conn = int(md.get('threads_connected',0) or 0) + int(d.get('apache',{}).get('busy_workers',0) or 0)
if conn >= wc: p.append('%sConn %d' % (W, conn))

if vb:
  for iface in d.get('network',{}).get('interfaces',[]):
    n = iface.get('iface','')
    if n.startswith('eth') or n.startswith('ens'):
      rx = int(iface.get('rx_bytes',0))/1024/1024
      tx = int(iface.get('tx_bytes',0))/1024/1024
      p.append('RX %.0fM TX %.0fM' % (rx, tx))
      break

print(' | '.join(p))
PYEOF
    py_out="$(printf '%s' "${json}" | python3 "${py_script}" 2>&1)" || py_out="ERROR collecting metrics"
    rm -f "${py_script}"
    local line="${py_out}"

    printf '%s' "${line}"
    [ "${WATCH}" -le 0 ] && printf '\n' && break
  done
}

main "$@"
