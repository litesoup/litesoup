#!/usr/bin/env bash
# site/site-create.sh -- create a WordPress site (Plan I.A: PHP 8.2 only).
# Sites live at /home/<user>/webapps/<domain>/, owned by <user>:<user>.
# PHP runs in the per-user FPM pool (created on demand).
# Usage:
#   sudo bash site-create.sh --domain=example.test [--user=NAME] [--dry-run]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export LITESOUP_REPO_ROOT="${REPO_ROOT}"

# shellcheck source=../install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=../install/lib/apt.sh
source "${REPO_ROOT}/install/lib/apt.sh"
# shellcheck source=../install/lib/users.sh
source "${REPO_ROOT}/install/lib/users.sh"
# shellcheck source=../install/lib/php.sh
source "${REPO_ROOT}/install/lib/php.sh"
# shellcheck source=../install/lib/mariadb.sh
source "${REPO_ROOT}/install/lib/mariadb.sh"
# shellcheck source=../install/lib/certbot.sh
source "${REPO_ROOT}/install/lib/certbot.sh"
# shellcheck source=../install/lib/redis.sh
source "${REPO_ROOT}/install/lib/redis.sh"
# shellcheck source=./_vhost_render.sh
source "${REPO_ROOT}/site/_vhost_render.sh"

# Test hook: bats can replace functions that need real root / a real system by
# sourcing a stub file. Requires TWO explicit env vars to defend against
# attacker-controlled environments where only LITESOUP_TEST_STUBS might be set
# (the second var is intentionally undocumented outside this file -- production
# users never set it).
if [ "${LITESOUP_ALLOW_TEST_STUBS:-0}" = "1" ] \
   && [ -n "${LITESOUP_TEST_STUBS:-}" ] \
   && [ -f "${LITESOUP_TEST_STUBS}" ]; then
  # shellcheck disable=SC1090
  source "${LITESOUP_TEST_STUBS}"
fi

DOMAIN=""
SITE_USER="${DEFAULT_SITE_USER}"
PHP_VERSION="${PHP_VERSION_DEFAULT}"
TLS_MODE="none"
TLS_EMAIL=""
POOL_TIER="medium"
GIT_REPO=""
GIT_BRANCH=""
FRAMEWORK="wordpress"

usage() {
  cat <<'EOF'
litesoup site-create -- provision a WordPress/Laravel site

Usage: sudo bash site-create.sh --domain=DOMAIN [--user=NAME] [--php=X.Y] \
                                [--tier=small|medium|large] \
                                [--tls=letsencrypt|self-signed|none] [--email=ADDR] \
                                [--framework=wordpress|laravel|generic] \
                                [--git-repo=URL] [--git-branch=B] \
                                [--dry-run]
  --user=NAME    System user that will own the docroot and run PHP-FPM
                 (default: litesoup; created if missing)
  --php=X.Y      PHP version for this site (default: PHP_VERSION_DEFAULT)
  --tier=TIER    FPM pool sizing (default: small -- v0.3 back-compat).
                 Tier is per per-user+version pool, not per site -- multiple
                 sites sharing the pool share the tier.
                 small:  5 children,  ondemand (low-traffic + dev)
                 medium: 20 children, dynamic  (production sites)
                 large:  50 children, dynamic  (high-traffic)
  --tls=MODE     TLS mode (default: none -- v0.2 back-compat).
                 letsencrypt: real LE cert via HTTP-01 (requires --email)
                 self-signed: openssl-generated cert at /etc/litesoup/ssl/<d>/
                 none:        HTTP only
  --email=ADDR   Required when --tls=letsencrypt; LE expiry notices go here
  --framework=FRAMEWORK  Site framework (default: wordpress).
                 wordpress: download WP + wp-config setup (existing behaviour)
                 laravel:   composer create-project + artisan key:generate
                 generic:   empty docroot, no framework-specific steps
  --git-repo=URL Clone this Git repo into the docroot instead of downloading
                 a fresh WordPress. Accepts https:// and git@... URLs.
  --git-branch=B Branch/tag/SHA to check out (default: repo default branch)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --domain=*)     DOMAIN="${arg#*=}" ;;
      --user=*)       SITE_USER="${arg#*=}" ;;
      --php=*)        PHP_VERSION="${arg#*=}" ;;
      --tier=*)       POOL_TIER="${arg#*=}" ;;
      --tls=*)        TLS_MODE="${arg#*=}" ;;
      --email=*)      TLS_EMAIL="${arg#*=}" ;;
      --git-repo=*)   GIT_REPO="${arg#*=}" ;;
      --git-branch=*) GIT_BRANCH="${arg#*=}" ;;
      --framework=*)  FRAMEWORK="${arg#*=}" ;;
      --dry-run)      DRY_RUN=1 ;;
      --help|-h)      usage; exit 0 ;;
      *) log_error "unknown argument: ${arg}"; usage; exit 64 ;;
    esac
  done
  export DRY_RUN
  if [ -z "${DOMAIN}" ]; then
    log_error "--domain is required"; usage; exit 64
  fi
  if ! [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "invalid domain: ${DOMAIN}"; exit 64
  fi
  if ! [[ "${SITE_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "invalid user name: ${SITE_USER}"; exit 64
  fi
  validate_php_version "${PHP_VERSION}" \
    || { log_error "unsupported PHP version: ${PHP_VERSION} (allowed: ${SUPPORTED_PHP_VERSIONS[*]})"; exit 64; }
  case "${POOL_TIER}" in
    small|medium|large) ;;
    *) log_error "--tier must be one of: small, medium, large (got '${POOL_TIER}')"; exit 64 ;;
  esac
  case "${TLS_MODE}" in
    letsencrypt|self-signed|none) ;;
    *) log_error "--tls must be one of: letsencrypt, self-signed, none (got '${TLS_MODE}')"; exit 64 ;;
  esac
  if [ "${TLS_MODE}" = "letsencrypt" ] && [ -z "${TLS_EMAIL}" ]; then
    log_error "--tls=letsencrypt requires --email=ADDR"; exit 64
  fi
  if [ -n "${GIT_REPO}" ] && ! [[ "${GIT_REPO}" =~ ^(https?://|git@) ]]; then
    log_error "--git-repo: must start with https://, http://, or git@ (got '${GIT_REPO}')"; exit 64
  fi
  case "${FRAMEWORK}" in
    wordpress|laravel|generic) ;;
    *) log_error "--framework must be one of: wordpress, laravel, generic (got '${FRAMEWORK}')"; exit 64 ;;
  esac
}

# Derive a DB identifier from the domain (mariadb name limit = 64; we stay short).
db_ident_for() {
  local d="$1"
  echo "wp_$(echo "${d}" | tr '.-' '__' | cut -c1-29)"
}

create_database() {
  local db user pw
  db="$(db_ident_for "${DOMAIN}")"
  user="${db}"
  # Generate a 24-char alphanumeric password. Three quirks bundled in here:
  #   1. LC_ALL=C: BSD tr (macOS) emits "Illegal byte sequence" on binary
  #      input under UTF-8 locale; GNU tr is unaffected.
  #   2. set +o pipefail: head -c 24 closes the pipe before tr finishes
  #      reading /dev/urandom, which makes tr exit 141 (SIGPIPE) under the
  #      script's pipefail. Scope the disable to the subshell so the rest of
  #      the script keeps pipefail.
  #   3. Length check: defend against truncation; we want a real 24-char
  #      password, never a passwordless MariaDB user from a silent failure.
  # If wp-config.php from a prior site-create run already exists, reuse its DB
  # password. This heals a half-installed site (e.g., a previous run aborted at
  # apache configtest after the DB user was created -- a re-run with a fresh
  # random pw would mismatch what MySQL stored, and `CREATE USER IF NOT EXISTS`
  # silently keeps the OLD password). Otherwise generate a fresh 24-char pw.
  # Caught on sg10.codetot.org acceptance, fixes litesoup/litesoup#9.
  # Path to the existing wp-config.php is overridable via env so bats tests can
  # exercise the reuse branch end-to-end without writing to /home/...
  local existing_wp_config="${LITESOUP_TEST_EXISTING_WP_CONFIG:-/home/${SITE_USER}/webapps/${DOMAIN}/wp-config.php}"
  pw=""
  if [ -f "${existing_wp_config}" ]; then
    pw="$(awk -F"'" '/define\([[:space:]]*.DB_PASSWORD./{print $4; exit}' "${existing_wp_config}" 2>/dev/null || true)"
    # Defense-in-depth: the parsed pw flows directly into the SQL heredoc below.
    # If a hand-edited wp-config holds a quote/backslash/space/etc., the SQL
    # breaks (or worse, injects). Restrict reuse to alphanumeric pws -- the
    # set our own generator produces. Anything else falls through to fresh
    # generation (and ALTER USER below resyncs MySQL to the new pw).
    if [ -n "${pw}" ] && [ "${#pw}" -ge 16 ] && [[ "${pw}" =~ ^[A-Za-z0-9]+$ ]]; then
      log_info "site-create: reusing existing wp-config DB password (${#pw} chars) for ${user}"
    else
      [ -n "${pw}" ] && log_warn "site-create: ignoring existing wp-config DB password (not alphanumeric or too short); generating fresh"
      pw=""
    fi
  fi
  if [ -z "${pw}" ]; then
    pw="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
    [ "${#pw}" -eq 24 ] || { log_error "site-create: failed to generate 24-char DB password (got '${#pw}' chars)"; exit 1; }
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would create db ${db} and user ${user}"
    DB_NAME="${db}"; DB_USER="${user}"; DB_PASS="dryrun"
    return 0
  fi

  # CREATE USER IF NOT EXISTS doesn't update an existing user's password.
  # ALTER USER does. Combining both is fully idempotent and self-healing:
  # - first run creates + sets pw
  # - re-run reuses the wp-config pw and re-asserts it on MySQL, healing any
  #   drift left by a prior aborted run.
  mariadb_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pw}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  DB_NAME="${db}"; DB_USER="${user}"; DB_PASS="${pw}"
}

create_docroot() {
  local docroot="/home/${SITE_USER}/webapps/${DOMAIN}"
  run_or_dryrun install -d -o "${SITE_USER}" -g "${SITE_USER}" -m 0755 "${docroot}"
  DOCROOT="${docroot}"
  # VHOST_DOCROOT is the DocumentRoot used in Apache vhost.
  # For WordPress it matches the site root; for Laravel/generic it's /public.
  case "${FRAMEWORK}" in
    laravel|generic) VHOST_DOCROOT="${docroot}/public" ;;
    *)               VHOST_DOCROOT="${docroot}" ;;
  esac
  if [ "${DRY_RUN}" != "1" ]; then
    install -d -o "${SITE_USER}" -g "${SITE_USER}" -m 0755 "${VHOST_DOCROOT}"
  fi
}

ensure_htaccess() {
  local htaccess="${DOCROOT}/.htaccess"
  if [ -f "${htaccess}" ]; then
    log_info "site-create: .htaccess already present — skipping"
    return 0
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would write default WordPress .htaccess to ${htaccess}"
    return 0
  fi
  sudo -H -u "${SITE_USER}" tee "${htaccess}" >/dev/null <<'HTACCESS'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS
  log_info "site-create: wrote default WordPress .htaccess"
}

download_wordpress() {
  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would wp core download into ${DOCROOT} as ${SITE_USER}"
    log_info "[DRYRUN] would inject WP_CACHE_KEY_SALT + WP_REDIS_* constants"
    return 0
  fi
  sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" core download --skip-content
  sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" config create \
    --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" \
    --dbhost="localhost" --dbprefix="wp_" --skip-check
  inject_cache_constants
  ensure_htaccess
}

init_submodules() {
  [ -f "${DOCROOT}/.gitmodules" ] || return 0

  local submodule_count
  submodule_count=$(grep -c '^\[submodule' "${DOCROOT}/.gitmodules" 2>/dev/null || echo 0)
  log_info "site-create: found ${submodule_count} submodule(s) — initializing"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would git submodule update --init --recursive in ${DOCROOT}"
    return 0
  fi

  # When GIT_REPO embeds an HTTPS token (https://TOKEN@github.com/...), rewrite
  # git@github.com: → https://TOKEN@github.com/ globally for this user so the
  # same token authenticates private submodules during the clone. The rewrite
  # must be global (not per-repo) because git submodule update spawns fresh
  # git-clone processes that don't inherit the parent repo's local config.
  # Also ensure github.com is in known_hosts so SSH host-key verification
  # doesn't block the clone even when the rewrite is active.
  local token=""
  if [[ "${GIT_REPO}" =~ ^https://([^@]+)@github\.com/ ]]; then
    token="${BASH_REMATCH[1]}"
    sudo -H -u "${SITE_USER}" mkdir -p "/home/${SITE_USER}/.ssh"
    sudo -H -u "${SITE_USER}" sh -c "ssh-keyscan -H github.com >> /home/${SITE_USER}/.ssh/known_hosts 2>/dev/null" || true
    sudo -H -u "${SITE_USER}" git config --global \
      "url.https://${token}@github.com/.insteadOf" "git@github.com:"
  fi

  sudo -H -u "${SITE_USER}" git -C "${DOCROOT}" submodule update --init --recursive \
    || log_warn "site-create: submodule init failed — check repo access or add SSH key for git@github.com"

  # Remove the credential rewrite immediately so it is never persisted.
  if [ -n "${token}" ]; then
    sudo -H -u "${SITE_USER}" git config --global --unset \
      "url.https://${token}@github.com/.insteadOf" 2>/dev/null || true
  fi
}

clone_repo() {
  local branch_args=()
  [ -n "${GIT_BRANCH}" ] && branch_args=(--branch "${GIT_BRANCH}")

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would git clone ${GIT_REPO}${GIT_BRANCH:+ (branch: ${GIT_BRANCH})} into ${DOCROOT} as ${SITE_USER}"
    log_info "[DRYRUN] would create wp-config.php if absent; inject WP_CACHE_KEY_SALT + WP_REDIS_* constants"
    return 0
  fi

  if [ -d "${DOCROOT}/.git" ]; then
    log_info "site-create: repo already cloned at ${DOCROOT} — pulling latest"
    sudo -H -u "${SITE_USER}" git -C "${DOCROOT}" pull --ff-only
  else
    # Shallow clone (--depth=1) for speed on slow networks. Use timeout
    # to prevent hanging indefinitely if the remote is unreachable.
    local clone_timeout=120
    log_info "site-create: cloning ${GIT_REPO} (timeout ${clone_timeout}s)..."
    timeout "${clone_timeout}" sudo -H -u "${SITE_USER}" git clone \
      --depth=1 "${branch_args[@]}" "${GIT_REPO}" "${DOCROOT}" 2>/dev/null || {
      log_error "site-create: git clone failed or timed out (${clone_timeout}s)"
      log_error "site-create: ${DOCROOT} exists but repo was not cloned"
      log_error "site-create: re-run with --git-repo after checking network or use a smaller repo"
      exit 1
    }
  fi

  init_submodules

  # If the repo ships a wp-config.php, honour it and only inject cache constants.
  # Otherwise create a fresh config the same way download_wordpress does.
  if [ -f "${DOCROOT}/wp-config.php" ]; then
    log_info "site-create: wp-config.php found in repo — skipping wp config create"
    inject_cache_constants
  else
    sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" config create \
      --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" \
      --dbhost="localhost" --dbprefix="wp_" --skip-check
    inject_cache_constants
  fi
  ensure_htaccess
}

# Idempotently set a single wp-config constant only if not already defined.
# Skips silently if the constant already exists -- a re-run of site-create.sh
# against an existing site must not rotate the salt or change Redis settings,
# which would invalidate live caches.
_wp_set_constant_if_unset() {
  local key="$1" value="$2"
  if sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" config has \
       "${key}" --type=constant >/dev/null 2>&1; then
    return 0
  fi
  sudo -H -u "${SITE_USER}" wp --path="${DOCROOT}" config set \
    "${key}" "${value}" --type=constant --add >/dev/null
}

# Inject cache-related constants into wp-config.php:
#   WP_CACHE_KEY_SALT  -- random per site; prevents cross-tenant Redis key
#                         collisions when multiple sites share one Redis.
#                         NOTE: wp-cli 2.12+ generates this constant natively
#                         in `wp config create` using the full WP secret-key
#                         alphabet (higher entropy than our 64-char hex). The
#                         `wp config has` guard below correctly defers when
#                         that's the case; our path is the fallback for older
#                         wp-cli releases.
#   WP_REDIS_HOST/PORT/PASSWORD/DATABASE -- so plugins like Redis Object Cache
#                         work the moment the user runs `wp plugin install
#                         redis-cache --activate && wp redis enable`.
# Redis password is read from /etc/litesoup/redis.env as root (the env file is
# 0640 root:root; SITE_USER cannot read it directly). The password is then
# passed to wp-cli via argv. This matches how DB_PASS is already passed at
# `wp config create` above.
inject_cache_constants() {
  local salt
  salt="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
  _wp_set_constant_if_unset WP_CACHE_KEY_SALT "${salt}"

  if [ ! -r "${REDIS_ENV_FILE}" ]; then
    log_warn "site-create: ${REDIS_ENV_FILE} not found -- skipping WP_REDIS_* injection"
    log_warn "site-create: run install-stack.sh to install Redis, then re-run site-create or set WP_REDIS_* manually"
    return 0
  fi
  local redis_password
  # shellcheck disable=SC1090
  redis_password="$(. "${REDIS_ENV_FILE}" && printf '%s' "${REDIS_PASSWORD:-}")"
  if [ -z "${redis_password}" ]; then
    log_warn "site-create: ${REDIS_ENV_FILE} has empty REDIS_PASSWORD -- skipping WP_REDIS_* injection"
    return 0
  fi

  _wp_set_constant_if_unset WP_REDIS_HOST     "127.0.0.1"
  _wp_set_constant_if_unset WP_REDIS_PORT     "6379"
  _wp_set_constant_if_unset WP_REDIS_PASSWORD "${redis_password}"
  _wp_set_constant_if_unset WP_REDIS_DATABASE "0"

  log_info "site-create: injected WP_CACHE_KEY_SALT + WP_REDIS_* into wp-config.php"
}

# ── Laravel setup ──────────────────────────────────────────────────────────
# Called when --framework=laravel. Runs composer create-project, artisan
# key:generate, and storage:link in the site docroot.
setup_laravel() {
  local app_dir="${DOCROOT}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "[DRYRUN] would composer create-project laravel/laravel in ${app_dir}"
    log_info "[DRYRUN] would php artisan key:generate in ${app_dir}"
    log_info "[DRYRUN] would php artisan storage:link in ${app_dir}"
    return 0
  fi

  # Only create the project if the directory is empty (no .env, no artisan).
  if [ -f "${app_dir}/artisan" ]; then
    log_info "site-create: artisan already present -- skipping composer create-project"
  else
    log_info "site-create: creating Laravel project via composer..."
    sudo -H -u "${SITE_USER}" composer create-project --no-interaction \
      laravel/laravel "${app_dir}" \
      || { log_error "site-create: composer create-project failed"; exit 1; }
  fi

  # Key generation (idempotent -- artisan skips if APP_KEY already set)
  log_info "site-create: generating app key..."
  sudo -H -u "${SITE_USER}" php -d allow_url_fopen=On \
    "${app_dir}/artisan" key:generate \
    || log_warn "site-create: artisan key:generate had warnings (non-fatal)"

  # Storage link (idempotent -- artisan skips if link already exists)
  log_info "site-create: linking storage..."
  sudo -H -u "${SITE_USER}" php "${app_dir}/artisan" storage:link \
    || log_warn "site-create: artisan storage:link had warnings (non-fatal)"

  # Ensure /public/storage exists for the vhost
  if [ ! -L "${VHOST_DOCROOT}/storage" ] && [ ! -d "${VHOST_DOCROOT}/storage" ]; then
    log_info "site-create: storage symlink not in public/ -- creating manually"
    sudo -H -u "${SITE_USER}" ln -sf \
      "${app_dir}/storage/app/public" "${VHOST_DOCROOT}/storage" 2>/dev/null || true
  fi
}

# ── Generic setup ──────────────────────────────────────────────────────────
# Called when --framework=generic. Nothing to do -- docroot is ready.
setup_generic() {
  log_info "site-create: generic framework -- no setup needed"
}

main() {
  parse_args "$@"
  require_root

  log_info "site-create: ${DOMAIN} (owner=${SITE_USER}, php=${PHP_VERSION}, tls=${TLS_MODE})"
  ensure_user "${SITE_USER}"
  ensure_php_pool_for_user "${SITE_USER}" "${PHP_VERSION}" "${POOL_TIER}"
  create_database
  create_docroot

  # For LE we MUST have the HTTP-only vhost up first so the HTTP-01 challenge
  # under /.well-known/acme-challenge/ can be served. For self-signed we can
  # generate the cert before any vhost work.
  if [ "${TLS_MODE}" = "letsencrypt" ]; then
    TLS_MODE="none" write_vhost          # render HTTP-only vhost first
    certbot_obtain "${DOMAIN}" "${TLS_EMAIL}" "${DOCROOT}" \
      || { log_error "site-create: LE failed for ${DOMAIN}; site exists with HTTP only. Run site-set-tls --tls=self-signed if you need TLS now."; exit 1; }
    write_vhost                           # re-render with HTTPS block
  elif [ "${TLS_MODE}" = "self-signed" ]; then
    certbot_self_signed "${DOMAIN}"
    write_vhost
  else
    write_vhost                           # tls=none, HTTP only
  fi

  if [ -n "${GIT_REPO}" ]; then
    clone_repo
  else
    case "${FRAMEWORK}" in
      laravel) setup_laravel ;;
      generic) setup_generic ;;
      *)       download_wordpress ;;
    esac
  fi

  local scheme="http"
  [ "${TLS_MODE}" != "none" ] && scheme="https"
  local wp_path=""
  [ "${FRAMEWORK}" = "wordpress" ] && wp_path="/wp-admin/install.php"
  log_info "site-create: ${DOMAIN} -> ${scheme}://${DOMAIN}${wp_path}"
  log_info "site-create: docroot ${DOCROOT}"
  log_info "site-create: framework ${FRAMEWORK}"
  log_info "site-create: php ${PHP_VERSION} (socket $(php_fpm_socket_for_user "${SITE_USER}" "${PHP_VERSION}"))"
  log_info "site-create: tls ${TLS_MODE}"
  if [ -n "${GIT_REPO}" ]; then
    # Strip any embedded credentials (https://token@host → https://host) before logging.
    local git_repo_safe
    if [[ "${GIT_REPO}" == https://*@* ]]; then
      git_repo_safe="https://${GIT_REPO##*@}"
    else
      git_repo_safe="${GIT_REPO}"
    fi
    log_info "site-create: git ${git_repo_safe}${GIT_BRANCH:+ @ ${GIT_BRANCH}}"
  fi
}

main "$@"
