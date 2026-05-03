# litesoup

> WordPress hosting on your own VPS. Sane defaults, no lock-in.

[![CI](https://github.com/codetot-web/litesoup/actions/workflows/ci.yml/badge.svg)](https://github.com/codetot-web/litesoup/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/codetot-web/litesoup)](https://github.com/codetot-web/litesoup/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

One bash script turns a fresh **Ubuntu 24.04** box into a production-ready WordPress host:

- **Apache 2.4** + multi-version **PHP 8.0–8.5** + **MariaDB** + **wp-cli** + **certbot**
- **Redis** + **Memcached** with safe loopback defaults
- **ufw** + **fail2ban** + **unattended-upgrades** + per-service hardening (sshd / apache / php)
- Each WordPress site runs as its own UNIX user with isolated PHP-FPM, never as `www-data`

Built for agencies hosting 5–50 client sites per box who don't want runcloud lock-in or Docker complexity.

## 30-second start

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh
sudo bash site/site-create.sh --domain=example.com --tls=letsencrypt --email=ops@example.com
```

That's a working HTTPS WordPress site. ~15 min total on a fresh Ubuntu 24.04 box.

## Networks where launchpad is blocked

If `ppa.launchpadcontent.net` is unreachable from your host (some DigitalOcean regions, GitHub Actions runners), add the env var:

```bash
LITESOUP_PPA_FORCE_MIRROR=cloudpanel sudo bash install/install-stack.sh
```

This skips the slow launchpad attempt and goes straight to the CloudPanel CDN mirror (same packages, byte-equivalent installs).

## Documentation

Full docs at **[docs.litesoup.com](https://docs.litesoup.com)**.

Quick links:

- [Install](https://docs.litesoup.com/install.html) — full guide, requirements, all flags
- [Sites](https://docs.litesoup.com/sites.html) — `site-create`, `site-set-php`, `site-set-tier`, `site-set-tls`
- [Hardening](https://docs.litesoup.com/hardening.html) — what's locked down + opt-in stricter posture
- [Caching](https://docs.litesoup.com/caching.html) — Redis / Memcached + recommended WP plugins
- [Audit](https://docs.litesoup.com/audit.html) — read-only check scripts
- [Troubleshooting](https://docs.litesoup.com/troubleshooting.html) — common issues + fixes
- [Architecture](https://docs.litesoup.com/architecture.html) — how it's built, why bare-metal apt over Docker
- [Roadmap](https://docs.litesoup.com/roadmap.html) — what's done + what's next
- [Contributing](https://docs.litesoup.com/contributing.html) — dev setup + multi-agent dispatch pattern

## Get help

- Bug or feature request: [open an issue](https://github.com/codetot-web/litesoup/issues/new)
- Questions: [GitHub Discussions](https://github.com/codetot-web/litesoup/discussions)

## License

[MIT](LICENSE) — use it, fork it, ship it. No tracking, no telemetry, no upsell.
