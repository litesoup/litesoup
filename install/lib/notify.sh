#!/usr/bin/env bash
# install/lib/notify.sh — notification helper for litesoup scripts.
# Provides notify_event() for sending alerts via email (if configured) and
# syslog (always). Source from any litesoup script that needs alerting.
#
# Email config: /etc/litesoup/notify-email.conf contains the recipient address.
# If the file is missing or mail isn't installed, notifications fall back
# to syslog-only (never silent: syslog is always written).
#
# Idempotent guard: re-source is a no-op.

[ -n "${LITESOUP_NOTIFY_SH:-}" ] && return 0
LITESOUP_NOTIFY_SH=1

NOTIFY_EMAIL_CONF="/etc/litesoup/notify-email.conf"

# Detect available mail transport at source time.
_NOTIFY_MAIL_CMD=""
if command -v mail >/dev/null 2>&1; then
  _NOTIFY_MAIL_CMD="mail"
elif command -v sendmail >/dev/null 2>&1; then
  _NOTIFY_MAIL_CMD="sendmail"
fi

# notify_event SUBJECT BODY
# Sends a notification through all available channels.
# Always writes to syslog (user.notice).
# Also sends email when /etc/litesoup/notify-email.conf exists and a MTA is
# available.
notify_event() {
  local subject="${1:?notify_event: subject required}"
  local body="${2:?notify_event: body required}"

  # 1. Syslog (always)
  logger -t "litesoup" -p user.notice "${subject}: ${body}"

  # 2. Email (if configured)
  if [ -z "${_NOTIFY_MAIL_CMD}" ]; then
    return 0  # no MTA available, syslog is enough
  fi
  if [ ! -f "${NOTIFY_EMAIL_CONF}" ]; then
    return 0  # no email recipient configured
  fi
  local to
  to="$(head -1 "${NOTIFY_EMAIL_CONF}" 2>/dev/null || true)"
  if [ -z "${to}" ]; then
    return 0  # empty recipient
  fi
  case "${_NOTIFY_MAIL_CMD}" in
    mail)
      printf '%s\n' "${body}" | mail -s "[litesoup] ${subject}" "${to}" 2>/dev/null || true
      ;;
    sendmail)
      {
        printf 'Subject: [litesoup] %s\n' "${subject}"
        printf 'To: %s\n' "${to}"
        printf '\n%s\n' "${body}"
      } | sendmail "${to}" 2>/dev/null || true
      ;;
  esac
}
