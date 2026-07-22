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

@test "site-create defaults to --tier=medium" {
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
  assert_output --partial "POOL: litesoup 8.2 medium"
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

@test "create_database emits ALTER USER for idempotent password reset" {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
  source "${REPO_ROOT}/install/lib/php.sh"
  source "${REPO_ROOT}/install/lib/mariadb.sh"
  source "${REPO_ROOT}/site/_vhost_render.sh"

  # Stub mariadb_root to capture the SQL piped to it.
  mariadb_root() { cat > "${BATS_TEST_TMPDIR}/sql.captured"; }

  # Source site-create.sh's body without running main(); pull the function in.
  # site-create.sh runs `main "$@"` at the bottom -- we don't want that here,
  # so we source via a subshell trick: feed an exit before main.
  DOMAIN="example.test"
  SITE_USER="litesoup"
  DRY_RUN=0
  unset DB_NAME DB_USER DB_PASS

  # Pull just the create_database function definition out of site-create.sh.
  eval "$(awk '/^create_database\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"
  eval "$(awk '/^db_ident_for\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"

  create_database

  SQL="$(cat "${BATS_TEST_TMPDIR}/sql.captured")"
  [[ "${SQL}" == *"CREATE USER IF NOT EXISTS"* ]] || { echo "missing CREATE USER: ${SQL}"; return 1; }
  [[ "${SQL}" == *"ALTER USER"* ]] || { echo "missing ALTER USER: ${SQL}"; return 1; }
  [[ "${SQL}" == *"GRANT ALL PRIVILEGES"* ]] || { echo "missing GRANT: ${SQL}"; return 1; }
  # CREATE and ALTER must use the SAME password (avoid the v0.1 drift bug).
  CREATE_PW="$(echo "${SQL}" | grep CREATE | grep -oE "IDENTIFIED BY '[^']+'" | head -1)"
  ALTER_PW="$(echo  "${SQL}" | grep ALTER  | grep -oE "IDENTIFIED BY '[^']+'" | head -1)"
  [ "${CREATE_PW}" = "${ALTER_PW}" ] || { echo "CREATE/ALTER pw mismatch: ${CREATE_PW} vs ${ALTER_PW}"; return 1; }
}

@test "create_database reuses existing wp-config password end-to-end" {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
  source "${REPO_ROOT}/install/lib/php.sh"
  source "${REPO_ROOT}/install/lib/mariadb.sh"
  source "${REPO_ROOT}/site/_vhost_render.sh"

  mariadb_root() { cat > "${BATS_TEST_TMPDIR}/sql.captured"; }

  DOMAIN="example.test"
  SITE_USER="litesoup"
  DRY_RUN=0
  unset DB_NAME DB_USER DB_PASS

  # Plant a wp-config.php with a known DB_PASSWORD; the env override below
  # makes create_database read it instead of /home/...
  KNOWN_PW="ZeroOneTwoThreeFourFive99"
  TMPCFG="${BATS_TEST_TMPDIR}/wp-config.php"
  cat >"${TMPCFG}" <<PHP
<?php
define( 'DB_NAME',     'wp_example_test' );
define( 'DB_USER',     'wp_example_test' );
define( 'DB_PASSWORD', '${KNOWN_PW}' );
define( 'DB_HOST',     'localhost' );
PHP
  export LITESOUP_TEST_EXISTING_WP_CONFIG="${TMPCFG}"

  eval "$(awk '/^create_database\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"
  eval "$(awk '/^db_ident_for\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"

  create_database

  unset LITESOUP_TEST_EXISTING_WP_CONFIG

  # The captured SQL must use the wp-config password, not a freshly generated one.
  SQL="$(cat "${BATS_TEST_TMPDIR}/sql.captured")"
  [[ "${SQL}" == *"IDENTIFIED BY '${KNOWN_PW}'"* ]] \
    || { echo "expected reused pw '${KNOWN_PW}' in SQL, got: ${SQL}"; return 1; }
  # And DB_PASS must match what we planted -- not a regenerated value.
  [ "${DB_PASS}" = "${KNOWN_PW}" ] \
    || { echo "DB_PASS mismatch: got '${DB_PASS}', wanted '${KNOWN_PW}'"; return 1; }
}

@test "create_database refuses non-alphanumeric wp-config password (SQL injection guard)" {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
  source "${REPO_ROOT}/install/lib/php.sh"
  source "${REPO_ROOT}/install/lib/mariadb.sh"
  source "${REPO_ROOT}/site/_vhost_render.sh"

  mariadb_root() { cat > "${BATS_TEST_TMPDIR}/sql.captured"; }

  DOMAIN="example.test"
  SITE_USER="litesoup"
  DRY_RUN=0
  unset DB_NAME DB_USER DB_PASS

  # Hand-edited wp-config password containing a single quote -- if reused
  # verbatim, would break (or inject into) the SQL heredoc.
  EVIL_PW="hello'; DROP TABLE users;--"
  TMPCFG="${BATS_TEST_TMPDIR}/wp-config-evil.php"
  cat >"${TMPCFG}" <<PHP
<?php
define( 'DB_PASSWORD', '${EVIL_PW}' );
PHP
  export LITESOUP_TEST_EXISTING_WP_CONFIG="${TMPCFG}"

  eval "$(awk '/^create_database\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"
  eval "$(awk '/^db_ident_for\(\) \{/,/^\}/' "${REPO_ROOT}/site/site-create.sh")"

  create_database

  unset LITESOUP_TEST_EXISTING_WP_CONFIG

  SQL="$(cat "${BATS_TEST_TMPDIR}/sql.captured")"
  # The evil pw must NOT appear in the SQL.
  [[ "${SQL}" != *"DROP TABLE"* ]] || { echo "SQL injection NOT prevented: ${SQL}"; return 1; }
  [[ "${SQL}" != *"hello';"* ]]   || { echo "raw evil pw leaked into SQL: ${SQL}"; return 1; }
  # A fresh 24-char alphanumeric pw should have been generated instead.
  [ "${#DB_PASS}" -eq 24 ] \
    || { echo "expected 24-char generated pw, got '${DB_PASS}' (${#DB_PASS} chars)"; return 1; }
  [[ "${DB_PASS}" =~ ^[A-Za-z0-9]+$ ]] \
    || { echo "generated pw not alphanumeric: '${DB_PASS}'"; return 1; }
}
