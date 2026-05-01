#!/usr/bin/env bats

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
}

@test "log_info prints to stderr with INFO prefix" {
  run -0 bash -c "source ${REPO_ROOT}/install/lib/common.sh; log_info hello 2>&1 1>/dev/null"
  assert_output --partial "[INFO] hello"
}

@test "log_error prints to stderr with ERROR prefix" {
  run -0 bash -c "source ${REPO_ROOT}/install/lib/common.sh; log_error oops 2>&1 1>/dev/null"
  assert_output --partial "[ERROR] oops"
}

@test "run_or_dryrun executes when DRY_RUN=0" {
  DRY_RUN=0 run -0 bash -c "source ${REPO_ROOT}/install/lib/common.sh; run_or_dryrun true"
}

@test "run_or_dryrun does NOT execute when DRY_RUN=1" {
  DRY_RUN=1 run -0 bash -c "source ${REPO_ROOT}/install/lib/common.sh; run_or_dryrun false"
}

@test "run_or_dryrun prints DRYRUN line on DRY_RUN=1" {
  DRY_RUN=1 run -0 bash -c "source ${REPO_ROOT}/install/lib/common.sh; run_or_dryrun echo planted 2>&1 1>/dev/null"
  assert_output --partial "[DRYRUN] echo planted"
}
