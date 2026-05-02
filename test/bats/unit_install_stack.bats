#!/usr/bin/env bats

load test_helper

@test "install-stack help mentions --php-versions" {
  run -0 bash "${REPO_ROOT}/install/install-stack.sh" --help
  assert_output --partial "--php-versions"
}

@test "install-stack rejects unsupported PHP version" {
  run -64 bash "${REPO_ROOT}/install/install-stack.sh" --php-versions=7.4 --dry-run
  assert_output --partial "unsupported PHP version: 7.4"
}

@test "install-stack rejects empty --php-versions" {
  run -64 bash "${REPO_ROOT}/install/install-stack.sh" --php-versions= --dry-run
  assert_output --partial "--php-versions"
}

@test "install-stack rejects malformed --php-versions" {
  run -64 bash "${REPO_ROOT}/install/install-stack.sh" --php-versions=8.2,, --dry-run
  assert_output --partial "--php-versions"
}

@test "install-stack rejects --php-versions missing default" {
  run -64 bash "${REPO_ROOT}/install/install-stack.sh" --php-versions=8.3,8.4 --dry-run
  assert_output --partial "must include the default PHP version"
}
