#!/usr/bin/env bats

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/apt.sh"
}

@test "is_pkg_installed returns 0 when dpkg-query reports installed" {
  dpkg-query() { echo "install ok installed"; return 0; }
  export -f dpkg-query
  run -0 is_pkg_installed bash
}

@test "is_pkg_installed returns 1 when dpkg-query reports not-installed" {
  dpkg-query() { return 1; }
  export -f dpkg-query
  run is_pkg_installed nonexistent-pkg
  [ "$status" -ne 0 ]
}

@test "ensure_pkgs is no-op when all packages installed" {
  is_pkg_installed() { return 0; }
  export -f is_pkg_installed
  apt_install() { echo "SHOULD NOT CALL"; return 1; }
  export -f apt_install
  run -0 ensure_pkgs foo bar
  refute_output --partial "SHOULD NOT CALL"
}
