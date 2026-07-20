#!/usr/bin/env bash
# backup/backup-install.sh — one-time backup system setup for litesoup.
#
# Creates directory structure, installs systemd timer units, and generates
# config templates. Run after install-stack.sh completes.
#
# Usage:
#   sudo bash backup/backup-install.sh [--email=ADDR] [--s3-key=KEY --s3-secret=SEC ...]
#
# Options:
#   --email=ADDR        Notification email recipient (creates notify-email.conf).
#   --s3-bucket=NAME    S3 bucket name.
#   --s3-endpoint=URL   S3 endpoint URL (e.g. https://s3.amazonaws.com).
#   --s3-key=KEY        S3 access key.
#   --s3-secret=SEC     S3 secret key.
#   --s3-region=REGION  S3 region (default: us-east-1).
#   --s3-prefix=PREFIX  S3 key prefix (default: backups/).
#   --dry-run           Preview without executing.
#   --help              Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/notify.sh
source "${REPO_ROOT}/install/lib/notify.sh"

LITESOUP_LIB="/usr/lib/litesoup"
BACKUP_CONF_DIR="/etc/litesoup"
NOTIFY_EMAIL_CONF="${BACKUP_CONF_DIR}/notify-email.conf"
S3_CONF="${BACKUP_CONF_DIR}/backup-s3.conf"

NOTIFY_EMAIL=""
S3_BUCKET=""
S3_ENDPOINT="https://s3.amazonaws.com"
S3_KEY=""
S3_SECRET=""
S3_REGION="us-east-1"
S3_PREFIX="backups/"

usage() {
  cat <<'EOF'
litesoup backup-install — set up the backup system on this host

Usage: sudo bash backup/backup-install.sh [options]

Options:
  --email=ADDR         Notification email recipient.
  --s3-bucket=NAME     S3 bucket name.
  --s3-endpoint=URL    S3 endpoint URL (default: https://s3.amazonaws.com).
  --s3-key=KEY         S3 access key.
  --s3-secret=SEC      S3 secret key.
  --s3-region=REGION   S3 region (default: us-east-1).
  --s3-prefix=PREFIX   S3 key prefix (default: backups/).
  --dry-run            Preview without executing.
  --help, -h           Show this help.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --email=*)        NOTIFY_EMAIL="${arg#*=}" ;;
      --s3-bucket=*)    S3_BUCKET="${arg#*=}" ;;
      --s3-endpoint=*)  S3_ENDPOINT="${arg#*=}" ;;
      --s3-key=*)       S3_KEY="${arg#*=}" ;;
      --s3-secret=*)    S3_SECRET="${arg#*=}" ;;
      --s3-region=*)    S3_REGION="${arg#*=}" ;;
      --s3-prefix=*)    S3_PREFIX="${arg#*=}" ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  log_info "backup-install: setting up litesoup backup system"

  # 1. Ensure config directory exists
  run_or_dryrun mkdir -p "${BACKUP_CONF_DIR}"

  # 2. Write notification config
  if [ -n "${NOTIFY_EMAIL}" ]; then
    log_info "backup-install: configuring email notification -> ${NOTIFY_EMAIL}"
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would write ${NOTIFY_EMAIL_CONF} with: ${NOTIFY_EMAIL}"
    else
      printf '%s\n' "${NOTIFY_EMAIL}" > "${NOTIFY_EMAIL_CONF}"
      chmod 0600 "${NOTIFY_EMAIL_CONF}"
    fi
  fi

  # 3. Write S3 config (if bucket provided)
  if [ -n "${S3_BUCKET}" ]; then
    if [ -z "${S3_KEY}" ] || [ -z "${S3_SECRET}" ]; then
      log_error "backup-install: --s3-key and --s3-secret are required when --s3-bucket is set"
      exit 64
    fi
    log_info "backup-install: configuring S3 backup -> s3://${S3_BUCKET}/${S3_PREFIX}"
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would write ${S3_CONF} with S3 credentials (mode 0600)"
    else
      cat > "${S3_CONF}" <<S3EOF
# litesoup S3 backup config — managed by backup/backup-install.sh
# Mode 0600 — contains credentials.
S3_BUCKET=${S3_BUCKET}
S3_ENDPOINT=${S3_ENDPOINT}
S3_ACCESS_KEY=${S3_KEY}
S3_SECRET_KEY=${S3_SECRET}
S3_REGION=${S3_REGION}
S3_PREFIX=${S3_PREFIX}
S3EOF
      chmod 0600 "${S3_CONF}"
      log_info "backup-install: S3 config written to ${S3_CONF}"
    fi
  fi

  # 4. Copy backup scripts to /usr/lib/litesoup/backup/ (skip when already
  #    installed — running from the installed directory makes source and
  #    destination the same file, which `install` refuses).
  local backup_src
  backup_src="$(cd "${REPO_ROOT}/backup" && pwd)"
  local backup_dst="${LITESOUP_LIB}/backup"
  if [ "${backup_src}" = "$(cd "${backup_dst}" 2>/dev/null && pwd || echo '')" ]; then
    log_info "backup-install: already installed — skipping script copy"
  else
    log_info "backup-install: installing backup scripts to ${backup_dst}/"
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would install backup/*.sh -> ${backup_dst}/"
    else
      run_or_dryrun mkdir -p "${backup_dst}/lib"
      for f in "${REPO_ROOT}/backup/"*.sh; do
        run_or_dryrun install -m 0755 "${f}" "${backup_dst}/"
      done
      for f in "${REPO_ROOT}/backup/lib/"*.sh; do
        run_or_dryrun install -m 0644 "${f}" "${backup_dst}/lib/"
      done
      run_or_dryrun install -m 0644 "${REPO_ROOT}/install/lib/notify.sh" "${LITESOUP_LIB}/install/lib/"
    fi
  fi

  # 5. Create backup directories for existing site users
  log_info "backup-install: ensuring backup dirs for existing site users..."
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would iterate /home/*/ and create /home/*/backups/"
  else
    for user_home in /home/*/webapps/; do
      local user
      user="$(basename "$(dirname "${user_home}")")"
      run_or_dryrun mkdir -p "/home/${user}/backups"
      run_or_dryrun chmod 0700 "/home/${user}/backups"
    done
  fi

  # 6. Install systemd timer templates
  log_info "backup-install: installing systemd units"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would install systemd units for litesoup-backup@.service and .timer"
  else
    mkdir -p /etc/systemd/system

    cat > /etc/systemd/system/litesoup-backup@.service <<'SERVICEEOF'
[Unit]
Description=litesoup backup for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/litesoup/backup/backup-site.sh --domain=%i
User=root
SERVICEEOF

    cat > /etc/systemd/system/litesoup-backup@.timer <<'TIMEREOF'
[Unit]
Description=Daily litesoup backup for %i

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

    systemctl daemon-reload 2>/dev/null || true
    log_info "backup-install: systemd units installed"
  fi

  log_info "backup-install: COMPLETE"
  log_info "backup-install: to enable daily backup for a site:"
  log_info "  systemctl enable --now litesoup-backup@example.com.timer"
  log_info "backup-install: to run a backup immediately:"
  log_info "  systemctl start litesoup-backup@example.com"
  log_info "backup-install: or manually:"
  log_info "  sudo bash /usr/lib/litesoup/backup/backup-site.sh --domain=example.com"
}

main "$@"
