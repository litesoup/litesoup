#!/usr/bin/env bash
# install/lib/wp_cli.sh — install wp-cli phar to /usr/local/bin/wp with sha512 verify.

[ -n "${LITESOUP_WP_CLI_SH:-}" ] && return 0
LITESOUP_WP_CLI_SH=1

WP_CLI_PHAR_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
WP_CLI_HASH_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512"
WP_CLI_BIN="/usr/local/bin/wp"

ensure_wp_cli() {
  ensure_pkgs curl ca-certificates less mariadb-client

  if [ -x "${WP_CLI_BIN}" ] && "${WP_CLI_BIN}" --info >/dev/null 2>&1; then
    log_info "wp-cli: already installed at ${WP_CLI_BIN}"
    return 0
  fi

  log_info "wp-cli: downloading + verifying"
  local tmp
  tmp="$(mktemp -d)"
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would curl ${WP_CLI_PHAR_URL} and verify sha512"
    rm -rf "${tmp}"
    return 0
  fi
  curl -fsSL -o "${tmp}/wp-cli.phar"      "${WP_CLI_PHAR_URL}"
  curl -fsSL -o "${tmp}/wp-cli.phar.sha512" "${WP_CLI_HASH_URL}"
  ( cd "${tmp}" && printf '%s  wp-cli.phar\n' "$(cat wp-cli.phar.sha512)" | sha512sum -c - )
  install -m 0755 "${tmp}/wp-cli.phar" "${WP_CLI_BIN}"
  rm -rf "${tmp}"
  "${WP_CLI_BIN}" --info >/dev/null
}
