#!/usr/bin/env bash
# install/lib/certbot.sh -- TLS/HTTPS provisioning for litesoup sites.
# Provides:
#   ensure_certbot                       -- install certbot + apache plugin + enable renewal timer
#   ensure_certbot_renewal_timer         -- enable certbot.timer (idempotent)
#   certbot_obtain DOMAIN EMAIL DOCROOT  -- run certbot certonly --webroot, return 0 on success
#   certbot_self_signed DOMAIN           -- generate 4096-bit RSA self-signed cert + key
#   certbot_paths_for_domain DOMAIN MODE -- echo "<fullchain> <privkey>" for vhost rendering
#   certbot_revoke DOMAIN                -- best-effort revoke + delete on site teardown
# Requires: install/lib/apt.sh and install/lib/common.sh sourced first.

[ -n "${LITESOUP_CERTBOT_SH:-}" ] && return 0
LITESOUP_CERTBOT_SH=1

# Where self-signed certs land. Real LE certs stay at /etc/letsencrypt/live/<domain>/.
LITESOUP_SSL_DIR="${LITESOUP_SSL_DIR:-/etc/litesoup/ssl}"

ensure_certbot() {
  ensure_pkgs certbot python3-certbot-apache
  ensure_certbot_renewal_timer
}

ensure_certbot_renewal_timer() {
  # certbot.timer is bundled with the certbot package and auto-enabled on Ubuntu,
  # but we make it explicit + idempotent so `install-stack --dry-run` shows it
  # and re-runs are safe.
  run_or_dryrun systemctl enable --now certbot.timer
}

# certbot_paths_for_domain DOMAIN MODE -- echo the fullchain + privkey paths for
# vhost rendering. MODE is "letsencrypt" (paths under /etc/letsencrypt/live/) or
# "self-signed" (paths under LITESOUP_SSL_DIR/<domain>/).
certbot_paths_for_domain() {
  local domain="${1:?domain required}" mode="${2:?mode required}"
  case "${mode}" in
    letsencrypt) echo "/etc/letsencrypt/live/${domain}/fullchain.pem /etc/letsencrypt/live/${domain}/privkey.pem" ;;
    self-signed) echo "${LITESOUP_SSL_DIR}/${domain}/fullchain.pem ${LITESOUP_SSL_DIR}/${domain}/privkey.pem" ;;
    *) log_error "certbot: unknown TLS mode ${mode}"; return 1 ;;
  esac
}

# certbot_obtain DOMAIN EMAIL DOCROOT -- request a real LE cert via HTTP-01 webroot.
# Idempotent: certbot itself is happy to be re-run on an existing cert.
certbot_obtain() {
  local domain="${1:?domain required}"
  local email="${2:?email required}"
  local docroot="${3:?docroot required}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would run: certbot certonly --webroot -w ${docroot} -d ${domain} --email ${email} --agree-tos --no-eff-email --non-interactive"
    return 0
  fi

  log_info "certbot: obtaining LE cert for ${domain} via HTTP-01 (webroot ${docroot})"
  certbot certonly --webroot \
    --webroot-path "${docroot}" \
    --domain "${domain}" \
    --email "${email}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    || { log_error "certbot: failed to obtain cert for ${domain}"; return 1; }
}

# certbot_self_signed DOMAIN -- generate a 4096-bit RSA self-signed cert valid 10y.
# Writes to LITESOUP_SSL_DIR/<domain>/{fullchain.pem,privkey.pem}.
certbot_self_signed() {
  local domain="${1:?domain required}"
  local dir="${LITESOUP_SSL_DIR}/${domain}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would generate self-signed cert at ${dir}/{fullchain,privkey}.pem"
    return 0
  fi

  install -d -m 0755 "${LITESOUP_SSL_DIR}"
  install -d -m 0755 "${dir}"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${dir}/privkey.pem" \
    -out "${dir}/fullchain.pem" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" \
    >/dev/null 2>&1 \
    || { log_error "certbot: openssl failed to generate self-signed cert for ${domain}"; return 1; }
  chmod 0644 "${dir}/fullchain.pem"
  chmod 0600 "${dir}/privkey.pem"
  log_info "certbot: self-signed cert ready for ${domain}"
}

# certbot_revoke DOMAIN -- best-effort revoke (LE) + delete (both modes). Used by
# site-delete. Never fails the calling script; revocation is courtesy.
certbot_revoke() {
  local domain="${1:?domain required}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would revoke LE cert + remove ${LITESOUP_SSL_DIR}/${domain}"
    return 0
  fi

  if [ -d "/etc/letsencrypt/live/${domain}" ]; then
    log_info "certbot: revoking LE cert for ${domain}"
    certbot revoke --non-interactive --cert-name "${domain}" 2>/dev/null || true
    certbot delete  --non-interactive --cert-name "${domain}" 2>/dev/null || true
  fi
  rm -rf "${LITESOUP_SSL_DIR:?}/${domain}" 2>/dev/null || true
}
