# litesoup

> An opinionated, lean WordPress server stack and fleet dashboard.

Litesoup is a one-line bash installer that turns a fresh Ubuntu server into a hardened WordPress host, paired with a single-binary Go dashboard for managing one or many servers and a scoped tenant portal for end users.

## Components

- **Stack installer** — Apache (mpm_event) + PHP-FPM + MariaDB + Redis + Memcached + Let's Encrypt + wp-cli, hardened by default
- **Site helpers** — `site-create`, `site-delete`, backup, migrate, malware scan, vulnerability check
- **Fleet dashboard** — single Go binary with two roles: admin (full fleet) and client (assigned sites only)

## Status

**Pre-release (v0.0.x).** Active development. Not yet recommended for production. Releases will be signed with [Sigstore](https://www.sigstore.dev/) keyless signing once v0.1.0 lands.

## Requirements

- Ubuntu 24.04 LTS (x86_64)
- Root or sudo access
- A domain pointing at the server (for SSL)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
