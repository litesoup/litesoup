# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-05-02

Plan I.D: TLS / Let's Encrypt. `site-create` and the new `site-set-tls` provision per-site HTTPS with auto-renewal. v0.2 callers (no `--tls=` flag) keep working unchanged.

### Added

- `site-create.sh --tls=letsencrypt|self-signed|none --email=ADDR` flag for per-site TLS at creation. `--tls=letsencrypt` requires `--email`; runs HTTP-01 challenge via Apache `.well-known/acme-challenge` after the HTTP-only vhost is up, then re-renders with the HTTPS block.
- `site-set-tls.sh --domain=X --tls=Y [--email=Z]` operation: retroactively flip an existing v0.2 (or `--tls=none`) site to HTTPS. Looks up owner / php-version / docroot from the existing vhost, runs cert provisioning, rewrites the vhost. No DB / docroot / WP changes.
- New `install/lib/certbot.sh` module: `ensure_certbot`, `ensure_certbot_renewal_timer`, `certbot_obtain`, `certbot_self_signed`, `certbot_revoke`, `certbot_paths_for_domain`.
- New `site/_vhost_render.sh` shared lib: `write_vhost`, `existing_site_owner`, `existing_site_php`, `existing_site_docroot`. Used by `site-create.sh` and `site-set-tls.sh`. Renders the template via `python3` (already pulled in as a dep of `python3-certbot-apache`) so multi-line replacement is safe.
- HTTPS vhost block: HTTP/2 (`Protocols h2 http/1.1`), TLSv1.2 + TLSv1.3 only, ECDHE-only ciphers, HSTS 1y + `includeSubDomains`, `Secure` flag on all cookies (`Header edit Set-Cookie`), HTTP→HTTPS 301 redirect on port 80 (with `/.well-known/acme-challenge/` exception so renewal works).
- `install-stack.sh` stage 6/6: installs `certbot` + `python3-certbot-apache` from the Ubuntu archive (no PPA needed) and enables `certbot.timer` for auto-renewal.
- `install/lib/apache.sh` baseline now enables `mod_http2` (free with the existing `apache2` package).
- New bats unit suites: `unit_certbot.bats` (3 tests), `unit_site_set_tls.bats` (4 tests). 6 new tests appended to `unit_site_create.bats` covering `--tls` and `--email` flag combinations. Total bats coverage: 51 tests.
- `test/acceptance-i-d-run.sh`: docker harness extended to provision `alpha.test` with `--tls=self-signed`, curl `https://...` (with `-k` for the self-signed cert), assert HTTP→HTTPS 301 redirect, then run `site-set-tls beta.test --tls=self-signed` to validate the retroactive upgrade path.

### Changed

- `templates/apache/vhost.conf.tmpl`: now contains conditional placeholders `__HTTP_REDIRECT__` and `__HTTPS_BLOCK__`. When `--tls=none` both are empty strings (back-compat with v0.2 sites). When TLS is active, the rendered vhost includes the full HTTPS server block plus HTTP→HTTPS redirect. Always-on `/.well-known/acme-challenge/` Alias on port 80 so renewal keeps working even after the rest of the site redirects.
- `site-delete.sh` now best-effort revokes the LE cert (`certbot revoke --cert-name X`) and removes the `/etc/litesoup/ssl/<domain>/` dir on teardown. Safe to run on v0.2 sites with no TLS.
- `install-stack.sh` stage labels renumbered from `1/5..5/5` to `1/6..5/6` to make room for stage 6 (certbot).
- `install/lib/php.sh` write_vhost is gone from `site-create.sh` — moved to the shared lib `site/_vhost_render.sh` so `site-set-tls.sh` can reuse it.

### Known limitations (deferred)

- No `site-renew-tls` wrapper for forced renewal — use `certbot renew --force-renewal --cert-name X` directly.
- No OCSP stapling — Plan I.E.
- No domain-reachability gate before LE attempt — LE itself errors clearly; user re-runs with `--tls=self-signed`.
- HTTP-01 challenge only — no DNS-01, no wildcard certs.
- HSTS preload header is set but no automatic preload-list submission.

[0.3.0]: https://github.com/codetot-web/litesoup/releases/tag/v0.3.0

## [0.2.0] - 2026-05-02

Plan I.B: multi-version PHP. Builds directly on v0.1.0 — per-user pool naming was already pre-formatted as `<user>-php<version>` so on-disk layout, vhost template, and pool template are unchanged.

### Added

- `install-stack.sh --php-versions=X.Y[,X.Y…]` installs any subset of PHP `{8.0, 8.1, 8.2, 8.3, 8.4, 8.5}` side-by-side via the Ondrej PPA. Default if the flag is omitted: `8.2,8.3,8.4`. The default version (`PHP_VERSION_DEFAULT`, currently 8.2) must be in the install set.
- `site-create.sh --php=X.Y` selects the PHP version per site (default `PHP_VERSION_DEFAULT`). Validated against installed versions.
- `SUPPORTED_PHP_VERSIONS` array + `validate_php_version` helper in `install/lib/php.sh`.
- `ensure_php_fpm <version>` and `ensure_php_pool_for_user <user> <version>` parameterized helpers.
- New bats unit suites: `unit_php.bats` (11 tests), `unit_install_stack.bats` (5 tests), `unit_site_create.bats` (4 tests). Total bats coverage: 38 tests.
- `LITESOUP_TEST_STUBS` env hook in `site-create.sh` so bats can replace functions that need real root / a real system.
- Acceptance test `test/acceptance-i-b-run.sh` and reference log `test/acceptance-i-b.log` — two sites at PHP 8.2 + 8.4 on the same host, both serving the WordPress install screen, idempotency re-run.

### Fixed

- `ensure_ppa` falls back to manual PPA registration on **any** `add-apt-repository` failure (was previously only triggered on Launchpad 504/timeout). Caught during Plan I.B Docker acceptance: the container hit `OSError: [Errno 99] Cannot assign requested address` from `launchpadlib`'s IPv6 connect attempt, which the old grep didn't match — installer aborted instead of falling through to the working keyserver path. Now any failure tries the manual route if a key mapping exists.

### Deprecated

- `ensure_php_82_fpm` — use `ensure_php_fpm 8.2` instead. Kept as a back-compat shim with a `log_warn`. Removed in v0.3.0.
- `ensure_php_82_pool_for_user` — use `ensure_php_pool_for_user <user> 8.2` instead. Same shim treatment. Removed in v0.3.0.

### Unchanged

- v0.1.0 callers (anyone sourcing `install/lib/php.sh` and calling the `_82` functions) continue to work via the shims.
- `site-delete.sh`, vhost template, pool template — no changes required.

### Known limitations (deferred)

- Cannot change a live site's PHP version (no `site-set-php` yet) → Plan I.C.
- All pools share the v0.1.0 default sizing (`pm.max_children=5`, `pm=ondemand`) → Plan I.C will introduce per-tier sizing.
- Cannot remove an installed PHP version (no `install-stack --remove-php=X.Y` yet) → Plan I.D.

## [0.1.0] - 2026-05-01

First public release. Implements [Plan I.A](https://github.com/codetot-web/litesoup/pull/2): a one-line bash installer that turns a fresh Ubuntu 24.04 host into a working WordPress server.

### Added

#### Stack installer (`install/install-stack.sh`)

- Apache 2.4 with `mpm_event` + `mod_proxy_fcgi` + `mod_rewrite` + `mod_headers` + `mod_ssl`
- PHP 8.2 (FPM + CLI) via the [Ondrej Surý PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php), full WordPress extension set (`opcache`, `mysql`, `mbstring`, `xml`, `curl`, `gd`, `zip`, `intl`, `bcmath`, `soap`, `imagick`, `redis`)
- MariaDB 10.x with non-interactive secure baseline (random root password stored at `/root/.litesoup-mariadb-root` mode `0600`)
- wp-cli installed to `/usr/local/bin/wp` with sha512 verification
- Default site user `litesoup` (no shell, `/home/litesoup` mode `0711`) plus a per-user PHP-FPM pool at `/run/php/litesoup-php8.2-fpm.sock`

#### Per-user FPM pool model (security boundary)

- PHP runs as the **site owner UID**, never as `www-data`. Apache (running as `www-data`) only proxies requests through the unix socket.
- The default Ubuntu `www-data` pool is **disabled** (renamed to `www.conf.disabled`)
- Per-user `open_basedir` confines PHP to `/home/<user>/webapps/`, `/home/<user>/.php_tmp/`, and `/home/<user>/.php_sessions/` — no shared `/tmp` or system session paths
- `disable_functions` blocks `exec`, `passthru`, `shell_exec`, `system`, `proc_open`, `popen`, `pcntl_exec`, `proc_get_status` (none used by WordPress core)
- `expose_php = off`, `allow_url_fopen = off`, `allow_url_include = off`
- `pm = ondemand` with `pm.max_children = 5` (sensible default; tunable in Plan I.B)

#### Site lifecycle

- `site/site-create.sh --domain=<d> [--user=<u>] [--dry-run]` — provisions the system user (if missing) + per-user FPM pool + MariaDB DB + DB user + docroot at `/home/<user>/webapps/<domain>/` (owned by `<user>:<user>`) + WordPress core via wp-cli + `wp-config.php`
- `site/site-delete.sh --domain=<d> [--user=<u>] [--purge-db] [--dry-run]` — removes the Apache vhost and docroot, optionally drops the DB and DB user; preserves the system user and per-user FPM pool (other sites may share)

#### Testing & CI

- 18 bats-core unit tests covering `common`, `distro`, `apt`, and `users` libs (`test/bats/`)
- 3 systemd-Docker integration tests (`test/integration/`):
  - `01_install_stack.sh` — full installer + idempotent re-run
  - `02_site_create.sh` — site provisioning + `curl` assertion that the WordPress install screen renders
  - `03_site_delete.sh` — site removal + `--purge-db` cleanup
- GitHub Actions workflow with `shellcheck -x`, bats unit suite, and the three integration jobs (`.github/workflows/ci.yml`)

### Acceptance

```bash
sudo bash install/install-stack.sh
sudo bash site/site-create.sh --domain=example.test
curl -H 'Host: example.test' http://127.0.0.1/wp-admin/install.php
# → returns the WordPress installation screen
```

### Known limitations (deferred to follow-on sub-plans)

- **Plan I.B** — multi-version PHP (8.0/8.1/8.3/8.4/8.5) + per-site `--php=X.Y`
- **Plan I.C** — Redis + Memcached + per-site Apache FastCGI cache + Redis object cache auto-config
- **Plan I.D** — `ufw`, `fail2ban`, `unattended-upgrades`, certbot/TLS, broader hardening, Sigstore-signed releases, distro detection beyond Ubuntu 24.04

[0.2.0]: https://github.com/codetot-web/litesoup/releases/tag/v0.2.0
[0.1.0]: https://github.com/codetot-web/litesoup/releases/tag/v0.1.0
