# Plan I.C Acceptance — `test/acceptance-i-c-run.sh`

End-to-end script for v0.4.0 site-set-php + per-tier FPM pool sizing. Spins up a systemd-enabled Ubuntu 24.04 container, installs the stack with `--php-versions=8.2,8.4`, validates `--tier=medium` produces the expected `pm.*` lines, downgrades a site's PHP version with `site-set-php`, retunes a pool with `site-set-tier --tier=large`, and confirms the same-tier re-run is a no-op.

## How to run

```bash
./test/acceptance-i-c-run.sh        # writes test/acceptance-i-c.log (gitignored)
```

Cleans up the prior `litesoup-ic` container automatically. Leaves the container running on success for inspection — `docker rm -f litesoup-ic` to clean up.

## Expected output (success path)

```
[1] pull + start geerlingguy/docker-ubuntu2404-ansible:latest
  systemd ready (try N)
[2] install-stack --php-versions=8.2,8.4 (includes certbot stage 6)
  ...
[3] verify FPM services + default litesoup pool starts at small (max_children=5)
  default pool small OK (max_children=5)
[4a] site-create alpha.test --php=8.2 --tier=medium --tls=self-signed
[4b] site-create beta.test --php=8.4 --tier=small (back-compat default)
[4c] verify alpha pool is medium (pm.max_children=20, pm=dynamic)
  pm = dynamic OK
  max_children = 20 OK
  max_requests = 1000 OK
[4d] verify beta pool is small (pm.max_children=5, pm=ondemand)
  pm = ondemand OK
  max_children = 5 OK
[5] site-set-php beta.test --php=8.2 (downgrade 8.4 -> 8.2)
[5b] verify beta now serves on PHP 8.2 (vhost rewritten + pool present)
  beta.test now reports: PHP Version => 8.2
  vhost socket rewritten to php8.2 OK
[6] site-set-tier --user=litesoup --version=8.2 --tier=large
[6b] verify pool is now large (pm.max_children=50, max_requests=2000)
  max_children = 50 OK
  max_requests = 2000 OK
[7] idempotency: re-run site-set-tier with same tier (large)
  ...already configured (tier=large)
  no-op detected OK
ACCEPTANCE: PASS
```

## Run history

### 2026-05-02 — local container run

Pending. Per user direction acceptance is deferred to a separate test pass after the plan stack lands. Same caveat as `acceptance-i-d.md`: macOS Docker Desktop has historically had network issues with this harness; CI runners and any real Ubuntu host run it cleanly.

For codetot-internal: `sg10.codetot.org` is a real public hostname suitable for end-to-end including the `--tls=letsencrypt` flow that lands in Plan I.D.
