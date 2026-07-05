# Minimal Mail Server (Single Container)

This is a single‑container, minimal mail server for a small number of users. It provides:
- SMTP receive (25)
- SMTP submission (587) and SMTPS (465)
- Local Maildir delivery with optional IMAP
- Optional Roundcube webmail (requires IMAP; typically served via HTTPS proxy on 8443)
- Optional HTTPS reverse proxy (Caddy on 8443)
- Optional automatic TLS cert issuance/renewal via ACME (Let’s Encrypt)

## Install (Recommended)

### Prerequisites
- Linux server with Docker installed
- Root or sudo access
- Port 80 free during initial setup (for Let's Encrypt)
- DNS for `mail.<domain>` pointing to your server IP (can be added after install)

### Steps

1. **Build the image**
```
docker build -t lightmail:latest .
```

2. **Run the install script**
```
sudo ./install.sh
```

The script will:
- Prompt for your domain, admin email, and user accounts
- Obtain a Let's Encrypt certificate via Certbot
- Use Cloudflare DNS-01 automatically if you provide a Cloudflare API token
- Start the mail container with IMAP, Roundcube, and HTTPS proxy enabled
- Save config to `./lightmail-data/install.conf` for future runs
- Print the DNS records you need to add

Data is stored in `./lightmail-data/`:
- `mail/` — Maildir storage
- `config/` — users, DKIM keys, Roundcube config
- `certs/` — TLS certificates

3. **Add DNS records**
Follow the output from `install.sh`, or see [External Setup](#external-setup-required) below.

4. **Verify DNS**
```
./check-dns.sh example.com YOUR_SERVER_IP docker
```

5. **Set up certificate renewal (cron)**
```
0 3 1 * * /path/to/lightmail/renew-cert.sh mail.example.com /path/to/lightmail-data/certs lightmail >> /var/log/lightmail-renew.log 2>&1
```
If you use Cloudflare DNS-01, the renewal helper reuses `lightmail-data/certs/cloudflare.ini` and does not need port 80. Otherwise, port 80 must be free when the cron job runs. Certbot renews only when the cert is close to expiry.

### Access after install
- **Webmail:** `https://mail.<domain>:8443`
- **IMAP:** `mail.<domain>:993` (SSL/TLS)
- **SMTP:** `mail.<domain>:587` (STARTTLS)
- **Username:** full email address (e.g. `user1@example.com`)

## Manual Install

If you prefer to run the container yourself instead of using `install.sh`:

### Build

```
docker build -t lightmail:latest .
```

### Run

Example run command (replace passwords):

```
docker run -d \
  --name lightmail \
  -p 25:25 -p 465:465 -p 587:587 -p 8443:8443 -p 993:993 \
  -v /path/to/certs:/etc/ssl/mail \
  -v /path/on/host/mail:/var/mail \
  -v /path/on/host/lightmail:/etc/lightmail \
  -e DOMAIN=example.com \
  -e HOSTNAME=mail.example.com \
  -e USERS="user1:pass1,user2:pass2" \
  -e ENABLE_IMAP=1 \
  -e ENABLE_ROUNDCUBE=1 \
  -e ENABLE_HTTPS_PROXY=1 \
  lightmail:latest
```

Place `fullchain.pem` and `privkey.pem` in the certs directory before starting. Use `renew-cert.sh` to obtain or renew Let's Encrypt certificates.

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

### Verify DNS
Run `check-dns.sh` to verify all records are set correctly:
```
./check-dns.sh example.com
./check-dns.sh example.com 203.0.113.10                    # with expected IP
./check-dns.sh example.com 203.0.113.10 docker              # validate DKIM from container
./check-dns.sh example.com 203.0.113.10 ./lightmail-data/config/dkim/example.com/mail.txt
```

3. Firewall
- Inbound TCP: `25, 587, 465` (add `993` if IMAP is enabled)
- If Roundcube is enabled without HTTPS proxy, open/map TCP `8081`
- If HTTPS proxy is enabled, open/map TCP `8443`
- If ACME is enabled, temporarily open/map TCP `80` for certificate issuance
- Ensure outbound TCP 25 is allowed

## Notes / Limitations
- IMAP is optional (disabled by default); spam filtering and antivirus are intentionally not included for minimal resource usage.
- TLS certs are required. Provide them via volume mounts to `/etc/ssl/mail` (e.g. `fullchain.pem` and `privkey.pem`). Use `install.sh` to obtain Let's Encrypt certificates initially; use `renew-cert.sh` to renew them. Or provide your own certs.
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
Use the helper script to renew certificates when needed. It uses Cloudflare DNS-01 automatically if `cloudflare.ini` exists in the cert directory; otherwise it briefly maps port 80 and restarts the container.

```
./renew-cert.sh mail.example.com ./lightmail-data/certs lightmail
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
