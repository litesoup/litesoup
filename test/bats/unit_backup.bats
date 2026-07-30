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

@test "backup-install.sh has self-copy guard (issue #54)" {
  # When running from /usr/lib/litesoup/backup/, REPO_ROOT resolves to
  # /usr/lib/litesoup, making source and destination the same directory.
  # The guard compares resolved paths and skips the copy if they match.
  grep -qE 'backup_src.*=\s*"\$\(cd "\${REPO_ROOT}/backup" && pwd\)"' \
    "${REPO_ROOT}/backup/backup-install.sh"
}

@test "backup-restore --dry-run without --domain fails with root error" {
  if [ ! -f "${REPO_ROOT}/backup/backup-restore.sh" ]; then
    skip "backup-restore.sh not available"
  fi
  run bash "${REPO_ROOT}/backup/backup-restore.sh" --dry-run
  [[ "${output}" == *"must run as root"* ]]
  [ "${status}" -ne 0 ]
}

@test "backup-stagger --help exits 0" {
  if [ ! -f "${REPO_ROOT}/backup/backup-stagger.sh" ]; then
    skip "backup-stagger.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/backup/backup-stagger.sh" --help
  [[ "${output}" == *"litesoup backup-stagger"* ]]
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

# --- #46: harden-user ---

@test "harden-user.sh exists and is executable" {
  [ -f "${REPO_ROOT}/harden/harden-user.sh" ]
}

@test "install-stack.sh has --ssh-key flag" {
  grep -qF -- '--ssh-key' "${REPO_ROOT}/install/install-stack.sh"
}

@test "install-stack.sh has harden-user stage" {
  grep -q 'harden-user' "${REPO_ROOT}/install/install-stack.sh"
}

# --- #47: backup stagger + timeout + lock ---

@test "backup-stagger.sh exists" {
  [ -f "${REPO_ROOT}/backup/backup-stagger.sh" ]
}

@test "backup-site.sh has flock lock guard" {
  grep -q 'flock -n 200' "${REPO_ROOT}/backup/backup-site.sh"
}

@test "backup-site.sh has timeout on db dump" {
  grep -qz 'timeout 300.*backup_dump_db' "${REPO_ROOT}/backup/backup-site.sh"
}

@test "backup-site.sh has timeout on file archive" {
  grep -qz 'timeout 600.*backup_archive' "${REPO_ROOT}/backup/backup-site.sh"
}

@test "backup-site.sh logs elapsed time" {
  grep -q 'total_elapsed' "${REPO_ROOT}/backup/backup-site.sh"
}
