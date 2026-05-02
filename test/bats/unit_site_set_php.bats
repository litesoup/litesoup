#!/usr/bin/env bats

load test_helper

@test "site-set-php help mentions --php" {
  run -0 bash "${REPO_ROOT}/site/site-set-php.sh" --help
  assert_output --partial "--php="
}

@test "site-set-php requires --domain" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-php.sh" --php=8.4
  assert_output --partial "--domain is required"
}

@test "site-set-php requires --php" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-php.sh" --domain=example.test
  assert_output --partial "--php is required"
}

@test "site-set-php rejects unsupported --php version" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-php.sh" --domain=example.test --php=7.4
  assert_output --partial "unsupported PHP version: 7.4"
}

@test "site-set-php rejects unknown domain" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
existing_site_owner() { return 1; }
STUBS
  run -1 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-php.sh" --domain=nope.test --php=8.4
  assert_output --partial "site nope.test does not exist"
}

@test "site-set-php calls ensure_php_pool_for_user with new version" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
existing_site_owner()   { echo "litesoup"; }
existing_site_php()     { echo "8.2"; }
existing_site_docroot() { echo "/home/litesoup/webapps/example.test"; }
ensure_php_pool_for_user() { echo "POOL: $*"; }
write_vhost() { echo "VHOST: domain=${DOMAIN} php=${PHP_VERSION}"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-php.sh" --domain=example.test --php=8.4
  assert_output --partial "POOL: litesoup 8.4"
  assert_output --partial "VHOST: domain=example.test php=8.4"
}
