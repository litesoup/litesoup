# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.8] - 2026-08-03

### Added (feature #70)

- **Decouple site directory name from domain** — `site-create.sh` now takes a
  required `--name=APP` flag. The docroot directory
  (`/home/<user>/webapps/<name>/`), DB name, cache keys and log files all derive
  from the stable app slug instead of the domain, so the domain (a pure network
  property) can be changed later without touching the filesystem.
  (`site/site-create.sh`, `site/_vhost_render.sh`)
- **New `site/site-set-domain.sh`** — Change an existing site's domain
  (ServerName, TLS cert, and WordPress `siteurl`/`home` in the DB) without
  moving or renaming anything on disk. Identifies the site by `--name` or
  `--domain`. (`site/site-set-domain.sh`)
- **Downstream scripts accept `--name`** — `site-set-php.sh`, `site-set-tls.sh`,
  `site-set-webhook.sh`, `site-delete.sh` and `site-import.sh` now resolve an
  app `--name` to the site's current domain via vhost metadata
  (`/etc/litesoup/vhost/*.conf`), with `--domain` kept as a backward-compatible
  alias. (`site/_vhost_render.sh`, `site/site-set-php.sh`, `site/site-set-tls.sh`,
  `site/site-set-webhook.sh`, `site/site-delete.sh`, `site/site-import.sh`)
- **Vhost metadata now stores `SITE_NAME` + `DOMAIN`** so backup scripts and
  the new `site-set-domain.sh` can resolve name → domain → owner → docroot.
  (`site/_vhost_render.sh`)

### Breaking change

- `--name` is now **required** on `site-create.sh`. Existing usage without
  `--name` fails with a clear error. To preserve your current directory
  structure, pass `--name=<current-domain>` (same value as `--domain`) — this
  keeps `/webapps/<domain>/` and lets `site-set-domain` change the domain freely
  later. Dashboard agent / CLI playbooks must be updated accordingly (follow-up
  in `litesoup-dashboard` + `litesoup-cli`).

## [0.10.7] - 2026-07-30

### Fixed (issue #1)

- **`backup-site.sh` `timeout bash -c` lost function context** — The subshell
  created by `timeout bash -c "backup_dump_db ..."` did not inherit functions
  from `common.sh`, causing `backup_dump_db: command not found`. Fixed by
  sourcing `common.sh` inside the subshell. (`backup/backup-site.sh`)
- **Permission denied on `wp db export`** — `mkdir -p` created the backup dir
  as root, then `wp db export` ran as the site user with no write access.
  Fixed by `chown`-ing the dest dir to the site user before export.
  (`backup/lib/common.sh`)
- **Missing `/etc/litesoup/vhost/` directory** — Backup scripts read vhost
  metadata from a directory never created during site provisioning. Fixed by
  writing the metadata file in `write_vhost()` after Apache configtest passes.
  (`site/_vhost_render.sh`)

## [0.10.6] - 2026-07-22

### Fixed (issue #69)

- **CI: bats unit test 79 (restart guard)** — Comment marker `# Force restart`
  was on the line before `systemctl restart ssh` instead of the same line,
  so the `grep -v` filter missed it. Moved to same line so the exception
  is correctly excluded. (`harden/harden-ssh.sh`, `test/bats/unit_harden.bats`)
- **CI: shellcheck failures in `site/site-import.sh`** — Added `-e SC2016`
  (literal grep patterns in single quotes, intentional) and `-e SC1090`
  (non-constant source for REDIS_ENV_FILE, intentional) to CI exception
  list. Only warnings/info, no actual bugs. (`.github/workflows/ci.yml`)

## [0.10.5] - 2026-07-21

### Added

- **6G firewall (WAF)** — New `--waf` flag on `site-create.sh`. Blocks
  exploit scanners, AI crawlers, bad request methods, and spam referers
  via Apache-level rules. Exempts wp-admin and wp-json to avoid false
  positives. (`templates/apache/waf-6g.conf`, `templates/apache/vhost.conf.tmpl`,
  `site/_vhost_render.sh`, `site/site-create.sh`)

### Fixed

- **SSH socket activation conflict (regression on Ubuntu 24.04)** —
  Ubuntu 24.04 ships socket-activated SSH by default (`ssh.socket`).
  When `systemctl daemon-reload` runs (e.g. from `litesoup backup
  configure`), systemd can silently deactivate the socket unit, taking
  port 22 down with zero error logs. Script now detects `ssh.socket`
  and switches to traditional standalone sshd. (`harden/harden-ssh.sh`)
- **`.git/` directory probing** — Apache now returns 404 for
  `.git/` paths. (`templates/apache/vhost.conf.tmpl`)
- **PHP execution in `wp-content/uploads/`** — Direct PHP access in
  uploads is blocked (mitigates file-upload RCE).
  (`templates/apache/vhost.conf.tmpl`, `site/_vhost_render.sh`)
- **`wp-content/debug.log` access** — Direct log reads return 403.
  (`templates/apache/vhost.conf.tmpl`, `site/_vhost_render.sh`)

## [0.10.4] - 2026-07-19

### Added (issue #54)

- **Unit tests for backup scripts** — Self-copy guard detection, `--help` smoke
  tests for backup-restore and backup-stagger, root-error assertion for
  restore dry-run. (`test/bats/unit_backup.bats`)

## [0.10.3] - 2026-07-19

### Fixed (issue #54)

- **backup-install.sh self-copy when run from installed location** — When
  `litesoup backup configure` runs `backup-install.sh` from
  `/usr/lib/litesoup/backup/`, `REPO_ROOT` resolves to `/usr/lib/litesoup`,
  making source and destination the same directory. Fix compares resolved
  paths and skips the copy if they match. (`backup/backup-install.sh`)

## [0.10.2] - 2026-07-19

### Fixed (issue #53)

- **harden-ssh health check false-positive on busy systems** — Increased
  poll from 3×2s to 6×2s (12s total). If sshd process is alive but port not
  bound, log a warning and proceed — only revert if sshd is completely dead.
  (`harden/harden-ssh.sh`)

## [0.10.1] - 2026-07-18

### Fixed (issue #50)

- **harden-ssh.sh: post-reload health check** — After `systemctl reload ssh`,
  the script now polls 3×2 seconds for sshd to be actively listening on the
  configured port (detected via `SSH_CONNECTION` or `sshd -T`). If the check
  fails, the override is reverted and sshd restarted with the original config,
  preventing permanent SSH lockout on fresh Ubuntu 24.04 installs.
  (`harden/harden-ssh.sh`)

### Changed

- **harden-ssh.sh is no longer called during install-stack** — SSH hardening
  is now a post-install step, not a required stage. Run manually when ready:
  `bash /usr/lib/litesoup/harden/harden-ssh.sh [--no-root-login] [--no-password-auth]`.
  The script is still installed to `/usr/lib/litesoup/harden/` during stage 17.
  (`install/install-stack.sh`)

### Fixed

- **NodeSource GPG key for Node.js 22.x** — Stage 10 now uses the official
  NodeSource setup script instead of manual `gpg --dearmor` key import, which
  `apt-get update` rejected on Ubuntu 24.04. (`install/install-stack.sh`)

## [0.10.0] - 2026-07-15

### Added (issues #46, #47)

- **litesoup SSH user** — `harden/harden-user.sh` configures shell, SSH
  authorized_keys, and passwordless sudo. Enabled via `install-stack.sh --ssh-key`.
  Optional `--lock-root` flag disables direct root SSH login.
  (`harden/harden-user.sh`, `install/install-stack.sh`)
- **Backup stagger** — `backup/backup-stagger.sh` runs staggered backups for all
  discovered sites with configurable delay and per-backup timeout.
  (`backup/backup-stagger.sh`)
- **Backup concurrency protection** — `flock` lock file prevents concurrent
  backup runs for the same domain. (`backup/backup-site.sh`)
- **Backup per-step timeout** — 300s timeout on DB dumps, 600s on file archives.
  Exit code tracking (TIMEOUT/FAIL/DONE) with structured logging.
  (`backup/backup-site.sh`)

## [0.9.2] - 2026-07-15

### Added

- **Landing page for default vhost** — access server IP directly now shows
  the LiteSoup landing page with icon, tagline, links to website/docs/github,
  and CODE TOT / Khoi Pro credits. Replaces the old Apache 404 / Ubuntu
  default page. (`templates/apache/default-index.html`,
  `templates/apache/000-default.conf.tmpl`, `install/install-stack.sh`)

## [0.9.1] - 2026-07-15

Bug fixes discovered during Laravel (TSTT) deployment on jp1.

### Fixed

- **Missing default vhost** — access server IP directly no longer falls back
  to the alphabetically-first named site. A `000-default.conf` catch-all serves
  HTTP 404 on both *:80 and *:443 (with SSL snakeoil cert). Installed and
  enabled by `install-stack.sh` stage 17. (`templates/apache/000-default.conf.tmpl`,
  `install/install-stack.sh`)
- **`--git-repo` timeout** — git clone now uses `--depth=1` (shallow), has a
  120-second timeout via `timeout`, and exits with a clear error message on
  failure instead of hanging indefinitely. (`site/site-create.sh`)
- **PHP-FPM pool exhaustion** — default tier changed from `small`
  (max_children=5) to `medium` (max_children=20), preventing intermittent 500s
  when multiple sites share the same pool. (`site/site-create.sh`,
  `site/site-import.sh`)
- **VHOST_DOCROOT unbound** — `site-set-tls.sh` and `site-set-php.sh` now set
  `VHOST_DOCROOT` before calling `write_vhost()`, fixing "unbound variable"
  errors with `--framework=generic` sites. (`site/site-set-tls.sh`,
  `site/site-set-php.sh`)
- **`repo_root` unbound** — moved `repo_root` and `litesoup_lib` declarations
  outside the `skip_hardening` if/else block so stages 17-19 run even with
  `--skip-hardening`. (`install/install-stack.sh`)

## [0.9.0] - 2026-07-14

Added per-site backup system with local + S3-compatible storage, scheduling,
and notification. Also fixed the landing page docs.

### Added

- **backup system** — `backup/backup-site.sh` creates timestamped snapshots of
  site files and database at `/home/<user>/backups/<domain>/<timestamp>/`. Full
  mode (files + DB) and partial mode (`--skip-files`, `--skip-db`,
  `--exclude=PATH`). (`backup/*`)
- **restore** — `backup/backup-restore.sh` restores from a specific or most
  recent backup. Extracts files, imports DB via `wp db import`, flushes caches,
  fixes ownership. (`backup/backup-restore.sh`)
- **S3 destination** — upload to any S3-compatible store (AWS S3, IDrive e2,
  Backblaze B2, DigitalOcean Spaces, etc.) via `s3cmd`. Config stored at
  `/etc/litesoup/backup-s3.conf` (mode 0600). (`backup/lib/s3.sh`)
- **scheduling** — systemd timer `litesoup-backup@DOMAIN.{service,timer}` with
  daily default and custom schedule override. (`backup/backup-install.sh`)
- **notification** — `install/lib/notify.sh` sends alerts via email (if
  configured) and syslog (always). (`install/lib/notify.sh`)
- **litesoup-cli backup group** — `litesoup backup site|restore|list|configure`.
- **docs** — full backup documentation at `docs/backup.md`.

### Fixed

- **install-stack** — backup scripts are auto-installed to `/usr/lib/litesoup/`
  during stage 19. Uses `repo_root` (lowercase) correctly.
- **landing page** — `litesoup.com/docs/installation/` now uses the
  `curl .../install.sh | sudo bash` quick install pattern instead of
  `git clone`.

## [0.8.3] - 2026-07-14

Fixed a provisioning-breaking bug where `install-stack.sh` locked out SSH
on fresh Ubuntu 24.04 VPS that use non-standard SSH ports configured via
`/etc/ssh/sshd_config.d/*.conf` drop-ins (common with cloud-init / VPS
providers). Also fixed pre-existing shellcheck warnings in `site-create.sh`
that were blocking CI.

### Fixed

- **harden-firewall & harden-fail2ban** — `detect_ssh_port()` now uses
  `sshd -T` as the primary detection method, which resolves the full config
  chain including `Include` directives from `/etc/ssh/sshd_config.d/*.conf`.
  Previously it only parsed `/etc/ssh/sshd_config` for an uncommented `Port`
  directive; on Ubuntu 24.04 the default `#Port 22` is commented, causing a
  fallback to port 22. Providers that set a non-standard port via drop-ins
  (e.g. `50-cloud-init.conf` with `Port 2222`) would see UFW open port 22
  (nothing listening) while blocking the real SSH port — **operator locked
  out**. (`harden/harden-firewall.sh`, `harden/harden-fail2ban.sh`,
  `test/bats/unit_harden.bats`)
- **site-create (pre-existing)** — `ssh-keyscan` redirect now runs inside
  `sh -c` so `sudo` applies correctly (SC2024); credential stripping uses
  bash-native pattern matching instead of `sed` (SC2001).
  (`site/site-create.sh`)

## [0.8.2] - 2026-07-14

Install-stack hardening fixes discovered during production provisioning.
Creates per-user FPM pools for every installed PHP version (was only creating
for the default 8.2). Apache `ServerName` is now set globally to suppress the
`AH00558` FQDN warning. MariaDB writes `/etc/mysql/debian.cnf` so the
debian-start maintenance script doesn't spam "Access denied" on every service
start. CLI install script is downloaded to a temp file before execution,
avoiding the `BASH_SOURCE[0]: unbound variable` error from the curl-pipe pattern.

### Fixed

- **install-stack stage 3** — `ensure_php_pool_for_user` now loops over all
  requested PHP versions instead of only `PHP_VERSION_DEFAULT` (8.2). On a
  fresh install with PHP 8.2, 8.3, 8.4, pools for 8.3 and 8.4 were missing,
  leaving php8.3-fpm and php8.4-fpm unable to start ("No pool defined").
  (`install/install-stack.sh`)
- **harden-apache** — added `ServerName 127.0.0.1` to the managed
  `52-litesoup-harden.conf` snippet, suppressing the `AH00558` warning on
  hosts without a global ServerName. (`harden/harden-apache.sh`)
- **mariadb** — after generating and applying the root password, the script
  now writes `/etc/mysql/debian.cnf` with the same credentials. The
  debian-start maintenance script (runs on every service start) reads from
  this file, so "Access denied for user 'root'@'localhost'" errors are
  eliminated. (`install/lib/mariadb.sh`)
- **install-stack stage 16** — CLI installer is now downloaded to a temp file
  (`mktemp`) and executed with `bash /tmp/...` instead of piping `curl | bash`.
  The previous pattern triggered `BASH_SOURCE[0]: unbound variable` because
  `BASH_SOURCE` is unset in piped stdin contexts. (`install/install-stack.sh`)

## [0.8.1] - 2026-05-14

Two-repo CLI architecture. `install-stack.sh` now copies all scripts to
`/usr/lib/litesoup/` (stage 15) so the new `litesoup-cli` dispatcher can
find them at a fixed path regardless of where the repo was cloned. Stage 16
optionally fetches and installs `litesoup-cli` from
`litesoup/litesoup-cli` — non-fatal if unreachable. All `codetot-web/litesoup`
references updated to `litesoup/litesoup` after org transfer.

### Added

- **Stage 15** — `install-stack.sh` copies `install/`, `site/`, `harden/`,
  `audit/` scripts and `VERSION` to `/usr/lib/litesoup/`. Idempotent:
  re-running overwrites safely without restarting any service.
- **Stage 16** — optional, non-fatal `litesoup-cli` install via `curl`.
  Uses `|| true` so a missing or unreachable CLI installer never fails a
  core stack install.
- `total_stages` updated from 14 to 16 (10 with `--skip-hardening`).

### Changed

- All `codetot-web/litesoup` references in `README.md`, `CHANGELOG.md`,
  `site/site-create.sh`, and acceptance test docs updated to
  `litesoup/litesoup` after GitHub org transfer.

## [0.8.0] - 2026-05-03

Documentation overhaul. README slimmed from 237 lines to 62 (no technical
detail, just what + who + 30-second start). Multi-page docs site under
`docs/` served via GitHub Pages with the just-the-docs theme. Closes
codetot-web/litesoup#22. Stage 12 install-stack log label corrected to
match v0.7.1's softer sshd defaults.

This release was built via parallel multi-agent dispatch — 8 Claude
subagents wrote the docs pages in ~15 min (1550 LOC of markdown across
9 files). One local Ollama gemma4 probe (on `docs/install.md`) failed
with empty/malformed JSON output and fell back to a Claude subagent;
matches the Wave 2 finding that local models are less reliable than
subagents for content with judgment.

### Added — `docs/` multi-page site (Jekyll + just-the-docs)

New `docs/` folder served via GitHub Pages at
`https://codetot-web.github.io/litesoup/`. Pages:

- **`docs/index.md`** — landing: who it's for, 30-second start, what you
  get out of the box.
- **`docs/install.md`** — full install guide: requirements, common flags,
  the `LITESOUP_PPA_FORCE_MIRROR=cloudpanel` env var, 14-stage table.
- **`docs/sites.md`** — `site-create`, `site-set-php`, `site-set-tier`,
  `site-set-tls`, `site-delete` reference.
- **`docs/hardening.md`** — all 6 `harden/*` scripts, opt-in flags
  (especially `harden-ssh --no-password-auth` / `--no-root-login`),
  `--skip-hardening` guidance.
- **`docs/caching.md`** — existing v0.5.0 caching policy doc; light
  tone-pass + Jekyll frontmatter added.
- **`docs/audit.md`** — all 4 `audit/*` scripts with example output and
  cron-friendly `--format=json` snippets.
- **`docs/troubleshooting.md`** — common issues with Symptom / Cause /
  Fix shape: PHP install errors, SSH lockout recovery, vhost template
  bug pre-v0.4.1, fail2ban port mismatch, etc.
- **`docs/architecture.md`** — filesystem layout, per-user FPM model,
  why bare-metal apt over Docker, idempotency as a first principle.
- **`docs/roadmap.md`** — what shipped (chronological table v0.1.0→v0.7.1)
  + what's next (self-hosted aptly mirror, harden-mariadb/redis, OCSP,
  distro detection, Sigstore signing, tune/maintain/monitor packages).
- **`docs/contributing.md`** — local test loop, conventions
  (set-Eeuo-pipefail, common.sh, cmp-then-install idempotency,
  reload-not-restart), test layers, multi-agent dispatch pattern.

### Added — Jekyll + GitHub Pages infra

- **`docs/_config.yml`** — `remote_theme: just-the-docs/just-the-docs`,
  dark color scheme, search enabled, edit-this-page footer link.
- **`.github/workflows/pages.yml`** — builds + deploys docs on every
  push to main that touches `docs/` or the workflow itself. Uses the
  official `actions/jekyll-build-pages@v1` + `actions/deploy-pages@v4`
  flow. To activate: repo Settings → Pages → Source = GitHub Actions
  (one-time, post-merge).

### Changed — `README.md` (slim)

- Was 237 lines of technical detail (filesystem layout, hardening tables,
  caching deep-dive). Now 62 lines: tagline + status badges + 30-second
  start + link block to docs pages + get-help + license.
- Everything cut from README is preserved + expanded on its dedicated
  docs page. Operators land on the README, get the quick start, then
  click through to the relevant docs page.

### Changed — `install/install-stack.sh`

- Stage 12 log label updated from
  `harden-ssh (PermitRootLogin no, password off, key-only)` to
  `harden-ssh (always-safe defaults; --no-password-auth / --no-root-login are opt-in)`.
  The old label was stale post-v0.7.1 (the directives are no longer in the
  default heredoc — they're opt-in flags). Operators reading install logs
  no longer see misleading "PermitRootLogin no" claims.

### Verified on sg10.codetot.org (real Ubuntu 24.04 acceptance)

Re-installed v0.7.1 stack on a freshly-rebuilt sg10 droplet:

- All 14 install-stack stages PASS in ~4 min wall-clock
- `LITESOUP_PPA_FORCE_MIRROR=cloudpanel` env var fast-path correctly
  bypassed launchpad
- `php8.2-imagick` + `php8.2-redis` correctly skipped with warning
  (CloudPanel mirror coverage gap, expected)
- `harden-ssh` wrote only the always-safe directives:
  ```
  MaxAuthTries 3
  ClientAliveInterval 300
  ClientAliveCountMax 2
  X11Forwarding no
  AllowAgentForwarding no
  PermitEmptyPasswords no
  ```
- `sshd -T` confirms `permitrootlogin yes` and `passwordauthentication
  yes` are still in effect — exactly what the v0.7.1 hot-fix promised.
  No SSH lockout risk for hosts that bootstrap as root with password
  auth.

### Out of scope (queued)

- Search-engine setup (Algolia etc.) — Jekyll's built-in search is
  sufficient for v1.
- Translations (English-only for now).
- Architecture diagrams — text-first; add later if a page needs one.
- Self-hosted aptly mirror (still TODO; the CloudPanel dependency note
  in `docs/architecture.md` flags the long-term posture).

### Multi-agent dispatch notes (this release)

- **8 Claude subagents in parallel** (single-message multi-tool call):
  audit, hardening, sites, troubleshooting, architecture, roadmap,
  contributing, install (fallback) + caching frontmatter update. Total
  wall-clock: ~3 min from dispatch to all subagents reporting done.
  Total output: 1550 LOC of markdown.
- **1 local Ollama gemma4 probe** on `docs/install.md`: failed with
  empty/malformed JSON response from the `/api/generate` endpoint.
  Fell back to a Claude subagent (delivered in 64s). Confirms the Wave
  2 finding: local models work for one-shot drafts but their failure
  modes (silent malformed output, no error to retry on) are worse for
  unattended dispatch than Claude subagents.
- 3 high-judgment files (README slim, `docs/index.md` landing,
  `docs/_config.yml`) written by Claude (parent) — these set tone /
  brand / theme config, not delegation candidates.

## [0.7.1] - 2026-05-03

Hot-fix release. v0.7.0's `harden/harden-ssh.sh` defaults were too aggressive
for litesoup's typical deployment pattern (operators SSH as root, some hosts
allow password auth intentionally). v0.7.1 makes both `PasswordAuthentication
no` and `PermitRootLogin no` opt-in via flags. Closes
litesoup/litesoup#20.

### ⚠️ v0.7.0 → v0.7.1 behavior change (deliberate)

If you ran v0.7.0's `install-stack.sh` and want to KEEP the v0.7.0 hardened
posture (key-only SSH, no root login), pass the explicit flags now:

```bash
sudo bash harden/harden-ssh.sh --no-password-auth --no-root-login
```

Otherwise: re-running `install-stack.sh` (or `harden/harden-ssh.sh` standalone)
under v0.7.1 will REWRITE `/etc/ssh/sshd_config.d/52-litesoup-harden.conf`
with the gentler default — which means **password SSH and root SSH that you
previously disabled will be re-enabled** (subject to whatever the lower-numbered
sshd_config.d/ files say). This is intentional: the v0.7.0 default broke a
real workflow (couldn't run install-stack on `sg10.codetot.org` because it
would have locked the operator out). If your security posture depends on the
stricter setting, pass the opt-in flags every time.

### Fixed

- **`harden-ssh.sh` default no longer disables `PasswordAuthentication`**
  (was forced off in v0.7.0). Operators who bootstrap with password SSH or
  who run install-stack on hosts that lack pre-installed SSH keys are no
  longer locked out by the install. The directive is still available as
  opt-in via `--no-password-auth`.

- **`harden-ssh.sh` default no longer disables `PermitRootLogin`** (was
  forced `no` in v0.7.0). Many litesoup deployments run `install-stack.sh`
  AS root over SSH; v0.7.0's default would have terminated that workflow
  on next session. The directive is still available as opt-in via
  `--no-root-login`.

- **Always-safe defaults still applied** (no change from v0.7.0): `MaxAuthTries
  3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `X11Forwarding no`,
  `AllowAgentForwarding no`, `PermitEmptyPasswords no`. These don't depend on
  policy choices and are universally safer.

### Added

- `--no-password-auth` flag on `harden-ssh.sh` — adds `PasswordAuthentication
  no` to the managed override.
- `--no-root-login` flag on `harden-ssh.sh` — adds `PermitRootLogin no` to
  the managed override.
- 5 new bats regression tests in `test/bats/unit_harden.bats`:
  - Default heredoc must NOT contain `PermitRootLogin no` (guards against
    a future regression that re-introduces v0.7.0's behavior)
  - Default heredoc must NOT contain `PasswordAuthentication no`
  - `--help` documents `--no-password-auth`
  - `--help` documents `--no-root-login`
  - All 6 always-safe defaults are still in the heredoc (guards against
    over-removal during this hot-fix)
- Total bats unit tests: 116 → **121**.

### Changed

- `harden-ssh.sh` `usage()` text — now lists "Always-applied defaults"
  separately from "Opt-in extras" so operators can see at a glance what
  changes vs what stays.
- Documentation in script header points operators who want stricter policy
  to write a higher-numbered file (e.g. `99-local-strict.conf`) themselves.

### Notes

- v0.7.0 release/tag stays in place but is effectively superseded.
  v0.7.1 release notes call out the behavior change explicitly.
- `harden-apache.sh` and `harden-php.sh` defaults are unchanged — those are
  not policy-dependent in the same way.
- `install-stack.sh` does not pass any new flags by default. To get the
  v0.7.0 behavior back, edit `install-stack.sh` stage 12 to pass
  `--no-password-auth --no-root-login` to `harden/harden-ssh.sh`, OR run
  the standalone script with those flags after install completes.

## [0.7.0] - 2026-05-03

Wave 2 of Plan I.E + Plan H: per-service hardening for sshd, Apache, and PHP
(global ini level). Closes litesoup/litesoup#18. Three new `harden/`
scripts wired into install-stack as stages 12/13/14.

This release was built via multi-agent dispatch with a real fallback story:
local Ollama qwen2.5-coder:14b was tried first per `~/.claude/CLAUDE.md`
routing ("daily driver codegen"). Output was shellcheck-clean but contained
3 semantic bugs (literal `\n` in heredoc content → invalid sshd_config;
validation against the wrong file; unset variable crash under `set -u`).
Fell back to 3 Claude subagents in parallel — all 3 delivered correct
working scripts in ~2 min, no further bugs caught by adversarial review.
Lesson: shellcheck-clean does not equal semantically-correct. The per-script
brief that explicitly called out each qwen failure mode helped subagents
avoid them.

### ⚠️ Breaking-by-default

`harden-ssh.sh` disables `PasswordAuthentication`. **If you bootstrap a host
via password-only SSH** (e.g., a fresh DO droplet's root password) and then
run `install-stack.sh`, you will be locked out on next session. **Always
set up an SSH key BEFORE running install-stack on a new host**.
`install-stack.sh:184` documents this in a comment block. To opt out for a
specific host, run `install-stack.sh --skip-hardening` (skips all
stages 9-14, not just SSH) or re-enable password auth manually via a
higher-numbered file in `/etc/ssh/sshd_config.d/` after install completes.

### Added — `harden/` Wave 2

- **`harden/harden-ssh.sh`** — writes a managed override at
  `/etc/ssh/sshd_config.d/52-litesoup-harden.conf`:
  `PermitRootLogin no`, `PasswordAuthentication no` (key-only),
  `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`,
  `X11Forwarding no`, `AllowAgentForwarding no`, `PermitEmptyPasswords no`.
  **Validate-then-revert flow**: snapshots existing override (if any)
  to a tmp backup → writes new override → runs `sshd -t` (full include
  chain) → on failure, restores backup and re-validates so a broken
  pre-existing config is surfaced separately from a broken new override.
  Reload (NOT restart) — preserves the live SSH session. Skips the Port
  directive (that's harden-firewall's concern). DOES NOT edit
  `/etc/ssh/sshd_config` directly (apt may rewrite it).

- **`harden/harden-apache.sh`** — writes two managed snippets to
  `/etc/apache2/conf-available/`:
  - `52-litesoup-harden.conf` — `ServerTokens Prod`, `ServerSignature
    Off`, `TraceEnable Off`, plus security headers via mod_headers
    (`X-Content-Type-Options nosniff`, `X-Frame-Options SAMEORIGIN`,
    `Referrer-Policy strict-origin-when-cross-origin`). Headers wrapped
    in `<IfModule mod_headers.c>` so the snippet is safe even on
    non-litesoup hosts where mod_headers isn't loaded.
  - `52-litesoup-mod-status.conf` — restricts `/server-status` to
    `Require local` if mod_status is loaded.
  - Disables mod_info if currently loaded (`a2dismod info || true`).
  - `apache2ctl configtest` AFTER write, BEFORE reload. Reload-only
    (preserves connections).

- **`harden/harden-php.sh`** — discovers every installed PHP version
  under `/etc/php/X.Y/`, writes managed `52-litesoup-harden.ini` to
  BOTH `cli/conf.d/` AND `fpm/conf.d/`:
  `expose_php = Off`, `allow_url_fopen = Off`, `allow_url_include = Off`,
  `display_errors = Off`, `display_startup_errors = Off`, `log_errors = On`,
  `session.cookie_httponly = 1`, `session.cookie_secure = 1`,
  `session.use_strict_mode = 1`. Per-version FPM reload tracking — only
  reloads `php<v>-fpm.service` for versions whose conf actually changed
  AND whose service is `is-active`. Complementary to existing per-pool
  hardening already in `install/lib/php.sh`'s pool template.

### Changed — `install/install-stack.sh`

- Stages bumped 1/11..11/11 → **1/14..14/14**. Added stages 12 (ssh),
  13 (apache), 14 (php). With `--skip-hardening`, total stays at /8.
- Comment block at the SSH stage documents the password-lockout risk.

### Added — tests

- 7 new bats in `test/bats/unit_harden.bats`:
  - `--help` smoke for harden-ssh, harden-apache, harden-php (3 cases)
  - Path discipline guard: harden-ssh writes to `sshd_config.d/`, not
    main config (1 case — defends against a future regression that
    edits the package-managed file)
  - Path discipline guard: harden-php writes to `conf.d/`, not main
    php.ini (1 case)
  - harden-apache uses `apache2ctl configtest` before reload (1 case)
  - All 3 Wave-2 harden scripts use `systemctl reload`, not `restart`
    (1 case — preserves SSH sessions / Apache connections / PHP-FPM
    requests)
- Total bats unit tests: 109 → **116**.

### Multi-agent dispatch notes (see also v0.6.0 notes)

- **Local Ollama qwen2.5-coder:14b** (per `~/.claude/CLAUDE.md` routing
  table for daily-driver codegen): generated harden-ssh.sh in 29s,
  shellcheck-clean, but produced 3 semantic bugs (literal `\n`, wrong
  validation order, unset variable crash). shellcheck does not catch
  semantic correctness — it only catches syntactic and a handful of
  pattern-based issues.
- **Fallback to 3 parallel Claude subagents** (single-message multi-tool
  call, per Wave 1 pattern): all 3 scripts delivered correct + working
  in ~2 min combined. Per-script briefs explicitly called out the
  qwen failure modes ("don't write `\n` strings — use heredoc"; "validate
  AFTER write, not before"; "initialize CHANGED=0 — set -u crashes
  otherwise"). Each subagent reported avoiding the specific failure modes.
- **Routing decision**: for bash codegen with critical correctness
  requirements (semantic correctness, not just syntactic), Claude
  subagents remain the safer default. Local models are useful for
  drafts but need a verification pass that catches more than shellcheck
  before integration.

### Out of scope (Wave 3)

- harden-mariadb, harden-redis (broader hardening)
- I.E.2 OCSP stapling, I.E.3 distro detection, I.E.4 Sigstore signed
  releases, I.E.5 `--remove-php=X.Y` flag
- `tune/`, `maintain/`, `monitor/` directory ports

## [0.6.0] - 2026-05-03

Wave 1 of Plan I.E (security basics) + Plan H (litesoup-native audit/harden
packages, ported from runcloud-bash-scripts conventions). Closes
litesoup/litesoup#16. Two new top-level directories: `harden/` (3
state-changing scripts) and `audit/` (4 read-only check scripts).

This release was built via multi-agent parallel dispatch — 4 Claude subagents
wrote the audit ports in ~3min, 3 more subagents wrote the harden scripts in
~85s after a DeepSeek/9router fallback. Total: 2367 LOC of shellcheck-clean
bash across 7 new files. Adversarial review pass caught one real bug
(harden-fail2ban watching the wrong port if sshd is non-default — now uses
the same `detect_ssh_port` parser as harden-firewall). Documented for future
reuse of the multi-agent pattern.

### Added — `harden/` (state-changing security baseline)

- `harden/harden-firewall.sh` — configures `ufw` with `deny incoming` /
  `allow outgoing`, allows the actual sshd port (parsed from
  `/etc/ssh/sshd_config`, fallback 22) plus 80/tcp + 443/tcp, then enables
  with `--force` (avoids the interactive prompt that hangs in non-tty
  contexts). Idempotent: re-runs detect existing rules and report
  "already configured" without re-applying.

- `harden/harden-fail2ban.sh` — installs fail2ban with two managed jails:
  `[sshd]` (systemd backend, 3 retries / 1h ban / port matched against
  sshd_config — NOT the `ssh` alias, which would silently miss
  non-default ports) and `[apache-auth]` (apache2 error logs, 5 retries
  / 1h ban). Apache jail skipped with a warning if `/var/log/apache2/`
  is absent. Idempotent: jail files written via `cmp -s` + `install -m
  0644` pattern (mirrors `install/lib/redis.sh`); fail2ban only reloaded
  when at least one file changes.

- `harden/harden-unattended-upgrades.sh` — installs unattended-upgrades +
  apt-listchanges; writes `/etc/apt/apt.conf.d/52litesoup-unattended`
  (security-only allowed-origins, no auto-reboot, mail off, remove unused
  deps) and `/etc/apt/apt.conf.d/20auto-upgrades` (periodic timers). The
  `52` prefix overrides the package-default `50unattended-upgrades`,
  which apt may rewrite on package upgrades. Smoke-tested with
  `unattended-upgrade --dry-run --debug`. Idempotent.

### Added — `audit/` (read-only check scripts)

- `audit/audit-wp-health.sh` — discovers all WP sites under
  `/home/*/webapps/` (or one via `--domain=`); per site checks core
  version + update available, plugin count + outdated count, DB
  connection + size, disk usage, wp-config.php permissions, TLS cert
  expiry, error log size. Exits 0/1/2 (healthy/warning/critical).
  Ported from `runcloud-bash-scripts/wp-health-check.sh`, adapted to
  litesoup conventions (per-user FPM pool layout, common.sh helpers).

- `audit/audit-system-metrics.sh` — read-only system + service metrics:
  CPU (load + cores + iowait), memory + swap, per-mount disk + inode
  usage (flags >85%), network (per-iface tx/rx + socket counts), Apache
  (`/server-status?auto` if reachable), PHP-FPM (per-pool active/idle),
  MariaDB (connection count + slow query log scan), Redis (INFO with
  auth from `/etc/litesoup/redis.env`). `--format=text|json` flag.
  Ported from `runcloud-bash-scripts/server-metrics.sh`; dropped the
  webhook + HMAC POST (this is a local audit, not a metrics shipper).

- `audit/audit-wp-vulnerabilities.sh` — per-site CVE scan against the
  free WPVulnerability.net API (no auth required). Enumerates installed
  plugins/themes via wp-cli, cross-references against the vulnerability
  database, reports CVE / severity / fixed-version. `--include-core`,
  `--plugins-only`, `--themes-only` flags. Documents the litesoup secret
  pattern (`/etc/litesoup/wpscan.env`) for future migration to the paid
  WPScan API. Ported from `runcloud-bash-scripts/wp-vuln-check.sh`.

- `audit/audit-performance.sh` (NEW — flagged in architecture doc Plan I.F
  future-work line) — compares live config of Apache (mpm_event),
  PHP-FPM per-pool sizing, OPcache, MariaDB, and Redis against
  recommended values for the system's RAM tier (small <2G / medium 2–8G
  / large ≥8G — same tier mapping as `install/lib/redis.sh`). Per-tunable
  findings with current vs recommended values + WARN/CRIT severity.
  `--service=apache|php-fpm|opcache|mariadb|redis|all` and
  `--format=text|json` flags.

### Changed — `install/install-stack.sh`

- Stages bumped from `1/8..8/8` to `1/11..11/11`. Added stages
  9/10/11 invoking the three harden scripts (after services are up so
  fail2ban can watch real Apache logs).
- New `--skip-hardening` flag for dev VMs / hosts where the firewall is
  managed elsewhere. With this flag, stages 9–11 are skipped and the
  total stage label drops to `/8` so log progression stays accurate.

### Changed — CI

- `shellcheck` job now also covers `harden/*.sh` and `audit/*.sh`.

### Added — tests

- `test/bats/unit_harden.bats` — 18 new unit tests covering
  `detect_ssh_port` (5 cases — fallback, present, last-wins,
  comment-skipping, non-numeric rejection), `ufw_is_active` /
  `ufw_rule_present` (4 cases), parser parity between
  harden-firewall and harden-fail2ban (1 case — guards against the bug
  caught in adversarial review where the two scripts could disagree on
  the SSH port), `--help` smoke for all 7 new scripts (7 cases), and
  install-stack `--help` mentions `--skip-hardening` (1 case).
- Total bats unit tests: 91 → **109**.

### Out of scope (Wave 2/3 in plan I.E + plan H)

- Wave 2: `harden/` ports of ssh / apache / php / mariadb / redis
  (broader hardening beyond Wave 1's firewall/fail2ban/auto-updates).
- Wave 2: I.E.4 — Sigstore-signed installer releases.
- Wave 3: I.E.2 (OCSP stapling), I.E.3 (Debian 12 + Ubuntu 22.04
  support), I.E.5 (`install-stack --remove-php=X.Y` flag).
- Wave 3: `tune/`, `maintain/`, `monitor/` directory ports.

### Multi-agent dispatch notes (for the next wave)

- **Claude subagents (general-purpose) work great** for shell-script
  generation when given a self-contained brief with conventions to read
  + scope-locked target file + max-2-retries. 4 audit scripts + 3 harden
  scripts produced in two parallel batches, all shellcheck-clean on first
  delivery.
- **opencode/DeepSeek hung** — appears 9router (the local routing proxy
  at `localhost:20128`) was down. opencode buffered to 9router and
  produced no output for 24+ minutes before being killed. Falling back
  to subagents was faster than diagnosing the proxy.
- **Adversarial pass found one bug** — fail2ban using `port = ssh`
  resolves to 22 via /etc/services, while harden-firewall correctly
  parsed sshd_config. On a host with sshd on a non-default port, the
  firewall would open the right port and fail2ban would watch the wrong
  one (= no SSH brute-force protection at all). Fixed by extracting
  the same `detect_ssh_port` parser into both files.

## [0.5.1] - 2026-05-03

Bug-fix release. Unblocks CI and any DO Singapore / blocked-network deployment
that can't reach `ppa.launchpadcontent.net`. Closes litesoup/litesoup#14.
First green CI on any branch since the v0.3.0 / Plan I.D merge.

### Fixed

- **CI / install-stack PPA reachability** (closes litesoup/litesoup#14):
  `install/lib/apt.sh` `ensure_ppa()` now probes apt-get update for our
  specific URI after `add-apt-repository` succeeds, and dispatches to a
  per-PPA mirror when the URI fails to fetch. Previously: GitHub Actions
  ubuntu-24.04 runners and DO Singapore VPSes (incl. sg10.codetot.org)
  couldn't reach `ppa.launchpadcontent.net:443` (TLS handshake failure
  / 503 / connection timed out); apt-get update returned 0 with
  warnings, then the next apt-get install died with "Unable to locate
  package php8.2-fpm" because the PPA index never made it into the
  cache. CI has been red on main since the v0.3.0 / I.D merge for
  exactly this reason.

  Mirror chosen: **packages.cloudpanel.io** (CloudPanel CE's
  CloudFront-fronted apt mirror, repackaged Sury PHP builds for
  Ubuntu noble/jammy + Debian). Same package names, byte-equivalent
  installs (version suffix `+clp-noble` vs upstream). GPG fingerprint
  pinned to `4FFD41A7CB8F2CEA5F75E6CC1FD0B9CFEFC59AC9` so silent key
  rotation fails loudly. arm64/amd64 origin auto-detected via
  `dpkg --print-architecture`.

  **Coverage caveat:** CloudPanel mirrors core PHP + standard
  extensions but NOT PECL extensions (`php-imagick`, `php-redis`).
  Both ARE in the launchpad PPA. To handle this without aborting on
  CloudPanel-fallback networks, `PHP_EXTENSIONS` was split:
  - `PHP_EXTENSIONS_CORE` (required, aborts if missing): fpm, cli,
    common, opcache, mysql, mbstring, xml, curl, gd, zip, intl,
    bcmath, soap.
  - `PHP_EXTENSIONS_OPTIONAL` (best-effort, log_warn + skip when
    not in configured repos): imagick, redis.

  When skipped, WP Redis Object Cache automatically falls back to the
  bundled Predis pure-PHP client (slower but functional); WP image
  processing falls back to GD (already in CORE).

  New apt.sh helper: `ensure_pkgs_optional` uses `apt-cache policy`
  (stricter than `apt-cache show`, which returns 0 even for packages
  only referenced as dep names) to filter to packages with a real
  Candidate before invoking `apt_install`.

  End-to-end verified on sg10.codetot.org (Ubuntu 24.04.4 LTS, DO
  Singapore, launchpad genuinely blocked): all 8 install-stack stages
  PASS, php8.2-fpm + 12 standard extensions installed from CloudPanel
  mirror, php8.2-imagick + php8.2-redis correctly skipped with
  warning, redis-server + memcached configured, site-create injects
  cache constants across two sites with distinct salts and is
  idempotent on re-run.

  Long-term posture: self-host an aptly mirror of `ppa:ondrej/php`
  and remove this third-party dependency. Filed as a separate
  follow-up.

- **WP_CACHE_KEY_SALT injection deferred to wp-cli native generation**:
  WP-CLI 2.12.0+ generates `WP_CACHE_KEY_SALT` natively in
  `wp config create` using the full WordPress secret-key alphabet
  (higher entropy than our 64-char hex). The existing `wp config has`
  guard in `inject_cache_constants()` correctly defers — our injection
  is now a fallback for older wp-cli releases. Test assertions
  relaxed accordingly (length ≥ 32 + non-empty + distinct across two
  sites, instead of `^[0-9a-f]{64}$`).

- **Vendor PHP-FPM pool disable handles non-Ubuntu naming**: CloudPanel
  ships `php8.X-fpm` with `default.conf` (a real `[default]` pool
  running as `www-data` on `127.0.0.1:17000` with `pm.max_children=250`
  — same security/resource hole as Ubuntu's `www.conf`, just renamed)
  instead of Ubuntu's `www.conf`. `ensure_php_fpm()` previously only
  knew about `www.conf`, so on CloudPanel-mirror installs the default
  pool ran unchecked. Now disables every `*.conf` in `pool.d/` that
  isn't litesoup-owned, regardless of vendor naming. Skips
  `litesoup-*` (ours) and `global.conf` (the [global] settings file,
  not a pool — master fpm needs it). Test assertions updated to assert
  the security property generically (no non-litesoup `*.conf` left
  active, plus at least one `*.conf.disabled` marker).

- **`ensure_php_fpm` idempotent re-run** (`set -e` footgun): the
  function's last statement was `[ "${disabled_any}" = "1" ] &&
  systemctl reload`. On re-run when nothing needed disabling, the
  `&&` short-circuits, the function returns 1, and `set -e` in the
  caller (`install-stack.sh`'s `for v in ...; do ensure_php_fpm; done`)
  trips. Result: re-running `install-stack.sh` aborted at "failed at
  line 128 (exit 1)" even though everything was already in the
  desired state. Replaced with explicit `if/then/fi` (an `if`
  statement returns 0 when no branch executes).

- **Probe + mirror fallback also runs after manual PPA registration**:
  The earlier reachability probe was wired only to the
  `add-apt-repository succeeds` branch. When `add-apt-repository`
  itself failed (network flake fetching launchpad metadata), control
  fell through to the manual-registration path, which writes a
  launchpad-style `.sources` file pointing at the still-unreachable
  URL. Both paths now go through the same `_ppa_reachable_or_fallback`
  call — catches both reachability failure modes uniformly.

### Added

- 11 new bats unit tests in `test/bats/unit_apt.bats` covering
  `ensure_pkgs_optional`, `_ppa_reachable_or_fallback`,
  `_ppa_fallback`, and `_ensure_repo_cloudpanel_php` (dry-run path).
  Total bats unit tests: 80 → 91.

- ERR trap in `test/integration/01_install_stack.sh` that prints
  `FAIL @ <file>:<line>: <command>` on assertion failure. Cheap
  diagnostic that surfaces which assertion broke without needing a
  follow-up CI cycle.

### Changed

- **CI: collapse 3 integration jobs into one container.** Previously
  `integration-install-stack` → `integration-site-create` →
  `integration-site-delete` were three `needs:`-chained jobs each
  spinning a fresh systemd container and running `install-stack.sh`
  from scratch — `apt install` + PHP from the CloudPanel mirror ran
  3× per CI run. Now one `integration` job runs all three integration
  scripts sequentially in the SAME container via
  `test/docker/run-integration.sh`'s new multi-script support
  (`./run-integration.sh 01_install_stack.sh 02_site_create.sh
  03_site_delete.sh`). Per-script `=== <name> ===` /
  `=== FAILED in <name> (exit N) ===` markers preserve failure
  granularity. Same coverage; ~3× faster; one CloudPanel fetch per PR.

## [0.5.0] - 2026-05-02

Plan I.F: caching infrastructure (Redis + Memcached) plus per-site
`WP_CACHE_KEY_SALT` injection. Closes litesoup/litesoup#12.

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
- **`site-create.sh` DB password idempotency** (closes litesoup/litesoup#9): `create_database` generated a fresh random password every run AND used `CREATE USER IF NOT EXISTS` which silently keeps the OLD password if the user exists. A site-create that aborted partway (e.g., apache configtest fail, network glitch on certbot) and was re-run wrote a NEW password to `wp-config.php` while MySQL kept the OLD password — WordPress returned 500 with `Error establishing a database connection`. Now: if `wp-config.php` already exists, reuse its password; either way, the SQL emits both `CREATE USER IF NOT EXISTS` AND `ALTER USER ... IDENTIFIED BY '<pw>'` so MySQL always matches `wp-config.php`. Self-healing on retry.

### Added

- 2 new bats tests in `unit_site_create.bats` covering the `create_database` SQL emit (`CREATE USER` + `ALTER USER` always present with the same password) and the wp-config.php password reuse parser.

### Acknowledged false positive (closed)

- litesoup/litesoup#10 (pool template missing `log_errors`): the `php_admin_flag[log_errors] = on` line IS present in the template at line 22 and renders correctly. The reason `/home/<user>/.logs/php<v>-fpm.error.log` didn't exist on sg10 was that PHP had no fatal error to log — WordPress's 500 was an application-level HTML response. Issue closed.

[0.4.1]: https://github.com/litesoup/litesoup/releases/tag/v0.4.1

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

[0.4.0]: https://github.com/litesoup/litesoup/releases/tag/v0.4.0

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

[0.3.0]: https://github.com/litesoup/litesoup/releases/tag/v0.3.0

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

First public release. Implements [Plan I.A](https://github.com/litesoup/litesoup/pull/2): a one-line bash installer that turns a fresh Ubuntu 24.04 host into a working WordPress server.

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

[0.10.0]: https://github.com/litesoup/litesoup/releases/tag/v0.10.0
[0.9.2]: https://github.com/litesoup/litesoup/releases/tag/v0.9.2
[0.9.1]: https://github.com/litesoup/litesoup/releases/tag/v0.9.1
[0.9.0]: https://github.com/litesoup/litesoup/releases/tag/v0.9.0
[0.8.3]: https://github.com/litesoup/litesoup/releases/tag/v0.8.3
[0.8.2]: https://github.com/litesoup/litesoup/releases/tag/v0.8.2
[0.8.1]: https://github.com/litesoup/litesoup/releases/tag/v0.8.1
[0.8.0]: https://github.com/litesoup/litesoup/releases/tag/v0.8.0
[0.7.1]: https://github.com/litesoup/litesoup/releases/tag/v0.7.1
[0.7.0]: https://github.com/litesoup/litesoup/releases/tag/v0.7.0
[0.6.0]: https://github.com/litesoup/litesoup/releases/tag/v0.6.0
[0.5.1]: https://github.com/litesoup/litesoup/releases/tag/v0.5.1
[0.5.0]: https://github.com/litesoup/litesoup/releases/tag/v0.5.0
[0.2.0]: https://github.com/litesoup/litesoup/releases/tag/v0.2.0
[0.1.0]: https://github.com/litesoup/litesoup/releases/tag/v0.1.0
