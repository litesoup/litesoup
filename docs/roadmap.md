---
layout: default
title: Roadmap
nav_order: 9
---

# Roadmap

A friendly look at where litesoup is today, where it's been, and where it's headed. No dates on future work — just direction.

## Today (v0.7.1)

What works right now, on a fresh Ubuntu 24.04 host:

- **One-line install.** `sudo bash install/install-stack.sh` turns a blank Ubuntu box into a working WordPress server in 14 stages.
- **Multi-version PHP.** Install any subset of PHP 8.0 through 8.5 side-by-side. Pick the version per site at creation time, or flip an existing site to a different version with `site-set-php`.
- **Real HTTPS, automatically.** `site-create --tls=letsencrypt --email=you@example.com` provisions a Let's Encrypt cert via HTTP-01, wires up HTTP/2, modern ciphers, HSTS, and HTTP→HTTPS redirect. Auto-renews via `certbot.timer`. Self-signed mode for local/dev domains.
- **Per-tier FPM pool sizing.** `--tier=small|medium|large` selects worker pool sizing (5/20/50 children). Retune any pool retroactively with `site-set-tier`.
- **Caching infrastructure.** Redis (with auth, RAM-tier-sized maxmemory, loopback-bound) and Memcached (UDP off, loopback-bound) installed and configured. Every new site gets `WP_CACHE_KEY_SALT` and Redis connection constants injected into `wp-config.php` — pick any cache plugin (Redis Object Cache, LiteSpeed Cache, W3TC, WP Rocket) and it Just Works.
- **Security baseline.** UFW firewall, fail2ban (sshd + apache-auth jails), unattended-upgrades for security patches, plus per-service hardening for sshd, Apache, and PHP. Pass `--skip-hardening` if you manage security elsewhere.
- **Read-only audits.** Four `audit/*` scripts check WP health, system metrics, WP plugin/theme CVEs (free WPVulnerability.net API), and live config drift vs RAM-tier recommendations.
- **Site lifecycle.** Create sites with `site-create`, delete with `site-delete` (best-effort revokes the LE cert), flip TLS mode with `site-set-tls`, change PHP version with `site-set-php`, retune pools with `site-set-tier`.
- **CI tested.** 121 bats unit tests plus three systemd-Docker integration scripts run on every PR. Acceptance-tested on a real DO Singapore VPS that genuinely can't reach launchpad — fallback to the CloudPanel mirror keeps installs working.

## What's shipped

| Version | Date | Headline |
|---------|------|----------|
| v0.1.0 | 2026-05-01 | MVP WordPress stack installer |
| v0.2.0 | 2026-05-02 | Multi-version PHP (8.0–8.5) |
| v0.3.0 | 2026-05-02 | TLS / Let's Encrypt automation |
| v0.4.0 | 2026-05-02 | Per-tier FPM pool sizing + site-set-php |
| v0.4.1 | 2026-05-02 | Bug fixes (DB password idempotency, vhost template) |
| v0.5.0 | 2026-05-02 | Redis + Memcached infrastructure |
| v0.5.1 | 2026-05-03 | CI / CloudPanel mirror fallback |
| v0.6.0 | 2026-05-03 | First harden/* + audit/* packages (security baseline) |
| v0.7.0 | 2026-05-03 | Per-service hardening (sshd, apache, php) |
| v0.7.1 | 2026-05-03 | harden-ssh safer defaults (opt-in for password/root SSH) |

## Up next

These are queued — already designed or partly prototyped, not yet shipped. Order is rough; we'll let real-world friction decide what lands first.

- **Self-host an aptly mirror of `ppa:ondrej/php`.** Today, when launchpad is unreachable (DO Singapore, GitHub Actions runners), we fall back to the CloudPanel CE mirror. That works but introduces a third-party dependency we'd rather own. A self-hosted aptly mirror removes the runtime dependency on either upstream.
- **Per-service hardening for MariaDB and Redis.** v0.7.0 added per-service hardening for sshd, Apache, and PHP. MariaDB and Redis are the remaining two services that deserve the same treatment (managed override files, validate-then-reload, idempotent re-runs).
- **OCSP stapling for TLS.** Better certificate revocation checking — clients don't have to phone home to the CA on every connection. The TLS work in v0.3.0 left this on the table deliberately to keep the first TLS release small.
- **Distro support beyond Ubuntu 24.04.** Debian 12 and Ubuntu 22.04 are the two obvious targets. Distro detection is straightforward; the work is mostly testing each install/harden script against the older systemd / openssl / php-fpm packaging differences.
- **Sigstore-signed installer releases.** Provenance and tamper-evidence for the `install/install-stack.sh` you `curl | bash`. So you can verify what you're running came from this repo's CI, not a man-in-the-middle.
- **`install-stack --remove-php=X.Y`.** Cleanup helper for when a PHP version is EOL and no live site uses it. Today you can install any subset side-by-side, but removing one is a manual apt dance.
- **`tune/` package — performance tuning helpers.** `mariadb my.cnf` sized for the host, `opcache` sizing per PHP version, Apache MPM tuning. Same RAM-tier model as Redis maxmemory.
- **`maintain/` package — recurring ops.** Disk cleanup (old logs, orphaned wp-content uploads), WP core auto-updates with rollback, DB optimize. The kind of cron-driven housekeeping every long-lived host needs.
- **`monitor/` package — uptime + cert-expiry watchers.** Lightweight checks that ping a webhook (or just exit non-zero for an external monitor to pick up) when something's wrong. Not a full APM — just the bare minimum operators actually want.
- **GitHub Pages docs site.** The page you're reading is part of it. More to come — full reference docs, troubleshooting playbooks, real-world deployment write-ups.
- **Multi-server orchestration via `runcloud-go`.** Long-term: a single-binary Go control plane for managing a fleet of litesoup hosts. Separate repo, separate scope. The bash stack stays usable standalone forever.

## Not on the roadmap, by design

We get asked about these regularly. Here's why they're explicit non-goals:

- **Docker-per-app deployment.** WordPress is filesystem-chatty (uploads, plugin updates, wp-cron, log writes), and the per-user FPM pool model already gives us the security boundary that containers give other people. Adding Docker on top would slow disk I/O without buying us isolation we don't already have.
- **Server-level page cache (Apache `mod_cache_disk`).** WP cache plugins (LiteSpeed Cache, WP Rocket, W3TC) handle page caching better because they have access to WordPress hooks — `save_post`, `comment_post`, theme/plugin updates. Layering a server-level cache on top produces stale-content bugs that are painful to debug at scale.
- **Auto-install of any WP plugin.** Even Redis Object Cache. Operators pick their plugins. The stack makes sure they work — for example, by injecting `WP_REDIS_*` constants so any object cache plugin connects without configuration. But the choice stays with the operator.
- **GUI / web dashboard.** A separate `runcloud-go` project tackles the multi-server dashboard, eventually. The litesoup stack itself stays bash-only and CLI-driven — that's how it stays auditable, scriptable, and easy to drop into Ansible / Terraform / your own automation.

---

Have a feature you'd like to see? [Open an issue](https://github.com/codetot-web/litesoup/issues) — we read every one.
