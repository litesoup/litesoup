#!/usr/bin/env bats
#
# Guards the CI integration harness itself. A test harness that cannot fail is
# worse than no harness: from 2026-08-14 to 2026-11 every integration job
# reported SUCCESS while its log printed "=== FAILED in 01_install_stack.sh
# (exit 0) ===", so the real suite was green-but-broken for ~3 months.

load test_helper

# write_docker_stub <dir> — a `docker` that succeeds at everything the harness
# does EXCEPT the integration-script exec, which exits 7. Crucially the stub must
# also succeed for the systemd readiness probe and the `mkdir`/`cp` setup: if the
# stub aborts earlier, `set -e` kills the harness before the loop and the test
# passes for the wrong reason.
write_docker_stub() {
  local dir="$1"
  cat > "${dir}/docker" <<'STUB'
#!/usr/bin/env bash
args=("$@")
case "${1:-}" in
  rm|build|cp) exit 0 ;;
  run)      echo "fake-container-id"; exit 0 ;;
  inspect)  echo "true"; exit 0 ;;
  exec)
    if [[ "${args[*]}" == *"is-system-running"* ]]; then echo "running"; exit 0; fi
    if [[ "${args[*]}" == *"test/integration/"* ]]; then exit 7; fi
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${dir}/docker"
}

@test "run-integration.sh captures exit codes without the 'if ! cmd; then \$?' trap" {
  # Inside the body of `if ! cmd`, $? is the status of the NEGATION (always 0
  # when the branch is taken), so `EXIT=$?` records 0 no matter how badly cmd
  # failed — the job goes green while the log says FAILED. The correct form is
  # `cmd || rc=$?` outside a negation.
  ! grep -qE 'EXIT=\$\?' "${REPO_ROOT}/test/docker/run-integration.sh"
  grep -qE '\|\| rc=\$\?' "${REPO_ROOT}/test/docker/run-integration.sh"
}

@test "run-integration.sh propagates a failing integration script (exits 7, not 0)" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  write_docker_stub "${stub_dir}"

  local rc=0
  PATH="${stub_dir}:${PATH}" bash "${REPO_ROOT}/test/docker/run-integration.sh" \
    01_install_stack.sh >/dev/null 2>&1 || rc=$?
  rm -rf "${stub_dir}"

  [ "${rc}" -eq 7 ] || {
    echo "harness exited ${rc}, want 7 — the failure was swallowed" >&2
    return 1
  }
}

@test "integration test image installs openssh-server" {
  # install-stack runs harden-ssh.sh, which exits 1 when /etc/ssh/sshd_config.d
  # is missing. Real boxes always have openssh-server (it is how the operator
  # connects); omitting it from the image made the container diverge from
  # production and harden-ssh fail at stage 11.
  grep -q 'openssh-server' "${REPO_ROOT}/test/docker/Dockerfile.ubuntu2404-systemd"
}
