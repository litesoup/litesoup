---
layout: default
title: Audit
nav_order: 5
---

# Audit your stack

## Overview

The four scripts under `audit/` are read-only checks. None of them mutate
state — no config rewrites, no service restarts, no package installs. They
inspect the running system, print a summary, and exit with a status code you
can wire into cron, monitoring, or a pre-deploy gate. Every script accepts
`--help` and can be run standalone:

```
sudo bash audit/audit-wp-health.sh --help
```

If you only remember one thing: read the table at the bottom of each text
report. That's the answer.

---

## audit-wp-health.sh

Probes WordPress sites for core/plugin updates, DB reachability, file
permissions, disk usage, error log size, and TLS expiry.

**Useful flags**

- `--domain=example.com` — audit just one site instead of every site under `/home/*/webapps/`
- `--user=alice` — narrow to one system user (rare; only when two users own a same-named domain)
- `--dry-run` — list discovered sites without probing them

**Try it**

```bash
sudo bash audit/audit-wp-health.sh --domain=example.com
```

You get one block per site with seven lines (core, plugins, db, disk, perms,
tls, errlog), each prefixed `OK:`, `WARN:`, or `CRIT:`. If `tls` says
`WARN: TLS expires in 12d`, you have your weekend renewal task. If `perms`
says `wp-config.php mode 644 is world-readable`, fix it before lunch — that
file holds the DB password.

**Exit codes**

- `0` — every site healthy
- `1` — at least one site raised warnings (outdated plugin, big log, cert in 30-day window)
- `2` — at least one critical (DB unreachable, cert expired, wp-cli missing) or script error

---

## audit-system-metrics.sh

Snapshots load, memory, per-mount disk, network sockets, and the live state
of Apache / PHP-FPM / MariaDB / Redis. Designed to run cheaply and produce
either a glanceable table or one JSON object.

**Useful flags**

- `--format=text|json` — pick the renderer (default `text`)
- `--watch=N` — refresh every N seconds; `Ctrl-C` to stop. `text` mode clears the screen each tick.
- `--dry-run` — print which sources it *would* read, without touching them

**Try it**

```bash
sudo bash audit/audit-system-metrics.sh --watch=5
```

That's the "something's slow, watch it live" command. The `[Disk]` section
flags any mount over 85% used with `HIGH`. The `[PHP-FPM]` section shows
`active`/`idle` workers per pool — if `idle=0` everywhere, your fleet is
saturated and pages are queueing. The `[MariaDB]` line surfaces
`threads_connected` and `slow_queries_last_hour`.

**Exit code**

This script always exits `0` after a successful run — it's a *reporter*, not
a pass/fail check. Use `audit-performance.sh` if you want a non-zero exit
when something's outside recommended bands.

---

## audit-wp-vulnerabilities.sh

Enumerates installed plugins, themes, and (optionally) WordPress core via
wp-cli, then cross-references each against the free
[wpvulnerability.net](https://www.wpvulnerability.net) API. No API key
required.

**Useful flags**

- `--domain=example.com` — scan only one site
- `--format=text|json` — JSON for log shippers, text for humans
- `--plugins-only` / `--themes-only` — narrow scope
- `--include-core` — also check the WordPress core version (off by default)
- `--dry-run` — enumerate components but skip outbound API calls (safe for offline CI)

**Try it**

```bash
sudo bash audit/audit-wp-vulnerabilities.sh --domain=example.com --include-core
```

You get a one-line summary like `found 3 vulnerabilities (critical=1,
high=2)` followed by indented blocks with the CVE id, CVSS score, and the
component that's exposed. The `note: no fix available upstream` line means
no patched version exists — your only options are removal, isolation, or
WAF rules.

**Exit codes**

- `0` — no known vulnerabilities matched
- `1` — at least one matched (any severity)
- `64` — bad arguments
- `65` — no WordPress sites found

---

## audit-performance.sh

Compares your live Apache, PHP-FPM, OPcache, MariaDB, and Redis settings
against the recommended values for the server's RAM tier
(`small` < 2 GiB, `medium` 2–8 GiB, `large` >= 8 GiB). Same tier mapping the
installer uses, so you can tell when a host has drifted off-spec.

**Useful flags**

- `--service=apache|php-fpm|opcache|mariadb|redis|all` — limit to one subsystem (default `all`)
- `--format=text|json`
- `--dry-run` — show what it would query

**Try it**

```bash
sudo bash audit/audit-performance.sh --service=opcache
```

The output is a table: `Service | Tunable | Current | Recommended | Stat |
Note`. `Stat` is `OK`, `WARN` (current is more than 2x or less than 0.5x the
recommended value), or `CRIT`. The most common `CRIT` you'll see is
`opcache.validate_timestamps=1` in production — that re-stats every PHP
include on every request. Fix it and the audit goes green.

**Exit codes**

- `0` — every checked tunable OK
- `1` — at least one WARN
- `2` — at least one CRIT (e.g. `validate_timestamps=1`, redis unbounded, mariadb unreachable)

---

## Common workflows

**Quick site health check** — what most operators run first thing:

```bash
sudo bash audit/audit-wp-health.sh --domain=example.com
```

**Pre-upgrade vuln scan** — run before bumping plugin versions or pushing
new code so you know which CVEs the deploy clears:

```bash
sudo bash audit/audit-wp-vulnerabilities.sh
```

**Find why the server's slow** — start with a live dashboard, then drill
into config drift if the metrics look weird:

```bash
sudo bash audit/audit-system-metrics.sh --watch=5
# (Ctrl-C, then:)
sudo bash audit/audit-performance.sh
```

The first one shows you *what* is over budget right now. The second tells
you *whether the config explains it* — e.g. PHP-FPM `max_children=5` on a
medium-tier box means you're hitting the worker ceiling, not a real load
problem.

---

## JSON output for monitoring

Both `audit-system-metrics.sh --format=json` and `audit-performance.sh
--format=json` emit a single JSON document per run, suitable for cron jobs
and log shippers (Vector, Fluent Bit, Promtail).

Example `/etc/cron.d/litesoup-audit` snippet:

```cron
*/5 * * * * root /usr/local/bin/litesoup-audit/audit-system-metrics.sh --format=json >> /var/log/litesoup/metrics.jsonl
0   * * * * root /usr/local/bin/litesoup-audit/audit-performance.sh    --format=json >> /var/log/litesoup/perf.jsonl
```

That's metrics every 5 minutes and a config-drift check every hour. Point
your shipper at `/var/log/litesoup/*.jsonl` and you have a free monitoring
pipeline. The performance script's exit code (0/1/2) also means you can wrap
it in any alerting that watches process exits — e.g. `systemd` `OnFailure=`
or a simple `|| mail-on-fail` in the cron line.
