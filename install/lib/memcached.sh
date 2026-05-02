#!/usr/bin/env bash
# install/lib/memcached.sh — Memcached pinned to 127.0.0.1 with UDP disabled.
#
# Memcached has no auth; localhost binding + UDP off is the only realistic
# safe-default for a multi-tenant box. Multi-tenant key-prefix isolation is
# the user's plugin's responsibility (most WP Memcached plugins don't do it
# well — see docs/caching.md).

[ -n "${LITESOUP_MEMCACHED_SH:-}" ] && return 0
LITESOUP_MEMCACHED_SH=1

MEMCACHED_CONF="/etc/memcached.conf"
MEMCACHED_BLOCK_BEGIN="# >>> litesoup-managed (do not edit) >>>"
MEMCACHED_BLOCK_END="# <<< litesoup-managed <<<"

ensure_memcached() {
  ensure_pkgs memcached

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would ensure litesoup-managed block in ${MEMCACHED_CONF} (-l 127.0.0.1, -U 0)"
    run_or_dryrun systemctl enable --now memcached
    return 0
  fi

  # Build the desired managed block. start-memcached concatenates these into
  # the memcached argv, and later occurrences of -l/-U override earlier ones,
  # so appending our block guarantees we win.
  local desired_block
  desired_block="$(cat <<EOF
${MEMCACHED_BLOCK_BEGIN}
-l 127.0.0.1
-U 0
${MEMCACHED_BLOCK_END}
EOF
)"

  # Strip any existing managed block, then append the desired one.
  local stripped
  stripped="$(awk -v b="${MEMCACHED_BLOCK_BEGIN}" -v e="${MEMCACHED_BLOCK_END}" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip   { print }
  ' "${MEMCACHED_CONF}")"

  # Trim ALL trailing newlines from stripped so re-runs converge to a fixed
  # point (otherwise each re-run accumulates one blank line before our block).
  while [ -n "${stripped}" ] && [ "${stripped: -1}" = $'\n' ]; do
    stripped="${stripped%$'\n'}"
  done

  local desired
  if [ -z "${stripped}" ]; then
    desired="${desired_block}"$'\n'
  else
    desired="${stripped}"$'\n\n'"${desired_block}"$'\n'
  fi

  local current
  current="$(cat "${MEMCACHED_CONF}")"
  if [ "${current}" = "${desired}" ]; then
    log_info "memcached: ${MEMCACHED_CONF} already up to date"
  else
    log_info "memcached: writing managed block to ${MEMCACHED_CONF} (-l 127.0.0.1, -U 0)"
    local tmp
    tmp="$(mktemp /tmp/litesoup-memcached.conf.XXXXXX)"
    printf '%s' "${desired}" > "${tmp}"
    install -m 0644 -o root -g root "${tmp}" "${MEMCACHED_CONF}"
    rm -f "${tmp}"
    run_or_dryrun systemctl restart memcached
  fi

  run_or_dryrun systemctl enable --now memcached

  # Smoke test: TCP connect + version probe.
  local _x
  for _x in $(seq 1 15); do
    if printf 'version\r\nquit\r\n' | timeout 2 bash -c 'cat >/dev/tcp/127.0.0.1/11211' 2>/dev/null; then
      log_info "memcached: TCP probe ok on 127.0.0.1:11211"
      return 0
    fi
    sleep 1
  done
  log_error "memcached: TCP probe to 127.0.0.1:11211 failed within 15s"
  return 1
}
