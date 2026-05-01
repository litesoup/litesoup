# litesoup

> An opinionated, lean WordPress server stack and fleet dashboard.

Litesoup is a one-line bash installer that turns a fresh Ubuntu 24.04 server into a hardened WordPress host, paired with a single-binary Go dashboard for managing one or many servers and a scoped tenant portal for end users.

## Status

**v0.1 — Plan I.A landed (2026-05-01):** the MVP WordPress stack installer is shippable. A fresh Ubuntu 24.04 host can be turned into a working WordPress server in one command.

## Quickstart (Ubuntu 24.04 only)

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh
sudo bash site/site-create.sh --domain=example.test
curl -H 'Host: example.test' http://127.0.0.1/wp-admin/install.php
```

## What's installed by `install-stack.sh`

- **Apache 2.4** with `mpm_event` + `mod_proxy_fcgi` + `mod_rewrite` + `mod_headers` + `mod_ssl`
- **PHP 8.2** (FPM + CLI) via the [Ondrej Surý PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php), with the standard WordPress extension set (`opcache`, `mysql`, `mbstring`, `xml`, `curl`, `gd`, `zip`, `intl`, `bcmath`, `soap`, `imagick`, `redis`)
- **MariaDB 10.x** with non-interactive secure baseline (random root password stored at `/root/.litesoup-mariadb-root` mode `0600`)
- **wp-cli** (installed to `/usr/local/bin/wp`, sha512-verified)
- A system user **`litesoup`** (no shell, home `/home/litesoup` mode `0711`) and a **per-user PHP-FPM pool** at `/run/php/litesoup-php8.2-fpm.sock` running as the `litesoup` user with `open_basedir` confined to `/home/litesoup/webapps/`. The default Ubuntu `www-data` pool is **disabled** — every site runs under its owner UID, never as Apache.

### Hardening baked into the per-user pool

- `disable_functions` blocks `exec`, `passthru`, `shell_exec`, `system`, `proc_open`, `popen`, `pcntl_exec`, `proc_get_status` (none used by WordPress core)
- `expose_php = off`, `allow_url_fopen = off`, `allow_url_include = off`
- `open_basedir` scoped to per-user dirs only — no shared `/tmp` or system session paths
- `pm = ondemand` with `pm.max_children = 5` (sane default for v1; tuneable in Plan I.B)

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

## What's deferred to later sub-plans

- **Plan I.B** — multi-version PHP (8.0/8.1/8.3/8.4/8.5) + per-site `--php=X.Y` flag
- **Plan I.C** — Redis + Memcached + per-site Apache FastCGI cache + Redis object cache auto-config
- **Plan I.D** — `ufw`, `fail2ban`, `unattended-upgrades`, certbot/TLS, broader hardening, distro-detection beyond Ubuntu 24.04, and Sigstore-signed releases
- **Plan H** — bash-scripts reorganization into `audit/`, `harden/`, `tune/` directories
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
- A domain pointing at the server (only needed once Plan I.D adds TLS; HTTP works today)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
