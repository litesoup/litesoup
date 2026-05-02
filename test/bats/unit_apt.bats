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

# --- ensure_pkgs_optional ---

@test "ensure_pkgs_optional skips packages with Candidate: (none)" {
  apt_update_once() { :; }
  is_pkg_installed() { return 1; }
  apt-cache() {
    case "$2" in
      php8.2-imagick|php8.2-redis) printf '%s:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n' "$2" ;;
      *)                            printf '%s:\n  Installed: (none)\n  Candidate: 1.0\n' "$2" ;;
    esac
  }
  apt_install() { echo "INSTALL: $*"; }
  export -f apt_update_once is_pkg_installed apt-cache apt_install
  run -0 ensure_pkgs_optional php8.2-imagick php8.2-redis php8.2-fpm
  assert_output --partial "skipping: php8.2-imagick php8.2-redis"
  assert_output --partial "INSTALL: php8.2-fpm"
  refute_output --partial "INSTALL: php8.2-imagick"
}

@test "ensure_pkgs_optional skips packages absent from apt-cache entirely" {
  apt_update_once() { :; }
  is_pkg_installed() { return 1; }
  apt-cache() { return 1; }   # nothing known
  apt_install() { echo "INSTALL: $*"; }
  export -f apt_update_once is_pkg_installed apt-cache apt_install
  run -0 ensure_pkgs_optional ghost-pkg
  assert_output --partial "skipping: ghost-pkg"
  refute_output --partial "INSTALL:"
}

@test "ensure_pkgs_optional is no-op when packages already installed" {
  apt_update_once() { :; }
  is_pkg_installed() { return 0; }
  apt-cache()   { echo "SHOULD NOT CALL"; return 1; }
  apt_install() { echo "SHOULD NOT CALL"; return 1; }
  export -f apt_update_once is_pkg_installed apt-cache apt_install
  run -0 ensure_pkgs_optional php8.2-redis
  refute_output --partial "SHOULD NOT CALL"
  refute_output --partial "skipping"
}

# --- _ppa_reachable_or_fallback ---

@test "_ppa_reachable_or_fallback returns OK when probe finds no fetch errors" {
  # apt-get update writes nothing matching the failure regex.
  apt-get() { return 0; }
  export -f apt-get
  _ppa_fallback() { echo "SHOULD NOT FALLBACK"; return 1; }
  export -f _ppa_fallback

  local probe; probe="$(mktemp)"
  cat > "${probe}" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/
Suites: noble
Components: main
EOF
  run -0 _ppa_reachable_or_fallback ppa:ondrej/php "${probe}"
  refute_output --partial "SHOULD NOT FALLBACK"
  rm -f "${probe}"
}

@test "_ppa_reachable_or_fallback dispatches to fallback on URI fetch failure" {
  # The function under test invokes apt-get via `env DEBIAN_FRONTEND=...
  # apt-get update -qq`, which bypasses bash function mocks (env resolves
  # via PATH). Use a real PATH stub instead.
  local stub_dir; stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/apt-get" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "W: Failed to fetch https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/noble/InRelease  Could not connect" >&2
exit 0
EOS
  chmod +x "${stub_dir}/apt-get"
  PATH="${stub_dir}:${PATH}"
  _ppa_fallback() { echo "FALLBACK: $1"; return 0; }
  export -f _ppa_fallback

  local probe; probe="$(mktemp)"
  cat > "${probe}" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/
Suites: noble
Components: main
EOF
  run -0 _ppa_reachable_or_fallback ppa:ondrej/php "${probe}"
  assert_output --partial "FALLBACK: ppa:ondrej/php"
  rm -rf "${stub_dir}" "${probe}"
}

@test "_ppa_reachable_or_fallback returns OK when stub apt-get emits no errors" {
  # Sanity: the same PATH-stub harness, but the stub emits nothing -> primary
  # path stays in use.
  local stub_dir; stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/apt-get" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${stub_dir}/apt-get"
  PATH="${stub_dir}:${PATH}"
  _ppa_fallback() { echo "SHOULD NOT FALLBACK"; return 1; }
  export -f _ppa_fallback

  local probe; probe="$(mktemp)"
  cat > "${probe}" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/
Suites: noble
Components: main
EOF
  run -0 _ppa_reachable_or_fallback ppa:ondrej/php "${probe}"
  refute_output --partial "SHOULD NOT FALLBACK"
  rm -rf "${stub_dir}" "${probe}"
}

@test "_ppa_reachable_or_fallback falls back when probe file has no URIs" {
  _ppa_fallback() { echo "FALLBACK: $1"; return 0; }
  export -f _ppa_fallback

  local probe; probe="$(mktemp)"
  echo "# stub file with no URIs:" > "${probe}"
  run -0 _ppa_reachable_or_fallback ppa:ondrej/php "${probe}"
  assert_output --partial "FALLBACK: ppa:ondrej/php"
  rm -f "${probe}"
}

@test "_ppa_reachable_or_fallback respects DRY_RUN" {
  _ppa_fallback() { echo "SHOULD NOT FALLBACK"; return 1; }
  export -f _ppa_fallback
  DRY_RUN=1 run -0 _ppa_reachable_or_fallback ppa:ondrej/php /nonexistent
  refute_output --partial "SHOULD NOT FALLBACK"
}

# --- _ppa_fallback dispatcher ---

@test "_ppa_fallback dispatches ppa:ondrej/php to cloudpanel" {
  _ensure_repo_cloudpanel_php() { echo "CLOUDPANEL: $1"; return 0; }
  export -f _ensure_repo_cloudpanel_php
  run -0 _ppa_fallback ppa:ondrej/php /tmp/fake.sources
  assert_output --partial "CLOUDPANEL: /tmp/fake.sources"
}

@test "_ppa_fallback errors on unknown PPA" {
  run _ppa_fallback ppa:unknown/repo /tmp/fake.sources
  [ "$status" -ne 0 ]
  assert_output --partial "no mirror fallback configured"
}

# --- _ensure_repo_cloudpanel_php dry-run ---

@test "_ensure_repo_cloudpanel_php dry-run logs without mutating fs" {
  DRY_RUN=1 run -0 _ensure_repo_cloudpanel_php /tmp/should-not-create
  assert_output --partial "would swap /tmp/should-not-create"
  [ ! -f /tmp/should-not-create ]
}
