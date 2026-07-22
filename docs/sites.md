---
layout: default
title: Sites
nav_order: 3
---

# Manage WordPress sites

## Overview

Every site lives at `/home/<user>/webapps/<domain>/` and is owned by its
system user (`<user>:<user>`, never `www-data`). PHP runs in a per-user
PHP-FPM pool as that same user, so one site's PHP process can't read
another site's files. The `site-*` scripts in `site/` are the
operator-facing wrappers around create, delete, switch PHP version,
resize the FPM pool, and add or change TLS.

All scripts must be run with `sudo`. All accept `--dry-run` to preview
the actions without touching the system.

## Create a site

The workhorse. Provisions docroot, MariaDB database + user, PHP-FPM pool,
Apache vhost, and downloads WordPress core.

Simple HTTP site (default user `litesoup`, default PHP, no TLS):

```bash
sudo bash site/site-create.sh --domain=example.test
```

HTTPS via Let's Encrypt (domain must already point at this server):

```bash
sudo bash site/site-create.sh \
  --domain=example.com \
  --tls=letsencrypt \
  --email=admin@example.com
```

Self-signed cert for local development:

```bash
sudo bash site/site-create.sh \
  --domain=dev.local \
  --tls=self-signed
```

Pick a specific PHP version:

```bash
sudo bash site/site-create.sh \
  --domain=legacy.example.com \
  --php=8.1
```

Custom user for per-client isolation (the user is created if missing):

```bash
sudo bash site/site-create.sh \
  --domain=clientco.com \
  --user=clientco \
  --tls=letsencrypt \
  --email=ops@example.com
```

When the script finishes it prints the install URL, e.g.
`http://example.test/wp-admin/install.php`.

## Import an existing site

Use `site-import.sh` when you have a WordPress site already running elsewhere
and want to migrate it to this server. The script accepts a git repo URL and/or
a database dump file.

```bash
# Import from a git repo (WordPress files)
sudo bash site/site-import.sh --domain=example.com --git-repo=git@github.com:org/repo.git

# Import from a git repo + SQL dump
sudo bash site/site-import.sh --domain=example.com --git-repo=git@github.com:org/repo.git --db-dump=./example.sql

# Import a flat docroot (no git) from a local archive
sudo bash site/site-import.sh --domain=example.com --archive=/path/to/site.tar.gz
```

The script creates the system user, MariaDB database + user, PHP-FPM pool,
Apache vhost, and imports your content. Run `site-import.sh --help` for all
available flags.

## Switch PHP version

Use `site-set-php.sh` when you want to test a plugin against a different
PHP version, or when an existing PHP version reaches end of life and you
need to roll a site forward.

```bash
sudo bash site/site-set-php.sh --domain=example.com --php=8.3
```

The script reads the site's owner, docroot, and TLS mode from the
existing Apache vhost, ensures a per-user pool exists for the new
version (creating it if this is the first site on that owner+version),
re-renders the vhost so its FPM handler points at the new socket, then
runs `apachectl configtest` and reloads Apache. It does not touch the
database, docroot, or `wp-config.php`.

The pool tier of the old version carries over to the new pool, so a
production-sized pool stays production-sized after the switch.

## Resize PHP-FPM pool tier

Pool tier controls how many PHP worker processes a pool can spawn. Tier
is **per user + per PHP version**, not per site, so all sites that share
a pool share the tier.

```bash
sudo bash site/site-set-tier.sh \
  --user=litesoup --version=8.3 --tier=medium
```

| Tier   | Children | Process manager | Use it for                       |
|--------|----------|-----------------|----------------------------------|
| small  | 5        | ondemand        | low-traffic sites, dev, staging  |
| medium | 20       | dynamic         | normal production sites          |
| large  | 50       | dynamic         | high-traffic production sites    |

`small` is the default and the cheapest at idle (`ondemand` lets workers
exit when no requests arrive). `medium` and `large` use `dynamic` so a
warm pool of workers is always ready.

Re-running with the current tier is a no-op.

## Add or change TLS

If you created a site as HTTP-only and now want HTTPS, use
`site-set-tls.sh`. No DB, docroot, or WordPress changes — just certs
and the vhost.

Add Let's Encrypt to an existing HTTP site:

```bash
sudo bash site/site-set-tls.sh \
  --domain=example.com \
  --tls=letsencrypt \
  --email=admin@example.com
```

Switch to a self-signed cert:

```bash
sudo bash site/site-set-tls.sh \
  --domain=dev.local \
  --tls=self-signed
```

Drop TLS back to HTTP-only:

```bash
sudo bash site/site-set-tls.sh --domain=example.com --tls=none
```

## Set up Git webhook auto-deploy

Use `site-set-webhook.sh` to configure automatic deployments from a Git
repository. Every time you push to the configured branch, the server pulls
the latest code automatically.

```bash
sudo bash site/site-set-webhook.sh --domain=example.com
```

The script configures a webhook endpoint and creates a systemd service that
runs `git pull` on the docroot when triggered. The webhook URL is printed
after setup — add it to your Git provider (GitHub, GitLab, etc.).

## Delete a site

```bash
sudo bash site/site-delete.sh --domain=example.com
```

This removes the docroot, the Apache vhost, and revokes the
Let's Encrypt cert (if any). It keeps the system user and the per-user
FPM pool — other sites may still be using them.

> **Heads up:** `site-delete.sh` does **not** drop the database by
> default. The script logs a warning telling you the DB was kept. Pass
> `--purge-db` to drop the database and DB user as well:
>
> ```bash
> sudo bash site/site-delete.sh --domain=example.com --purge-db
> ```

If you used a non-default user, pass it through:

```bash
sudo bash site/site-delete.sh --domain=clientco.com --user=clientco --purge-db
```

## Idempotency

Every `site-*` script is safe to re-run. Re-running `site-create.sh`
against an existing site heals a half-installed site without rotating
the WP cache salt or the DB password. Re-running `site-set-php.sh`,
`site-set-tier.sh`, or `site-set-tls.sh` with the current value is a
no-op. Use `--dry-run` on any script to see exactly what would change.
