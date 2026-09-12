#!/usr/bin/env bash
# install/wp-cron-runner.sh — run due WP-Cron events for ONE site, with flock + logging.
#
# Called by cron (as the litesoup user), one line per site, staggered every 30 min:
#   M,30+M * * * * /opt/litesoup/wp-cron-runner.sh <site>
#
# Installed to /opt/litesoup/wp-cron-runner.sh by install-stack.sh; the per-site
# cron line is registered by site-create.sh (enable_system_wp_cron). Replacing the
# self-looping wp-cron.php (disabled via DISABLE_WP_CRON=true) with this system cron
# cuts constant background PHP load. flock prevents overlapping runs; per-site logs
# land in /var/log/wp-cron/<site>.log.
set -u
SITE="${1:-}"
if [ -z "${SITE}" ]; then echo "usage: $0 <site>"; exit 1; fi
WEBROOT="/home/litesoup/webapps/${SITE}"
if [ ! -f "${WEBROOT}/wp-config.php" ]; then
  echo "$(date '+%F %T') ERROR: not a WP site: ${SITE}" >> /var/log/wp-cron/error.log
  exit 1
fi
LOCK="/run/locks/wp-cron-${SITE}.lock"
LOG="/var/log/wp-cron/${SITE}.log"
exec 9>"${LOCK}"
flock -n 9 || { echo "$(date '+%F %T') skipped (previous run active)" >> "${LOG}"; exit 0; }
echo "===== $(date '+%F %T') =====" >> "${LOG}"
/usr/local/bin/wp --path="${WEBROOT}" cron event run --due-now >> "${LOG}" 2>&1