# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-05-02

Plan I.F: caching infrastructure (Redis + Memcached) plus per-site
`WP_CACHE_KEY_SALT` injection. Closes codetot-web/litesoup#12.

This release ships **caching infrastructure**, not WordPress-side
caching configuration — that's a deliberate split. The stack now
installs Redis and Memcached with hardened defaults, and
`site-create.sh` wires every new site's `wp-config.php` so that any
cache plugin the user installs (Redis Object Cache, LiteSpeed Cache,
WP Rocket, etc.) Just Works. We do not auto-install WP plugins or ship
a server-level page cache (Apache `mod_cache_disk` etc.) because
server-level + plugin-level page caching produces stale-content bugs
that are painful to debug at scale. See [`docs/caching.md`](docs/caching.md)
for the full rationale and recommended plugin list.

### Added

- `install/lib/redis.sh` — `ensure_redis()` installs `redis-server`,
  generates a 32-char random password persisted to
  `/etc/litesoup/redis.env` (`0640 root:root`), and writes a managed
  override at `/etc/redis/litesoup.conf` with `bind 127.0.0.1 -::1`,
  `protected-mode yes`, `requirepass`, RAM-tier-sized `maxmemory`
  (small <2G→`128mb`, medium 2–8G→`512mb`, large ≥8G→`2gb`), and
  `maxmemory-policy allkeys-lru`. Smoke-tested via `AUTH+PING` after
  `systemctl restart`. Override the auto-tier with the new
  `--redis-maxmemory=SIZE` flag on `install-stack.sh`.
- `install/lib/memcached.sh` — `ensure_memcached()` installs
  `memcached` and appends a litesoup-managed block to
  `/etc/memcached.conf` enforcing `-l 127.0.0.1` and `-U 0` (UDP off,
  removing the historic amplification-attack vector). Block is
  idempotent — verified converged after 3 successive re-runs.
- `site/site-create.sh` — `download_wordpress()` now calls
  `inject_cache_constants()` after `wp config create`. Each constant
  is set via `wp config set --add` only if `wp config has` returns
  false, so re-runs against an existing site never rotate
  `WP_CACHE_KEY_SALT` (would invalidate live caches) or change Redis
  settings. Constants written: `WP_CACHE_KEY_SALT` (random 64-char
  hex per site — prevents cross-tenant Redis key collisions),
  `WP_REDIS_HOST=127.0.0.1`, `WP_REDIS_PORT=6379`, `WP_REDIS_PASSWORD`
  (read by root from `/etc/litesoup/redis.env` then passed to wp-cli
  via argv, matching existing `DB_PASS` handling), `WP_REDIS_DATABASE=0`.
  Gracefully degrades with a `log_warn` if `redis.env` is missing.
- `install/install-stack.sh` — sources the two new libs; adds stages
  7/8 (redis) and 8/8 (memcached); bumps existing 1/6..6/6 stage
  labels to /8; new `--redis-maxmemory=SIZE` flag with shape validation
  (e.g. `256mb`, `1gb`, raw bytes).
- `docs/caching.md` — what's installed and where, the per-site salt
  rationale and multi-tenant warning, recommended object/page cache
  plugins (Redis Object Cache + LiteSpeed/WP Rocket/W3TC), the
  Memcached caveat, verification snippets, and a migration one-liner
  for sites created before v0.5.0.
- `test/integration/01_install_stack.sh` — extends to assert
  redis-server + memcached active, password file shape/perms, override
  config contents, loopback-only binding (no external listeners),
  AUTH+PING, memcached UDP off, and re-run idempotency (password not
  rotated, configs unchanged, include directive count == 1, override
  flag flows through).
- `test/integration/02_site_create.sh` — extends to assert
  `WP_CACHE_KEY_SALT` shape (64-char hex), all four `WP_REDIS_*`
  constants present and matching the env file, two sites get distinct
  salts, and a `site-create.sh` re-run does NOT rotate the salt.
- `test/acceptance-i-f-run.sh` + `test/acceptance-i-f.md` — full local
  container acceptance harness plus the real-Ubuntu run procedure
  (`sg10.codetot.org`) required per
  `memory/project_real_acceptance_findings.md`.

### Changed

- `README.md` — install description lists `certbot`, `redis-server`,
  `memcached` (was missing); new "Caching" section pointing at
  `docs/caching.md`; removed the "Plan I.F future work" line item
  (now done).
- `install-stack.sh` `usage()` text documents `--redis-maxmemory` and
  the new install items.

### Out of scope (by design)

- No Apache `mod_cache_disk` / FastCGI page cache. Server-level page
  cache layered on top of a plugin page cache produces stale-content
  bugs that are hard to diagnose at scale.
- No auto-install of `redis-object-cache` or any other WP plugin. The
  user picks their plugin; the stack makes sure it works.
- No `site-set-cache` / `site-cache-purge` scripts. Cache invalidation
  belongs in WordPress (where the plugin has access to `save_post`,
  `comment_post`, theme/plugin update hooks).
- No automatic `WP_CACHE_KEY_SALT` rotation for existing sites — a
  documented manual one-liner is in `docs/caching.md`.

### Migration

Sites created with litesoup < 0.5.0 lack the new constants. Run the
per-site one-liner in `docs/caching.md` ("Migrating sites created
before v0.5.0") to add them. Existing Redis / Memcached configurations
on a host (e.g. installed by hand or by a previous version) are not
overwritten — `ensure_redis` only writes the managed include if its
content differs, and `ensure_memcached` only edits the managed block
between its BEGIN/END markers.

## [0.4.1] - 2026-05-02

Bugfix release. Two issues caught by the v0.4.0 acceptance run on real Ubuntu (`sg10.codetot.org`).

### Fixed

- **vhost template comment substitution bug** (commit `cbe1801`, ships as part of v0.4.0 history but documented here): `templates/apache/vhost.conf.tmpl` head comment block contained the literal placeholder strings `__HTTP_REDIRECT__` and `__HTTPS_BLOCK__`. Python's `str.replace()` substitutes inside `#`-comments, so with TLS active the multi-line HTTPS block dumped into a comment line broke the comment boundary and Apache's `apache2ctl configtest` failed (`</VirtualHost> without matching <VirtualHost>`). Net: every `--tls=letsencrypt` or `--tls=self-signed` site since v0.3.0 ships rendered an invalid vhost. Affects v0.3.0 through v0.4.0; fix landed before v0.4.0 published, so users only see this if they cherry-picked from a pre-`cbe1801` commit.
- **`site-create.sh` DB password idempotency** (closes codetot-web/litesoup#9): `create_database` generated a fresh random password every run AND used `CREATE USER IF NOT EXISTS` which silently keeps the OLD password if the user exists. A site-create that aborted partway (e.g., apache configtest fail, network glitch on certbot) and was re-run wrote a NEW password to `wp-config.php` while MySQL kept the OLD password — WordPress returned 500 with `Error establishing a database connection`. Now: if `wp-config.php` already exists, reuse its password; either way, the SQL emits both `CREATE USER IF NOT EXISTS` AND `ALTER USER ... IDENTIFIED BY '<pw>'` so MySQL always matches `wp-config.php`. Self-healing on retry.

### Added

- 2 new bats tests in `unit_site_create.bats` covering the `create_database` SQL emit (`CREATE USER` + `ALTER USER` always present with the same password) and the wp-config.php password reuse parser.

### Acknowledged false positive (closed)

- codetot-web/litesoup#10 (pool template missing `log_errors`): the `php_admin_flag[log_errors] = on` line IS present in the template at line 22 and renders correctly. The reason `/home/<user>/.logs/php<v>-fpm.error.log` didn't exist on sg10 was that PHP had no fatal error to log — WordPress's 500 was an application-level HTML response. Issue closed.

[0.4.1]: https://github.com/codetot-web/litesoup/releases/tag/v0.4.1

## [0.4.0] - 2026-05-02

Plan I.C: `site-set-php` + per-tier FPM pool sizing. Closes the two pool-management gaps left after Plan I.B (multi-version PHP) — existing sites can now flip PHP version, and pools can be sized for actual workload. v0.3 callers keep working unchanged.

### Added

- `site/site-set-php.sh --domain=X --php=Y` operation: flip an existing site to a different PHP version. Looks up owner / docroot / TLS mode from the existing vhost, ensures the per-user pool exists for the new version (creates it if first site for owner+new-version), re-renders the vhost so the FPM SetHandler points at the new socket, runs apache reload. No DB / docroot / WP changes; TLS mode is preserved automatically (detected from the existing vhost).
- `site/site-set-tier.sh --user=NAME --version=X.Y --tier=TIER` operation: retune the FPM pool for a user+version. Pool conf is re-rendered with the new tier's `pm.*` block and `php<v>-fpm` is reloaded. Idempotent: re-running with the current tier is a no-op.
- `site-create.sh --tier=small|medium|large` flag: selects FPM pool sizing at site creation time. Default `small` (v0.3 back-compat).
- `install/lib/php.sh` additions: `SUPPORTED_POOL_TIERS=(small medium large)`, `validate_pool_tier`, `php_pool_tier_block <tier>` helper that emits the `pm.*` block for the requested tier. `ensure_php_pool_for_user` gains an optional 3rd `tier` arg (default `small`).
- New `_php_pool_current_tier` helper inspects an existing pool conf's `pm.max_children` to detect tier (5→small, 20→medium, 50→large). Used by `ensure_php_pool_for_user` to no-op same-tier re-runs.
- New bats unit suites: `unit_site_set_php.bats` (6 tests), `unit_site_set_tier.bats` (6 tests). 7 new tier-related tests appended to `unit_php.bats`. 4 new `--tier=` tests appended to `unit_site_create.bats`. Total bats coverage: 51 → 77.
- `test/acceptance-i-c-run.sh`: docker harness validates `--tier=medium` writes the right `pm.*` lines, `site-set-php` flips an existing site's PHP version (curl phpinfo confirms before + after), `site-set-tier --tier=large` retunes the pool, idempotency re-run is a no-op.

### Changed

- `templates/php/pool.conf.tmpl`: hardcoded `pm.*` lines replaced with `__TIER_BLOCK__` placeholder. The placeholder is filled by `php_pool_tier_block <tier>` at render time. v0.3 sites already on disk are untouched until the next `ensure_php_pool_for_user` call (which keeps tier=small if no third arg is passed — matches v0.3 semantics).
- `ensure_php_pool_for_user` rendering switched from `sed` to `python3` (the multi-line `__TIER_BLOCK__` doesn't survive sed substitution). `python3` is in the install-stack baseline since Plan I.D pulled it in via `python3-certbot-apache`.
- `php-fpm --test` stderr is now captured to a temp file and printed on failure (was previously silenced via `2>/dev/null`). Operators see the actual syntax error on the rare case of a malformed pool conf.

### Tier reference

| Tier | `pm` | `pm.max_children` | `pm.start_servers` | `pm.max_requests` |
|------|------|------------------:|-------------------:|------------------:|
| `small` (default) | `ondemand` | 5 | 1 | 500 |
| `medium` | `dynamic` | 20 | 4 | 1000 |
| `large` | `dynamic` | 50 | 10 | 2000 |

### Known limitations (deferred)

- Tier is per pool (per-user+version), not per site. Workaround: use `--user=NAME` to give a site its own system user.
- No custom tier definitions — three presets only. Advanced users edit `php_pool_tier_block` in `install/lib/php.sh` directly.
- `site-set-php` doesn't change tier; `site-set-tier` doesn't change PHP version. Run them separately if you need both.
- Caching (Redis object cache, Apache FastCGI cache, Memcached) → Plan I.F.

[0.4.0]: https://github.com/codetot-web/litesoup/releases/tag/v0.4.0

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
