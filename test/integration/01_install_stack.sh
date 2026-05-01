#!/usr/bin/env bash
# Runs INSIDE the systemd-Docker container at /opt/litesoup.
set -Eeuo pipefail

cd /opt/litesoup
source install/lib/common.sh
source install/lib/distro.sh
source install/lib/apt.sh
source install/lib/apache.sh

log_info "integration: distro check"
require_ubuntu_2404

log_info "integration: ensure_apache"
ensure_apache

log_info "integration: assert apache running"
systemctl is-active --quiet apache2
ss -ltn | grep -E ':80\b' >/dev/null

log_info "integration: assert mpm_event loaded"
apache2ctl -M 2>&1 | grep -q 'mpm_event_module'

log_info "integration: assert proxy_fcgi loaded"
apache2ctl -M 2>&1 | grep -q 'proxy_fcgi_module'

log_info "integration: ensure_php_82_fpm"
source install/lib/users.sh
source install/lib/php.sh
ensure_php_82_fpm

log_info "integration: assert php-fpm running"
systemctl is-active --quiet php8.2-fpm

log_info "integration: assert default www-data pool is disabled"
[ ! -f /etc/php/8.2/fpm/pool.d/www.conf ]
[ -f /etc/php/8.2/fpm/pool.d/www.conf.disabled ]

log_info "integration: assert php cli is 8.2"
php -v | head -1 | grep -Eq 'PHP 8\.2\.'

log_info "integration: ensure_php_82_pool_for_user litesoup"
ensure_user litesoup
ensure_php_82_pool_for_user litesoup

log_info "integration: assert litesoup pool socket exists"
[ -S /run/php/litesoup-php8.2-fpm.sock ]
[ -f /etc/php/8.2/fpm/pool.d/litesoup-php8.2.conf ]

log_info "integration: PASS"
