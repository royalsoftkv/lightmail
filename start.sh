#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-lightmail}"
IMAGE_NAME="${IMAGE_NAME:-lightmail:latest}"
DATA_ROOT="${DATA_ROOT:-$(pwd)/lightmail-data}"
CONFIG_FILE="${DATA_ROOT}/install.conf"

DEFAULT_DOMAIN="example.com"
DEFAULT_USERS="placeholder:placeholder"

config_domain=""
config_users=""

if [[ -f "${CONFIG_FILE}" ]]; then
  # Parse only expected KEY="value" lines.
  while IFS='=' read -r key val; do
    case "${key}" in
      MAIN_DOMAIN)
        val="${val%\"}"
        val="${val#\"}"
        config_domain="${val}"
        ;;
      MAIL_USERS)
        val="${val%\"}"
        val="${val#\"}"
        config_users="${val}"
        ;;
    esac
  done < "${CONFIG_FILE}"
fi

DOMAIN="${DOMAIN:-${config_domain:-$DEFAULT_DOMAIN}}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-mail.${DOMAIN}}"
# USERS is only used on first run if /etc/lightmail/users does not already exist.
USERS="${USERS:-${config_users:-$DEFAULT_USERS}}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart=always \
  -p 25:25 \
  -p 465:465 \
  -p 587:587 \
  -p 993:993 \
  -p 8443:8443 \
  -v "${DATA_ROOT}/mail:/var/mail" \
  -v "${DATA_ROOT}/config:/etc/lightmail" \
  -v "${DATA_ROOT}/certs:/etc/ssl/mail" \
  -e DOMAIN="${DOMAIN}" \
  -e HOSTNAME="${MAIL_HOSTNAME}" \
  -e USERS="${USERS}" \
  -e ENABLE_IMAP=1 \
  -e ENABLE_ROUNDCUBE=1 \
  -e ENABLE_HTTPS_PROXY=1 \
  "${IMAGE_NAME}"

echo "Started ${CONTAINER_NAME} from ${IMAGE_NAME}"
