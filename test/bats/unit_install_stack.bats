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

@test "install-stack reloads apache AFTER a2ensite 000-default.conf" {
  # a2ensite only writes the sites-enabled symlink; Apache keeps serving the OLD
  # config until reloaded. Without the reload the _default_:443 catch-all never
  # takes effect and port 443 answers PLAIN HTTP — every https:// request fails
  # with "wrong version number"/000 while `ss -tlnp` still shows *:443 listening
  # and `a2query -m ssl` is enabled, so it looks healthy. Caught on vn19 (2026-11).
  local enable_line reload_line
  enable_line="$(grep -n 'a2ensite 000-default.conf' "${REPO_ROOT}/install/install-stack.sh" | head -1 | cut -d: -f1)"
  reload_line="$(grep -n 'systemctl reload apache2' "${REPO_ROOT}/install/install-stack.sh" | head -1 | cut -d: -f1)"
  [ -n "${enable_line}" ] && [ -n "${reload_line}" ]
  [ "${enable_line}" -lt "${reload_line}" ]
}

@test "install-stack installs ssl-cert BEFORE enabling 000-default.conf" {
  # 000-default.conf references the snakeoil cert in its _default_:443 block, so
  # configtest fails (and the reload is skipped) if ssl-cert lands afterwards.
  local cert_line enable_line
  cert_line="$(grep -n 'ensure_pkgs ssl-cert' "${REPO_ROOT}/install/install-stack.sh" | head -1 | cut -d: -f1)"
  enable_line="$(grep -n 'a2ensite 000-default.conf' "${REPO_ROOT}/install/install-stack.sh" | head -1 | cut -d: -f1)"
  [ -n "${cert_line}" ] && [ -n "${enable_line}" ]
  [ "${cert_line}" -lt "${enable_line}" ]
}

@test "install-stack verifies TLS locally after the reload" {
  grep -q 'curl -sk .*https://127.0.0.1/' "${REPO_ROOT}/install/install-stack.sh"
}
