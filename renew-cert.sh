#!/usr/bin/env bash
set -euo pipefail

DOMAIN=${1:-mail.terenac.com}
EMAIL=${2:-admin@terenac.com}
CERT_DIR=${3:-/root/lightmail-data/certs}
IMAGE=${4:-lightmail:latest}
CONTAINER=${5:-lightmail}

mkdir -p "$CERT_DIR"

echo "[1/2] Issuing/renewing cert for $DOMAIN (requires port 80 free)..."
docker run --rm --entrypoint /bin/bash -p 80:80 \
  -v "$CERT_DIR:/certs" \
  "$IMAGE" -lc \
  "curl -fsSL https://get.acme.sh | sh -s email=$EMAIL --force && \
   /root/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --keylength ec-256 && \
   /root/.acme.sh/acme.sh --install-cert -d $DOMAIN \
     --key-file /certs/privkey.pem \
     --fullchain-file /certs/fullchain.pem"

echo "[2/2] Restarting mail container: $CONTAINER"
docker restart "$CONTAINER" >/dev/null

echo "Done."
