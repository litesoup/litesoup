# Backup System Implementation Plan

> **For Hermes:** Use plan skill — plan mode only, no execution until go-ahead.

**Goal:** Add per-site backup capabilities to litesoup: manual backup, scheduled backup (daily/weekly/custom), local + S3-compatible destinations, full + partial backup modes.

**Architecture:** New `backup/` directory following the existing `site/` pattern. Each backup script sources lib functions from `backup/lib/*.sh`. Scheduling via systemd timers (per-site). S3 support via `s3cmd` CLI (S3-compatible, works with AWS S3, IDrive e2, Backblaze B2, etc.).

**Existing patterns to follow:**
- `install/lib/*.sh` — idempotent guard at top, `set -Eeuo pipefail`, `run_or_dryrun`, `log_*`, `ensure_pkgs`
- `site/site-create.sh` — `SCRIPT_DIR` + `REPO_ROOT` detection, `source "${REPO_ROOT}/install/lib/common.sh"`, `usage()` and `main()` pattern, CLI argument parsing
- Per-site user lives at `/home/<user>/`, webapps at `/home/<user>/webapps/<domain>/`
- MariaDB root creds at `/root/.litesoup-mariadb-root`

---

## Features

### Backup types
- **Full backup**: entire `/home/<user>/webapps/<domain>/` + database dump (mysqldump)
- **Partial backup**: configurable exclusions (`--skip-files`, `--skip-db` + `--exclude=path1,path2`)

### Destinations
- **Local**: `/home/<user>/backups/<domain>/YYYY-MM-DD_HHMMSS/`
- **S3-compatible**: AWS S3, IDrive e2, Backblaze B2, etc. via `s3cmd`

### Scheduling
- Per-site systemd timer: `litesoup-backup@<domain>.timer`
- Presets: `daily`, `weekly`, `custom` (cron expression)
- Timer runs `backup/backup-site.sh` as root

### Retention
- Local: configurable `--keep=N` (default: keep last 7 backups, delete older)
- S3: handled by S3 lifecycle policies or `s3cmd sync --delete-removed`

### Configuration
- Per-site config file: `/home/<user>/backups/<domain>.conf`
- Global config: `/etc/litesoup/backup.conf`
- Config contains: S3 endpoint/credentials, schedule, retention, exclusions

---

## Files to create/modify

### New files

| File | Purpose |
|---|---|
| `backup/backup-site.sh` | Main CLI entry point — runs a backup for one domain |
| `backup/backup-list.sh` | List existing backups for a domain |
| `backup/lib/common.sh` | Shared backup lib: archive, upload, config parsing |
| `backup/lib/s3.sh` | S3-compatible upload/download helpers |
| `backup/backup-install.sh` | Install backup scripts, create directory structure, set up systemd timer |
| `install/lib/backup.sh` | (Optional) Integration with install-stack.sh — install backup scripts during stack install |
| `docs/backup.md` | Documentation page |

### Modified files

| File | Change |
|---|---|
| `install/install-stack.sh` | Add optional "install backup" stage at end |
| `README.md` | Add "Backups" section to feature list |
| `docs/index.md` | Add backup doc link |

---

## Step-by-step tasks

### Task 1: Create `backup/lib/common.sh`

Shared backup functions:
- `backup_config_load(domain)` — reads `/home/<user>/backups/<domain>.conf` and `/etc/litesoup/backup.conf`
- `backup_detect_user(domain)` — finds the site owner from Apache vhost or webapps directory
- `backup_archive(folder, dest)` — creates a tar.gz archive
- `backup_dump_db(domain, dest)` — mysqldump to SQL file
- `backup_rotate_local(backup_dir, keep=N)` — delete backups older than N newest
- `backup_name()` — generates `YYYY-MM-DD_HHMMSS` timestamp

**Idempotent guard:** `LITESOUP_BACKUP_COMMON_SH`

### Task 2: Create `backup/lib/s3.sh`

S3 helpers:
- `backup_s3_ensure_cfg()` — ensure s3cmd is installed and configured
- `backup_s3_upload(local_path, remote_path)` — s3cmd put
- `backup_s3_list(prefix)` — s3cmd ls
- `backup_s3_sync(local_dir, remote_prefix)` — s3cmd sync for retention management

**S3 config model:**
```ini
# /home/<user>/backups/<domain>.conf or /etc/litesoup/backup.conf
[S3]
type = s3
bucket = litesoup-backups
endpoint = https://e2.idy.idrivee2.com
access_key = AKIAXXX
secret_key = ...
region = us-east-1  # most S3-compatible ignore this

[Backup:example.com]
schedule = daily
keep_local = 7
keep_s3 = 30
skip_files = cache/,uploads/backup/
skip_db = false
exclude = node_modules/, .git/
s3_prefix = backups/example.com/
```

### Task 3: Create `backup/backup-site.sh`

Main CLI:
```
Usage: sudo bash backup/backup-site.sh --domain=DOMAIN [options]

Options:
  --domain=DOMAIN     Required. Site domain (e.g. example.com)
  --user=NAME         Site system user (auto-detected from vhost if omitted)
  --dest=local|s3|all Destination(s). Default: local
  --skip-files        Skip file archive (database-only)
  --skip-db           Skip database dump (files-only)
  --exclude=PATH      Additional exclude path (repeatable: --exclude=cache/ --exclude=.git)
  --keep=N            Local retention (default: 7)
  --dry-run           Preview without executing
  --help
```

Steps:
1. Load config (per-domain + global)
2. Detect site user from docroot path
3. Create backup dir: `/home/<user>/backups/<domain>/YYYY-MM-DD_HHMMSS/`
4. Dump database (unless `--skip-db`)
5. Archive files (unless `--skip-files`), respecting exclusions
6. Upload to S3 if `--dest=s3` or `--dest=all`
7. Rotate local backups (keep last N)
8. Print backup path and size

### Task 4: Create `backup/backup-list.sh`

List existing backups:
```
sudo bash backup/backup-list.sh --domain=example.com [--s3]
```

Shows: backup timestamp, size, type (full/files-only/db-only), location

### Task 5: Create `backup/backup-install.sh`

One-time setup:
- Creates `/etc/litesoup/backup.conf` template if missing
- Creates `/home/<user>/backups/` dirs for existing site users
- Installs systemd timer units
- Enables timers

### Task 6: Create docs/backup.md

Documentation page covering:
- Quick start: create first backup
- Restore procedure (manual steps)
- S3 configuration
- Scheduling (daily/weekly/custom)
- Exclusion patterns
- Retention policies
- Verification (cron backup log + health check)

### Task 7: Modify `install/install-stack.sh`

Add optional Stage 19: install backup scripts and prompt for S3 config.

### Task 8: Update README + docs/index.md

Add backup to feature lists and navigation.

---

## Systemd timer design

**Unit: `litesoup-backup@.service`**
```ini
[Unit]
Description=litesoup backup for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/litesoup/backup/backup-site.sh --domain=%i --dest=local
User=root
```

**Timer: `litesoup-backup@.timer`**
For daily:
```ini
[Unit]
Description=Daily litesoup backup for %i

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

For custom schedule, a separate `@` template or instance override:
```
# /etc/systemd/system/litesoup-backup@.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/lib/litesoup/backup/backup-site.sh --domain=%i --dest=all
```

---

## Restore procedure (manual, no dedicated script in v1)

```bash
# 1. Extract backup
tar -xzf /home/<user>/backups/<domain>/2026-07-14_120000/files.tar.gz -C /tmp/restore/

# 2. Restore files
rsync -a /tmp/restore/home/<user>/webapps/<domain>/ /home/<user>/webapps/<domain>/

# 3. Import database
mysql -u root -p < /home/<user>/backups/<domain>/2026-07-14_120000/database.sql

# 4. Fix permissions
chown -R <user>:<user> /home/<user>/webapps/<domain>/
```

A dedicated `backup/backup-restore.sh` may be added in a follow-up.

---

## Verification

- Run: `sudo bash backup/backup-site.sh --domain=example.com --dry-run` — shows intended actions
- Run: `sudo bash backup/backup-site.sh --domain=example.com` — creates backup at `/home/litesoup/backups/example.com/`
- Run: `sudo bash backup/backup-site.sh --domain=example.com --dest=s3` — also uploads
- Check: `ls -la /home/litesoup/backups/example.com/` — timestamps and files present
- Check: `backup/backup-list.sh --domain=example.com` — lists all backups
- Systemd: `systemctl status litesoup-backup@example.com` — timer active and running

---

## Open questions

1. **S3 config security** — access keys in plaintext config file? Use s3cmd's `~/.s3cfg` which supports env var overrides (`S3_ACCESS_KEY`, `S3_SECRET_KEY`)?
2. **Database credential discovery** — site-create.sh creates MariaDB user/pass per site. How does backup-db discover them? From `wp-config.php` (`DB_USER`, `DB_PASSWORD` constants) or a dedicated cred store?
3. **Restore script** — include in v1 or defer to v2?
4. **Backup encryption** — GPG-encrypt backups before S3 upload? Add in v2?
5. **Backup notification** — email/Slack/webhook on failure? Defer to v2?
