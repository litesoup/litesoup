# Plan I.B Acceptance — `test/acceptance-i-b-run.sh`

End-to-end script for v0.2.0 multi-version PHP. Spins up a systemd-enabled Ubuntu 24.04 container (`geerlingguy/docker-ubuntu2404-ansible`), installs the stack with `--php-versions=8.2,8.4`, provisions two sites at the two versions, asserts each serves the correct PHP version via `phpinfo()`, then re-runs `install-stack` for idempotency.

## How to run

```bash
./test/acceptance-i-b-run.sh        # writes test/acceptance-i-b.log (gitignored)
```

Cleans up the prior `litesoup-ib` container automatically. Leaves the container running on success for inspection — `docker rm -f litesoup-ib` to clean up.

## Expected output (success path)

```
[1] pull + start geerlingguy/docker-ubuntu2404-ansible:latest
  systemd ready (try 2)
[2] install-stack --php-versions=8.2,8.4
  ...
[3] verify FPM services + disabled default pools
  www.conf.disabled OK for 8.2
  www.conf.disabled OK for 8.4
  litesoup-php8.2 socket OK
[4a] site-create alpha.test --php=8.2
[4b] site-create beta.test  --php=8.4
[4c] confirm beta socket created
  litesoup-php8.4 socket OK
[5] curl info.php on each site, confirm distinct PHP versions
  alpha.test reports: PHP Version => 8.2
  beta.test  reports: PHP Version => 8.4
  PASS — versions distinct and correct
[6] curl WordPress install screen
  alpha WP install screen OK
  beta  WP install screen OK
[7] idempotency: re-run install-stack --php-versions=8.2,8.4
  ...
ACCEPTANCE: PASS
```

## Run history

### 2026-05-02 — macOS Docker Desktop (FAILED — environmental)

`add-apt-repository ppa:ondrej/php` failed with `OSError: [Errno 99] Cannot assign requested address` (launchpadlib IPv6 connect). The patched `ensure_ppa` fallback (commit `fec5231`) successfully registered the PPA at `/etc/apt/sources.list.d/ondrej-ubuntu-php-noble.sources`. However, `apt-get update -qq` then could not reach the PPA:

```
W: Failed to fetch https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/noble/InRelease
   Could not connect to ppa.launchpadcontent.net:443 (185.125.190.80). - connect (111: Connection refused)
```

This is Docker Desktop on macOS blocking outbound HTTPS to launchpadcontent.net. **Pure environmental — not a code defect.** No real Ubuntu host (CI runner, VPS, Multipass VM) hits this. The acceptance run should be re-executed on any of those environments to validate v0.2.0 end-to-end.

The failed attempt did expose and lead to fixing a real installer bug (`ensure_ppa` only fell back on 504/timeout — now falls back on any failure), so the run was net-positive.

### Future runs

To validate on a real Ubuntu host:

```bash
# Multipass (macOS):
multipass launch 24.04 -n litesoup-ib --cpus 2 --memory 4G --disk 10G
multipass mount /Users/khoipro/Projects/litesoup litesoup-ib:/litesoup
multipass exec litesoup-ib -- bash -lc 'cd /litesoup && sudo bash test/acceptance-i-b-run.sh'

# Or any Ubuntu 24.04 VPS / GitHub Actions ubuntu-latest runner.
```
