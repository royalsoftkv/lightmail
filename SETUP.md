# Lightmail All‑In‑One Guide

This document consolidates requirements, external setup, install steps, and final configuration for the lightweight single‑container mail server.

## Requirements
- Single Docker container, Ubuntu base image.
- Minimal resource usage.
- SMTP receive (25), SMTP submission (587) and SMTPS (465).
- Local Maildir storage persisted on a host volume.
- Optional IMAP (993).
- Optional Roundcube webmail (requires IMAP).
- TLS for SMTP/IMAP/HTTPS via provided certs or ACME.
- No antivirus, no antispam.
- Small number of users.

## External Setup (Required)
### 1) DNS records
Set these for your domain:
- `A` record: `mail.<domain>` -> your server IP
- `MX` record: `<domain>` -> `mail.<domain>` (priority 10)
- `TXT` SPF: `v=spf1 mx -all`
- `TXT` SPF for HELO (recommended): add on `mail.<domain>` -> `v=spf1 a -all`
- `TXT` DKIM: required when `ENABLE_DKIM=1` (default)
- `TXT` DMARC: `v=DMARC1; p=none; rua=mailto:postmaster@<domain>`

DKIM TXT value is generated in the container:
```
docker exec lightmail cat /etc/lightmail/dkim/<domain>/mail.txt
```

### 2) Reverse DNS (PTR)
Set PTR for server IP to `mail.<domain>` (must match your HELO/hostname).

### 3) Firewall / Network
Open inbound TCP:
- Always: `25, 587` (and optionally `465`)
- If IMAP enabled: `993`
- If Roundcube is enabled without HTTPS proxy: `8081`
- If HTTPS proxy enabled: `8443`
- If ACME enabled: temporarily `80` during issuance

Outbound TCP 25 must be allowed by the provider.

## Install Steps (Server)

### 1) Build image
```
docker build -t lightmail:latest /root/lightmail
```

### 2) Prepare volumes
```
mkdir -p /root/lightmail-data/mail
mkdir -p /root/lightmail-data/config
mkdir -p /root/lightmail-data/certs
```

### 3) Provide TLS certs (recommended)
Place your certs here:
- `/root/lightmail-data/certs/fullchain.pem`
- `/root/lightmail-data/certs/privkey.pem`

If you want ACME to issue certs inside the container, set `ENABLE_ACME=1` and map port 80 temporarily. You can also use `renew-cert.sh` to renew certs outside the main container; it will use Cloudflare DNS-01 automatically when `lightmail-data/certs/cloudflare.ini` exists.

### 4) Run container (example)
```
docker run -d \
  --name lightmail \
  -p 25:25 -p 465:465 -p 587:587 -p 8443:8443 -p 993:993 \
  -v /root/lightmail-data/mail:/var/mail \
  -v /root/lightmail-data/config:/etc/lightmail \
  -v /root/lightmail-data/certs/fullchain.pem:/certs/fullchain.pem:ro \
  -v /root/lightmail-data/certs/privkey.pem:/certs/privkey.pem:ro \
  -e DOMAIN=example.com \
  -e HOSTNAME=mail.example.com \
  -e CERT_PATH=/certs/fullchain.pem \
  -e KEY_PATH=/certs/privkey.pem \
  -e USERS="user1:pass1,user2:pass2" \
  -e ENABLE_IMAP=1 \
  -e ENABLE_ROUNDCUBE=1 \
  -e ENABLE_HTTPS_PROXY=1 \
  -e HTTPS_PORT=8443 \
  -e CATCHALL_USER=catchall \
  -e ENABLE_DKIM=1 \
  -e DKIM_SELECTOR=mail \
  lightmail:latest
```

## Final Service Access

### SMTP (clients)
- Host: `mail.<domain>`
- Port: `587` with STARTTLS (recommended) or `465` with SSL/TLS
- Auth: `user` or `user@<domain>`

### IMAP (optional)
- Host: `mail.<domain>`
- Port: `993`
- SSL/TLS: enabled
- Auth: `user` or `user@<domain>`

### Roundcube (optional)
- If HTTPS proxy enabled: `https://mail.<domain>:8443/roundcube`
- If proxy disabled and port mapped: `http://mail.<domain>:8081/`

## Configuration Reference (Env Vars)
- `DOMAIN` (required)
- `HOSTNAME` (default `mail.<domain>`)
- `USERS` (required on first run if `/etc/lightmail/users` does not exist)
- `CERT_PATH`, `KEY_PATH` (paths inside container)
- `ENABLE_IMAP` (0/1)
- `ENABLE_ROUNDCUBE` (0/1)
- `ROUNDCUBE_PORT` (default 8081)
- `ROUNDCUBE_ALLOW_SELF_SIGNED` (default 1)
- `ROUNDCUBE_VERSION` (default 1.6.13)
- `ENABLE_HTTPS_PROXY` (0/1)
- `HTTPS_PORT` (default 8443)
- `HTTPS_HOST` (default `mail.<domain>`)
- `ROUNDCUBE_PATH` (default `/roundcube`)
- `ENABLE_ACME` (0/1)
- `ADMIN_EMAIL` (defaults to `admin@<domain>`)
- `ENABLE_ACME_RENEW` (0/1)
- `CATCHALL_USER` (default `catchall`)
- `ENABLE_DKIM` (default 1)
- `DKIM_SELECTOR` (default `mail`)
- Optional SMTP relay: `RELAYHOST`, `RELAY_PORT`, `RELAY_USER`, `RELAY_PASS`

## User Management
Users are persisted in `/etc/lightmail/users` (volume). Add or update without restart:
```
/root/lightmail/userctl.sh add <user> <password>
/root/lightmail/userctl.sh passwd <user> <password>
/root/lightmail/userctl.sh disable <user>
/root/lightmail/userctl.sh enable <user>
/root/lightmail/userctl.sh list
```

## Logs
- `docker logs -f lightmail`
