---
layout: default
title: Install
nav_order: 2
---

# Install litesoup

Get a working WordPress stack on a fresh Ubuntu 24.04 server in about 10 to 15 minutes. One script, sane defaults, no surprises.

## Requirements

- **Ubuntu 24.04 LTS.** No other distros, no other versions. The installer checks and refuses to run elsewhere.
- **Root SSH access.** You'll run the script as `root` (or via `sudo`).
- **A working SSH key on the host.** This only matters if you later pass `--no-password-auth` to `harden-ssh.sh`. The default install keeps password SSH on, so you won't lock yourself out — but adding a key now is still a good idea.
- **1 GB RAM minimum.** 2 GB or more is more comfortable. The installer auto-tunes Redis based on what's available.

## One-line install

```bash
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh
```

That's it. Roughly 10 to 15 minutes later you'll have:

- Apache (mpm_event + HTTP/2)
- PHP-FPM 8.2, 8.3, and 8.4 (one pool per version, side-by-side)
- MariaDB
- wp-cli
- certbot (for Let's Encrypt HTTPS)
- Redis (localhost only, password-protected, RAM-tiered)
- Memcached (localhost only, UDP off)
- UFW firewall
- fail2ban
- unattended-upgrades
- Hardened sshd, Apache, and php.ini

The installer also creates a default site owner `litesoup` at `/home/litesoup/webapps/` with its own PHP-FPM pool on PHP 8.2.

## Common flags

```bash
sudo bash install/install-stack.sh --help
```

The flags you'll actually use:

- `--php-versions=8.2,8.4` — install only specific PHP versions. Default is `8.2,8.3,8.4`. Allowed range is 8.0 through 8.5. The default version (8.2) must be in the set.
- `--redis-maxmemory=512mb` — override the Redis cap. Default is auto: under 2 GB RAM gets 128 MB, 2 to 8 GB gets 512 MB, 8 GB and up gets 2 GB.
- `--skip-hardening` — skip stages 9 through 14 (firewall, fail2ban, auto-updates, sshd, Apache, php hardening). Use this on dev VMs or when something else manages security.
- `--dry-run` — print what would happen without changing anything.
- `--help` — show the full usage.

Example:

```bash
sudo bash install/install-stack.sh --php-versions=8.3,8.4 --redis-maxmemory=1gb
```

## Networks where launchpad is blocked

Some networks can't reach `ppa.launchpadcontent.net` — most notably DigitalOcean Singapore VPSes and some GitHub Actions runners. The installer detects this and falls back to a CloudPanel CDN mirror, but the launchpad probe still costs you 1 to 2 minutes.

If you already know your host can't reach launchpad, skip the probe:

```bash
LITESOUP_PPA_FORCE_MIRROR=cloudpanel sudo bash install/install-stack.sh
```

This goes straight to the CloudPanel mirror. Same packages (byte-equivalent, signed by a pinned GPG fingerprint), no waiting around.

## Stage table

The installer runs in stages. You'll see `stage N/14:` in the log as it goes.

| Stage | What it does                                       |
|-------|----------------------------------------------------|
| 1     | apache (mpm_event + http2)                         |
| 2     | php-fpm (one pool per requested version)           |
| 3     | default site user `litesoup` + per-user FPM pool   |
| 4     | mariadb                                            |
| 5     | wp-cli                                             |
| 6     | certbot (Let's Encrypt + auto-renewal)             |
| 7     | redis (localhost, requirepass, RAM-tiered)         |
| 8     | memcached (localhost, UDP off)                     |
| 9     | ufw firewall                                       |
| 10    | fail2ban                                           |
| 11    | unattended-upgrades                                |
| 12    | sshd hardening                                     |
| 13    | Apache hardening                                   |
| 14    | php.ini hardening (per version)                    |

With `--skip-hardening`, stages 9 through 14 are skipped and the installer reports 8 stages total instead of 14.

## After install

- For creating sites, see the [Sites](sites.md) page — it covers `site-create.sh` with TLS, per-user pools, and database provisioning.
- For tightening SSH further (key-only, no root login), see [Hardening](hardening.md). The opt-in flags `--no-password-auth` and `--no-root-login` on `harden/harden-ssh.sh` are how you get the strict posture. They're opt-in by design — see the v0.7.1 release notes in the CHANGELOG for why.

## Re-running

Everything is idempotent. Re-running `install-stack.sh` is safe — it detects existing state and only changes what's needed. You can run it again to:

- Add a PHP version you skipped the first time (`--php-versions=8.2,8.3,8.4,8.5`)
- Adjust Redis memory (`--redis-maxmemory=2gb`)
- Re-apply hardening after upstream package updates
- Recover from a partial install that bailed mid-stage

One caveat: re-running stage 12 (`harden-ssh`) under v0.7.1 rewrites `/etc/ssh/sshd_config.d/52-litesoup-harden.conf` with the gentler default. If you previously enabled `--no-password-auth` or `--no-root-login`, you need to pass those flags again — otherwise password and root SSH come back on. See the v0.7.1 notes in the CHANGELOG for the full story.
