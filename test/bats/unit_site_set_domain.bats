#!/usr/bin/env bats

load test_helper

@test "site-set-domain help mentions --name and --new-domain" {
  run -0 bash "${REPO_ROOT}/site/site-set-domain.sh" --help
  assert_output --partial "--name=APP"
  assert_output --partial "--new-domain=NEW"
}

@test "site-set-domain --dry-run issues NO cert calls (guards steps 1 and 5)" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
_find_vhost() { echo "/etc/apache2/sites-available/example.test.conf"; }
existing_site_owner() { echo "litesoup"; }
existing_site_php() { echo "8.2"; }
existing_site_docroot() { echo "/home/litesoup/webapps/example.test"; }
write_vhost() { echo "VHOST: tls=${TLS_MODE} domain=${DOMAIN}"; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
certbot_revoke() { echo "REVOKE: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=1 \
    bash "${REPO_ROOT}/site/site-set-domain.sh" \
      --domain=example.test --new-domain=new.test --tls=letsencrypt --email=admin@example.test --dry-run
  assert_output --partial "[DRYRUN] would re-issue TLS cert for new.test"
  assert_output --partial "[DRYRUN] would revoke old-domain cert for example.test"
  refute_output --partial "OBTAIN:"
  refute_output --partial "SELFSIGNED:"
  refute_output --partial "REVOKE:"
}

@test "site-set-domain without --dry-run calls cert functions" {
  STUBS_FILE="${BATS_TEST_TMPDIR}/stubs.sh"
  cat >"${STUBS_FILE}" <<'STUBS'
require_root() { :; }
_find_vhost() { echo "/etc/apache2/sites-available/example.test.conf"; }
existing_site_owner() { echo "litesoup"; }
existing_site_php() { echo "8.2"; }
existing_site_docroot() { echo "/home/litesoup/webapps/example.test"; }
write_vhost() { echo "VHOST: tls=${TLS_MODE} domain=${DOMAIN}"; }
certbot_obtain() { echo "OBTAIN: $*"; }
certbot_self_signed() { echo "SELFSIGNED: $*"; }
certbot_revoke() { echo "REVOKE: $*"; }
a2dissite() { echo "A2DISSITE: $*"; }
systemctl() { echo "SYSTEMCTL: $*"; }
rm() { echo "RM: $*"; }
STUBS
  run -0 env LITESOUP_ALLOW_TEST_STUBS=1 LITESOUP_TEST_STUBS="${STUBS_FILE}" DRY_RUN=0 \
    bash "${REPO_ROOT}/site/site-set-domain.sh" \
      --domain=example.test --new-domain=new.test --tls=self-signed
  assert_output --partial "SELFSIGNED: new.test"
  assert_output --partial "REVOKE: example.test"
}

@test "site-set-domain requires --new-domain" {
  run -64 bash "${REPO_ROOT}/site/site-set-domain.sh" --name=myapp
  assert_output --partial "--new-domain=NEW is required"
}