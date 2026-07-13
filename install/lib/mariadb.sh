#!/usr/bin/env bash
# install/lib/mariadb.sh — MariaDB 10.x with non-interactive hardening.
# Root password is randomly generated and written to /root/.litesoup-mariadb-root
# (mode 0600). For Plan I.A this is the simplest correct posture; Plan I.D will
# move secret storage into a proper credentials store.

[ -n "${LITESOUP_MARIADB_SH:-}" ] && return 0
LITESOUP_MARIADB_SH=1

MARIADB_ROOT_PW_FILE="/root/.litesoup-mariadb-root"

_gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }

ensure_mariadb() {
  ensure_pkgs mariadb-server mariadb-client

  run_or_dryrun systemctl enable --now mariadb

  # Wait for mariadb socket (max 30s) — not gated by dry-run
  if [ "${DRY_RUN}" != "1" ]; then
    local _x
    for _x in $(seq 1 30); do
      if mysqladmin ping --silent 2>/dev/null; then break; fi
      sleep 1
    done
  fi

  # Idempotent secure: only run if password file missing
  if [ ! -f "${MARIADB_ROOT_PW_FILE}" ]; then
    local pw
    pw="$(_gen_pw)"
    log_info "mariadb: generating root password and applying secure baseline"
    if [ "${DRY_RUN}" = "1" ]; then
      log_info "[DRYRUN] would generate root password and write ${MARIADB_ROOT_PW_FILE}"
    else
      mysql --protocol=socket -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${pw}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
      umask 077
      printf '[client]\nuser=root\npassword=%s\n' "${pw}" > "${MARIADB_ROOT_PW_FILE}"
      chmod 600 "${MARIADB_ROOT_PW_FILE}"
      # Write /etc/mysql/debian.cnf so the mariadb debian-start maintenance
      # script can run without "Access denied" noise on every service start.
      printf '[client]\nuser=root\npassword=%s\nhost=localhost\n' "${pw}" > /etc/mysql/debian.cnf
      chmod 640 /etc/mysql/debian.cnf
    fi
  else
    log_info "mariadb: root credentials already configured (${MARIADB_ROOT_PW_FILE})"
  fi
}

# Run a SQL statement as root using the saved credentials.
mariadb_root() {
  mysql --defaults-file="${MARIADB_ROOT_PW_FILE}" "$@"
}
