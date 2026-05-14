---
layout: default
title: Architecture
nav_order: 8
---

# How litesoup is built

## Design choices in one paragraph

litesoup runs WordPress on bare-metal Ubuntu — Apache, PHP-FPM, MariaDB, Redis, and Memcached straight from apt — not Docker per app, not Kubernetes, not anything fancy. Each site gets its own Linux user and its own PHP-FPM pool running under that user's UID, instead of the usual shared `www-data` model. Every script is idempotent: re-running `install-stack.sh` on a host that's already set up is a no-op (or surgically fixes drift), never a destructive replay. The first release (v0.1.0) put a security boundary around per-user FPM pools as the headline feature; the caching release (v0.5.0) doubled down on the bare-metal stance by shipping infrastructure (Redis + Memcached locked to localhost) instead of a server-level page cache, on the grounds that server-level + plugin-level page caching layered together produces stale-content bugs that are painful to debug at scale. The whole stack is built for one operator running 5–50 small/medium WordPress sites on a single VPS, and every decision is tuned for that scale.

## Filesystem layout

Each site owner is a real Linux user. Their home directory holds the docroot, plus three private runtime directories that PHP-FPM uses:

```
/home/<user>/                  0711 <user>:<user>
├── webapps/
│   └── <domain>/              0755 <user>:<user>
│       ├── wp-config.php
│       └── (WP core)
├── .php_tmp/                  0700 — open_basedir-only tmp
├── .php_sessions/             0700 — per-user PHP sessions
└── .logs/                     0700 — per-user FPM/error logs
```

Mode `0711` on `/home/<user>/` is deliberate: other UIDs can traverse the directory (so Apache can `stat` the docroot) but cannot list it. Sessions, tmp, and logs are `0700` — only the owner reads them.

litesoup also writes a small set of system-level config files. They all live under predictable paths and are marked as managed in the file body:

- `/etc/litesoup/redis.env` — `0640 root:root`, holds `REDIS_PASSWORD=…`. Generated once and reused on every re-run.
- `/etc/redis/litesoup.conf` — managed override pulled in via `include` from `/etc/redis/redis.conf`.
- `/etc/memcached.conf` — managed block delimited by BEGIN/END markers; the rest of the file is left alone.
- `/etc/ssh/sshd_config.d/52-litesoup-harden.conf` — sshd hardening (never edits the package-managed main config).
- `/etc/apache2/conf-available/52-litesoup-*.conf` — Apache hardening + mod_status restriction.
- `/etc/php/<v>/{cli,fpm}/conf.d/52-litesoup-harden.ini` — global php.ini hardening, written once per installed PHP version.
- `/etc/apt/apt.conf.d/52litesoup-unattended` — unattended-upgrades policy.
- `/etc/fail2ban/jail.d/litesoup-*.local` — sshd + Apache jails.

Everything litesoup-managed uses the `52-` prefix so it sorts predictably among other vendor drop-ins.

## Why per-user FPM, not shared www-data

The default Ubuntu `www.conf` pool runs PHP as `www-data`. So does every WordPress tutorial on the internet. We disable that pool. Instead, each site owner gets a pool named `<user>-php<version>` that runs as the owner's UID and listens on a private unix socket at `/run/php/<user>-php<v>-fpm.sock`.

Why this matters: a compromised plugin in `siteA` runs as user `siteA`. It cannot read `/home/siteB/webapps/siteB.com/wp-config.php` because `siteB`'s home is mode `0711` and the file isn't world-readable. Under the usual shared-`www-data` model, every PHP process on the box can read every site's DB credentials — the box has one trust boundary, not N. Per-user UID separation gives you a real isolation story without Docker.

`open_basedir` adds a second wall: each pool is confined to `/home/<user>/webapps/`, `/home/<user>/.php_tmp/`, and `/home/<user>/.php_sessions/`. Even if a plugin tries to read outside its own subtree, PHP refuses. Sessions go to a per-user directory instead of `/var/lib/php/sessions/`, so a session-fixation attack across tenants is structurally impossible.

There's also a friendly side-effect: when you `ls -la` the docroot, the file owner is the human-meaningful site user, not `www-data`. SFTP, `chown` discipline, and per-user quotas all become simple again.

## Why bare-metal apt, not Docker

WordPress is filesystem-chatty. A single page render can `stat` hundreds of plugin and theme files; an admin page push can write dozens. Layering OverlayFS on top of every site's filesystem multiplies that I/O cost for no functional gain — these aren't twelve-factor apps, they're PHP files that live on disk and want to stay on disk.

Per-app containers also waste RAM. Each container needs its own PHP-FPM master, its own service supervisor, often its own Apache or nginx, sometimes its own MariaDB sidecar. At 30–50 sites per server (litesoup's target scale), that's 30–50× the per-process overhead before you've served a single request. Bare-metal apt gives you one PHP-FPM master per PHP version, one Apache, one MariaDB, and N tiny per-user pools that consume only the RAM their actual workers need.

The v0.5.0 caching release leaned into this: rather than ship a server-level Redis-backed page cache (the kind a Kubernetes-flavored stack would default to), litesoup installs Redis and Memcached locked to `127.0.0.1`, generates per-site cache key salts so multi-tenant Redis can't collide, and lets the operator pick a WordPress plugin — Redis Object Cache, LiteSpeed, WP Rocket, W3TC. The plugin owns invalidation, because the plugin is the only thing that knows when `save_post` fires. Stacking server-cache on top of plugin-cache produces stale-content bugs that take days to find.

Docker per WP site is wasteful. We don't do it.

## Idempotency as a first principle

Every script is safe to re-run. That's a hard requirement, not a goal. `install-stack.sh` runs on every host on every release, and a non-idempotent step would multiply failures across the fleet — you'd patch one host and break ten.

The patterns that enforce this:

- **Render → compare → write only if changed.** `redis.sh` builds the desired override config in a shell variable, reads what's currently on disk, and only writes (and only restarts the service) if the two differ. Same pattern for `memcached.sh`, `harden-apache.sh`, `harden-php.sh`.
- **Service reloads, not restarts, when content changed.** `systemctl reload` preserves live connections — important for sshd (you're SSHed in right now), Apache (live HTTP requests), and PHP-FPM (in-flight pool workers).
- **Marker files for managed sections.** Memcached's `/etc/memcached.conf` has a `# BEGIN litesoup` / `# END litesoup` block; everything else in the file is left alone, so an operator's hand-edits survive.
- **Detect-and-no-op on tier changes.** `_php_pool_current_tier` parses `pm.max_children` from the existing pool conf and bails early if the tier hasn't changed, instead of rewriting the file and reloading FPM for nothing.
- **Self-healing DB password reuse.** If `wp-config.php` already exists, `site-create.sh` parses its `DB_PASSWORD` and re-asserts it on MySQL via `ALTER USER`. A previous run that aborted between DB user creation and `wp-config` write doesn't leave the site stuck — the next run reconciles.
- **`install -d -m 0700 -o user`** for directory creation. Sets ownership and mode atomically; safe to run on existing directories.

The mental model: every script is a convergence step toward a desired state, never a one-shot setup recipe.

## Stages 1–14: what install-stack does

`install-stack.sh` runs in 14 stages (8 with `--skip-hardening`). Order matters more than it looks.

| # | Stage | Why this order |
|---|-------|----------------|
| 1 | Apache (mpm_event + http2) | Everything else proxies to it, and stage 10 needs `/var/log/apache2/*error.log` to exist before fail2ban watches it. |
| 2 | PHP-FPM (per requested version) | Each version installed via Ondrej PPA; vendor default pool disabled so every site must use a per-user pool. |
| 3 | Default site owner + per-user pool | Creates user `litesoup` with home, runtime dirs, and a pool at `PHP_VERSION_DEFAULT`. |
| 4 | MariaDB | Random root password persisted to `/root/.litesoup-mariadb-root` (`0600`). |
| 5 | wp-cli | Installed to `/usr/local/bin/wp` with sha512 verification. |
| 6 | Certbot + LE auto-renewal timer | Pulled from Ubuntu archive, no PPA needed. |
| 7 | Redis | RAM-tier-sized maxmemory: `<2G→128mb`, `2–8G→512mb`, `≥8G→2gb`. Override with `--redis-maxmemory=SIZE`. |
| 8 | Memcached | UDP off (`-U 0`), loopback only (`-l 127.0.0.1`). |
| 9 | harden-firewall (ufw) | Opens 22/80/443; deny everything else. |
| 10 | harden-fail2ban | Watches Apache + sshd logs. Has to run after stage 1 so the log files exist. |
| 11 | harden-unattended-upgrades | Security updates only. |
| 12 | harden-ssh | **Reads the warning in the script header before running on a fresh host** — see SSH note below. |
| 13 | harden-apache | `ServerTokens Prod`, security headers, mod_status restricted to local. |
| 14 | harden-php | Global php.ini hardening per installed version. |

The "services first, lock down second" ordering is deliberate: every hardening stage depends on the thing it's hardening already being installed and configured. Reorder this and stage 10 fails because there are no Apache logs yet.

**SSH gotcha (v0.7.1):** the default SSH hardening no longer disables password auth or root login (v0.7.0 did, and locked an operator out of `sg10.codetot.org`). To opt back into the strict v0.7.0 posture, run `harden-ssh.sh --no-password-auth --no-root-login` explicitly. Always have an SSH key on the box before running install-stack — even with the gentler default, you don't want to find out the hard way that your bootstrap method was the only thing keeping you in.

## The CloudPanel mirror story

Ubuntu's PHP packages stop at whatever was current when the LTS was cut. To install PHP 8.0–8.5 side by side, litesoup uses the [Ondrej Surý PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php). The problem: `ppa.launchpadcontent.net` is unreachable from roughly 10% of networks — many CI runners, several Southeast Asian VPS providers, and at least one DigitalOcean region. We hit this on `sg10.codetot.org` (DO Singapore), where every `apt-get update` against launchpad hangs for 60–120s before timing out. There is no good upstream fix.

So `install/lib/apt.sh` does this: it tries `add-apt-repository ppa:ondrej/php` first, then probes whether the registered URL is actually reachable (an `apt-get update` succeeding doesn't prove the repo is fetchable — apt happily caches stale state). If launchpad is unreachable, it falls back to [packages.cloudpanel.io](https://packages.cloudpanel.io), which mirrors the same Sury packages over a CloudFront-backed CDN. Same packages, byte-equivalent (signed by Sury's GPG key), but reachable from networks that launchpad isn't. The PECL extensions (`imagick`, `redis`) aren't in the CloudPanel mirror — when they're skipped, WP Redis Object Cache falls back to the bundled Predis client (slower but functional), and image processing falls back to GD (already in core).

You can force the mirror up front by setting `LITESOUP_PPA_FORCE_MIRROR=cloudpanel` in the environment, which skips the launchpad probe entirely and saves 60–120s on hosts you already know are blocked.
