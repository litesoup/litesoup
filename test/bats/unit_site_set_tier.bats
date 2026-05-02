#!/usr/bin/env bats

load test_helper

@test "site-set-tier help mentions --user, --version, --tier" {
  run -0 bash "${REPO_ROOT}/site/site-set-tier.sh" --help
  assert_output --partial "--user="
  assert_output --partial "--version="
  assert_output --partial "--tier="
}

@test "site-set-tier requires --user" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tier.sh" --version=8.2 --tier=medium
  assert_output --partial "--user is required"
}

@test "site-set-tier requires --version" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tier.sh" --user=alice --tier=medium
  assert_output --partial "--version is required"
}

@test "site-set-tier requires --tier" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tier.sh" --user=alice --version=8.2
  assert_output --partial "--tier is required"
}

@test "site-set-tier rejects unsupported tier" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tier.sh" --user=alice --version=8.2 --tier=huge
  assert_output --partial "--tier must be one of: small, medium, large"
}

@test "site-set-tier calls ensure_php_pool_for_user with all three args" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_php_pool_for_user() { echo "POOL: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tier.sh" --user=alice --version=8.2 --tier=large
  assert_output --partial "POOL: alice 8.2 large"
}
