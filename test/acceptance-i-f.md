# Plan I.F Acceptance — `test/acceptance-i-f-run.sh`

End-to-end script for v0.5.0 Plan I.F (Redis + Memcached infrastructure +
`WP_CACHE_KEY_SALT` injection). Spins up a systemd-enabled Ubuntu 24.04
container, runs `install-stack.sh`, validates that:

- `redis-server` and `memcached` are running, configured, and bound to
  loopback only (no external exposure).
- Redis password is generated, persisted at `/etc/litesoup/redis.env`
  (`0640 root:root`), and `AUTH+PING` works.
- Redis `maxmemory` is set per RAM tier; `--redis-maxmemory=` override
  flows through to the live Redis `CONFIG GET maxmemory`.
- Memcached UDP is OFF (`-U 0`).
- Two newly-created sites get distinct 64-char-hex `WP_CACHE_KEY_SALT`
  values, plus `WP_REDIS_HOST/PORT/PASSWORD/DATABASE` constants matching
  what install-stack wrote.
- Re-running `site-create.sh` against an existing site does NOT rotate
  the salt (would invalidate any live object cache).
- Re-running `install-stack.sh` does NOT rotate the Redis password,
  duplicate the `include` directive in `redis.conf`, or churn the
  managed block in `memcached.conf`.

## How to run

```bash
./test/acceptance-i-f-run.sh        # writes test/acceptance-i-f.log (gitignored)
```

Cleans up the prior `litesoup-if` container automatically. Leaves the
container running on success for inspection — `docker rm -f litesoup-if`
to clean up.

## Expected output (success path)

```
[1] pull + start geerlingguy/docker-ubuntu2404-ansible:latest
  systemd ready (try N)
[2] install-stack (default flags -- redis tier auto-detected from RAM)
  ...
  redis: detected NNNNMB RAM -> tier=medium maxmemory=512mb
  redis: AUTH+PING ok
  memcached: TCP probe ok on 127.0.0.1:11211
[3] verify redis + memcached running, configs correct
  redis-server active
  memcached active
  /etc/litesoup/redis.env present
  redis.env mode/owner OK (640 root:root)
  REDIS_PASSWORD shape OK (32 alnum)
  /etc/redis/litesoup.conf present
  bind 127.0.0.1 -::1 OK
  protected-mode yes OK
  requirepass set OK
  maxmemory set OK (512mb)
  maxmemory-policy allkeys-lru OK
  include directive in redis.conf OK
  redis bound to loopback only OK
  redis AUTH+PING OK
  memcached managed block present
  memcached -l 127.0.0.1 OK
  memcached -U 0 (UDP off) OK
  memcached bound to loopback only OK
  memcached UDP off OK
[4] site-create alpha-cache.test + beta-cache.test, verify per-site salts
  alpha salt: <64-char hex>
  beta  salt: <different 64-char hex>
  per-site salts distinct + 64-char hex OK
  WP_REDIS_PASSWORD matches /etc/litesoup/redis.env OK
[5] re-run site-create on alpha-cache.test, verify salt NOT rotated
  salt unchanged on site-create re-run OK
[6] re-run install-stack, verify redis password + configs unchanged
  redis password unchanged on re-run OK
  /etc/redis/litesoup.conf unchanged on re-run OK
  /etc/memcached.conf unchanged on re-run OK
  include directive count = 1 OK
[7] --redis-maxmemory override flows through
  maxmemory now 64mb OK
  redis CONFIG GET maxmemory == 64mb OK
ACCEPTANCE: PASS
```

## Real-Ubuntu acceptance (required per `project_real_acceptance_findings`)

Per `memory/project_real_acceptance_findings.md`, container-only acceptance
is not sufficient — bats+Docker have repeatedly missed bugs that only
surface on a real Ubuntu host. Before tagging v0.5.0, run the same harness
against `sg10.codetot.org` (or any clean Ubuntu 24.04 VPS / Multipass VM):

```bash
# On the target host (root or sudo), from a clean checkout:
git clone https://github.com/codetot-web/litesoup.git
cd litesoup
sudo bash install/install-stack.sh

# Verify Redis + Memcached posture
systemctl is-active redis-server memcached
sudo cat /etc/redis/litesoup.conf
sudo redis-cli -a "$(sudo grep ^REDIS_PASSWORD /etc/litesoup/redis.env | cut -d= -f2)" \
     --no-auth-warning CONFIG GET maxmemory

# Provision two sites on a real public hostname
sudo bash site/site-create.sh --domain=cache-a.example.com --tls=letsencrypt --email=ops@example.com
sudo bash site/site-create.sh --domain=cache-b.example.com --tls=letsencrypt --email=ops@example.com

# Inspect the injected constants
sudo -H -u litesoup wp --path=/home/litesoup/webapps/cache-a.example.com config list --type=constant | grep -E 'WP_CACHE_KEY_SALT|WP_REDIS_'
sudo -H -u litesoup wp --path=/home/litesoup/webapps/cache-b.example.com config get WP_CACHE_KEY_SALT --type=constant

# Optional: install Redis Object Cache as a smoke test (NOT required for the
# acceptance to pass -- this is what a user would do).
cd /home/litesoup/webapps/cache-a.example.com
sudo -H -u litesoup wp plugin install redis-cache --activate
sudo -H -u litesoup wp redis enable
sudo -H -u litesoup wp redis status
```

For codetot-internal: `sg10.codetot.org` is the canonical real-Ubuntu
acceptance target (see existing `acceptance-i-c.md` / `acceptance-i-d.md`
for the same workflow).

## Run history

### 2026-05-02 — local container run

Pending. The harness above is committed but has not yet been executed
inside this PR cycle. Will be run before the v0.5.0 release commit and
the log committed to `test/acceptance-i-f.log` (gitignored).

### 2026-05-02 — sg10 real-Ubuntu run

Pending. Required before v0.5.0 ships per
`memory/project_real_acceptance_findings.md`.
