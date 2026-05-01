#!/usr/bin/env bash
# install/install-stack.sh — Plan I.A entry point.
# Usage:
#   sudo bash install-stack.sh [--dry-run] [--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/distro.sh
source "${LIB_DIR}/distro.sh"
# shellcheck source=lib/apt.sh
source "${LIB_DIR}/apt.sh"
# shellcheck source=lib/users.sh
source "${LIB_DIR}/users.sh"
# shellcheck source=lib/apache.sh
source "${LIB_DIR}/apache.sh"
# shellcheck source=lib/php.sh
source "${LIB_DIR}/php.sh"
# shellcheck source=lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=lib/wp_cli.sh
source "${LIB_DIR}/wp_cli.sh"

usage() {
  cat <<'EOF'
litesoup install-stack — MVP WordPress stack for Ubuntu 24.04

Usage: sudo bash install-stack.sh [options]

Options:
  --dry-run    Print actions without executing
  --help       Show this help

Installs: Apache (mpm_event), PHP 8.2 FPM (Ondrej PPA, per-user pool),
          MariaDB, wp-cli. Provisions the default site owner `litesoup`
          at /home/litesoup/webapps/.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root
  require_ubuntu_2404

  log_info "stage 1/5: apache"
  ensure_apache

  log_info "stage 2/5: php 8.2 fpm"
  ensure_php_82_fpm

  log_info "stage 3/5: default site owner (${DEFAULT_SITE_USER}) + per-user pool"
  ensure_user "${DEFAULT_SITE_USER}"
  ensure_php_82_pool_for_user "${DEFAULT_SITE_USER}"

  log_info "stage 4/5: mariadb"
  ensure_mariadb

  log_info "stage 5/5: wp-cli"
  ensure_wp_cli

  log_info "litesoup install-stack: COMPLETE"
}

main "$@"
