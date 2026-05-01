#!/usr/bin/env bats

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/apt.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
}

@test "DEFAULT_SITE_USER is litesoup" {
  [ "${DEFAULT_SITE_USER}" = "litesoup" ]
}

@test "ensure_user is no-op when user exists (dry-run shows no useradd)" {
  id() { return 0; }
  export -f id
  DRY_RUN=1 run -0 ensure_user fakeuser 2>&1
  refute_output --partial "useradd"
}

@test "ensure_user calls useradd when user missing (dry-run)" {
  id() { return 1; }
  export -f id
  DRY_RUN=1 run -0 ensure_user newuser 2>&1
  assert_output --partial "useradd"
  assert_output --partial "newuser"
}
