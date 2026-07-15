#!/usr/bin/env bash
# backup/backup-stagger.sh — run staggered backups for all discovered sites.
#
# Executes backup-site.sh for each site under /home/*/webapps/ with a delay
# between each to prevent thundering herd on CPU, disk I/O, and MariaDB.
# Each backup process has a configurable timeout to prevent hung jobs from
# blocking subsequent runs.
#
# Usage: sudo bash backup-stagger.sh [options]
#
# Typically triggered by a single systemd timer litesoup-backup.timer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install/lib/common.sh
source "${SCRIPT_DIR}/../install/lib/common.sh"
# shellcheck source=../backup/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DELAY=60
BACKUP_TIMEOUT=300
S3=0
INCLUDE=""
EXCLUDE=""

usage() {
  cat <<'EOF'
litesoup backup-stagger — staggered multi-site backup

Usage: sudo bash backup-stagger.sh [options]

Automatically discovers all sites under /home/*/webapps/ and runs
backup-site.sh for each with a stagger delay to spread load.

Options:
  --delay=SEC         Seconds between each site backup start (default: 60)
  --timeout=SEC       Max seconds per backup-site.sh run (default: 300)
  --include=DOMAIN    Only back up these domains (comma-separated)
  --exclude=DOMAIN    Skip these domains (comma-separated)
  --s3                Also upload backups to S3
  --dry-run           Print actions without executing
  --help, -h          Show this help
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --delay=*)      DELAY="${arg#--delay=}" ;;
      --timeout=*)    BACKUP_TIMEOUT="${arg#--timeout=}" ;;
      --include=*)    INCLUDE="${arg#--include=}" ;;
      --exclude=*)    EXCLUDE="${arg#--exclude=}" ;;
      --s3)           S3=1 ;;
      --dry-run)      DRY_RUN=1 ;;
      --help|-h)      usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  # Discover sites: every directory under /home/*/webapps/ that has a
  # corresponding Apache vhost (named sites, not default).
  local -a sites=()
  while IFS= read -r -d '' dir; do
    local domain
    domain="$(basename "${dir}")"
    # Skip directories that don't look like fqdns
    case "${domain}" in
      *.*) ;;
      *) continue ;;
    esac
    # Apply include/exclude filters
    if [ -n "${INCLUDE}" ]; then
      local matched=0
      local inc
      for inc in ${INCLUDE//,/ }; do
        [ "${domain}" = "${inc}" ] && matched=1 && break
      done
      [ "${matched}" = "0" ] && continue
    fi
    if [ -n "${EXCLUDE}" ]; then
      local exc
      for exc in ${EXCLUDE//,/ }; do
        [ "${domain}" = "${exc}" ] && continue 2
      done
    fi
    sites+=("${domain}")
  done < <(find /home/*/webapps -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

  if [ "${#sites[@]}" -eq 0 ]; then
    log_info "backup-stagger: no sites found"
    exit 0
  fi

  log_info "backup-stagger: found ${#sites[@]} site(s): ${sites[*]}"
  local total_stagger=$(( (${#sites[@]} - 1) * DELAY ))
  log_info "backup-stagger: stagger delay=${DELAY}s, per-backup timeout=${BACKUP_TIMEOUT}s, total window=${total_stagger}s"

  local -a pids=()
  local i=0

  for domain in "${sites[@]}"; do
    local delay=$(( i * DELAY ))

    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] site ${domain}: would start backup after ${delay}s delay"
      ((i++))
      continue
    fi

    log_info "backup-stagger: QUEUE ${domain} (delayed ${delay}s)"
    (
      sleep "${delay}"
      local s3_flag=""
      [ "${S3}" = "1" ] && s3_flag=" --s3"
      # shellcheck disable=SC2086
      timeout "${BACKUP_TIMEOUT}" bash "${SCRIPT_DIR}/backup-site.sh" \
        --domain="${domain}"${s3_flag} \
        >> "/var/log/litesoup-backup.${domain}.log" 2>&1
      local ec=$?
      if [ "${ec}" -eq 124 ]; then
        log_error "backup-stagger: TIMEOUT ${domain} (exceeded ${BACKUP_TIMEOUT}s)"
      elif [ "${ec}" -ne 0 ]; then
        log_error "backup-stagger: FAIL ${domain} (exit ${ec})"
      else
        log_info "backup-stagger: DONE ${domain}"
      fi
    ) &
    pids+=($!)
    ((i++))
  done

  # Wait and show progress
  local done_count=0
  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
    done_count=$((done_count + 1))
    log_info "backup-stagger: progress ${done_count}/${#sites[@]}"
  done

  log_info "backup-stagger: COMPLETE (${done_count}/${#sites[@]} sites)"
}

main "$@"
