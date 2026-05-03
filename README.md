# litesoup

> An opinionated, lean WordPress server stack and fleet dashboard.

Litesoup is a one-line bash installer that turns a fresh Ubuntu 24.04 server into a hardened WordPress host, paired with a single-binary Go dashboard for managing one or many servers and a scoped tenant portal for end users.

## Status

**v0.4 — Plan I.C landed (2026-05-02):** `site-set-php` flips PHP version on an existing site (TLS preserved); `--tier=small|medium|large` selects FPM pool sizing on `site-create` (default small, 5 workers); `site-set-tier` retunes a pool retroactively. v0.3 callers keep working via the `small` default.

**v0.3 — Plan I.D (2026-05-02):** TLS / Let's Encrypt. `site-create --tls=letsencrypt --email=ADDR` provisions real LE certs via HTTP-01; `--tls=self-signed` for local/internal sites; auto-renewal via `certbot.timer`. Existing v0.2 sites can be flipped to HTTPS retroactively with `site-set-tls`. v0.2 callers (no `--tls=` flag) keep working unchanged.

**v0.2 — Plan I.B (2026-05-02):** multi-version PHP. Install any subset of PHP 8.0–8.5 side-by-side; pick the version per site with `--php=X.Y`. v0.1.0 callers keep working via deprecated shims.

**v0.1 — Plan I.A (2026-05-01):** initial MVP WordPress stack installer.

## Quickstart (Ubuntu 24.04 only)

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh                                                              # PHP 8.2 + 8.3 + 8.4 + certbot
sudo bash site/site-create.sh --domain=blog.example.com --tls=letsencrypt --email=ops@example.com  # HTTPS public site
sudo bash site/site-create.sh --domain=alpha.test --tls=self-signed                             # HTTPS local/dev site
sudo bash site/site-create.sh --domain=legacy.test --php=8.1                                    # HTTP-only (back-compat)
curl -k -H 'Host: alpha.test' https://127.0.0.1/wp-admin/install.php
```

## FPM pool sizing + version flips (v0.4)

`--tier=small|medium|large` on `site-create.sh` (or the `site-set-tier.sh` operation) selects FPM pool sizing for a per-user+version pool.

| Tier | `pm` | `max_children` | `max_requests` | Use case |
|------|------|---------------:|---------------:|----------|
| `small` (default) | `ondemand` | 5 | 500 | Low-traffic sites, dev |
| `medium` | `dynamic` | 20 | 1000 | Production sites |
| `large` | `dynamic` | 50 | 2000 | High-traffic sites |

**Tier is per pool, not per site.** A pool is identified by `<user>-php<version>`, so all sites for the same owner+PHP-version share the tier. If you need per-site sizing, use `--user=NAME` to give that site its own system user (and therefore its own pool).

`site-set-php.sh --domain=DOMAIN --php=X.Y` flips an existing site to a different PHP version. TLS mode is preserved automatically (auto-detected from the existing vhost).

```bash
# Create a high-traffic production site with TLS
sudo bash site/site-create.sh --domain=blog.example.com --tls=letsencrypt --email=ops@example.com --tier=large

# Retune an existing pool (small -> medium)
sudo bash site/site-set-tier.sh --user=litesoup --version=8.2 --tier=medium

# Change PHP version of an existing site (TLS preserved)
sudo bash site/site-set-php.sh --domain=blog.example.com --php=8.4
```

## TLS / HTTPS (v0.3)

`site-create.sh --domain=DOMAIN --tls=MODE [--email=ADDR]` provisions HTTPS during site creation.

- `--tls=letsencrypt` (requires `--email=ADDR`): real Let's Encrypt cert via HTTP-01 challenge. Auto-renewed by `certbot.timer` (enabled by `install-stack`).
- `--tls=self-signed`: openssl-generated 4096-bit RSA cert at `/etc/litesoup/ssl/<domain>/`. Use for local / internal / `.test` / `.local` domains.
- `--tls=none` (default): HTTP only, v0.2 behavior.

When TLS is active, the vhost includes:

- HTTPS on port 443 with HTTP/2 (`Protocols h2 http/1.1`)
- TLSv1.2 + TLSv1.3 only, ECDHE-only ciphers
- HSTS (`max-age=31536000; includeSubDomains`)
- HTTP→HTTPS 301 redirect on port 80 (with `/.well-known/acme-challenge/` exception so renewal works)
- `Secure` flag added to all `Set-Cookie` headers

`site-set-tls.sh --domain=DOMAIN --tls=MODE [--email=ADDR]` retroactively sets TLS on an existing v0.2 (or `--tls=none`) site. Same flag set as `site-create`'s TLS subset.

```bash
# Public site with real LE cert
sudo bash site/site-create.sh --domain=blog.example.com --tls=letsencrypt --email=ops@example.com

# Local dev site, self-signed
sudo bash site/site-create.sh --domain=alpha.test --tls=self-signed

# Upgrade an existing HTTP-only site to LE
sudo bash site/site-set-tls.sh --domain=oldsite.example.com --tls=letsencrypt --email=ops@example.com

# Force-renew a cert (manual; certbot.timer handles auto-renewal)
sudo certbot renew --cert-name blog.example.com --force-renewal
```

## Multi-version PHP (v0.2)

`install-stack.sh --php-versions=X.Y[,X.Y…]` installs any subset of `8.0, 8.1, 8.2, 8.3, 8.4, 8.5` side-by-side via the Ondrej PPA. Default if the flag is omitted: `8.2,8.3,8.4`. The default version (`PHP_VERSION_DEFAULT`, currently 8.2) must be in the install set so the default user has a pool to land on.

`site-create.sh --domain=DOMAIN --php=X.Y` pins a site to the chosen PHP version (default 8.2). The version must already be installed.

Each site owner gets one FPM pool per version it uses, named `<user>-php<version>` and listening on `/run/php/<user>-php<version>-fpm.sock`. A user can host multiple sites at different PHP versions (one pool per active version).

```bash
# Install PHP 8.2 + 8.4 only
sudo bash install/install-stack.sh --php-versions=8.2,8.4

# Site on PHP 8.2 (default)
sudo bash site/site-create.sh --domain=alpha.test

# Site on PHP 8.4
sudo bash site/site-create.sh --domain=beta.test --php=8.4
```

## What's installed by `install-stack.sh`

- **Apache 2.4** with `mpm_event` + `mod_proxy_fcgi` + `mod_rewrite` + `mod_headers` + `mod_ssl`
- **PHP** (FPM + CLI) via the [Ondrej Surý PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php), with the standard WordPress extension set (`opcache`, `mysql`, `mbstring`, `xml`, `curl`, `gd`, `zip`, `intl`, `bcmath`, `soap`, `imagick`, `redis`). Default install set: `8.2, 8.3, 8.4`. Other versions in `8.0–8.5` available via `--php-versions=`.
- **MariaDB 10.x** with non-interactive secure baseline (random root password stored at `/root/.litesoup-mariadb-root` mode `0600`)
- **wp-cli** (installed to `/usr/local/bin/wp`, sha512-verified)
- **certbot** (Let's Encrypt) with auto-renewal via the `certbot.timer` systemd timer
- **Redis 7.x** bound to `127.0.0.1` with `requirepass` set (random 32-char password persisted to `/etc/litesoup/redis.env` mode `0640 root:root`), `maxmemory` sized per RAM tier (small <2G→128mb, medium 2–8G→512mb, large ≥8G→2gb), `maxmemory-policy allkeys-lru`. Override with `--redis-maxmemory=SIZE`. See [`docs/caching.md`](docs/caching.md).
- **Memcached** bound to `127.0.0.1` with UDP disabled (`-U 0`)
- A system user **`litesoup`** (no shell, home `/home/litesoup` mode `0711`) and a **per-user PHP-FPM pool** at `/run/php/litesoup-php8.2-fpm.sock` running as the `litesoup` user with `open_basedir` confined to `/home/litesoup/webapps/`. The default Ubuntu `www-data` pool is **disabled** — every site runs under its owner UID, never as Apache.

### Hardening baked into the per-user pool

- `disable_functions` blocks `exec`, `passthru`, `shell_exec`, `system`, `proc_open`, `popen`, `pcntl_exec`, `proc_get_status` (none used by WordPress core)
- `expose_php = off`, `allow_url_fopen = off`, `allow_url_include = off`
- `open_basedir` scoped to per-user dirs only — no shared `/tmp` or system session paths
- `pm = ondemand` with `pm.max_children = 5` (sane default for v1 + v0.2; per-tier sizing comes in Plan I.C)

## Filesystem layout

```
/home/litesoup/                      0711 litesoup:litesoup   (no shell, no login)
├── webapps/
│   └── <domain>/                    0755 litesoup:litesoup
│       ├── wp-config.php
│       └── (WP core)
├── .php_tmp/                        0700 — open_basedir-only tmp for this user
├── .php_sessions/                   0700 — per-user PHP session store
└── .logs/                           0700 — per-user FPM/error logs
```

To run a site under a different system user (e.g., per-client isolation), pass `--user=NAME` to `site-create.sh`. The user is created on demand and gets its own FPM pool at `/run/php/<user>-php8.2-fpm.sock`.

## Hardening

`install-stack.sh` also runs three hardening scripts at the end (stages
9–11), each idempotent and standalone-runnable:

- **`harden/harden-firewall.sh`** — ufw with `deny incoming` / `allow
  outgoing`, opens sshd's actual port (parsed from `sshd_config`,
  fallback 22) plus 80/tcp + 443/tcp, then `ufw --force enable`.
- **`harden/harden-fail2ban.sh`** — fail2ban with managed `[sshd]`
  jail (systemd backend, 3 retries / 1h ban, port matches sshd_config)
  and `[apache-auth]` jail (5 retries / 1h ban). Apache jail skipped
  if Apache isn't installed.
- **`harden/harden-unattended-upgrades.sh`** — security-only
  auto-updates (no auto-reboot, no mail), via a `52litesoup-unattended`
  override that survives package updates of the default config.

Pass `--skip-hardening` to `install-stack.sh` to skip these on dev
VMs / hosts where the firewall is managed elsewhere.

## Auditing

Read-only check scripts under `audit/`. None of them mutate state.
Run any of them standalone with `--help` to see options.

- **`audit/audit-wp-health.sh`** — per-site WP health (core version,
  plugins, DB, disk, perms, TLS expiry, error log size). Exit code
  reflects severity (0/1/2 = healthy/warning/critical).
- **`audit/audit-system-metrics.sh`** — CPU / memory / disk / net /
  Apache / PHP-FPM / MariaDB / Redis metrics in text or JSON.
- **`audit/audit-wp-vulnerabilities.sh`** — per-site CVE scan against
  the free WPVulnerability.net API.
- **`audit/audit-performance.sh`** — compares live config of Apache,
  PHP-FPM, OPcache, MariaDB, Redis against recommended values for the
  system's RAM tier; flags drift with WARN/CRIT severity.

## Caching

Redis and Memcached are installed by `install-stack.sh`. `site-create.sh`
injects per-site `WP_CACHE_KEY_SALT` (random, prevents cross-tenant Redis
key collisions) plus `WP_REDIS_HOST/PORT/PASSWORD/DATABASE` into every
new site's `wp-config.php`. Pick the WP cache plugin you want (Redis
Object Cache for object cache; LiteSpeed Cache / W3TC / WP Rocket for
page cache) — they read those constants and Just Work.

litesoup does **not** ship a server-level page cache (Apache
`mod_cache_disk` etc.). Server-level page cache layered on top of a
plugin page cache produces stale-content bugs that are painful to
diagnose. Full details and recommended plugins: [`docs/caching.md`](docs/caching.md).

## What's deferred to later sub-plans

- **Plan I.E (Wave 2/3)** — Sigstore-signed installer releases, OCSP stapling, distro detection beyond Ubuntu 24.04, `install-stack --remove-php=X.Y`, broader per-service hardening (ssh, apache, php, mariadb, redis)
- **Plan H (Wave 2/3)** — `tune/`, `maintain/`, `monitor/` package ports
- **Plans A / J / E** — VPS migration, two-tier dashboard, client tenant portal

## Testing

All work is tested in two tiers and gated by CI:

```bash
# Unit (bats)
./test/bats/bats-core/bin/bats test/bats/

# Integration (systemd-enabled Docker)
./test/docker/run-integration.sh 01_install_stack.sh
./test/docker/run-integration.sh 02_site_create.sh
./test/docker/run-integration.sh 03_site_delete.sh
```

Requires Docker Desktop / OrbStack / colima (any Docker Engine that supports `--privileged` containers with `/sys/fs/cgroup` mounted).

## Requirements

- Ubuntu 24.04 LTS (x86_64) — strict in v1
- Root or sudo access
- A domain pointing at the server (required for `--tls=letsencrypt`; HTTP-only and `--tls=self-signed` work without public DNS)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
