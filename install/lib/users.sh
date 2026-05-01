#!/usr/bin/env bash
# install/lib/users.sh — system user provisioning for site owners.
# Sites live under /home/<user>/webapps/<domain>/. The default owner is `litesoup`;
# additional users (e.g. per-client) can be provisioned by passing --user=NAME to
# site-create.sh. Per-user PHP-FPM pools are configured by install/lib/php.sh.

[ -n "${LITESOUP_USERS_SH:-}" ] && return 0
LITESOUP_USERS_SH=1

# shellcheck disable=SC2034  # consumed by callers after sourcing
DEFAULT_SITE_USER="litesoup"

ensure_user() {
  local user="${1:?ensure_user: username required}"

  if id "${user}" >/dev/null 2>&1; then
    log_info "users: ${user} already exists"
  else
    log_info "users: creating ${user} (home=/home/${user}, shell=/usr/sbin/nologin)"
    run_or_dryrun useradd \
      --create-home \
      --home-dir "/home/${user}" \
      --shell /usr/sbin/nologin \
      --user-group \
      "${user}"
  fi

  # /home/<user> mode 0711 — apache (www-data) can traverse but cannot list
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would chmod 0711 /home/${user} and ensure /home/${user}/webapps"
    return 0
  fi
  chmod 0711 "/home/${user}"

  if [ ! -d "/home/${user}/webapps" ]; then
    install -d -o "${user}" -g "${user}" -m 0755 "/home/${user}/webapps"
  fi
}
