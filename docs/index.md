---
layout: default
title: Home
nav_order: 1
---

# litesoup

WordPress hosting on your own VPS. Sane defaults, no lock-in.

One bash script turns a fresh Ubuntu 24.04 box into a production-ready WordPress host. Apache + multi-version PHP + MariaDB + Redis + Memcached + TLS + firewall + fail2ban + auto-updates. Each site runs as its own UNIX user with isolated PHP-FPM, never as `www-data`.

Built for agencies hosting 5–50 sites per box who don't want to pay $25/month for runcloud and don't want to babysit Docker.

## 30-second start

```bash
# Quick install (one-liner):
curl -fsSL https://raw.githubusercontent.com/litesoup/litesoup/main/install.sh | sudo bash
```

That's a working WordPress stack. ~10-15 minutes.

Once the stack is installed, clone the repo for site management:

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash site/site-create.sh --domain=example.com --tls=letsencrypt --email=ops@example.com
```

Prefer to inspect before installing? Clone the full repo instead:

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh
```

## Who this is for

- **Agencies** hosting 5–50 client WordPress sites on bare VPSes (DO, Hetzner, Linode).
- **Developers** who want bare-metal control without the runcloud / cloudways subscription.
- **Anyone migrating off** runcloud / cyberpanel / cloudpanel and wanting their stack in plain bash they can audit and modify.

## Who this is **not** for

- One-WP-per-host hobby setups — managed WordPress hosts (Kinsta, Pantheon) are easier.
- 100+ sites/box — you probably want Kubernetes, not bash.
- Anyone who wants a GUI — there isn't one (yet — see [Roadmap](roadmap.md)).

## What you get out of the box

| | |
|---|---|
| **Web** | Apache 2.4 + mpm_event + http2 |
| **PHP** | 8.0–8.5 side-by-side via Ondrej PPA (CloudPanel mirror fallback for blocked networks) |
| **DB** | MariaDB 10.x with non-interactive secure baseline |
| **Cache** | Redis (loopback, requirepass, RAM-tier maxmemory) + Memcached (loopback, UDP off) |
| **TLS** | Let's Encrypt automation via certbot timer |
| **WP** | wp-cli installed, sha512-verified |
| **Security** | ufw firewall · fail2ban · unattended-upgrades · sshd/apache/php hardening |
| **Per-site** | One PHP-FPM pool per site owner (UID isolation, open_basedir, FPM tier sizing) |

## Where to go next

- **[Install](install.md)** — full install guide, requirements, env vars, common flags.
- **[Sites](sites.md)** — `site-create`, `site-set-php`, `site-set-tier`, `site-set-tls`.
- **[Hardening](hardening.md)** — what's locked down by default, opt-in stricter posture.
- **[Caching](caching.md)** — Redis + Memcached + recommended WP cache plugins.
- **[Audit](audit.md)** — read-only check scripts (WP health, system metrics, vulns, perf drift).
- **[Troubleshooting](troubleshooting.md)** — common issues + fixes.
- **[Architecture](architecture.md)** — how it's built, why bare-metal apt over Docker.
- **[Roadmap](roadmap.md)** — what ships next.
- **[Contributing](contributing.md)** — dev setup, testing, multi-agent dispatch pattern.

## License

[MIT](https://github.com/codetot-web/litesoup/blob/main/LICENSE). Use it, fork it, ship it. No tracking, no telemetry, no upsell.
