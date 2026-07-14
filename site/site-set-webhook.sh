#!/usr/bin/env bash
# site/site-set-webhook.sh — set up a Git webhook auto-deploy for a site.
#
# Creates a lightweight webhook listener (systemd + Python) that pulls the
# latest code from Git whenever the remote repo sends a push event.
#
# Usage:
#   sudo bash site-set-webhook.sh --domain=DOMAIN [options]
#
# Options:
#   --domain=DOMAIN      Required. Site domain.
#   --user=NAME          System user (auto-detected).
#   --secret=STRING      Webhook secret for request validation (auto-generated).
#   --port=PORT          Listener port (default: 65200 + hash of domain).
#   --branch=BRANCH      Branch to track (default: the repo's current branch or main).
#   --post-deploy=CMD    Optional command to run after git pull (e.g. "make build").
#   --remove             Remove the webhook and disable the service.
#   --dry-run            Preview without executing.
#   --help               Show this help.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

LITESOUP_WEBHOOK_DIR="/etc/litesoup/webhooks"
WEBHOOK_LISTENER="/usr/lib/litesoup/site/webhook-listener.py"

DOMAIN=""
SITE_USER=""
SECRET=""
PORT=""
BRANCH=""
POST_DEPLOY=""
REMOVE=0

usage() {
  cat <<'EOF'
litesoup site-set-webhook — set up Git webhook auto-deploy for a site

Usage: sudo bash site-set-webhook.sh --domain=DOMAIN [options]

Options:
  --domain=DOMAIN      Required. Site domain.
  --user=NAME          System user (auto-detected).
  --secret=STRING      Webhook secret (auto-generated if omitted).
  --port=PORT          Listener port (default: auto from domain hash).
  --branch=BRANCH      Branch to track (default: repo's current branch).
  --post-deploy=CMD    Command to run after git pull (e.g. "make build").
  --remove             Remove webhook and disable service.
  --dry-run            Preview without executing.
  --help, -h           Show this help.

Examples:
  sudo bash site-set-webhook.sh --domain=example.com
  sudo bash site-set-webhook.sh --domain=example.com --secret=mypass
  sudo bash site-set-webhook.sh --domain=example.com --post-deploy="npm run build"
  sudo bash site-set-webhook.sh --domain=example.com --remove
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)     DOMAIN="${arg#*=}" ;;
      --user=*)       SITE_USER="${arg#*=}" ;;
      --secret=*)     SECRET="${arg#*=}" ;;
      --port=*)       PORT="${arg#*=}" ;;
      --branch=*)     BRANCH="${arg#*=}" ;;
      --post-deploy=*) POST_DEPLOY="${arg#*=}" ;;
      --remove)       REMOVE=1 ;;
      --dry-run)      DRY_RUN=1 ;;
      --help|-h)      usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
}

main() {
  parse_args "$@"
  require_root

  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"; usage; exit 64
  fi

  # 1. Resolve site user
  if [ -z "${SITE_USER}" ]; then
    SITE_USER="$(existing_site_owner "${DOMAIN}" 2>/dev/null || echo "${DEFAULT_SITE_USER}")"
  fi

  local docroot="/home/${SITE_USER}/webapps/${DOMAIN}"
  local config_file="${LITESOUP_WEBHOOK_DIR}/${DOMAIN}.conf"
  local service_name="litesoup-webhook@${DOMAIN}"

  # ── Remove mode ──────────────────────────────────────────────────────────
  if [ "${REMOVE}" = "1" ]; then
    log_info "site-set-webhook: removing webhook for ${DOMAIN}..."
    if systemctl is-active "${service_name}.service" &>/dev/null 2>&1; then
      run_or_dryrun systemctl disable --now "${service_name}.service"
    fi
    if systemctl is-active "${service_name}.socket" &>/dev/null 2>&1; then
      run_or_dryrun systemctl disable --now "${service_name}.socket"
    fi
    run_or_dryrun rm -f "${config_file}"
    run_or_dryrun rm -f "/etc/systemd/system/${service_name}.service"
    run_or_dryrun rm -f "/etc/systemd/system/${service_name}.socket"
    run_or_dryrun systemctl daemon-reload
    log_info "site-set-webhook: removed webhook for ${DOMAIN}"
    return 0
  fi

  # ── Setup mode ───────────────────────────────────────────────────────────
  if [ ! -d "${docroot}/.git" ]; then
    log_error "site-set-webhook: ${docroot} is not a git repository"
    exit 1
  fi

  # 2. Determine defaults
  if [ -z "${SECRET}" ]; then
    SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
    log_info "site-set-webhook: generated secret: ${SECRET}"
  fi
  if [ -z "${PORT}" ]; then
    # Derive port from domain hash: 65200 + (crc32 mod 400)
    local hash
    hash="$(printf '%s' "${DOMAIN}" | cksum | awk '{print $1}')"
    PORT="$(( 65200 + (hash % 400) ))"
  fi
  if [ -z "${BRANCH}" ]; then
    BRANCH="$(sudo -H -u "${SITE_USER}" git -C "${docroot}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
  fi

  log_info "site-set-webhook: setting up webhook for ${DOMAIN}"
  log_info "  docroot = ${docroot}"
  log_info "  port    = ${PORT}"
  log_info "  branch  = ${BRANCH}"
  log_info "  secret  = ${SECRET}"

  # 3. Create config directory
  run_or_dryrun mkdir -p "${LITESOUP_WEBHOOK_DIR}"

  # 4. Write config
  if [ "${DRY_RUN}" != "1" ]; then
    cat > "${config_file}" <<HOOKCONF
# litesoup webhook config for ${DOMAIN}
WEBHOOK_DOMAIN=${DOMAIN}
WEBHOOK_DOCROOT=${docroot}
WEBHOOK_USER=${SITE_USER}
WEBHOOK_SECRET=${SECRET}
WEBHOOK_BRANCH=${BRANCH}
WEBHOOK_POST_DEPLOY=${POST_DEPLOY:-}
HOOKCONF
    chmod 0600 "${config_file}"
  fi
  log_info "site-set-webhook: config written to ${config_file}"

  # 5. Install webhook listener Python script
  if [ "${DRY_RUN}" != "1" ]; then
    if [ ! -f "${WEBHOOK_LISTENER}" ]; then
      install -d -m 0755 "$(dirname "${WEBHOOK_LISTENER}")"
      cat > "${WEBHOOK_LISTENER}" <<'PYEOF'
#!/usr/bin/env python3
"""litesoup webhook listener — receives Git push events and deploys.

Reads config from /etc/litesoup/webhooks/<DOMAIN>.conf, validates the
webhook secret, and runs:
  1. git pull --ff-only
  2. git submodule update --init --recursive (if .gitmodules exists)
  3. Optional post-deploy command

Usage (via systemd socket activation):
  export CONTENT_TYPE="$CONTENT_TYPE"
  /usr/lib/litesoup/site/webhook-listener.py
"""

import json
import os
import subprocess
import sys

CONFIG_DIR = "/etc/litesoup/webhooks"


def log(msg):
    print(f"[webhook] {msg}", flush=True)


def respond(status, body=""):
    print(f"Status: {status}")
    print("Content-Type: text/plain")
    print()
    print(body)
    sys.exit(0 if status == "200 OK" else 1)


def main():
    # Read request body from stdin (CGI/socket activation style)
    content_length = int(os.environ.get("CONTENT_LENGTH", "0"))
    body = sys.stdin.read(content_length) if content_length > 0 else sys.stdin.read()

    if not body:
        respond("400 Bad Request", "empty request body")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        respond("400 Bad Request", "invalid JSON")

    # Determine domain from the event (GitHub: repository.name, GitLab: project.path)
    repo_name = None
    if "repository" in payload:
        repo_name = payload["repository"].get("full_name", payload["repository"].get("name"))
    elif "project" in payload:
        repo_name = payload["project"].get("path_with_namespace", payload["project"].get("path"))

    if not repo_name:
        respond("400 Bad Request", "could not determine repository")

    # Find matching webhook config
    config_path = None
    for f in os.listdir(CONFIG_DIR):
        if f.endswith(".conf"):
            cf = os.path.join(CONFIG_DIR, f)
            with open(cf) as fh:
                config = {}
                for line in fh:
                    line = line.strip()
                    if "=" in line:
                        k, v = line.split("=", 1)
                        config[k] = v
            # Simple match: domain suffix in repo name
            domain = config.get("WEBHOOK_DOMAIN", "")
            if domain and (domain in repo_name or repo_name.endswith(domain)):
                config_path = cf
                break

    if not config_path:
        respond("404 Not Found", f"no webhook config found for repo: {repo_name}")

    # Load config
    config = {}
    with open(config_path) as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                config[k] = v

    # Validate secret
    event_secret = (
        payload.get("secret")
        or os.environ.get("HTTP_X_HUB_SIGNATURE_256", "").replace("sha256=", "")
        or os.environ.get("HTTP_X_GITLAB_TOKEN", "")
    )
    expected = config.get("WEBHOOK_SECRET", "")
    if expected and event_secret != expected:
        respond("403 Forbidden", "invalid secret")

    docroot = config["WEBHOOK_DOCROOT"]
    user = config["WEBHOOK_USER"]
    branch = config.get("WEBHOOK_BRANCH", "main")
    post_deploy = config.get("WEBHOOK_POST_DEPLOY", "")

    # Check that the push targets our tracked branch
    ref = payload.get("ref", "")
    expected_ref = f"refs/heads/{branch}"
    if ref and ref != expected_ref:
        log(f"ignoring push to {ref} (watching {expected_ref})")
        respond("200 OK", f"ignored (ref {ref} ≠ {expected_ref})")

    log(f"deploying: {docroot} ({branch})")

    def run(cmd, cwd=None):
        proc = subprocess.run(
            ["sudo", "-H", "-u", user, "sh", "-c", cmd],
            cwd=cwd or docroot,
            capture_output=True, text=True, timeout=120,
        )
        for line in proc.stdout.splitlines():
            log(f"  {line}")
        if proc.returncode != 0:
            for line in proc.stderr.splitlines():
                log(f"  ERR: {line}")
            raise subprocess.CalledProcessError(proc.returncode, cmd)
        return proc.stdout

    try:
        run(f"git fetch origin && git checkout {branch} && git pull --ff-only origin {branch}")

        if os.path.exists(os.path.join(docroot, ".gitmodules")):
            run("git submodule update --init --recursive")

        if post_deploy:
            log(f"running post-deploy: {post_deploy}")
            run(post_deploy)

        log("deploy complete")
        respond("200 OK", f"deployed {branch} to {docroot}")
    except subprocess.CalledProcessError as e:
        log(f"deploy failed (exit {e.returncode})")
        respond("500 Internal Server Error", f"deploy failed: {e}")


if __name__ == "__main__":
    main()
PYEOF
      chmod 0755 "${WEBHOOK_LISTENER}"
    fi
  fi

  # 6. Install systemd units — socket + service
  if [ "${DRY_RUN}" != "1" ]; then
    # Socket unit — systemd listens on the port, spawns the service per request
    cat > "/etc/systemd/system/${service_name}.socket" <<SOCKETEOF
[Unit]
Description=litesoup webhook socket for ${DOMAIN}
PartOf=${service_name}.service

[Socket]
ListenStream=${PORT}
Accept=true

[Install]
WantedBy=sockets.target
SOCKETEOF

    # Service unit — one-shot per-connection via socket activation
    cat > "/etc/systemd/system/${service_name}.service" <<SERVICEEOF
[Unit]
Description=litesoup webhook handler for ${DOMAIN}
After=network-online.target

[Service]
Type=simple
StandardInput=socket
ExecStart=${WEBHOOK_LISTENER}
User=root
# Timeout: some deploys (composer, npm) can be slow
TimeoutStopSec=180
SERVICEEOF

    systemctl daemon-reload
    systemctl enable --now "${service_name}.socket"
    log_info "site-set-webhook: socket enabled on port ${PORT}"
  fi

  # 7. Print webhook URL + secret
  local ip
  ip="$(curl -fsSL ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' || echo "SERVER_IP")"
  log_info "site-set-webhook: COMPLETE for ${DOMAIN}"
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Webhook URL:"
  echo "    http://${ip}:${PORT}/webhook"
  echo ""
  echo "  Secret:"
  echo "    ${SECRET}"
  echo ""
  echo "  Configure your Git provider to send push events to"
  echo "  the URL above with the secret as:"
  echo "    - GitHub:   secret in 'Add webhook' form"
  echo "    - GitLab:   'Secret Token' in webhook settings"
  echo "    - Gitea:    'Secret' in webhook settings"
  echo ""
  echo "  Only pushes to branch '${BRANCH}' trigger a deploy."
  echo "═══════════════════════════════════════════════════════"
}

main "$@"
