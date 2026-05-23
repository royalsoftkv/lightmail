#!/usr/bin/env bash
set -euo pipefail

DOMAIN=${1:-mail.terenac.com}
CERT_DIR=${2:-./lightmail-data/certs}
CONTAINER=${3:-lightmail}

# Resolve to absolute path for Docker mount
CERT_DIR="$(cd "$CERT_DIR" && pwd)"

if [[ ! -d "${CERT_DIR}/live/${DOMAIN}" ]]; then
  echo "Certificate directory not found at ${CERT_DIR}/live/${DOMAIN}. Run install.sh first." >&2
  exit 1
fi

echo "[1/2] Renewing cert for $DOMAIN (requires port 80 free)..."
if lsof -i:80 &>/dev/null; then
  echo "Port 80 is already in use. Please stop the service on that port before running." >&2
  exit 1
fi

docker run --rm \
  -p 80:80 \
  -v "${CERT_DIR}:/etc/letsencrypt" \
  certbot/certbot renew

# Copy renewed certs to the format lightmail expects (same as install.sh)
CERT_LIVE_DIR="${CERT_DIR}/live/${DOMAIN}"
if [[ ! -f "${CERT_LIVE_DIR}/fullchain.pem" || ! -f "${CERT_LIVE_DIR}/privkey.pem" ]]; then
  echo "Cert renewal may have failed or certs not found at ${CERT_LIVE_DIR}" >&2
  exit 1
fi

cp -L "${CERT_LIVE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp -L "${CERT_LIVE_DIR}/privkey.pem" "${CERT_DIR}/privkey.pem"
chmod 600 "${CERT_DIR}/privkey.pem"

echo "[2/2] Restarting mail container: $CONTAINER"
docker restart "$CONTAINER" >/dev/null

echo "Done."
