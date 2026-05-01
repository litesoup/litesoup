#!/usr/bin/env bash
# Runs install-stack.sh end-to-end inside container, then asserts services
# and the default per-user pool layout.
set -Eeuo pipefail
cd /opt/litesoup

bash install/install-stack.sh

systemctl is-active --quiet apache2
systemctl is-active --quiet php8.2-fpm
systemctl is-active --quiet mariadb

# Default Ubuntu pool is disabled
[ ! -f /etc/php/8.2/fpm/pool.d/www.conf ]
[ -f /etc/php/8.2/fpm/pool.d/www.conf.disabled ]

# Default site user provisioned with correct home perms
id litesoup >/dev/null
[ "$(stat -c '%a %U:%G' /home/litesoup)" = "711 litesoup:litesoup" ]
[ -d /home/litesoup/webapps ]

# Per-user pool socket present
[ -S /run/php/litesoup-php8.2-fpm.sock ]
[ -f /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf ]

# Hardening assertions (from previous fixes)
grep -q 'disable_functions' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
grep -q 'expose_php\] = off' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf
! grep -E 'open_basedir.*[^a-z]/tmp/' /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf

# wp-cli installed
[ -x /usr/local/bin/wp ]

# MariaDB secure
mysqladmin --defaults-file=/root/.litesoup-mariadb-root ping | grep -q 'mysqld is alive'

# Re-run to verify idempotency (no duplicate-pool errors, no useradd retries)
bash install/install-stack.sh

echo "01_install_stack: PASS"
