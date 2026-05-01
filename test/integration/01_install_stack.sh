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

log_info "integration: PASS"
