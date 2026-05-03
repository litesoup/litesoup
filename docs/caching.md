---
layout: default
title: Caching
nav_order: 6
---

# Caching

litesoup ships caching **infrastructure** — Redis and Memcached are
installed, hardened, and listening on localhost — but does **not**
configure WordPress-side caching for you. Pick the WP plugin that
fits your workflow; the stack makes sure it works.

This is a deliberate split:

- **Server-level page cache + WP plugin page cache double-cache**
  produces stale-content bugs that are painful to diagnose at scale.
  We don't ship Apache `mod_cache_disk` or any FastCGI page cache.
- **Object cache and page cache plugins** can't install Redis
  themselves. So we install Redis (with safe defaults) and inject the
  connection details into every site's `wp-config.php` — your plugin
  picks them up the moment you activate it.

## What's installed

| Service       | Address           | Auth                 | Configured by                |
|---------------|-------------------|----------------------|------------------------------|
| `redis-server`| `127.0.0.1:6379`  | `requirepass` set    | `install/lib/redis.sh`       |
| `memcached`   | `127.0.0.1:11211` | none (loopback only) | `install/lib/memcached.sh`   |

Both are bound to loopback only (no external network exposure) and
enabled at boot via systemd.

### Redis configuration (managed)

`install-stack.sh` writes `/etc/redis/litesoup.conf` and adds an
`include` directive at the end of `/etc/redis/redis.conf`. Re-running
`install-stack.sh` is idempotent — the password is generated once and
never rotated automatically.

```
bind 127.0.0.1 -::1
protected-mode yes
requirepass <32-char generated>
maxmemory <tier-sized>
maxmemory-policy allkeys-lru
```

`maxmemory` is sized from total system RAM at install time:

| RAM            | Tier    | `maxmemory` |
|----------------|---------|-------------|
| < 2 GB         | small   | `128mb`     |
| 2 GB – 8 GB    | medium  | `512mb`     |
| ≥ 8 GB         | large   | `2gb`       |

Override with `--redis-maxmemory=SIZE` on `install-stack.sh`:

```bash
sudo bash install/install-stack.sh --redis-maxmemory=1gb
```

The Redis password lives at `/etc/litesoup/redis.env` (`0640 root:root`):

```
REDIS_PASSWORD=<32-char alnum>
```

### Memcached configuration (managed)

`install-stack.sh` appends a managed block to `/etc/memcached.conf`:

```
# >>> litesoup-managed (do not edit) >>>
-l 127.0.0.1
-U 0
# <<< litesoup-managed <<<
```

`-U 0` disables the UDP listener (only TCP is needed by WP plugins,
and UDP memcached has been a recurring amplification-attack vector).

## What `site-create.sh` injects

Every new site gets these constants written into `wp-config.php`:

```php
define('WP_CACHE_KEY_SALT',   '<64-char hex, unique per site>');
define('WP_REDIS_HOST',       '127.0.0.1');
define('WP_REDIS_PORT',       '6379');
define('WP_REDIS_PASSWORD',   '<from /etc/litesoup/redis.env>');
define('WP_REDIS_DATABASE',   '0');
```

Injection is **idempotent** — re-running `site-create.sh` against an
existing site does not rotate the salt or touch the Redis settings
(rotating the salt would invalidate any live object cache).

The `WP_CACHE_KEY_SALT` constant is the multi-tenant footgun mitigation:
without a unique salt per site, two WordPress installs sharing one Redis
instance can read each other's cached entries. Plugins that respect the
constant (Redis Object Cache does — it uses the salt as its default key
prefix) are safe by default.

## Recommended plugins

You install these yourself; the stack does not auto-install any plugin.

### Object cache: Redis Object Cache

The "wire it up and it just works" path:

```bash
cd /home/litesoup/webapps/<your-domain>
sudo -H -u litesoup wp plugin install redis-cache --activate
sudo -H -u litesoup wp redis enable
sudo -H -u litesoup wp redis status
```

The plugin reads `WP_REDIS_HOST/PORT/PASSWORD/DATABASE` and
`WP_CACHE_KEY_SALT` from `wp-config.php` automatically.

### Page cache

Pick one. None of these need Redis specifically — they use the
filesystem or your chosen backend.

| Plugin              | Cost  | Install                                              |
|---------------------|-------|------------------------------------------------------|
| LiteSpeed Cache     | free  | `wp plugin install litespeed-cache --activate`       |
| W3 Total Cache      | free  | `wp plugin install w3-total-cache --activate`        |
| WP Super Cache      | free  | `wp plugin install wp-super-cache --activate`        |
| WP Rocket           | paid  | upload via `wp plugin install /path/to/zip --activate` |

LiteSpeed Cache can also handle the object-cache layer via its own UI
if you'd rather avoid running two cache plugins.

## Memcached caveat

Most WordPress Memcached plugins do not implement per-site key
prefixing well. **Prefer Redis when running more than one site on a
single instance.** On a single-tenant box, if you want the slightly
lower memory footprint of Memcached, use the
[Memcached Object Cache](https://wordpress.org/plugins/memcached/)
drop-in. You'll need to manage key isolation yourself if you ever
add a second site.

## Verifying it works

```bash
# Services up
systemctl status redis-server memcached

# Redis AUTH+PING (read password from the env file)
sudo redis-cli -a "$(sudo grep ^REDIS_PASSWORD /etc/litesoup/redis.env | cut -d= -f2)" \
     --no-auth-warning ping

# Watch live Redis traffic from WordPress
sudo redis-cli -a "$(sudo grep ^REDIS_PASSWORD /etc/litesoup/redis.env | cut -d= -f2)" \
     --no-auth-warning monitor

# Memcached version probe
echo -e 'version\r\nquit\r\n' | nc 127.0.0.1 11211

# Confirm WP_CACHE_KEY_SALT is unique per site
for d in /home/*/webapps/*/wp-config.php; do
  domain="$(basename "$(dirname "${d}")")"
  user="$(stat -c '%U' "${d}")"
  salt="$(sudo -H -u "${user}" wp --path="$(dirname "${d}")" config get WP_CACHE_KEY_SALT --type=constant 2>/dev/null || true)"
  printf '%-40s %s\n' "${domain}" "${salt:0:8}..."
done
```

## Migrating sites created before v0.5.0

Sites created with `litesoup` < v0.5.0 lack the cache constants. Add
them per site:

```bash
DOMAIN=example.com
USER=litesoup
WP=/home/${USER}/webapps/${DOMAIN}

# Read the Redis password (root-only)
PW="$(sudo grep ^REDIS_PASSWORD /etc/litesoup/redis.env | cut -d= -f2)"
SALT="$(openssl rand -hex 32)"

for kv in \
  "WP_CACHE_KEY_SALT=${SALT}" \
  "WP_REDIS_HOST=127.0.0.1" \
  "WP_REDIS_PORT=6379" \
  "WP_REDIS_PASSWORD=${PW}" \
  "WP_REDIS_DATABASE=0"
do
  k="${kv%%=*}"; v="${kv#*=}"
  sudo -H -u "${USER}" wp --path="${WP}" config has "${k}" --type=constant >/dev/null 2>&1 && continue
  sudo -H -u "${USER}" wp --path="${WP}" config set "${k}" "${v}" --type=constant --add
done
```

There is no automatic migration script — run the snippet above per
site (or wrap it in a loop over `/home/*/webapps/*`).

## What we don't do (and why)

- **Apache `mod_cache_disk` / FastCGI page cache.** Server-level page
  cache layered on top of a plugin page cache produces stale-content
  bugs that are hard to diagnose under load. If you want zero-PHP page
  caching, configure it in your page-cache plugin (LiteSpeed Cache and
  W3TC both have full-page cache modes).
- **Auto-install of `redis-object-cache` or any other plugin.** The
  user picks the plugin. We make sure it works.
- **`site-set-cache` / `site-cache-purge` scripts.** Cache invalidation
  belongs in WordPress (where you have access to `save_post`,
  `comment_post`, theme/plugin update hooks) — your plugin handles it.
- **Automatic `WP_CACHE_KEY_SALT` rotation.** Rotation invalidates every
  cached entry instantly. Your plugin should never re-issue the salt
  after a site is in production. We generate it once, at site creation,
  and leave it alone.
