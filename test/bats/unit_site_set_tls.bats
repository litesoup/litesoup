#!/usr/bin/env bats

load test_helper

@test "site-set-tls help mentions --tls and --email" {
  run -0 bash "${REPO_ROOT}/site/site-set-tls.sh" --help
  assert_output --partial "--tls="
  assert_output --partial "--email="
}

@test "site-set-tls --tls=letsencrypt requires --email" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tls.sh" --domain=example.test --tls=letsencrypt
  assert_output --partial "--tls=letsencrypt requires --email"
}

@test "site-set-tls --tls=self-signed calls certbot_self_signed" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
existing_site_owner() { echo "litesoup"; }
existing_site_php() { echo "8.2"; }
existing_site_docroot() { echo "/home/litesoup/webapps/example.test"; }
write_vhost() { echo "VHOST: tls=${TLS_MODE} domain=${DOMAIN} php=${PHP_VERSION}"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tls.sh" --domain=example.test --tls=self-signed
  assert_output --partial "SELFSIGNED: example.test"
  assert_output --partial "VHOST: tls=self-signed"
}

@test "site-set-tls rejects unknown domain" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
existing_site_owner() { return 1; }
STUBS
  run -1 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-tls.sh" --domain=nope.test --tls=self-signed
  assert_output --partial "site nope.test does not exist"
}
