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
