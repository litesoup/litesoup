#!/usr/bin/env bash
# site/_vhost_render.sh -- shared vhost rendering + site introspection helpers
# used by site-create.sh and site-set-tls.sh. Not meant to be executed directly.
#
# write_vhost expects these vars in scope:
#   DOMAIN, DOCROOT, VHOST_DOCROOT, SITE_USER, PHP_VERSION, TLS_MODE, REPO_ROOT, DRY_RUN
#   WAF_ENABLED (optional: set to 1 to enable 6G firewall rules for this site)

[ -n "${LITESOUP_VHOST_RENDER_SH:-}" ] && return 0
LITESOUP_VHOST_RENDER_SH=1

# Locate a site's Apache vhost config file. Checks sites-available/ first
# (canonical Apache convention — used by write_vhost + a2ensite), then falls
# back to sites-enabled/ (some configurations write directly to enabled).
_find_vhost() {
  local domain="${1:?domain required}"
  for dir in /etc/apache2/sites-available /etc/apache2/sites-enabled; do
    local conf="${dir}/${domain}.conf"
    if [ -f "${conf}" ]; then
      printf '%s' "${conf}"
      return 0
    fi
  done
  return 1
}

# Look up the system user that owns the site by reading the FPM SetHandler line
# from the Apache vhost. Echoes the user; returns 1 if vhost does not exist.
existing_site_owner() {
  local vhost
  vhost="$(_find_vhost "${1:?domain required}")" || return 1
  grep -oE '/run/php/[^-]+-php[0-9.]+-fpm\.sock' "${vhost}" | head -1 \
    | sed -E 's|/run/php/([^-]+)-php.*|\1|'
}

# Echo the PHP version pinned in the existing vhost.
existing_site_php() {
  local vhost
  vhost="$(_find_vhost "${1:?domain required}")" || return 1
  grep -oE '/run/php/[^-]+-php[0-9.]+-fpm\.sock' "${vhost}" | head -1 \
    | sed -E 's|.*-php([0-9.]+)-fpm\.sock|\1|'
}

# Echo the docroot from the existing vhost.
existing_site_docroot() {
  local vhost
  vhost="$(_find_vhost "${1:?domain required}")" || return 1
  grep -oE 'DocumentRoot[[:space:]]+\S+' "${vhost}" | head -1 | awk '{print $2}'
}

# write_vhost -- render /etc/apache2/sites-available/${DOMAIN}.conf from the
# template. Substitutes __HTTP_REDIRECT__ and __HTTPS_BLOCK__ to empty strings
# when TLS_MODE is none, populates them when TLS_MODE is letsencrypt or
# self-signed. Uses VHOST_DOCROOT (which may differ from DOCROOT for
# Laravel/generic frameworks where DocumentRoot points to /public).
write_vhost() {
  local socket vhost http_redirect="" https_block="" cert_paths cert key waf_include=""
  local waf_dir="/etc/apache2/litesoup-waf.d"
  socket="$(php_fpm_socket_for_user "${SITE_USER}" "${PHP_VERSION}")"
  vhost="/etc/apache2/sites-available/${DOMAIN}.conf"
  # Auto-detect WAF from existing config
  if [ "${WAF_ENABLED:-0}" != "1" ] && [ -f "${waf_dir}/${DOMAIN}.conf" ]; then
    WAF_ENABLED=1
    log_info "site: 6G firewall detected (existing config) for ${DOMAIN}"
  fi
  if [ "${WAF_ENABLED:-0}" = "1" ]; then
    mkdir -p "${waf_dir}"
    local waf_file="${waf_dir}/${DOMAIN}.conf"
    if [ -f "${REPO_ROOT}/templates/apache/waf-6g.conf" ]; then
      cp "${REPO_ROOT}/templates/apache/waf-6g.conf" "${waf_file}"
      chmod 644 "${waf_file}"
      waf_include="IncludeOptional ${waf_file}"
      log_info "site: 6G firewall enabled for ${DOMAIN}"
    else
      log_warn "site: WAF rules template not found at ${REPO_ROOT}/templates/apache/waf-6g.conf"
    fi
  fi

  if [ "${TLS_MODE}" != "none" ]; then
    # HTTP -> HTTPS 301 (with .well-known/acme-challenge exception so renewal works)
    http_redirect=$'    RewriteEngine On\n    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/\n    RewriteRule ^/?(.*)$ https://%{HTTP_HOST}/$1 [R=301,L]'
    cert_paths="$(certbot_paths_for_domain "${DOMAIN}" "${TLS_MODE}")"
    cert="${cert_paths% *}"
    key="${cert_paths#* }"
    https_block=$(cat <<HTTPS
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot ${VHOST_DOCROOT}

    Protocols h2 http/1.1

    SSLEngine on
    SSLCertificateFile ${cert}
    SSLCertificateKeyFile ${key}
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLHonorCipherOrder off
    SSLSessionTickets off

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header edit Set-Cookie ^(.*)$ "\$1; Secure"

    <Directory ${VHOST_DOCROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        # Block version control + env file exposure
        RedirectMatch 404 \\.(git|svn|hg)(/.*)?$
        RedirectMatch 404 \\.env$
        # Block common scanner paths
        RedirectMatch 404 /(auth|SDK|cgi-bin|developmentserver)(/.*)?$
    </Directory>

    # Block PHP execution in wp-content/uploads (mitigates file-upload RCE)
    <Directory ${VHOST_DOCROOT}/wp-content/uploads>
        <FilesMatch \.php$>
            Require all denied
        </FilesMatch>
    </Directory>

    # Block direct access to wp-content/debug.log (prevents credential leaks)
    <Files "debug.log">
        Require all denied
    </Files>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${socket}|fcgi://localhost"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-access.log combined
</VirtualHost>
HTTPS
)
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would render vhost ${vhost} (tls=${TLS_MODE}, socket=${socket})"
    return 0
  fi

  # Use python3 for the multi-line substitution (sed with newlines in the
  # replacement string is portability-fragile; python3 is already pulled in
  # as a dep of python3-certbot-apache from install-stack stage 6).
  python3 -c "
tmpl = open('${REPO_ROOT}/templates/apache/vhost.conf.tmpl').read()
out = (tmpl
  .replace('__DOMAIN__',         '''${DOMAIN}''')
  .replace('__DOCROOT__',        '''${VHOST_DOCROOT}''')
  .replace('__FPM_SOCKET__',     '''${socket}''')
  .replace('__HTTP_REDIRECT__',  '''${http_redirect}''')
  .replace('__WAF_RULES__',      '''${waf_include}''')
  .replace('__HTTPS_BLOCK__',    '''${https_block}''')
)
open('${vhost}', 'w').write(out)
"
  a2enmod ssl headers http2 rewrite >/dev/null 2>&1 || true
  a2ensite "${DOMAIN}.conf" >/dev/null
  apache2ctl configtest \
    || { log_error "site-create: apache configtest failed for ${DOMAIN}"; return 1; }
  systemctl reload apache2
}
