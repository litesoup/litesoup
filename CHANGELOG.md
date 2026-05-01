# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Plan I.A (MVP WordPress stack installer)

- `install/install-stack.sh` — one-command installer for Ubuntu 24.04
- `install/lib/{common,distro,apt,users,apache,php,mariadb,wp_cli}.sh` — modular library set
- `templates/apache/vhost.conf.tmpl` — per-site Apache vhost
- `templates/php/pool.conf.tmpl` — hardened per-user PHP-FPM pool (open_basedir, disable_functions, expose_php=off)
- `site/site-create.sh --domain=<d> [--user=<u>]` — provisions DB + system user (if needed) + per-user FPM pool + docroot at `/home/<user>/webapps/<domain>/` + WordPress core
- `site/site-delete.sh --domain=<d> [--user=<u>] [--purge-db]` — removes vhost + docroot, optionally drops DB; keeps user + pool intact
- `test/bats/` — bats-core unit tests (common, distro, apt, users, smoke)
- `test/docker/` — systemd-enabled Ubuntu 24.04 container for integration testing
- `test/integration/{01_install_stack,02_site_create,03_site_delete}.sh` — end-to-end acceptance
- `.github/workflows/ci.yml` — shellcheck + bats + Docker integration jobs

### Initial scaffold

- Apache 2.0 license, README, .gitignore.
