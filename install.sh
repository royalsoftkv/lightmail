#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
DATA_ROOT="./lightmail-data"
CONTAINER_NAME="lightmail"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

# --- Script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Check Prerequisites
info "Checking prerequisites..."
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (or with sudo)."
fi
if ! command -v docker &> /dev/null; then
  error "Docker is not installed. Please install it first."
fi
info "Prerequisites met."

# 2. Gather User Input
mkdir -p "$DATA_ROOT"
CONFIG_FILE="${DATA_ROOT}/install.conf"
CLOUDFLARE_TOKEN_FILE="${DATA_ROOT}/certs/cloudflare.ini"
DATA_ROOT_ABS="$(cd "$DATA_ROOT" && pwd)"

# Load existing config or prompt for new
if [[ -f "$CONFIG_FILE" ]]; then
  info "Found existing configuration in ${CONFIG_FILE}:"
  source "$CONFIG_FILE"
  echo -e "  - Mail Domain: ${YELLOW}${MAIN_DOMAIN}${NC}"
  echo -e "  - Admin Email: ${YELLOW}${ADMIN_EMAIL}${NC}"
  echo -e "  - Users:       ${YELLOW}${MAIL_USERS}${NC}"
  read -rp "Use this configuration? [Y/n]: " response
  if ! [[ "$response" =~ ^[yY] || -z "$response" ]]; then
    # Clear variables to force re-entry
    MAIN_DOMAIN=""
  fi
fi

if [[ -z "${MAIN_DOMAIN:-}" ]]; then
  info "Please provide the following information:"
  read -rp "Enter your mail domain (e.g., example.com): " MAIN_DOMAIN
  if [[ -z "$MAIN_DOMAIN" ]]; then
    error "Domain cannot be empty."
  fi

  read -rp "Enter an admin email for Let's Encrypt alerts: " ADMIN_EMAIL
  if [[ -z "$ADMIN_EMAIL" ]]; then
    error "Admin email cannot be empty."
  fi

  read -rp "Enter initial user accounts (user1:pass1,user2:pass2): " MAIL_USERS
  if [[ -z "$MAIL_USERS" ]]; then
    error "You must specify at least one user."
  fi

  info "Saving configuration to ${CONFIG_FILE} for future runs."
  cat > "$CONFIG_FILE" <<EOF
MAIN_DOMAIN="${MAIN_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
MAIL_USERS="${MAIL_USERS}"
EOF
fi

HOSTNAME="mail.${MAIN_DOMAIN}"
SERVER_IP=$(curl -s4 ifconfig.me/ip || curl -s4 icanhazip.com || echo "")

CF_API_TOKEN="${CF_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
CF_DNS_PLUGIN_IMAGE="certbot/dns-cloudflare"
CERTBOT_IMAGE="certbot/certbot"

if [[ -z "${CF_API_TOKEN}" ]]; then
  read -rp "Enter a Cloudflare API token for DNS-01 certificate issuance (leave blank to use port 80 standalone): " CF_API_TOKEN
fi

if [[ -n "$SERVER_IP" ]]; then
    info "Detected server IP: ${YELLOW}${SERVER_IP}${NC}"
    read -rp "Is this correct? [Y/n]: " response
    if ! [[ "$response" =~ ^[yY] || -z "$response" ]]; then
      read -rp "Please enter the correct server IP: " SERVER_IP
    fi
else
    read -rp "Could not detect server IP. Please enter it manually: " SERVER_IP
fi
if [[ -z "$SERVER_IP" ]]; then
    error "Server IP cannot be empty."
fi


# 3. Obtain Certificate
CERT_DEST_FULLCHAIN="${DATA_ROOT}/certs/fullchain.pem"
CERT_DEST_PRIVKEY="${DATA_ROOT}/certs/privkey.pem"

if [[ -f "$CERT_DEST_FULLCHAIN" && -f "$CERT_DEST_PRIVKEY" ]]; then
  info "Existing certificates found at ${DATA_ROOT}/certs. Skipping Certbot run."
else
  info "Obtaining certificate for ${HOSTNAME} using Certbot..."

  mkdir -p "${DATA_ROOT}/certs"

  if [[ -n "${CF_API_TOKEN}" ]]; then
    info "Using Cloudflare DNS-01 validation."
    cat > "$CLOUDFLARE_TOKEN_FILE" <<EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
    chmod 600 "$CLOUDFLARE_TOKEN_FILE"

    docker run --rm \
      -v "$(pwd)/${DATA_ROOT}/certs:/etc/letsencrypt" \
      "${CF_DNS_PLUGIN_IMAGE}" certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
      --dns-cloudflare-propagation-seconds 30 \
      -d "$HOSTNAME" \
      --email "$ADMIN_EMAIL" \
      --agree-tos \
      --no-eff-email \
      --non-interactive \
      --key-type ecdsa
  else
    info "Using standalone HTTP-01 validation on port 80."
    if lsof -i:80 &>/dev/null; then
      error "Port 80 is already in use. Please stop the service on that port before running."
    fi

    docker run --rm \
      -p 80:80 \
      -v "$(pwd)/${DATA_ROOT}/certs:/etc/letsencrypt" \
      "${CERTBOT_IMAGE}" certonly \
      --standalone \
      -d "$HOSTNAME" \
      --email "$ADMIN_EMAIL" \
      --agree-tos \
      --no-eff-email \
      --non-interactive \
      --key-type ecdsa
  fi

  CERT_LIVE_DIR="${DATA_ROOT}/certs/live/${HOSTNAME}"
  if [[ ! -f "${CERT_LIVE_DIR}/fullchain.pem" || ! -f "${CERT_LIVE_DIR}/privkey.pem" ]]; then
    error "Certbot failed to create the certificate files. Please check the output above."
  fi

  info "Copying certificates to the final destination..."
  # The certs from certbot are symlinks, so we need to copy the actual files
  cp -L "${CERT_LIVE_DIR}/fullchain.pem" "$CERT_DEST_FULLCHAIN"
  cp -L "${CERT_LIVE_DIR}/privkey.pem" "$CERT_DEST_PRIVKEY"
  info "Certificate obtained and prepared successfully."
fi

# 4. Run Docker Container
info "Checking for 'lightmail:latest' Docker image..."
if ! docker image inspect lightmail:latest &>/dev/null; then
  error "Docker image 'lightmail:latest' not found. Please build it first with: docker build -t lightmail:latest ."
fi

info "Stopping and removing any existing Lightmail container..."
docker stop "$CONTAINER_NAME" &>/dev/null || true
docker rm "$CONTAINER_NAME" &>/dev/null || true

info "Launching the Lightmail container..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart=always \
  -p 25:25 \
  -p 465:465 \
  -p 587:587 \
  -p 993:993 \
  -p 8443:8443 \
  -v "$(pwd)/${DATA_ROOT}/mail:/var/mail" \
  -v "$(pwd)/${DATA_ROOT}/config:/etc/lightmail" \
  -v "$(pwd)/${DATA_ROOT}/certs:/etc/ssl/mail" \
  -e DOMAIN="$MAIN_DOMAIN" \
  -e HOSTNAME="$HOSTNAME" \
  -e ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e USERS="$MAIL_USERS" \
  -e CERT_PATH="/etc/ssl/mail/fullchain.pem" \
  -e KEY_PATH="/etc/ssl/mail/privkey.pem" \
  -e ENABLE_IMAP=1 \
  -e ENABLE_ROUNDCUBE=1 \
  -e ENABLE_HTTPS_PROXY=1 \
  lightmail:latest

if [[ -f "$CLOUDFLARE_TOKEN_FILE" ]]; then
  info "Installing automatic certificate renewal cron job..."
  CRON_FILE="/etc/cron.d/lightmail-renew"
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 1 * * root "${SCRIPT_DIR}/renew-cert.sh" "${HOSTNAME}" "${DATA_ROOT_ABS}/certs" "${CONTAINER_NAME}" >> /var/log/lightmail-renew.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
  touch /var/log/lightmail-renew.log
fi

info "Waiting for container to initialize..."
sleep 10

# Check if the container started successfully
if ! docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "$CONTAINER_NAME"; then
  error "Container failed to start. Check logs with: docker logs ${CONTAINER_NAME}"
fi

# 5. Display Final Instructions
DKIM_KEY_PATH="${DATA_ROOT}/config/dkim/${MAIN_DOMAIN}/mail.txt"
DKIM_RECORD_VALUE="DKIM key not found after 30 seconds. Check container logs: docker logs ${CONTAINER_NAME}"
info "Waiting for DKIM key to be generated..."
for i in {1..10}; do
  if [[ -f "$DKIM_KEY_PATH" ]]; then
    # Use a reliable method to extract the DKIM value by removing the fluff around it.
    DKIM_RECORD_VALUE=$(sed 's/.*( *//;s/ *).*//' "$DKIM_KEY_PATH" | tr -d '"' | tr -d '[:space:]')
    info "DKIM key found."
    break
  fi
  echo -n "."
  sleep 3
done
if [[ "$DKIM_RECORD_VALUE" == "DKIM key not found after 30 seconds. Check container logs: docker logs ${CONTAINER_NAME}" ]]; then
  warn "Could not find DKIM key. You may need to retrieve it manually later."
fi

echo -e "\n\n"
info "🎉 ${GREEN}Lightmail setup is complete!${NC} 🎉"
echo -e "\n${YELLOW}--- ACTION REQUIRED: DNS Configuration ---${NC}"
echo -e "You ${YELLOW}must${NC} add the following DNS records at your domain provider:"
echo -e "-----------------------------------------------------------------"
echo -e "${GREEN}A Record:${NC}"
echo -e "  Type:  A"
echo -e "  Name:  mail"
echo -e "  Value: ${SERVER_IP}"
echo -e "\n${GREEN}MX Record:${NC}"
echo -e "  Type:  MX"
echo -e "  Name:  @"
echo -e "  Value: ${HOSTNAME}"
echo -e "  Prio:  10"
echo -e "\n${GREEN}SPF Record:${NC}"
echo -e "  Type:  TXT"
echo -e "  Name:  @"
echo -e "  Value: v=spf1 mx -all"
echo -e "\n${GREEN}DKIM Record:${NC}"
echo -e "  Type:  TXT"
echo -e "  Name:  mail._domainkey"
echo -e "  Value: ${DKIM_RECORD_VALUE}"
echo -e "  ${YELLOW}NOTE: Copy the entire long value above and paste it into your DNS provider's value field.${NC}"
echo -e "\n${GREEN}DMARC Record:${NC}"
echo -e "  Type:  TXT"
echo -e "  Name:  _dmarc"
echo -e "  Value: v=DMARC1; p=none; rua=mailto:${ADMIN_EMAIL}"
echo -e "-----------------------------------------------------------------"
echo -e "\n${YELLOW}--- Client and Webmail Access ---${NC}"
echo -e "Once DNS has propagated, you can access your mail:"
echo -e "-----------------------------------------------------------------"
echo -e "${GREEN}Roundcube Webmail:${NC} https://${HOSTNAME}:8443"
echo -e "\n${GREEN}IMAP (Receiving Mail):${NC}"
echo -e "  Server:   ${HOSTNAME}"
echo -e "  Port:     993"
echo -e "  Security: SSL/TLS"
echo -e "\n${GREEN}SMTP (Sending Mail):${NC}"
echo -e "  Server:   ${HOSTNAME}"
echo -e "  Port:     587"
echo -e "  Security: STARTTLS"
echo -e "\n${GREEN}Username:${NC} Your full email address (e.g., user1@${MAIN_DOMAIN})"
echo -e "${GREEN}Password:${NC} The password you specified during setup."
echo -e "-----------------------------------------------------------------"
echo -e "\nTo view container logs, run: ${YELLOW}docker logs -f ${CONTAINER_NAME}${NC}"
echo -e "To stop the container, run: ${YELLOW}docker stop ${CONTAINER_NAME}${NC}"
echo -e "To start the container, run: ${YELLOW}docker start ${CONTAINER_NAME}${NC}"
echo -e "\n"
