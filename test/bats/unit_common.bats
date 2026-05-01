#!/usr/bin/env bats

load test_helper

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

@test "require_root exits non-zero when EUID != 0" {
  run bash -c "EUID=1000 source ${REPO_ROOT}/install/lib/common.sh; require_root"
  [ "$status" -eq 1 ]
  assert_output --partial "[ERROR] must run as root"
}

@test "common.sh re-source is a no-op (LITESOUP_COMMON_SH guard)" {
  run -0 bash -c "
    source ${REPO_ROOT}/install/lib/common.sh
    DRY_RUN=1
    source ${REPO_ROOT}/install/lib/common.sh   # would reset DRY_RUN to 0 if guard broken
    [ \"\${DRY_RUN}\" = \"1\" ]
  "
}
