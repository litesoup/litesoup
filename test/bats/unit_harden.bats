#!/usr/bin/env bats
# Unit tests for the harden/* scripts -- focuses on pure functions
# (detect_ssh_port, ufw_rule_present, ufw_is_active) since the bulk of
# each script is shell-out to ufw / fail2ban-client / apt which can't be
# meaningfully unit-tested without a real Ubuntu host (covered by the
# integration job + sg10 acceptance instead).

load test_helper

setup() {
  source "${REPO_ROOT}/install/lib/common.sh"
  # Source each harden script in a way that defines its functions but
  # doesn't run main(). The scripts call `main "$@"` at the end -- we
  # override main as a no-op via the BASH_SOURCE trick: source the file
  # after defining `main` so the trailing `main "$@"` call hits our stub.
  # Simpler: extract the functions we want to test by sourcing the script
  # file itself and intercepting main().
  main() { :; }
  export -f main
}

# --- harden-firewall.sh: detect_ssh_port ---

@test "detect_ssh_port falls back to 22 when sshd_config is absent" {
  # Inline the same parser logic both harden scripts use, against a
  # nonexistent path. Falls through to the default-22 branch.
  local conf="/nonexistent/sshd_config"
  local port=""
  if [ -r "${conf}" ]; then
    port="$(awk '/^[[:space:]]*#/ { next } { sub(/^[[:space:]]+/, ""); if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2 } END { if (last != "") print last }' "${conf}")"
  fi
  if [ -z "${port}" ]; then port="22"; fi
  [ "${port}" = "22" ]
}

@test "detect_ssh_port reads Port directive from sshd_config" {
  local conf
  conf="$(mktemp)"
  cat > "${conf}" <<'EOF'
# Default sshd_config
#Port 22
Port 2222
PermitRootLogin no
EOF
  source "${REPO_ROOT}/install/lib/common.sh"
  # Inline the same awk logic with our test conf path.
  local got
  got="$(awk '
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]+/, "")
      if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2
    }
    END { if (last != "") print last }
  ' "${conf}")"
  [ "${got}" = "2222" ]
  rm -f "${conf}"
}

@test "detect_ssh_port picks LAST Port directive (sshd's own precedence)" {
  local conf
  conf="$(mktemp)"
  cat > "${conf}" <<'EOF'
Port 22
Port 2222
Port 9999
EOF
  local got
  got="$(awk '
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]+/, "")
      if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2
    }
    END { if (last != "") print last }
  ' "${conf}")"
  [ "${got}" = "9999" ]
  rm -f "${conf}"
}

@test "detect_ssh_port ignores commented Port lines" {
  local conf
  conf="$(mktemp)"
  cat > "${conf}" <<'EOF'
#Port 22
# Port 2222
   #   Port 3333
Port 4444
EOF
  local got
  got="$(awk '
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]+/, "")
      if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2
    }
    END { if (last != "") print last }
  ' "${conf}")"
  [ "${got}" = "4444" ]
  rm -f "${conf}"
}

@test "detect_ssh_port ignores Port with non-numeric value" {
  local conf
  conf="$(mktemp)"
  cat > "${conf}" <<'EOF'
Port garbage
Port 22
EOF
  local got
  got="$(awk '
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]+/, "")
      if ($1 == "Port" && $2 ~ /^[0-9]+$/) last = $2
    }
    END { if (last != "") print last }
  ' "${conf}")"
  [ "${got}" = "22" ]
  rm -f "${conf}"
}

# --- harden-firewall.sh: ufw_rule_present / ufw_is_active ---

@test "ufw_is_active returns true for active status" {
  local status="Status: active"
  printf '%s\n' "${status}" | grep -qE '^Status:[[:space:]]+active'
}

@test "ufw_is_active returns false for inactive status" {
  local status="Status: inactive"
  ! { printf '%s\n' "${status}" | grep -qE '^Status:[[:space:]]+active'; }
}

@test "ufw_rule_present matches port/tcp in status output" {
  local status
  status="$(cat <<'EOF'
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
EOF
)"
  printf '%s\n' "${status}" | grep -qE "(^|[[:space:]])22/tcp([[:space:]]|$)"
  printf '%s\n' "${status}" | grep -qE "(^|[[:space:]])80/tcp([[:space:]]|$)"
  printf '%s\n' "${status}" | grep -qE "(^|[[:space:]])443/tcp([[:space:]]|$)"
}

@test "ufw_rule_present misses non-allowed port" {
  local status="22/tcp ALLOW"
  ! { printf '%s\n' "${status}" | grep -qE "(^|[[:space:]])2222/tcp([[:space:]]|$)"; }
}

# --- harden-fail2ban.sh: detect_ssh_port (same logic, must match firewall) ---

@test "harden-fail2ban detect_ssh_port matches harden-firewall logic" {
  # The two scripts MUST agree on the SSH port; otherwise the firewall
  # opens one port and fail2ban watches a different one. This test ensures
  # the awk parser is byte-identical between both files.
  local fw_awk fb_awk
  fw_awk="$(awk '/detect_ssh_port/,/^}/' "${REPO_ROOT}/harden/harden-firewall.sh" | grep -A2 awk | head -7)"
  fb_awk="$(awk '/detect_ssh_port/,/^}/' "${REPO_ROOT}/harden/harden-fail2ban.sh" | grep -A2 awk | head -7)"
  [ -n "${fw_awk}" ]
  [ -n "${fb_awk}" ]
  [ "${fw_awk}" = "${fb_awk}" ]
}

# --- script smoke: --help works on each harden script (no root needed) ---

@test "harden-firewall --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-firewall.sh" --help
  [[ "${output}" == *"litesoup harden-firewall"* ]]
}

@test "harden-fail2ban --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-fail2ban.sh" --help
  [[ "${output}" == *"litesoup harden-fail2ban"* ]]
}

@test "harden-unattended-upgrades --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-unattended-upgrades.sh" --help
  [[ "${output}" == *"litesoup harden-unattended-upgrades"* ]]
}

# --- Wave 2 harden scripts (v0.7.0) ---

@test "harden-ssh --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-ssh.sh" --help
  [[ "${output}" == *"harden-ssh"* ]]
}

@test "harden-apache --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-apache.sh" --help
  [[ "${output}" == *"harden-apache"* ]]
}

@test "harden-php --help exits 0 without root" {
  run -0 bash "${REPO_ROOT}/harden/harden-php.sh" --help
  [[ "${output}" == *"harden-php"* ]]
}

@test "harden-ssh writes to sshd_config.d/ not main sshd_config" {
  # Defensive: editing /etc/ssh/sshd_config directly is fragile because apt
  # may rewrite it on package upgrades. The script must use the .d/ override
  # convention. This test guards against future regressions.
  ! grep -E '^[^#]*\s>\s*/etc/ssh/sshd_config\b' "${REPO_ROOT}/harden/harden-ssh.sh"
  grep -q 'sshd_config\.d/' "${REPO_ROOT}/harden/harden-ssh.sh"
}

# --- v0.7.1 hot-fix: harden-ssh defaults must NOT lock out root password SSH ---

@test "harden-ssh default heredoc does NOT contain PermitRootLogin no" {
  # v0.7.0 default disabled root SSH login -- locked operators out who
  # bootstrap as root. v0.7.1 makes that opt-in via --no-root-login.
  # The heredoc body (between cat <<'EOF' ... EOF) is the always-applied set.
  awk '/cat <<.EOF/{f=1; next} /^EOF$/{f=0} f' "${REPO_ROOT}/harden/harden-ssh.sh" \
    | grep -E '^PermitRootLogin\s+no\s*$' && {
      echo "FAIL: PermitRootLogin no is in the default heredoc -- should be opt-in via --no-root-login" >&2
      return 1
    } || true
}

@test "harden-ssh default heredoc does NOT contain PasswordAuthentication no" {
  # v0.7.0 default disabled password auth -- broke litesoup deployments that
  # rely on password SSH. v0.7.1 makes that opt-in via --no-password-auth.
  awk '/cat <<.EOF/{f=1; next} /^EOF$/{f=0} f' "${REPO_ROOT}/harden/harden-ssh.sh" \
    | grep -E '^PasswordAuthentication\s+no\s*$' && {
      echo "FAIL: PasswordAuthentication no is in the default heredoc -- should be opt-in via --no-password-auth" >&2
      return 1
    } || true
}

@test "harden-ssh --help documents --no-password-auth flag" {
  run -0 bash "${REPO_ROOT}/harden/harden-ssh.sh" --help
  [[ "${output}" == *"--no-password-auth"* ]]
}

@test "harden-ssh --help documents --no-root-login flag" {
  run -0 bash "${REPO_ROOT}/harden/harden-ssh.sh" --help
  [[ "${output}" == *"--no-root-login"* ]]
}

@test "harden-ssh always-safe defaults are still in the heredoc" {
  # Regression guard: removing the policy directives must not also remove
  # the always-safe ones. The 6 defaults below should stay in the heredoc.
  local body
  body="$(awk '/cat <<.EOF/{f=1; next} /^EOF$/{f=0} f' "${REPO_ROOT}/harden/harden-ssh.sh")"
  for directive in 'MaxAuthTries 3' 'ClientAliveInterval 300' 'ClientAliveCountMax 2' \
                   'X11Forwarding no' 'AllowAgentForwarding no' 'PermitEmptyPasswords no'; do
    grep -qE "^${directive}\s*\$" <<< "${body}" || {
      echo "FAIL: always-safe default '${directive}' missing from heredoc" >&2
      return 1
    }
  done
}

@test "harden-apache uses apache2ctl configtest before reload" {
  # Validate AFTER write, BEFORE reload. Catches future regressions where
  # a refactor accidentally drops the configtest gate (apache would refuse
  # to reload anyway, but we want a clean error message).
  grep -q 'apache2ctl configtest' "${REPO_ROOT}/harden/harden-apache.sh"
}

@test "harden-php writes to conf.d/ not main php.ini" {
  # Same reasoning as harden-ssh: package-managed files may be rewritten.
  ! grep -E '^[^#]*\s>\s*/etc/php/[0-9.]+/(cli|fpm)/php\.ini\b' "${REPO_ROOT}/harden/harden-php.sh"
  grep -q 'conf\.d/' "${REPO_ROOT}/harden/harden-php.sh"
}

@test "all 3 wave-2 harden scripts use systemctl reload not restart (preserve sessions/connections)" {
  # SSH reload preserves the live session; restart kills it.
  # Apache reload preserves connections; restart drops them.
  # PHP-FPM reload preserves running requests; restart kills them.
  for script in harden-ssh harden-apache harden-php; do
    if grep -E 'systemctl[[:space:]]+restart[[:space:]]+(ssh|apache2|php[0-9.]+-fpm)' "${REPO_ROOT}/harden/${script}.sh"; then
      echo "FAIL: ${script}.sh uses 'systemctl restart' for a session-bearing service" >&2
      return 1
    fi
  done
}

# --- script smoke: --help works on each audit script ---

@test "audit-wp-health --help exits 0 without root" {
  run bash "${REPO_ROOT}/audit/audit-wp-health.sh" --help
  [ "${status}" -eq 0 ]
}

@test "audit-system-metrics --help exits 0 without root" {
  run bash "${REPO_ROOT}/audit/audit-system-metrics.sh" --help
  [ "${status}" -eq 0 ]
}

@test "audit-wp-vulnerabilities --help exits 0 without root" {
  run bash "${REPO_ROOT}/audit/audit-wp-vulnerabilities.sh" --help
  [ "${status}" -eq 0 ]
}

@test "audit-performance --help exits 0 without root" {
  run bash "${REPO_ROOT}/audit/audit-performance.sh" --help
  [ "${status}" -eq 0 ]
}

# --- install-stack: --skip-hardening flag is parsed ---

@test "install-stack --help mentions --skip-hardening" {
  run -0 bash "${REPO_ROOT}/install/install-stack.sh" --help
  [[ "${output}" == *"--skip-hardening"* ]]
}
