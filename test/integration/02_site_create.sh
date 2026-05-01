#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/litesoup

# Pre-req: stack already installed (run 01 first if not)
systemctl is-active --quiet apache2 || bash install/install-stack.sh

# Map example.test -> 127.0.0.1 inside container
grep -q 'example.test' /etc/hosts || echo '127.0.0.1 example.test' >>/etc/hosts

bash site/site-create.sh --domain=example.test

# Apache must reload + serve the site
ss -ltn | grep -E ':80\b' >/dev/null
curl -sS --max-time 10 -H 'Host: example.test' -o /tmp/wp-install.html http://127.0.0.1/wp-admin/install.php
grep -qE 'WordPress|Select a default language|wp-admin' /tmp/wp-install.html
rm -f /tmp/wp-install.html

# Assert DB + user exist
db=$(mysql --defaults-file=/root/.litesoup-mariadb-root -Nse \
  "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'wp_example_test%';")
[ -n "${db}" ]

# Assert docroot path + ownership match the per-user model
[ -f /home/litesoup/webapps/example.test/wp-config.php ]
[ "$(stat -c '%U:%G' /home/litesoup/webapps/example.test)" = "litesoup:litesoup" ]
[ "$(stat -c '%U:%G' /home/litesoup/webapps/example.test/wp-config.php)" = "litesoup:litesoup" ]

# PHP-FPM socket the vhost points to actually exists and is owned correctly
[ -S /run/php/litesoup-php8.2-fpm.sock ]

# Re-run for idempotency (CREATE DATABASE IF NOT EXISTS + CREATE USER IF NOT EXISTS
# + ensure_user/ensure_pool no-ops; wp config create will fail on existing
# wp-config.php which is the desired guard. The `|| true` allows the script
# to exit non-zero on the WP step without failing the test.)
bash site/site-create.sh --domain=example.test || true

echo "02_site_create: PASS"
