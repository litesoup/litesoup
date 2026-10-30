#!/usr/bin/env bash
# install/lib/apache.sh — Apache 2.4 with mpm_event + proxy_fcgi + rewrite.

[ -n "${LITESOUP_APACHE_SH:-}" ] && return 0
LITESOUP_APACHE_SH=1

ensure_apache() {
  ensure_pkgs apache2 apache2-utils ssl-cert

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

  # Cloudflare real client IP (mod_remoteip) — restores the real visitor
  # REMOTE_ADDR for PHP/WP, fail2ban, and access logs instead of the CF edge IP.
  ensure_cloudflare_realip

  # Disable the default site (we'll create per-site vhosts)
  if [ -L /etc/apache2/sites-enabled/000-default.conf ]; then
    run_or_dryrun a2dissite 000-default
  fi

  run_or_dryrun systemctl enable --now apache2
  run_or_dryrun systemctl reload apache2
}

# ensure_cloudflare_realip — enable mod_remoteip and trust Cloudflare's edge IPs
# so the real visitor IP is logged (and usable by fail2ban) for proxied sites.
# Idempotent: re-running only refreshes the trusted-proxy range list.
ensure_cloudflare_realip() {
  ensure_pkgs apache2
  run_or_dryrun a2enmod remoteip

  local conf=/etc/apache2/conf-available/cloudflare-realip.conf
  local tmp
  tmp="$(mktemp)"
  {
    echo "# litesoup: Cloudflare real-IP (mod_remoteip). Managed — do not edit by hand."
    echo "RemoteIPHeader CF-Connecting-IP"
    # IPv4 ranges from https://www.cloudflare.com/ips-v4 (refreshed at install)
    # NOTE: both endpoints return a body with NO trailing newline. Without the
    # explicit `echo` the last v4 range glues onto the first v6 line
    # ("RemoteIPTrustedProxy 131.0.72.0/22RemoteIPTrustedProxy 2400:cb00::/32")
    # and apache2ctl configtest fails with "Error parsing IP". Caught on sg14.
    curl -fsS https://www.cloudflare.com/ips-v4 2>/dev/null | tr -d '\r' \
      | sed '/^$/d; s|^|RemoteIPTrustedProxy |'
    echo
    # IPv6 ranges from https://www.cloudflare.com/ips-v6
    curl -fsS https://www.cloudflare.com/ips-v6 2>/dev/null | tr -d '\r' \
      | sed '/^$/d; s|^|RemoteIPTrustedProxy |'
    echo
  } > "${tmp}"

  # If the fetch produced no trusted-proxy lines (curl failed/offline), use the
  # built-in fallback — otherwise mod_remoteip trusts nothing and logs stay CF-edge.
  if ! grep -q '^RemoteIPTrustedProxy ' "${tmp}"; then
    log_warn "cloudflare-realip: range fetch failed, using built-in fallback ranges"
    cat > "${tmp}" <<'EOF'
# litesoup: Cloudflare real-IP (mod_remoteip). Managed — do not edit by hand.
RemoteIPHeader CF-Connecting-IP
RemoteIPTrustedProxy 173.245.48.0/20
RemoteIPTrustedProxy 103.21.244.0/22
RemoteIPTrustedProxy 103.22.200.0/22
RemoteIPTrustedProxy 103.31.4.0/22
RemoteIPTrustedProxy 141.101.64.0/18
RemoteIPTrustedProxy 108.162.192.0/18
RemoteIPTrustedProxy 190.93.240.0/20
RemoteIPTrustedProxy 188.114.96.0/20
RemoteIPTrustedProxy 197.234.240.0/22
RemoteIPTrustedProxy 198.41.128.0/17
RemoteIPTrustedProxy 162.158.0.0/15
RemoteIPTrustedProxy 104.16.0.0/13
RemoteIPTrustedProxy 104.24.0.0/14
RemoteIPTrustedProxy 172.64.0.0/13
RemoteIPTrustedProxy 131.0.72.0/22
RemoteIPTrustedProxy 2400:cb00::/32
RemoteIPTrustedProxy 2606:4700::/32
RemoteIPTrustedProxy 2803:f800::/32
RemoteIPTrustedProxy 2405:b500::/32
RemoteIPTrustedProxy 2405:8100::/32
RemoteIPTrustedProxy 2a06:98c0::/29
RemoteIPTrustedProxy 2c0f:f248::/32
EOF
  fi

  if [ -n "${DRYRUN:-}" ]; then
    run_or_dryrun "install ${conf}"; rm -f "${tmp}"
  else
    install -m 0644 "${tmp}" "${conf}"; rm -f "${tmp}"
  fi

  run_or_dryrun a2enconf cloudflare-realip
  log_info "apache: mod_remoteip enabled (Cloudflare real IP)"
}
