#!/usr/bin/env bash
# Check DNS records for Lightmail setup
set -euo pipefail

DOMAIN=${1:-}
EXPECTED_IP=${2:-}
DKIM_PATH=${3:-}
CONTAINER=${4:-lightmail}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

usage() {
  cat <<USAGE
Usage: $0 <domain> [expected_ip] [dkim_path|docker] [container]

  domain      Your mail domain (e.g., example.com)
  expected_ip Expected A record IP (optional; will use mail.<domain> A record if omitted)
  dkim_path   Path to DKIM mail.txt, or "docker" to fetch from container (optional)
  container   Docker container name when using dkim_path=docker (default: lightmail)

Examples:
  $0 example.com
  $0 example.com 203.0.113.10
  $0 example.com 203.0.113.10 ./lightmail-data/config/dkim/example.com/mail.txt
  $0 example.com 203.0.113.10 docker
USAGE
}

if [[ -z "$DOMAIN" ]]; then
  usage
  exit 1
fi

if ! command -v dig &>/dev/null; then
  echo "Error: 'dig' is required (install bind9-dnsutils or dnsutils)" >&2
  exit 1
fi

MAILHOST="mail.${DOMAIN}"

# Resolve expected IP from A record if not provided
if [[ -z "$EXPECTED_IP" ]]; then
  EXPECTED_IP=$(dig +short A "$MAILHOST" 2>/dev/null | head -n1)
  if [[ -z "$EXPECTED_IP" ]]; then
    fail "Cannot determine expected IP. Provide it as second argument or ensure A record exists."
    exit 1
  fi
  warn "Using $MAILHOST A record IP: $EXPECTED_IP"
fi

echo "Checking DNS for ${DOMAIN} (mail host: ${MAILHOST})"
echo "---"

# 1. A record: mail.<domain> -> server IP
a_records=$(dig +short A "$MAILHOST" 2>/dev/null | tr '\n' ' ')
if [[ "$a_records" == *"$EXPECTED_IP"* ]]; then
  pass "A record: $MAILHOST -> $EXPECTED_IP"
else
  fail "A record: $MAILHOST should point to $EXPECTED_IP (got: ${a_records:-none})"
fi

# 2. MX record: <domain> -> mail.<domain> (priority 10)
mx_records=$(dig +short MX "$DOMAIN" 2>/dev/null)
mx_ok=0
while read -r line; do
  if echo "$line" | grep -qF "${MAILHOST}"; then
    mx_ok=1
    break
  fi
done <<< "$mx_records"
if [[ "$mx_ok" -eq 1 ]]; then
  pass "MX record: $DOMAIN -> $MAILHOST"
else
  fail "MX record: $DOMAIN should point to $MAILHOST (got: ${mx_records:-none})"
fi

# 3. SPF record: @ -> v=spf1 mx -all
spf_record=$(dig +short TXT "$DOMAIN" 2>/dev/null | grep -o 'v=spf1[^"]*' | tr -d '"' | head -n1)
if echo "$spf_record" | grep -qE 'v=spf1.*mx.*-all'; then
  pass "SPF record: $DOMAIN -> $spf_record"
else
  fail "SPF record: $DOMAIN should contain 'v=spf1 mx -all' (got: ${spf_record:-none})"
fi

# 4. SPF for HELO: mail.<domain> -> v=spf1 a -all
spf_helo=$(dig +short TXT "$MAILHOST" 2>/dev/null | grep -o 'v=spf1[^"]*' | tr -d '"' | head -n1)
if echo "$spf_helo" | grep -qE 'v=spf1.*a.*-all'; then
  pass "SPF (HELO): $MAILHOST -> $spf_helo"
else
  fail "SPF (HELO): $MAILHOST should contain 'v=spf1 a -all' (got: ${spf_helo:-none})"
fi

# 5. DKIM record: mail._domainkey.<domain>
dkim_host="mail._domainkey.${DOMAIN}"
dkim_record=$(dig +short TXT "$dkim_host" 2>/dev/null | tr -d '"' | tr '\n' ' ')

# Get expected DKIM value if path or docker provided
expected_dkim=""
if [[ -n "$DKIM_PATH" ]]; then
  if [[ "$DKIM_PATH" == "docker" ]]; then
    expected_dkim=$(docker exec "$CONTAINER" cat "/etc/lightmail/dkim/${DOMAIN}/mail.txt" 2>/dev/null | sed 's/.*( *//;s/ *).*//' | tr -d '"' | tr -d '[:space:]' || true)
  elif [[ -f "$DKIM_PATH" ]]; then
    expected_dkim=$(sed 's/.*( *//;s/ *).*//' "$DKIM_PATH" | tr -d '"' | tr -d '[:space:]')
  fi
fi

if [[ -n "$dkim_record" ]]; then
  if [[ -n "$expected_dkim" ]]; then
    # Compare the p= (public key) portion - DKIM records can be split across multiple strings
    dkim_p_expected=$(echo "$expected_dkim" | sed -n 's/.*p=\([^;]*\).*/\1/p' | tr -d '[:space:]')
    dkim_p_actual=$(echo "$dkim_record" | sed -n 's/.*p=\([^;]*\).*/\1/p' | tr -d '[:space:]')
    if [[ -n "$dkim_p_expected" && -n "$dkim_p_actual" && "$dkim_p_actual" == *"$dkim_p_expected"* ]]; then
      pass "DKIM record: $dkim_host (public key matches)"
    elif [[ -n "$dkim_p_expected" && -n "$dkim_p_actual" ]]; then
      fail "DKIM record: $dkim_host exists but public key does not match expected value"
    else
      pass "DKIM record: $dkim_host (present)"
    fi
  else
    pass "DKIM record: $dkim_host (present, not validated - provide dkim_path for full check)"
  fi
else
  if [[ -n "$expected_dkim" ]]; then
    fail "DKIM record: $dkim_host missing (expected from $DKIM_PATH)"
  else
    fail "DKIM record: $dkim_host missing (add TXT record; get value from: docker exec $CONTAINER cat /etc/lightmail/dkim/${DOMAIN}/mail.txt)"
  fi
fi

# 6. DMARC record: _dmarc.<domain>
dmarc_host="_dmarc.${DOMAIN}"
dmarc_record=$(dig +short TXT "$dmarc_host" 2>/dev/null | tr -d '"' | tr '\n' ' ')
dmarc_expected="v=DMARC1"
if echo "$dmarc_record" | grep -qF "v=DMARC1"; then
  pass "DMARC record: $dmarc_host (present)"
else
  fail "DMARC record: $dmarc_host should contain v=DMARC1 (got: ${dmarc_record:-none})"
fi

# 7. PTR (reverse DNS): server IP -> mail.<domain>
ptr_record=$(dig +short -x "$EXPECTED_IP" 2>/dev/null | tr -d '\n' | sed 's/\.$//')
if [[ -n "$ptr_record" ]] && echo "$ptr_record" | grep -qiF "$MAILHOST"; then
  pass "PTR record: $EXPECTED_IP -> $MAILHOST"
else
  warn "PTR record: $EXPECTED_IP should reverse to $MAILHOST (got: ${ptr_record:-none})"
fi

echo "---"
echo "Done."
