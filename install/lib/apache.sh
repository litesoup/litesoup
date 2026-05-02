#!/usr/bin/env bash
# install/lib/apache.sh — Apache 2.4 with mpm_event + proxy_fcgi + rewrite.

[ -n "${LITESOUP_APACHE_SH:-}" ] && return 0
LITESOUP_APACHE_SH=1

ensure_apache() {
  ensure_pkgs apache2 apache2-utils

  # Switch to mpm_event (default mpm on Ubuntu is prefork-or-event depending; force event)
  if apache2ctl -V 2>/dev/null | grep -q 'Server MPM:.*prefork'; then
    log_info "apache: switching MPM prefork → event"
    run_or_dryrun a2dismod mpm_prefork
    run_or_dryrun a2enmod mpm_event
  else
    run_or_dryrun a2enmod mpm_event
  fi

  # Modules required for PHP-FPM, rewrite, headers, SSL, status
  local mod
  for mod in proxy proxy_fcgi rewrite headers ssl http2 setenvif expires; do
    run_or_dryrun a2enmod "${mod}"
  done

  # Disable the default site (we'll create per-site vhosts)
  if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    run_or_dryrun a2dissite 000-default
  fi

  run_or_dryrun systemctl enable --now apache2
  run_or_dryrun systemctl reload apache2
}
