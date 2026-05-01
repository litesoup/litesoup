#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/litesoup

# Setup: install + create site
systemctl is-active --quiet apache2 || bash install/install-stack.sh
grep -q 'example.test' /etc/hosts || echo '127.0.0.1 example.test' >>/etc/hosts
[ -f /home/litesoup/webapps/example.test/wp-config.php ] || bash site/site-create.sh --domain=example.test

# Delete with --purge-db
bash site/site-delete.sh --domain=example.test --purge-db

# Assertions
[ ! -f /etc/apache2/sites-available/example.test.conf ]
[ ! -L /etc/apache2/sites-enabled/example.test.conf ]
[ ! -d /home/litesoup/webapps/example.test ]

db=$(mysql --defaults-file=/root/.litesoup-mariadb-root -Nse \
  "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'wp_example_test%';")
[ -z "${db}" ]

# User and per-user pool must remain (they may host other sites)
id litesoup >/dev/null
[ -f /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf ]

echo "03_site_delete: PASS"
