#!/usr/bin/env bats

load test_helper

@test "smoke: bats helpers load" {
  assert_equal "1" "1"
}

@test "smoke: REPO_ROOT resolves" {
  [ -d "${REPO_ROOT}" ]
  [ -f "${REPO_ROOT}/README.md" ]
}
