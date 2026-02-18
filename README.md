# Minimal Mail Server (Single Container)

This is a single‑container, minimal mail server for a small number of users. It provides:
- SMTP receive (25)
- SMTP submission (587) and SMTPS (465)
- Local Maildir delivery with optional IMAP
- Optional Roundcube webmail (requires IMAP; typically served via HTTPS proxy on 8443)
- Optional HTTPS reverse proxy (Caddy on 8443)
- Optional automatic TLS cert issuance/renewal via ACME (Let’s Encrypt)

## Build

```
docker build -t lightmail:latest .
```

## Run

Example run command (replace passwords):

```
docker run -d \
  --name lightmail \
  -p 25:25 -p 465:465 -p 587:587 -p 8443:8443 -p 993:993 \
  -v /path/to/fullchain.pem:/certs/fullchain.pem:ro \
  -v /path/to/privkey.pem:/certs/privkey.pem:ro \
  -v /path/on/host/mail:/var/mail \
  -v /path/on/host/lightmail:/etc/lightmail \
  -e DOMAIN=example.com \
  -e HOSTNAME=mail.example.com \
  -e CERT_PATH=/certs/fullchain.pem \
  -e KEY_PATH=/certs/privkey.pem \
  -e USERS="user1:pass1,user2:pass2" \
  -e ENABLE_IMAP=1 \
  -e ENABLE_ROUNDCUBE=1 \
  -e ENABLE_HTTPS_PROXY=1 \
  lightmail:latest
```

Roundcube (if enabled without HTTPS proxy) is available at `http://mail.<domain>:8081/`.
If HTTPS proxy is enabled, use `https://mail.<domain>:8443/roundcube`.

## External Setup (Required)

1. DNS records
- `A` record: `mail.<domain>` -> your server IP
- `MX` record: `<domain>` -> `mail.<domain>` (priority 10)
- `TXT` SPF: `v=spf1 mx -all`
- `TXT` SPF for HELO: add on `mail.<domain>` -> `v=spf1 a -all`
- `TXT` DKIM: required if `ENABLE_DKIM=1` (default)
- `TXT` DMARC: `v=DMARC1; p=none; rua=mailto:postmaster@<domain>`

2. Reverse DNS (PTR)
- Set PTR for server IP to `mail.<domain>` (must match your HELO)

3. Firewall
- Inbound TCP: `25, 587, 465` (add `993` if IMAP is enabled)
- If Roundcube is enabled without HTTPS proxy, open/map TCP `8081`
- If HTTPS proxy is enabled, open/map TCP `8443`
- If ACME is enabled, temporarily open/map TCP `80` for certificate issuance
- Ensure outbound TCP 25 is allowed

## Notes / Limitations
- IMAP is optional (disabled by default); spam filtering and antivirus are intentionally not included for minimal resource usage.
- TLS certs are provided by you via `CERT_PATH` and `KEY_PATH`, or via ACME. If neither is provided/enabled, a self-signed cert is generated for SMTP/IMAP/HTTPS.
When outbound TCP 25 is blocked by your host, use an SMTP relay.

## DKIM (Enabled by Default)
OpenDKIM signs outbound mail. Keys are stored in `/etc/lightmail/dkim/<domain>`.
DNS record:
- `TXT` at `mail._domainkey.<domain>` with the value from `/etc/lightmail/dkim/<domain>/mail.txt`

Example lookup to show the DKIM TXT:
```
docker exec lightmail cat /etc/lightmail/dkim/<domain>/mail.txt
```

## Auto SSL (ACME)
- To auto-issue certs inside the container, set `ENABLE_ACME=1` and `ADMIN_EMAIL`.
- If `ADMIN_EMAIL` is not set, it defaults to `admin@<domain>`.
- Port 80 must be mapped and free during issuance.
- If port 80 is used by another web server, stop it temporarily or provide certs manually.
- By default, ACME is only used when no certs exist. To enable periodic renewal inside the container, set `ENABLE_ACME_RENEW=1` (requires port 80 to be reachable).

## Manual Renewal (No Port 80 Normally)
Use the helper script to renew certificates when needed. It briefly maps port 80 and restarts the container.

```
/root/lightmail/renew-cert.sh mail.terenac.com admin@terenac.com /root/lightmail-data/certs
```

## SMTP Relay (Optional)
Set these env vars to relay outbound mail through a provider (e.g., Gmail):
- `RELAYHOST` (e.g., `smtp.gmail.com`)
- `RELAY_PORT` (e.g., `587`)
- `RELAY_USER` (e.g., `your@gmail.com`)
- `RELAY_PASS` (app password)

## Roundcube (Optional)
Roundcube provides a full-featured webmail UI and requires IMAP.
- Set `ENABLE_ROUNDCUBE=1` and `ENABLE_IMAP=1`
- Optional: `ROUNDCUBE_PORT` (default `8081`)
- Optional: `ROUNDCUBE_ALLOW_SELF_SIGNED=1` to accept self-signed certs for IMAP/SMTP
- Optional: `ROUNDCUBE_VERSION` (default `1.6.13`)

## HTTPS Proxy (Optional)
Use Caddy to terminate TLS on a non-standard port and proxy to Roundcube.
- Set `ENABLE_HTTPS_PROXY=1`
- Optional: `HTTPS_PORT` (default `8443`)
- Optional: `HTTPS_HOST` (defaults to `mail.<domain>`)
- Optional: `ROUNDCUBE_PATH` (default `/roundcube`)

## User Management
- Users are set via `USERS` env var at container start.
- Format: `user1:pass1,user2:pass2`
- Each user gets a Maildir at `/var/mail/<domain>/<user>/Maildir`.
If `/etc/lightmail/users` already exists (via volume), the container will reuse it and recreate system users from that file.
If `CATCHALL_USER` is set, unknown local recipients are delivered to `catchall@<domain>`.

### Add/Change Users Without Restart
Use the helper script:

```
/root/lightmail/userctl.sh add <user> <password>
/root/lightmail/userctl.sh passwd <user> <password>
/root/lightmail/userctl.sh disable <user>
/root/lightmail/userctl.sh enable <user>
/root/lightmail/userctl.sh list
```

It edits `/etc/lightmail/users` inside the container and updates system accounts and Maildirs.


## Logs
- `docker logs -f lightmail`
