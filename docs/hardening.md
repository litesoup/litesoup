---
layout: default
title: Hardening
nav_order: 4
---

# Server hardening

`install-stack.sh` runs seven hardening scripts at the end (stages 11-17)
once the LAMP stack is up. Each script is idempotent — re-runs detect
"already configured" and skip the work. Each script also runs standalone,
so you can re-apply or update one piece without touching the rest. Pass
`--skip-hardening` to install-stack to skip all seven.

## What runs by default

- **stage 11 — harden-ssh.sh** — disables Ubuntu 24.04 socket-activated
  SSH (`ssh.socket`) and switches to standalone sshd on the configured
  port, then writes safe sshd defaults. **Must run before the firewall**
  so the port UFW opens is the one sshd actually listens on (see the
  socket-activation note below).
- **stage 12 — harden-firewall.sh** — installs ufw, denies inbound by
  default, opens SSH (auto-detected port) + 80/tcp + 443/tcp.
- **stage 13 — harden-fail2ban.sh** — installs fail2ban, ships managed
  jails for sshd and apache-auth.
- **stage 14 — harden-unattended-upgrades.sh** — turns on
  security-only auto-updates, no auto-reboot.
- **stage 15 — harden-apache.sh** — hides version banner, adds three
  security headers, restricts `/server-status` to localhost.
- **stage 16 — harden-php.sh** — global php.ini hardening (cli + fpm)
  for every installed PHP version.
- **stage 17 — harden-user.sh** — provisions the `litesoup` SSH user +
  sudo (only when `--ssh-key` is passed to install-stack).

After hardening, install-stack runs a **post-install SSH access check**
(`verify_ssh_access`): it confirms sshd is listening on the configured
port, UFW allows it, and `ssh.socket` is disabled. If any check fails,
install-stack aborts rather than declaring success while the operator is
about to be locked out.

## Detailed: each script

### harden-firewall.sh

```bash
sudo bash harden/harden-firewall.sh
```

Default policies become **deny incoming, allow outgoing**. The script
parses `/etc/ssh/sshd_config` to learn the actual SSH port (last
uncommented `Port` directive wins, falling back to 22) and opens that
plus 80/tcp and 443/tcp. `ufw --force enable` is used because bare
`ufw enable` prompts and hangs in non-interactive sessions like
cloud-init.

There is no managed config file — ufw rules live in its own database.
Re-running prints "already configured" when SSH + 80 + 443 are present
and ufw is active.

### harden-fail2ban.sh

```bash
sudo bash harden/harden-fail2ban.sh
```

Writes two managed jails:

- `/etc/fail2ban/jail.d/litesoup-sshd.local` — sshd jail using the
  systemd backend, 3 retries, 1-hour ban. Port matches the live sshd
  port (same parser as the firewall script — they cannot diverge).
- `/etc/fail2ban/jail.d/litesoup-apache-auth.local` — apache-auth
  jail watching `/var/log/apache2/*error.log`, 5 retries, 1-hour ban.
  Skipped (with a warning) if Apache isn't installed yet.

fail2ban is reloaded only when a jail file actually changed.

### harden-unattended-upgrades.sh

```bash
sudo bash harden/harden-unattended-upgrades.sh
```

Two managed files:

- `/etc/apt/apt.conf.d/52litesoup-unattended` — allowed origins limited
  to `${distro_id}:${distro_codename}-security`, no auto-reboot, empty
  package blacklist, prune unused dependencies.
- `/etc/apt/apt.conf.d/20auto-upgrades` — turns on the daily timers.

The `52` prefix sorts after the package-default `50unattended-upgrades`,
which apt may overwrite on package upgrades. Files are only rewritten
when content differs.

### harden-ssh.sh

```bash
sudo bash harden/harden-ssh.sh
```

Writes `/etc/ssh/sshd_config.d/52-litesoup-harden.conf` with these
always-on defaults:

```
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
```

Two opt-in flags add stricter directives only when you ask for them:

- `--no-password-auth` adds `PasswordAuthentication no`
- `--no-root-login` adds `PermitRootLogin no`

After writing, the script runs `sshd -t` against the full include chain.
If validation fails the override is reverted (or removed if there was no
prior version) so sshd is never left broken. On success, ssh is
**reloaded**, not restarted — your active session stays up.

This script never touches `/etc/ssh/sshd_config`. That file is
package-managed; apt rewrites it on upgrades. The drop-in directory is
the supported extension point.

**Socket activation (Ubuntu 24.04).** Ubuntu 24.04 ships
socket-activated SSH by default: `ssh.socket` binds the **default** port
and spawns sshd on demand — regardless of the `Port` directive in the
config chain. If you set a non-standard port via a drop-in, the socket
still owns the default port while nothing listens on your configured
port. A default-deny firewall that opens only the configured port then
blocks the socket port → lockout. To prevent this, harden-ssh disables
`ssh.socket` and enables standalone `ssh.service`, which reads the config
chain and binds the configured port. This runs on **every** invocation
(idempotent), so a package upgrade that re-enables the socket is caught
on re-run. Because of this, install-stack runs harden-ssh **before**
harden-firewall.

### harden-apache.sh

```bash
sudo bash harden/harden-apache.sh
```

Writes two managed snippets and enables them with `a2enconf`:

- `/etc/apache2/conf-available/52-litesoup-harden.conf` — `ServerTokens
  Prod`, `ServerSignature Off`, `TraceEnable Off`, plus three security
  headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options:
  SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`)
  wrapped in `<IfModule mod_headers.c>`.
- `/etc/apache2/conf-available/52-litesoup-mod-status.conf` —
  `Require local` on `/server-status` (only takes effect if mod_status
  is loaded; safe to ship either way).

Also disables `mod_info` if it's currently loaded. `apache2ctl
configtest` runs before the reload — a syntax error refuses the reload
instead of breaking the running server.

### harden-php.sh

```bash
sudo bash harden/harden-php.sh
```

Discovers every PHP version under `/etc/php/X.Y/` and writes the same
managed snippet to both SAPIs:

- `/etc/php/X.Y/cli/conf.d/52-litesoup-harden.ini`
- `/etc/php/X.Y/fpm/conf.d/52-litesoup-harden.ini`

Settings: `expose_php=Off`, `allow_url_fopen=Off`,
`allow_url_include=Off`, `display_errors=Off`,
`display_startup_errors=Off`, `log_errors=On`,
`session.cookie_httponly=1`, `session.cookie_secure=1`,
`session.use_strict_mode=1`.

Per-pool settings (`open_basedir`, `disable_functions`) live in the
FPM pool template, not here. Only FPM versions whose conf actually
changed get a `systemctl reload php<v>-fpm`, and only when the service
is active.

## The harden-ssh story

litesoup v0.7.0 forced both `PasswordAuthentication no` and
`PermitRootLogin no` by default. That broke real workflows: operators
who bootstrap with a password before pushing keys, and operators who
run install-stack as root over SSH (which is the documented happy
path), got locked out on the next session.

v0.7.1 made both opt-in. The defaults now ship the always-safe
directives only. Operators who want the stricter posture pass the
flags explicitly:

```bash
sudo bash harden/harden-ssh.sh --no-password-auth --no-root-login
```

Run this **after** you've confirmed your SSH keys work and you have a
non-root sudo user, not before.

## Going stricter

The litesoup defaults are deliberately conservative. To add directives
they don't cover, write a higher-numbered drop-in file — Apache, sshd,
PHP, and apt.conf all load drop-ins in lexical order, so a `99-` file
beats litesoup's `52-`:

- SSH: `/etc/ssh/sshd_config.d/99-local-strict.conf` for things like
  `AllowUsers`, `KbdInteractiveAuthentication no`, or stricter cipher
  lists.
- Apache: `/etc/apache2/conf-available/99-local-csp.conf` then
  `a2enconf 99-local-csp`. Useful for CSP headers, HSTS, or per-site
  `Require ip` rules on `/server-status`.
- PHP: `/etc/php/<v>/cli/conf.d/99-local-*.ini` and
  `/etc/php/<v>/fpm/conf.d/99-local-*.ini` for tighter
  `disable_functions`, custom `error_log`, or memory limits.
- apt unattended: `/etc/apt/apt.conf.d/99local-unattended` to add
  `-updates` origins or turn on auto-reboot.

litesoup will never touch `99-` files. Re-running a harden script
overwrites the `52-` file but leaves yours alone.

## Skipping hardening

```bash
sudo bash install/install-stack.sh --skip-hardening
```

Use this when:

- You're building a dev VM where firewall + fail2ban get in the way of
  rapid iteration.
- The host is behind a separate firewall appliance, or fail2ban runs
  on a different node.
- Security posture is managed by a config-management tool (Ansible,
  Puppet, Chef) and you want it to own these files.

`--skip-hardening` skips all six stages, not just SSH. If you only want
to skip one (say, you have your own firewall but want fail2ban + the
rest), let install-stack run everything and then revert that one
script's changes — or run install-stack with `--skip-hardening` and
invoke the five scripts you want directly.
