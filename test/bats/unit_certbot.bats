#!/usr/bin/env bats

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  source "${REPO_ROOT}/install/lib/apt.sh"
  source "${REPO_ROOT}/install/lib/users.sh"
  source "${REPO_ROOT}/install/lib/certbot.sh"
}

@test "ensure_certbot dry-run installs certbot + python3-certbot-apache" {
  ensure_pkgs() { local p; for p in "$@"; do echo "PKGS: $p"; done; }
  run_or_dryrun() { echo "RUN: $*"; }
  export -f ensure_pkgs run_or_dryrun
  DRY_RUN=1 run -0 ensure_certbot
  assert_output --partial "PKGS: certbot"
  assert_output --partial "PKGS: python3-certbot-apache"
}

@test "ensure_certbot enables certbot.timer for auto-renewal" {
  ensure_pkgs() { :; }
  run_or_dryrun() { echo "RUN: $*"; }
  export -f ensure_pkgs run_or_dryrun
  DRY_RUN=1 run -0 ensure_certbot
  assert_output --partial "RUN: systemctl enable --now certbot.timer"
}

@test "LITESOUP_SSL_DIR default is /etc/litesoup/ssl" {
  [ "${LITESOUP_SSL_DIR}" = "/etc/litesoup/ssl" ]
}
