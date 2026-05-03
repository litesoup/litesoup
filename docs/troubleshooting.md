---
layout: default
title: Troubleshooting
nav_order: 7
---

# Troubleshooting

A collection of real things that have gone wrong, and how to fix them. Each
section follows the same shape: **Symptom**, **Cause**, **Fix**. If you hit
something that isn't here, open an issue at
[codetot-web/litesoup](https://github.com/codetot-web/litesoup/issues) — most
entries on this page started life as a bug report.

---

## 1. `Unable to locate package php8.2-fpm` during install

**Symptom.** `install/install-stack.sh` aborts in stage 2 (PHP install) with:

```
E: Unable to locate package php8.2-fpm
```

**Cause.** Your VPS can't reach `ppa.launchpadcontent.net`. This bites
DigitalOcean Singapore droplets and a handful of other regions where the
launchpad CDN is firewalled or routes badly. The PPA appears to register
cleanly (apt-get update returns 0 with warnings) but the package index never
makes it into the cache, so the next `apt-get install` can't find anything.

**Fix.** Force the CloudPanel mirror, which serves byte-equivalent Sury PHP
builds from CloudFront:

```bash
LITESOUP_PPA_FORCE_MIRROR=cloudpanel sudo bash install/install-stack.sh
```

Same package names, same versions (suffix `+clp-noble` instead of upstream),
GPG key pinned. This was added in **v0.5.1** specifically to unblock these
networks. As of v0.5.1+ the installer will also auto-fall-back if it detects
the launchpad URL is unreachable — but forcing it skips the timeout entirely
(useful in CI).

---

## 2. `php8.2-imagick` or `php8.2-redis` skipped with a warning

**Symptom.** Toward the end of the PHP stage you see something like:

```
WARN: apt: php8.2-imagick has no Candidate -- skipping (optional)
WARN: apt: php8.2-redis has no Candidate -- skipping (optional)
```

**Cause.** You're installing through the CloudPanel mirror (either via
`LITESOUP_PPA_FORCE_MIRROR=cloudpanel` or the auto-fallback). CloudPanel
mirrors core PHP and the standard extension set, but **not** PECL extensions
like `imagick` or `redis`. The launchpad PPA has them; CloudPanel doesn't.

**Fix.** This is expected and the stack handles it for you:

- **Redis Object Cache plugin** automatically falls back to the bundled
  Predis pure-PHP client. Slower than the C extension, but functional.
- **Image processing** falls back to GD (already installed as a CORE
  extension). Plenty of WP themes never touch ImageMagick.

If you genuinely need the C extensions (e.g. you're processing thousands of
images per hour and Predis is too slow), use the launchpad PPA directly by
re-running install on a network where launchpad is reachable, or install the
extensions by hand from a different repo.

---

## 3. Locked out of SSH after running install-stack

**Symptom.** Your SSH session disconnects after running install, and you can't
reconnect. `ssh user@host` hangs or rejects you with `Permission denied
(publickey)`.

**Cause.** This **only** happens if you ran `harden/harden-ssh.sh` with
`--no-password-auth` or `--no-root-login` and didn't have a working SSH key
installed first. (As of **v0.7.1** the defaults are gentler — both flags are
opt-in. If you hit this on a fresh v0.7.0 install, it's the v0.7.0 default
that bit you; see the v0.7.1 release notes.)

**Fix.** Use your VPS provider's web console (DigitalOcean → Console,
Vultr → View Console, etc.) to log in, then either remove the offending
directives or override them:

```bash
sudo nano /etc/ssh/sshd_config.d/52-litesoup-harden.conf
# Delete or comment out:
#   PasswordAuthentication no
#   PermitRootLogin no
sudo sshd -t            # validate syntax first
sudo systemctl reload ssh
```

Or write a higher-numbered file that overrides litesoup's:

```bash
echo 'PasswordAuthentication yes' | sudo tee /etc/ssh/sshd_config.d/99-local.conf
sudo systemctl reload ssh
```

---

## 4. `bash site-create.sh` errors with "WordPress files seem to already be present"

**Symptom.** Re-running `site/site-create.sh --domain=example.com` against a
domain that already exists fails partway through with a wp-cli message about
WordPress files already being present in the docroot.

**Cause.** This is the desired guard. `site-create.sh` is for creating brand
new sites. Running it against an existing site would risk clobbering the
docroot or rotating live secrets.

**Fix.** Pick the operation that matches what you actually want:

- **To re-render the vhost (e.g. add or change TLS)** — run
  `site/site-set-tls.sh --domain=example.com --tls=letsencrypt --email=you@example.com`.
- **To change the PHP version** — run
  `site/site-set-php.sh --domain=example.com --php=8.3`.
- **To retune the FPM pool tier** — run `site/site-set-tier.sh ...`.
- **To delete and start over** — run
  `site/site-delete.sh --domain=example.com --purge-db`, then re-run
  site-create.

---

## 5. `Error establishing a database connection` after a failed site-create

**Symptom.** A previous `site-create.sh` aborted partway through (network
glitch on certbot, apache configtest failed, you ctrl-c'd it). You re-ran it,
it reported success, but visiting the site shows WordPress's white screen with
"Error establishing a database connection".

**Cause.** Pre-v0.4.1, `create_database` used `CREATE USER IF NOT EXISTS`,
which silently kept the **old** password if the user already existed — but
generated a **new** password and wrote it to `wp-config.php`. Mismatch =
500.

**Fix.** Make sure you're on **v0.4.1 or newer** (`cat VERSION` in the repo
root). Re-run `site-create.sh` for the affected domain:

```bash
sudo bash site/site-create.sh --domain=example.com
```

v0.4.1+ both reuses the existing wp-config password AND emits an `ALTER USER`
to force MySQL into sync. Self-healing on retry.

---

## 6. `apache2ctl configtest` fails after install

**Symptom.** Running `sudo apache2ctl configtest` reports something like:

```
AH00526: Syntax error
... </VirtualHost> without matching <VirtualHost>
```

…and Apache won't reload.

**Cause.** Almost always the v0.3.0–v0.4.0 vhost template substitution bug.
The template's head comment block contained the literal placeholders
`__HTTP_REDIRECT__` and `__HTTPS_BLOCK__`, and Python's `str.replace()`
substitutes inside `#` comments — so with TLS active, the multi-line HTTPS
block was injected into a comment, breaking the comment boundary.

**Fix.** Make sure you're on **v0.4.1 or newer**, then re-render the affected
vhost by re-running site-create's TLS step:

```bash
sudo bash site/site-set-tls.sh --domain=example.com --tls=letsencrypt --email=you@example.com
sudo apache2ctl configtest && sudo systemctl reload apache2
```

---

## 7. `fail2ban-client status sshd` shows port 22 but my sshd runs on a different port

**Symptom.** You moved sshd to a non-default port (say, 2222) but
`fail2ban-client status sshd` still reports it watching port 22 — meaning
brute-force attacks against your real port are unprotected.

**Cause.** Pre-v0.7.0, `harden-fail2ban.sh` wrote `port = ssh` into the jail
config, which `/etc/services` resolves to 22. Fixed in **v0.7.0** by parsing
the actual `Port` directive out of `/etc/ssh/sshd_config` (same parser used by
`harden-firewall.sh`).

**Fix.** Make sure you're on v0.7.0+, then refresh fail2ban:

```bash
sudo bash harden/harden-fail2ban.sh
sudo fail2ban-client status sshd       # confirm port matches sshd_config
```

---

## 8. CI integration test takes 5+ minutes on every PR

**Symptom.** Your fork's GitHub Actions run sits in
`integration-install-stack` for ages, eventually times out or finishes after
~5 minutes mostly waiting on apt.

**Cause.** GitHub's `ubuntu-24.04` runners can't reach
`ppa.launchpadcontent.net` reliably from every region. Each install attempt
burns the launchpad TLS-handshake timeout before falling back to the
CloudPanel mirror.

**Fix.** Skip the launchpad probe entirely by setting the env var at the job
level. See `.github/workflows/ci.yml` for the exact wiring — it's a one-liner:

```yaml
jobs:
  integration:
    env:
      LITESOUP_PPA_FORCE_MIRROR: cloudpanel
```

This is what litesoup's own CI uses.

---

## 9. How to verify the install actually worked

Two scripts in `audit/` give you a quick read on whether the stack is healthy:

```bash
# Read-only system + service metrics: CPU, RAM, disk, Apache, PHP-FPM,
# MariaDB, Redis. Flags >85% disk usage, slow queries, etc.
sudo bash audit/audit-system-metrics.sh

# Per-site WordPress health: core version, plugin count, DB connection,
# wp-config.php permissions, TLS cert expiry, error log size.
sudo bash audit/audit-wp-health.sh
```

Both are pure read scripts — they touch nothing. Exit codes follow the
nagios convention: `0` healthy, `1` warning, `2` critical, so they slot into
`cron` cleanly. Add `--format=json` to either script for machine-readable
output.

For a deeper performance audit (Apache mpm_event, FPM pool sizing, OPcache,
MariaDB, Redis vs recommended values for your RAM tier):

```bash
sudo bash audit/audit-performance.sh --service=all
```

---

## Still stuck?

- Check the [CHANGELOG](../CHANGELOG.md) — most issues here started as
  release notes, so a search for your error message often turns up the
  version that fixed it.
- Open a bug at
  [codetot-web/litesoup/issues](https://github.com/codetot-web/litesoup/issues)
  with: your `cat VERSION`, distro (`lsb_release -a`), and the last ~50 lines
  of `install-stack.sh` output.
