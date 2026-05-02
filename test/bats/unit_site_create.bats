#!/usr/bin/env bats

load test_helper

setup() {
  STUBS_DIR="${BATS_TEST_TMPDIR}"
  STUBS_FILE="${STUBS_DIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { echo "POOL: $*"; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/var/empty; }
write_vhost() { echo "VHOST: socket=$(php_fpm_socket_for_user "${SITE_USER}" "${PHP_VERSION}")"; }
download_wordpress() { :; }
STUBS
}

@test "site-create help mentions --php=X.Y" {
  run -0 bash "${REPO_ROOT}/site/site-create.sh" --help
  assert_output --partial "--php=X.Y"
}

@test "site-create rejects unsupported --php" {
  run -64 env LITESOUP_TEST_STUBS="${STUBS_FILE}" \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --php=7.4 --dry-run
  assert_output --partial "unsupported PHP version: 7.4"
}

@test "site-create defaults to PHP_VERSION_DEFAULT when --php omitted" {
  run -0 env LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test
  assert_output --partial "POOL: litesoup 8.2"
}

@test "site-create routes vhost socket to chosen --php" {
  run -0 env LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --php=8.4
  assert_output --partial "POOL: litesoup 8.4"
  assert_output --partial "php8.4-fpm.sock"
}
