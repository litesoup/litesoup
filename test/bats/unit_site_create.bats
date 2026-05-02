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
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --php=7.4 --dry-run
  assert_output --partial "unsupported PHP version: 7.4"
}

@test "site-create defaults to PHP_VERSION_DEFAULT when --php omitted" {
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test
  assert_output --partial "POOL: litesoup 8.2"
}

@test "site-create routes vhost socket to chosen --php" {
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --php=8.4
  assert_output --partial "POOL: litesoup 8.4"
  assert_output --partial "php8.4-fpm.sock"
}

@test "site-create defaults to --tls=none (back-compat)" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { :; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/var/empty; }
write_vhost() { echo "VHOST: tls=${TLS_MODE}"; }
download_wordpress() { :; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test
  assert_output --partial "VHOST: tls=none"
  refute_output --partial "OBTAIN:"
  refute_output --partial "SELFSIGNED:"
}

@test "site-create --tls=letsencrypt requires --email" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tls=letsencrypt
  assert_output --partial "--tls=letsencrypt requires --email"
}

@test "site-create --tls=letsencrypt with --email calls certbot_obtain" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { :; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/home/litesoup/webapps/example.test; }
write_vhost() { echo "VHOST: tls=${TLS_MODE}"; }
download_wordpress() { :; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tls=letsencrypt --email=ops@example.test
  assert_output --partial "OBTAIN: example.test ops@example.test"
  assert_output --partial "VHOST: tls=letsencrypt"
}

@test "site-create --tls=self-signed calls certbot_self_signed" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { :; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/var/empty; }
write_vhost() { echo "VHOST: tls=${TLS_MODE}"; }
download_wordpress() { :; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tls=self-signed
  assert_output --partial "SELFSIGNED: example.test"
  assert_output --partial "VHOST: tls=self-signed"
  refute_output --partial "OBTAIN:"
}

@test "site-create --tls=garbage rejected" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tls=garbage
  assert_output --partial "--tls must be one of: letsencrypt, self-signed, none"
}

@test "site-create help mentions --tls and --email" {
  run -0 bash "${REPO_ROOT}/site/site-create.sh" --help
  assert_output --partial "--tls="
  assert_output --partial "--email="
}

@test "site-create defaults to --tier=small" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { echo "POOL: $*"; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/var/empty; }
write_vhost() { :; }
download_wordpress() { :; }
certbot_obtain() { :; }
certbot_self_signed() { :; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test
  assert_output --partial "POOL: litesoup 8.2 small"
}

@test "site-create --tier=medium passes through to ensure_php_pool_for_user" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
ensure_user() { :; }
ensure_php_pool_for_user() { echo "POOL: $*"; }
create_database() { DB_NAME=db; DB_USER=u; DB_PASS=p; }
create_docroot() { DOCROOT=/var/empty; }
write_vhost() { :; }
download_wordpress() { :; }
certbot_obtain() { :; }
certbot_self_signed() { :; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tier=medium
  assert_output --partial "POOL: litesoup 8.2 medium"
}

@test "site-create --tier=garbage rejected" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
STUBS
  run -64 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-create.sh" --domain=example.test --tier=garbage
  assert_output --partial "--tier must be one of: small, medium, large"
}

@test "site-create help mentions --tier" {
  run -0 bash "${REPO_ROOT}/site/site-create.sh" --help
  assert_output --partial "--tier="
}
