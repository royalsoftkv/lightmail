#!/usr/bin/env bash
set -euo pipefail

DOMAIN=${1:-}
EMAIL=${2:-}
OUT_DIR=${3:-/root/lightmail-data/certs}

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain> [email] [output_dir]" >&2
  exit 1
fi

if [[ -z "$EMAIL" ]]; then
  EMAIL="admin@${DOMAIN}"
fi

mkdir -p "$OUT_DIR"

if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" --force
fi

/root/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --keylength ec-256

/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file "$OUT_DIR/privkey.pem" \
  --fullchain-file "$OUT_DIR/fullchain.pem"

chmod 600 "$OUT_DIR/privkey.pem"

echo "Certs written to:"
echo "  $OUT_DIR/fullchain.pem"
echo "  $OUT_DIR/privkey.pem"
