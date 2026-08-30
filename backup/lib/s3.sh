#!/usr/bin/env bash
# backup/lib/s3.sh — S3-compatible storage helpers for backup-*.sh scripts.
#
# Uses s3cmd (apt package) which works with AWS S3, IDrive e2, Backblaze B2,
# and any S3-compatible object store.
#
# Configuration is written by `litesoup backup configure` to
# /etc/litesoup/backup-s3.conf (mode 0600, root:root).
#
# Config format (shell-sourced):
#   S3_BUCKET=litesoup-backups
#   S3_ENDPOINT=https://e2.idy.idrivee2.com
#   S3_ACCESS_KEY=AKIAXXX
#   S3_SECRET_KEY=...
#   S3_REGION=us-east-1
#   S3_PREFIX=backups/

[ -n "${LITESOUP_BACKUP_S3_SH:-}" ] && return 0
LITESOUP_BACKUP_S3_SH=1

BACKUP_S3_CONF="/etc/litesoup/backup-s3.conf"

# backup_s3_ensure — install s3cmd and write a per-command .s3cfg from the
# config file. Returns 0 if S3 is usable, 1 if not configured.
backup_s3_ensure() {
  if [ ! -f "${BACKUP_S3_CONF}" ]; then
    log_warn "backup: S3 not configured — run 'litesoup backup configure' or create ${BACKUP_S3_CONF}"
    return 1
  fi

  # shellcheck disable=SC1090
  source "${BACKUP_S3_CONF}"

  : "${S3_BUCKET:?backup-s3: S3_BUCKET not set in ${BACKUP_S3_CONF}}"
  : "${S3_ENDPOINT:?backup-s3: S3_ENDPOINT not set in ${BACKUP_S3_CONF}}"
  : "${S3_ACCESS_KEY:?backup-s3: S3_ACCESS_KEY not set in ${BACKUP_S3_CONF}}"
  : "${S3_SECRET_KEY:?backup-s3: S3_SECRET_KEY not set in ${BACKUP_S3_CONF}}"

  if ! command -v s3cmd &>/dev/null; then
    log_info "backup: installing s3cmd"
    ensure_pkgs s3cmd
  fi

  return 0
}

# backup_s3_cfg_dir — returns a stable temp dir for the per-command .s3cfg.
_backup_s3_cfg_dir() {
  local d="/tmp/litesoup-s3cfg"
  mkdir -p "${d}"
  chmod 0700 "${d}"
  printf '%s' "${d}"
}

# backup_s3_cfg — writes a temporary .s3cfg for one s3cmd invocation and
# prints its path. Ensures credentials never leak into a shared ~/.s3cfg.
_backup_s3_cfg() {
  # shellcheck disable=SC1090
  source "${BACKUP_S3_CONF}"
  local dir
  dir="$(_backup_s3_cfg_dir)"
  local cfg="${dir}/$$.cfg"
  cat > "${cfg}" <<EOF
[default]
access_key = ${S3_ACCESS_KEY}
secret_key = ${S3_SECRET_KEY}
host_base = ${S3_ENDPOINT#https://}
host_bucket = ${S3_BUCKET}.${S3_ENDPOINT#https://}
bucket_location = ${S3_REGION:-us-east-1}
use_https = true
signature_v2 = false
gpg_passphrase =
EOF
  chmod 0600 "${cfg}"
  printf '%s' "${cfg}"
}

# _backup_s3_cleanup — remove temp .s3cfg files older than 1 hour.
_backup_s3_cleanup() {
  find /tmp/litesoup-s3cfg -type f -mmin +60 -delete 2>/dev/null || true
}

# backup_s3_upload LOCAL_PATH REMOTE_PATH — upload a file to S3.
# REMOTE_PATH is relative to S3_PREFIX (e.g. "example.com/2026-07-14_120000/").
backup_s3_upload() {
  local local_path="${1:?backup_s3_upload: local_path required}"
  local remote_path="${2:?backup_s3_upload: remote_path required}"

  backup_s3_ensure || return 1

  if [ ! -f "${local_path}" ] && [ ! -d "${local_path}" ]; then
    log_error "backup: local path not found: ${local_path}"
    return 1
  fi

  # shellcheck disable=SC1090
  source "${BACKUP_S3_CONF}"
  local remote_key="${S3_PREFIX}${remote_path}"
  local cfg
  cfg="$(_backup_s3_cfg)"
  # shellcheck disable=SC2064 # cfg expands at trap time intentionally
  trap "_backup_s3_cleanup; rm -f '${cfg}'" RETURN

  log_info "backup: uploading ${local_path} → s3://${S3_BUCKET}/${remote_key}"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would s3cmd --config=${cfg} put ${local_path} s3://${S3_BUCKET}/${remote_key}"
    return 0
  fi

  s3cmd --config="${cfg}" put "${local_path}" "s3://${S3_BUCKET}/${remote_key}" 2>/dev/null || {
    log_error "backup: s3 upload failed for ${local_path}"
    return 1
  }
  log_info "backup: upload complete"
}

# backup_s3_list PREFIX — list remote backups for a domain.
# Returns lines of "SIZE\tKEY" format.
backup_s3_list() {
  local prefix="${1:?backup_s3_list: prefix required}"

  backup_s3_ensure || return 1

  # shellcheck disable=SC1090
  source "${BACKUP_S3_CONF}"
  local remote_prefix="${S3_PREFIX}${prefix}"
  local cfg
  cfg="$(_backup_s3_cfg)"
  # shellcheck disable=SC2064 # cfg expands at trap time intentionally
  trap "_backup_s3_cleanup; rm -f '${cfg}'" RETURN

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would s3cmd --config=${cfg} ls s3://${S3_BUCKET}/${remote_prefix}"
    return 0
  fi

  s3cmd --config="${cfg}" ls "s3://${S3_BUCKET}/${remote_prefix}" 2>/dev/null | awk '{print $1 "\t" $4}' || true
}

# backup_s3_download REMOTE_KEY LOCAL_PATH — download a file from S3.
# REMOTE_KEY is the full object key INCLUDING S3_PREFIX (i.e. the KEY column
# returned by backup_s3_list), e.g. "backups/example.com/2026-07-14_120000/database.sql.zst".
# LOCAL_PATH is the destination file (parent dir must exist).
backup_s3_download() {
  local remote_key="${1:?backup_s3_download: remote_key required}"
  local local_path="${2:?backup_s3_download: local_path required}"

  backup_s3_ensure || return 1

  # shellcheck disable=SC1090
  source "${BACKUP_S3_CONF}"
  local cfg
  cfg="$(_backup_s3_cfg)"
  # shellcheck disable=SC2064 # cfg expands at trap time intentionally
  trap "_backup_s3_cleanup; rm -f '${cfg}'" RETURN

  log_info "backup: downloading s3://${S3_BUCKET}/${remote_key} → ${local_path}"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would s3cmd --config=${cfg} get s3://${S3_BUCKET}/${remote_key} ${local_path}"
    return 0
  fi

  s3cmd --config="${cfg}" get "s3://${S3_BUCKET}/${remote_key}" "${local_path}" 2>/dev/null || {
    log_error "backup: s3 download failed for ${remote_key}"
    return 1
  }
  log_info "backup: download complete (${local_path})"
}
