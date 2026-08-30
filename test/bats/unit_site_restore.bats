#!/usr/bin/env bats
# Unit tests for site-restore.sh — focuses on pure functions and CLI parsing.
# Shell-out operations (wp, mariadb, s3cmd, tar, site-create/site-import) are
# covered by integration tests or acceptance on a real host.

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  printf 'require_root() { :; }\n' > "${STUBS_FILE}"
}

# Run site-restore with require_root stubbed so validation exit codes are reached.
run_restore() {
  run env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" \
    bash "${REPO_ROOT}/site/site-restore.sh" "$@"
}

# --- CLI: --help ---

@test "site-restore --help exits 0" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run -0 bash "${REPO_ROOT}/site/site-restore.sh" --help
  [[ "${output}" == *"litesoup site-restore"* ]]
}

# --- CLI: validation ---

@test "site-restore without --domain exits 64" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--domain is required"* ]]
}

@test "site-restore rejects invalid --source" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --domain=example.com --source=ftp --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--source must be one of: local, s3"* ]]
}

@test "site-restore rejects invalid --target" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --domain=example.com --target=clone --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--target must be one of: override, new"* ]]
}

@test "site-restore rejects invalid --framework" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --domain=example.com --framework=react --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--framework must be one of: wordpress, laravel, generic"* ]]
}

@test "site-restore rejects --skip-files and --skip-db together" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --domain=example.com --skip-files --skip-db --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"cannot both be set"* ]]
}

@test "site-restore --target=new requires --tls=letsencrypt to have --email" {
  if [ ! -f "${REPO_ROOT}/site/site-restore.sh" ]; then
    skip "site-restore.sh not available"
  fi
  run_restore --domain=example.com --target=new \
    --new-domain=staging.example.com --tls=letsencrypt --dry-run
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"--tls=letsencrypt requires --email"* ]]
}

# --- pure helpers ---

# Source the script's helper functions WITHOUT triggering main. The script
# defines main() near the bottom, so we truncate the source just before the
# `# ---- main` section and source the remainder (all helpers + defaults).
source_site_restore_helpers() {
  local helpers
  helpers="$(mktemp)"
  awk '/^# ---- main /{exit} {print}' "${REPO_ROOT}/site/site-restore.sh" \
    | sed 's#^REPO_ROOT="\$(cd "\${SCRIPT_DIR}/.." \&\& pwd)"#REPO_ROOT="${REPO_ROOT}"#' \
    > "${helpers}"
  source "${helpers}"
  rm -f "${helpers}"
}

@test "db_ident_for derives wp_<slug>_ identifier" {
  source_site_restore_helpers
  run db_ident_for "example"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wp_example_" ]]
}

@test "db_ident_for sanitises non-alphanumeric slugs" {
  source_site_restore_helpers
  run db_ident_for "my-site.name"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wp_my_site_name_" ]]
}

@test "detect_framework returns wordpress for wp-config.php" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  touch "${tmp}/wp-config.php"
  run detect_framework "${tmp}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wordpress" ]]
  rm -rf "${tmp}"
}

@test "detect_framework returns laravel for artisan" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  touch "${tmp}/artisan"
  run detect_framework "${tmp}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "laravel" ]]
  rm -rf "${tmp}"
}

@test "detect_framework returns generic for empty docroot" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  run detect_framework "${tmp}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "generic" ]]
  rm -rf "${tmp}"
}

@test "get_wp_db_name parses DB_NAME from wp-config.php" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  cat > "${tmp}/wp-config.php" <<'EOF'
<?php
define( 'DB_NAME', 'wp_example_' );
define( 'DB_USER', 'wp_example_' );
EOF
  run get_wp_db_name "${tmp}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wp_example_" ]]
  rm -rf "${tmp}"
}

@test "get_laravel_db_name parses DB_DATABASE from .env" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  printf 'DB_DATABASE=wp_example_\nDB_USERNAME=x\n' > "${tmp}/.env"
  run get_laravel_db_name "${tmp}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wp_example_" ]]
  rm -rf "${tmp}"
}

@test "detect_table_prefix_from_zst sniffs custom prefix" {
  source_site_restore_helpers
  local dump
  dump="$(mktemp)"
  printf 'CREATE TABLE `wprg_options` (\nCREATE TABLE `wprg_posts` (\n' | zstd -8 > "${dump}"
  run detect_table_prefix_from_zst "${dump}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wprg" ]]
  rm -f "${dump}"
}

@test "detect_table_prefix_from_zst defaults to wp" {
  source_site_restore_helpers
  local dump
  dump="$(mktemp)"
  printf 'SET NAMES utf8mb4;\n' | zstd -8 > "${dump}"
  run detect_table_prefix_from_zst "${dump}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "wp" ]]
  rm -f "${dump}"
}

@test "set_wp_table_prefix patches wp-config.php" {
  source_site_restore_helpers
  local tmp
  tmp="$(mktemp -d)"
  printf "<?php\n\$table_prefix = 'wp_';\n" > "${tmp}/wp-config.php"
  run set_wp_table_prefix "${tmp}" "wprg"
  [ "${status}" -eq 0 ]
  grep -qF '$table_prefix = "wprg_";' "${tmp}/wp-config.php"
  rm -rf "${tmp}"
}

# --- packaging ---

@test "site-restore.sh is executable" {
  [ -x "${REPO_ROOT}/site/site-restore.sh" ]
}

@test "backup/lib/s3.sh provides backup_s3_download" {
  grep -q 'backup_s3_download()' "${REPO_ROOT}/backup/lib/s3.sh"
}

@test "site-restore.sh handles --source=s3 and --target=new flags" {
  grep -q -- '--source=' "${REPO_ROOT}/site/site-restore.sh"
  grep -q -- '--target=new' "${REPO_ROOT}/site/site-restore.sh"
  grep -q -- '--new-domain=' "${REPO_ROOT}/site/site-restore.sh"
  grep -q -- '--git-repo=' "${REPO_ROOT}/site/site-restore.sh"
}