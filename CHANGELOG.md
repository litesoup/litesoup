# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
