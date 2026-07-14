#!/usr/bin/env bats
# Unit tests for backup scripts — focuses on pure functions
# (backup_timestamp, backup_validate_name, backup_size_human, etc.)
# and packaging correctness. Shell-out operations (wp, s3cmd, tar)
# are covered by integration tests or acceptance on a real host.

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
}

# --- backup/lib/common.sh: helper functions ---

@test "backup_timestamp outputs YYYY-MM-DD_HHMMSS format" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  local ts
  ts="$(backup_timestamp 2>/dev/null || true)"
  [[ "${ts}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]
}

@test "backup_validate_name accepts valid domain" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name "example.com"
  [ "${status}" -eq 0 ]
}

@test "backup_validate_name accepts single-label name" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name "myhost"
  [ "${status}" -eq 0 ]
}

@test "backup_validate_name rejects name with spaces" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name "bad name.com"
  [ "${status}" -eq 1 ]
}

@test "backup_validate_name rejects name starting with dot" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name ".hidden"
  [ "${status}" -eq 1 ]
}

@test "backup_validate_name rejects name ending with dot" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name "example.com."
  [ "${status}" -eq 1 ]
}

@test "backup_validate_name rejects empty string" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_validate_name ""
  [ "${status}" -eq 1 ]
}

@test "backup_size_human returns B for small files" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  local tmp
  tmp="$(mktemp)"
  printf 'x' > "${tmp}"
  local result
  result="$(backup_size_human "${tmp}" 2>/dev/null || true)"
  [[ "${result}" == "1 B" ]] || [[ "${result}" == "1 B" ]]
  rm -f "${tmp}"
}

@test "backup_size_human returns 0B for missing path" {
  source "${REPO_ROOT}/backup/lib/common.sh" 2>/dev/null || skip "backup/lib/common.sh not available"
  run backup_size_human "/nonexistent/path"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "0B" ]]
}

# --- backup-site.sh: --help ---

@test "backup-site --help exits 0" {
  if [ ! -f "${REPO_ROOT}/backup/backup-site.sh" ]; then
    skip "backup-site.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/backup/backup-site.sh" --help
  [[ "${output}" == *"litesoup backup-site"* ]]
}

@test "backup-site --dry-run without --domain fails with root error" {
  if [ ! -f "${REPO_ROOT}/backup/backup-site.sh" ]; then
    skip "backup-site.sh not available"
  fi
  run bash "${REPO_ROOT}/backup/backup-site.sh" --dry-run
  [[ "${output}" == *"must run as root"* ]]
  [ "${status}" -ne 0 ]
}

# --- backup-restore.sh: --help ---

@test "backup-restore --help exits 0" {
  if [ ! -f "${REPO_ROOT}/backup/backup-restore.sh" ]; then
    skip "backup-restore.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/backup/backup-restore.sh" --help
  [[ "${output}" == *"litesoup backup-restore"* ]]
}

# --- backup-list.sh: --help ---

@test "backup-list --help exits 0" {
  if [ ! -f "${REPO_ROOT}/backup/backup-list.sh" ]; then
    skip "backup-list.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/backup/backup-list.sh" --help
  [[ "${output}" == *"litesoup backup-list"* ]]
}

@test "backup-list --dry-run without --domain exits 64" {
  if [ ! -f "${REPO_ROOT}/backup/backup-list.sh" ]; then
    skip "backup-list.sh not available"
  fi
  run bash "${REPO_ROOT}/backup/backup-list.sh"
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--domain is required"* ]]
}

# --- backup-install.sh: --help ---

@test "backup-install --help exits 0" {
  if [ ! -f "${REPO_ROOT}/backup/backup-install.sh" ]; then
    skip "backup-install.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/backup/backup-install.sh" --help
  [[ "${output}" == *"litesoup backup-install"* ]]
}

# --- notify.sh: sanity check ---

@test "notify.sh sources without error" {
  if [ ! -f "${REPO_ROOT}/install/lib/notify.sh" ]; then
    skip "notify.sh not available"
  fi
  LITESOUP_NOTIFY_SH=""
  run bash -c "source \"${REPO_ROOT}/install/lib/notify.sh\"; echo OK"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "OK" ]]
}
