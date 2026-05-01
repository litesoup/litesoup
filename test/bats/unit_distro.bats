#!/usr/bin/env bats

load test_helper

@test "require_ubuntu_2404 passes when /etc/os-release reports Ubuntu 24.04" {
  tmp=$(mktemp -d)
  cat >"${tmp}/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
EOF
  run -0 bash -c "export OS_RELEASE_PATH=${tmp}/os-release; source ${REPO_ROOT}/install/lib/common.sh; \
                  source ${REPO_ROOT}/install/lib/distro.sh; require_ubuntu_2404"
  rm -rf "${tmp}"
}

@test "require_ubuntu_2404 fails on Ubuntu 22.04" {
  tmp=$(mktemp -d)
  cat >"${tmp}/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu
EOF
  run bash -c "export OS_RELEASE_PATH=${tmp}/os-release; source ${REPO_ROOT}/install/lib/common.sh; \
               source ${REPO_ROOT}/install/lib/distro.sh; require_ubuntu_2404"
  [ "$status" -ne 0 ]
  assert_output --partial "Ubuntu 24.04"
  rm -rf "${tmp}"
}

@test "require_ubuntu_2404 fails on Debian" {
  tmp=$(mktemp -d)
  cat >"${tmp}/os-release" <<'EOF'
NAME="Debian GNU/Linux"
VERSION_ID="12"
ID=debian
EOF
  run bash -c "export OS_RELEASE_PATH=${tmp}/os-release; source ${REPO_ROOT}/install/lib/common.sh; \
               source ${REPO_ROOT}/install/lib/distro.sh; require_ubuntu_2404"
  [ "$status" -ne 0 ]
  rm -rf "${tmp}"
}
