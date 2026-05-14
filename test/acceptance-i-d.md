# Plan I.D Acceptance — `test/acceptance-i-d-run.sh`

End-to-end script for v0.3.0 TLS / Let's Encrypt. Spins up a systemd-enabled Ubuntu 24.04 container (`geerlingguy/docker-ubuntu2404-ansible`), installs the stack with `--php-versions=8.2,8.4` (which now includes certbot + mod_http2 in stage 6), provisions two sites at the two PHP versions (alpha with `--tls=self-signed`, beta with `--tls=none` for back-compat), validates HTTPS + HTTP→HTTPS 301 + the back-compat HTTP-only path, then upgrades beta retroactively via `site-set-tls --tls=self-signed` and re-validates.

## How to run

```bash
./test/acceptance-i-d-run.sh        # writes test/acceptance-i-d.log (gitignored)
```

Cleans up the prior `litesoup-id` container automatically. Leaves the container running on success for inspection — `docker rm -f litesoup-id` to clean up.

## Expected output (success path)

```
[1] pull + start geerlingguy/docker-ubuntu2404-ansible:latest
  systemd ready (try N)
[2] install-stack --php-versions=8.2,8.4 (includes certbot stage 6)
  ...
[3] verify FPM services + disabled default pools + certbot + http2
  www.conf.disabled OK for 8.2
  www.conf.disabled OK for 8.4
  litesoup-php8.2 socket OK
  certbot installed
  certbot.timer enabled
  apache mod_http2 enabled
[4a] site-create alpha.test --php=8.2 --tls=self-signed
[4b] site-create beta.test --php=8.4 --tls=none (back-compat path)
[4c] confirm beta socket + alpha self-signed cert artifacts
  litesoup-php8.4 socket OK
  alpha self-signed fullchain OK
  alpha self-signed privkey OK
  privkey.pem mode 0600 OK
  alpha vhost enabled
  alpha :443 block present
  beta :443 block absent (correct, tls=none)
[5a] curl info.php — confirm distinct PHP versions
  alpha.test (HTTPS) reports: PHP Version => 8.2
  beta.test  (HTTP)  reports: PHP Version => 8.4
  PASS — versions distinct and correct
[5b] curl https://alpha.test/wp-admin/install.php (self-signed, expect 200)
  alpha HTTPS install screen: HTTP 200
[5c] curl http://alpha.test (TLS active, expect 301 redirect to https)
  status:   HTTP/1.1 301 Moved Permanently
  Location: https://alpha.test/wp-admin/install.php
[5d] curl http://beta.test (back-compat, expect 200 not 301)
  beta HTTP install screen: HTTP 200
[6] curl WordPress install screen
  alpha WP install screen OK (HTTPS)
  beta  WP install screen OK (HTTP)
[7] site-set-tls beta.test --tls=self-signed (retroactive TLS upgrade)
[7b] confirm beta now has HTTPS + cert artifacts + 301 redirect
  beta self-signed fullchain OK
  beta :443 block present after upgrade
  beta HTTPS install screen: HTTP 200
  beta HTTP redirect: HTTP/1.1 301 Moved Permanently
[8] idempotency: re-run install-stack --php-versions=8.2,8.4
  ...
ACCEPTANCE: PASS
```

## Live Let's Encrypt acceptance (separate, requires public hostname)

The harness above only validates `--tls=self-signed` because Docker / Multipass containers don't have public DNS pointing at them. To validate the real LE flow, run on a real Ubuntu 24.04 host with a public hostname pointing at it:

```bash
# On the target host (root or sudo):
git clone https://github.com/litesoup/litesoup.git
cd litesoup
sudo bash install/install-stack.sh --php-versions=8.2

# Use the host's actual public hostname here:
sudo bash site/site-create.sh \
  --domain=test.example.com \
  --php=8.2 \
  --tls=letsencrypt \
  --email=ops@example.com

# Verify:
curl -I https://test.example.com/wp-admin/install.php  # expect 200 with valid LE cert
curl -I http://test.example.com/wp-admin/install.php   # expect 301 -> https
sudo certbot certificates                              # confirms LE cert is registered
sudo systemctl status certbot.timer                    # auto-renewal armed
```

For codetot-internal: `sg10.codetot.org` is a real public hostname suitable for this. After Plan I.D ships, that's the natural live-LE acceptance target.

## Run history

### 2026-05-02 — local container run

Pending. The harness above is committed but has not been executed yet on macOS Docker Desktop (the Plan I.B runs there hit network-layer issues unrelated to the script — see `test/acceptance-i-b.md` for context). For the live LE flow we need a real Ubuntu host anyway.
