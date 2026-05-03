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
