---
layout: default
title: Backups
nav_order: 7
---

# Backups

litesoup includes a per-site backup system that stores files and database
snapshots locally and optionally to S3-compatible storage (AWS S3, IDrive e2,
Backblaze B2, etc.).

## Quick start

```bash
# Back up a site locally
sudo bash backup/backup-site.sh --domain=example.com

# Back up to both local and S3
sudo bash backup/backup-site.sh --domain=example.com --dest=all

# Files-only backup (skip database)
sudo bash backup/backup-site.sh --domain=example.com --skip-db

# Database-only backup (skip files)
sudo bash backup/backup-site.sh --domain=example.com --skip-files
```

Each backup is stored at `/home/<user>/backups/<domain>/<timestamp>/`.

## Compression (zstd default)

Since v0.11.0, backups use **zstd** as the default compression instead of
gzip — it is ~2x faster on SQL dumps and ~12x faster on media with equal or
better ratios (benchmarked on sg10, 2026-08-29 — team-rd #17):

| Artifact | Command | Output |
|----------|---------|--------|
| Database | `wp db export - \| zstd -8` | `database.sql.zst` |
| Files     | `tar cf - \| zstd -1` | `files.tar.zst` |

Archives are verified after creation (`zstd -t`, and `CREATE TABLE` presence
for DB dumps). Restore transparently decompresses both formats. `zstd` is
installed automatically during `install-stack.sh` (backup stage) and on-demand
by the backup/restore scripts if missing.

## Restore from backup

```bash
# Restore most recent backup
sudo bash backup/backup-restore.sh --domain=example.com

# Restore a specific backup
sudo bash backup/backup-restore.sh --domain=example.com --from=2026-07-14_120000

# Files-only restore
sudo bash backup/backup-restore.sh --domain=example.com --skip-db

# Database-only restore
sudo bash backup/backup-restore.sh --domain=example.com --skip-files
```

The restore script:
1. Extracts files (preserves full paths, owned by the site user)
2. Imports the database via `wp db import`
3. Flushes WordPress and LiteSpeed caches
4. Fixes file ownership

## List backups

```bash
sudo bash backup/backup-list.sh --domain=example.com
```

Shows timestamps, sizes, and contents (files, database, or both).

```bash
sudo bash backup/backup-list.sh --domain=example.com --s3
```

Also shows remote backups on S3.

## Configure notifications

```bash
# Set email recipient for backup success/failure alerts
sudo bash backup/backup-install.sh --email=ops@example.com
```

This writes the recipient to `/etc/litesoup/notify-email.conf` (mode 0600).
Notifications go to both email (if an MTA is installed) and syslog
(`user.notice`). If no email config exists, only syslog is used.

## Configure S3 destination

```bash
sudo bash backup/backup-install.sh \
  --s3-bucket=litesoup-backups \
  --s3-endpoint=https://e2.idy.idrivee2.com \
  --s3-key=YOUR_ACCESS_KEY \
  --s3-secret=YOUR_SECRET_KEY
```

Or use any S3-compatible provider:

```bash
sudo bash backup/backup-install.sh \
  --s3-bucket=my-backups \
  --s3-endpoint=https://s3.us-east-1.amazonaws.com \
  --s3-key=AKIA... \
  --s3-secret=...
```

Config is stored at `/etc/litesoup/backup-s3.conf` (mode 0600, root only).

## Scheduling

### Daily backup with systemd timer

```bash
# Enable daily backups at a randomized time (1h delay window)
systemctl enable --now litesoup-backup@example.com.timer

# Run a backup immediately (even if timer is active)
systemctl start litesoup-backup@example.com

# Check timer status
systemctl status litesoup-backup@example.com.timer

# View last backup run
journalctl -u litesoup-backup@example.com.service --since "24 hours ago"
```

### Custom schedule

Override the default daily timer:

```bash
# Create override directory
mkdir -p /etc/systemd/system/litesoup-backup@example.com.timer.d/

# Write custom schedule (e.g. every 6 hours)
cat > /etc/systemd/system/litesoup-backup@example.com.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=30m
EOF

systemctl daemon-reload
systemctl restart litesoup-backup@example.com.timer
```

### Weekly backup

```bash
mkdir -p /etc/systemd/system/litesoup-backup@example.com.timer.d/
cat > /etc/systemd/system/litesoup-backup@example.com.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=weekly
RandomizedDelaySec=2h
EOF
```

## Retention

### Local

By default, the last **7** backups are kept. Older ones are automatically
removed after each new backup. Change with `--keep`:

```bash
sudo bash backup/backup-site.sh --domain=example.com --keep=30
```

### S3

Local retention does **not** affect S3. Use the S3 provider's lifecycle
policies to expire old remote backups:

```bash
# Example for AWS S3: expire after 90 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket litesoup-backups \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "expire-90d",
      "Status": "Enabled",
      "Prefix": "backups/",
      "Expiration": { "Days": 90 }
    }]
  }'
```

## Exclusion patterns

### Per-backup exclusions

```bash
# Skip specific directories (repeatable)
sudo bash backup/backup-site.sh --domain=example.com --exclude=cache/ --exclude=.git

# Skip large upload directories
sudo bash backup/backup-site.sh --domain=example.com --exclude=uploads/backwpup/
```

### Global exclusion file

Create `backup/backup-exclude-global.txt` in the litesoup repo to apply
exclusions to all sites. One pattern per line. Lines starting with `#` and
blank lines are ignored:

```
# Global backup exclusions for all sites
cache/
.git/
node_modules/
```

## S3-compatible providers

litesoup uses `s3cmd` which works with any S3-compatible API:

| Provider | Endpoint |
|----------|----------|
| AWS S3 | `https://s3.<region>.amazonaws.com` |
| IDrive e2 | `https://e2.idy.idrivee2.com` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` |
| DigitalOcean Spaces | `https://<region>.digitaloceanspaces.com` |
| Wasabi | `https://s3.<region>.wasabisys.com` |
| MinIO (self-hosted) | `https://minio.example.com` |

## Security notes

- Backup directories are owned by `root:root` with mode `0700` — site users
  cannot read each other's backups
- S3 credentials are stored in `/etc/litesoup/backup-s3.conf` (mode `0600`)
- Database dumps are created via `wp db export`, inheriting WordPress's
  database credentials (no hardcoded passwords), and compressed with zstd
- Restore runs as root but drops to the site user for `wp db import`
- Temp `.s3cfg` files (credential-bearing) are cleaned up after each S3
  operation; stale files older than 1 hour are purged automatically

## Via litesoup-cli

If litesoup-cli is installed, use:

```bash
litesoup backup site --domain=example.com
litesoup backup restore --domain=example.com
litesoup backup list --domain=example.com
litesoup backup configure --email=ops@example.com
```

## Via `litesoup stack install`

The backup scripts are automatically installed to `/usr/lib/litesoup/backup/`
during `install-stack.sh` stage 19. No separate install is needed.
