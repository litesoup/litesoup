#!/usr/bin/env bats

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/apt.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
  source "${REPO_ROOT}/install/lib/php.sh"
}

@test "SUPPORTED_PHP_VERSIONS contains 8.0 through 8.5" {
  for v in 8.0 8.1 8.2 8.3 8.4 8.5; do
    [[ " ${SUPPORTED_PHP_VERSIONS[*]} " == *" ${v} "* ]] \
      || { echo "missing ${v} in SUPPORTED_PHP_VERSIONS"; return 1; }
  done
}

@test "PHP_VERSION_DEFAULT remains 8.2" {
  [ "${PHP_VERSION_DEFAULT}" = "8.2" ]
}

@test "validate_php_version accepts supported versions" {
  run -0 validate_php_version "8.3"
}

@test "validate_php_version rejects unsupported versions" {
  run -1 validate_php_version "7.4"
  run -1 validate_php_version "9.0"
  run -1 validate_php_version "garbage"
}

@test "php_fpm_socket_for_user encodes version" {
  [ "$(php_fpm_socket_for_user alice 8.3)" = "/run/php/alice-php8.3-fpm.sock" ]
  [ "$(php_fpm_socket_for_user bob 8.0)"   = "/run/php/bob-php8.0-fpm.sock" ]
}

@test "ensure_php_fpm rejects unsupported version" {
  run -1 ensure_php_fpm "7.4"
}

@test "ensure_php_fpm dry-run installs version-specific packages" {
  ensure_ppa() { :; }
  ensure_pkgs() { local p; for p in "$@"; do echo "PKGS: $p"; done; }
  run_or_dryrun() { echo "RUN: $*"; }
  export -f ensure_ppa ensure_pkgs run_or_dryrun
  DRY_RUN=1 run -0 ensure_php_fpm "8.3"
  assert_output --partial "PKGS: php8.3-fpm"
  assert_output --partial "PKGS: php8.3-cli"
  assert_output --partial "RUN: systemctl enable --now php8.3-fpm"
  refute_output --partial "php8.2-fpm"
}

@test "ensure_php_82_fpm shim still works (deprecated)" {
  ensure_ppa() { :; }
  ensure_pkgs() { local p; for p in "$@"; do echo "PKGS: $p"; done; }
  run_or_dryrun() { echo "RUN: $*"; }
  export -f ensure_ppa ensure_pkgs run_or_dryrun
  DRY_RUN=1 run -0 ensure_php_82_fpm
  assert_output --partial "PKGS: php8.2-fpm"
}

@test "ensure_php_pool_for_user rejects unsupported version" {
  ensure_user() { :; }; export -f ensure_user
  run -1 ensure_php_pool_for_user alice "7.4"
}

@test "ensure_php_pool_for_user dry-run renders version-specific pool" {
  ensure_user() { :; }; export -f ensure_user
  systemctl() { echo "SYSTEMCTL: $*"; }; export -f systemctl
  log_info() { echo "INFO: $*"; }; export -f log_info

  DRY_RUN=1 run -0 ensure_php_pool_for_user alice "8.3"
  assert_output --partial "INFO: php: creating pool alice-php8.3"
  assert_output --partial "/run/php/alice-php8.3-fpm.sock"
  refute_output --partial "alice-php8.2"
}

@test "ensure_php_82_pool_for_user shim still works (deprecated)" {
  ensure_user() { :; }; export -f ensure_user
  log_info() { echo "INFO: $*"; }; export -f log_info

  DRY_RUN=1 run -0 ensure_php_82_pool_for_user alice
  assert_output --partial "alice-php8.2"
}
