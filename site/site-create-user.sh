#!/usr/bin/env bash
# site/site-create-user.sh — provision a client user with SSH, SFTP, and site.
#
# One-command workflow:
#   1. Create system user (with home, webapps dir)
#   2. Install SSH public key
#   3. Enable SFTP chroot (jailed — no shell commands, no sudo)
#   4. Create a WordPress/Laravel site under /home/<user>/webapps/<domain>/
#   5. Fix directory permissions for SFTP chroot
#
# The resulting user is jailed: they can SFTP/SSH in but CANNOT run
# arbitrary shell commands, install packages, or sudo.
#
# Usage: sudo bash site-create-user.sh --name=client --ssh-key="..." --domain=client.com

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/users.sh
source "${REPO_ROOT}/install/lib/users.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

NAME=""
SSH_KEY=""
DOMAIN=""
FRAMEWORK="wordpress"
PHP_VERSION="${PHP_VERSION_DEFAULT:-8.2}"
POOL_TIER="medium"
TLS_MODE="none"
TLS_EMAIL=""
NO_SITE=0
NO_SFTP=0

usage() {
  cat <<'EOF'
litesoup user create — provision a client user with SSH, SFTP, and site

Usage: sudo bash site-create-user.sh [options]

Required:
  --name=<name>       Username to create (lowercase, no spaces)
  --ssh-key="<key>"   SSH public key for user access

Optional:
  --domain=<domain>   Domain for the site (creates a site automatically)
  --framework=<type>  Site framework: wordpress (default) or generic
  --php=<version>     PHP version (default: 8.2)
  --tier=<tier>       PHP-FPM pool tier: small, medium, large (default: medium)
  --tls=<mode>        TLS mode: none (default), self-signed, letsencrypt
  --email=<email>     Email for Let's Encrypt (required if --tls=letsencrypt)
  --no-site           Skip site creation (user + SSH + SFTP only)
  --no-sftp           Skip SFTP chroot setup (SSH-only)
  --dry-run           Print actions without executing
  --help, -h          Show this help

Examples:
  # Create user + SFTP + WordPress site
  sudo bash site-create-user.sh \\
    --name=client1 \\
    --ssh-key="ssh-ed25519 AAAA..." \\
    --domain=client1.com \\
    --tls=letsencrypt --email=admin@example.com

  # Create user with SFTP only (no site)
  sudo bash site-create-user.sh \\
    --name=client1 \\
    --ssh-key="ssh-ed25519 AAAA..." \\
    --no-site
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --name=*)       NAME="${arg#--name=}" ;;
      --ssh-key=*)    SSH_KEY="${arg#--ssh-key=}" ;;
      --domain=*)     DOMAIN="${arg#--domain=}" ;;
      --framework=*)  FRAMEWORK="${arg#--framework=}" ;;
      --php=*)        PHP_VERSION="${arg#--php=}" ;;
      --tier=*)       POOL_TIER="${arg#--tier=}" ;;
      --tls=*)        TLS_MODE="${arg#--tls=}" ;;
      --email=*)      TLS_EMAIL="${arg#--email=}" ;;
      --no-site)      NO_SITE=1 ;;
      --no-sftp)      NO_SFTP=1 ;;
      --dry-run)      DRY_RUN=1 ;;
      --help|-h)      usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN

  require_root

  # --- Validate ---
  if [ -z "${NAME}" ]; then
    log_error "--name is required"
    usage
    exit 64
  fi
  if [[ ! "${NAME}" =~ ^[a-z][a-z0-9_-]+$ ]]; then
    log_error "invalid username: ${NAME} (lowercase, start with letter, alphanumeric only)"
    exit 64
  fi
  if [ -z "${SSH_KEY}" ] && [ "${NO_SFTP}" = "0" ]; then
    log_error "--ssh-key is required (or use --no-sftp for keyless access)"
    usage
    exit 64
  fi
  if [ -n "${DOMAIN}" ] && [ "${NO_SITE}" = "1" ]; then
    log_error "--domain and --no-site conflict"
    exit 64
  fi

  local home="/home/${NAME}"

  log_info "user-create: provisioning user ${NAME}"

  # --- 1. Create system user ---
  if id "${NAME}" >/dev/null 2>&1; then
    log_info "user-create: user ${NAME} already exists"
  else
    log_info "user-create: creating user ${NAME}"
    if [ "${DRY_RUN}" != "1" ]; then
      useradd --create-home --home-dir "${home}" --shell /bin/bash --user-group "${NAME}"
      # Create webapps dir
      install -d -o "${NAME}" -g "${NAME}" -m 0755 "${home}/webapps"
      log_info "user-create: home=${home}, shell=/bin/bash, group=${NAME}"
    fi
  fi

  # --- 2. Install SSH key ---
  if [ -n "${SSH_KEY}" ]; then
    log_info "user-create: installing SSH key for ${NAME}"
    if [ "${DRY_RUN}" != "1" ]; then
      install -d -m 0700 -o "${NAME}" -g "${NAME}" "${home}/.ssh"
      echo "${SSH_KEY}" >> "${home}/.ssh/authorized_keys"
      chmod 0600 "${home}/.ssh/authorized_keys"
      chown "${NAME}:${NAME}" "${home}/.ssh/authorized_keys"
    fi
  fi

  # --- 3. Enable SFTP chroot ---
  if [ "${NO_SFTP}" = "0" ]; then
    log_info "user-create: enabling SFTP chroot for ${NAME}"
    if [ "${DRY_RUN}" != "1" ]; then
      bash "${SCRIPT_DIR}/../harden/harden-sftp.sh" --user="${NAME}" --no-ssh
    fi
  fi

  # --- 4. Create site ---
  if [ -n "${DOMAIN}" ]; then
    log_info "user-create: creating site ${DOMAIN} under user ${NAME}"
    if [ "${DRY_RUN}" != "1" ]; then
      # Delegate to site-create.sh or site-import.sh
      SITE_USER="${NAME}" \
      bash "${SCRIPT_DIR}/site-create.sh" \
        --domain="${DOMAIN}" \
        --user="${NAME}" \
        --php="${PHP_VERSION}" \
        --tier="${POOL_TIER}" \
        --tls="${TLS_MODE}" \
        --email="${TLS_EMAIL}" \
        --framework="${FRAMEWORK}"
    fi
  fi

  # --- 5. Summary ---
  log_info "user-create: COMPLETE"
  log_info "user-create: user=${NAME}"
  log_info "user-create: home=${home}"
  log_info "user-create: SSH key installed: $([ -n "${SSH_KEY}" ] && echo yes || echo no)"
  log_info "user-create: SFTP chroot: $([ "${NO_SFTP}" = "0" ] && echo enabled || echo disabled)"
  log_info "user-create: domain: ${DOMAIN:-<none>}"
  log_info ""
  log_info "user-create: Connect: ssh -i <key> ${NAME}@<host>"
  log_info "user-create: SFTP:    sftp -i <key> ${NAME}@<host>"
  log_info "user-create: Website: https://${DOMAIN:-<not created>}"
}

main "$@"
