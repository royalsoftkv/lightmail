# Lightweight Mail Server Requirements

## Goal
Provide the simplest possible, minimal‑resource email server that can send and receive email for a configurable domain, with optional Roundcube webmail. The system must run inside a single Docker container based on the latest Ubuntu image, and load provided TLS certificates.

## Core Functional Requirements
- Send email for the configured domain via SMTP submission.
- Receive email for the configured domain via SMTP.
- Store messages locally (Maildir) for a small number of users, and persist Maildir via host volume.
- Provide optional Roundcube webmail for users who need a UI.
- Run fully inside a single Docker container (no docker‑compose).
- Domain must be configurable at container runtime (env vars/args).
- Use provided TLS certificates or ACME issuance inside the container. If not provided/enabled, generate self-signed certs for SMTP/IMAP/HTTPS.
- Map required ports from container to host.
- Maildir storage and user config must be portable via volumes.

## Explicit Non‑Requirements (Must NOT be enabled)
- IMAP service is optional and disabled by default.
- Anti‑spam filtering must not be enabled.
- Anti‑virus scanning must not be enabled.

## Constraints
- Must be as lightweight as possible in RAM/CPU usage.
- Must run as root in the container.
- Base image: latest Ubuntu.
- Designed for a small number of users (minimal mailbox count).
- Single container only.

## Minimal Feature Set ("Most Important Functions")
- SMTP server for inbound mail (port 25).
- SMTP submission for outbound mail (port 587, and optionally 465).
- TLS for SMTP endpoints (and IMAP when enabled).
- Local delivery to Maildir.
- Optional Roundcube webmail.

## Proposed High‑Level Design (For Implementation Phase)
- MTA: Postfix (minimal configuration) for inbound/outbound SMTP.
- Delivery: Local delivery to Maildir.
- Webmail: PHP app that reads Maildir directly and sends via local sendmail.
- TLS: Provided cert/key paths mounted into the container.

## External Setup Required (Outside This Server)
These steps are required for the domain to function reliably with email.

1. DNS records
- `A` (or `AAAA`) record for `mail.<domain>` pointing to the server IP.
- `MX` record for `<domain>` pointing to `mail.<domain>` with priority 10.
- `SPF` record (TXT) for `<domain>`: `v=spf1 mx -all` (adjust if you add other senders).
- `DKIM` record (TXT): required when DKIM signing is enabled (default).
- `DMARC` record (TXT): `v=DMARC1; p=none; rua=mailto:postmaster@<domain>` (tighten later if desired).

2. Reverse DNS (PTR)
- Set PTR for the server IP to `mail.<domain>` (usually in the hosting provider control panel).

3. Firewall / Network
- Open inbound TCP: 25, 587 (and optionally 465). If IMAP is enabled, open 993. If Roundcube is enabled without HTTPS proxy, open 8081. If HTTPS proxy is enabled, open 8443.
- Ensure outbound TCP 25 is not blocked by the provider.

## Configuration Inputs (Runtime)
- `DOMAIN` (e.g., `example.com`)
- `HOSTNAME` (e.g., `mail.example.com`)
- `CERT_PATH` (path to fullchain PEM inside container; optional)
- `KEY_PATH` (path to private key PEM inside container; optional)
- `ENABLE_IMAP` (default 0; set to 1 to enable IMAP on 993)
- `ENABLE_ROUNDCUBE` (default 0; set to 1 to enable Roundcube webmail)
- `ROUNDCUBE_PORT` (default 8081)
- `ROUNDCUBE_ALLOW_SELF_SIGNED` (default 1)
- `ROUNDCUBE_VERSION` (default 1.6.13)
- `ENABLE_HTTPS_PROXY` (default 0; set to 1 to enable Caddy HTTPS reverse proxy)
- `HTTPS_PORT` (default 8443)
- `HTTPS_HOST` (default `mail.<domain>`)
- `ROUNDCUBE_PATH` (default `/roundcube`)
- `ENABLE_ACME` (default 0; set to 1 to auto-issue certs via HTTP-01)
- `ADMIN_EMAIL` (required when ENABLE_ACME=1; defaults to `admin@<domain>` if unset)
- `ENABLE_ACME_RENEW` (default 0; set to 1 to run periodic ACME renewals in-container)
- `CATCHALL_USER` (default `catchall`; receives mail for unknown local recipients)
- `ENABLE_DKIM` (default 1; enable OpenDKIM signing)
- `DKIM_SELECTOR` (default `mail`)
- `USERS` (only used when `/etc/lightmail/users` does not exist)
- Optional SMTP relay env vars: `RELAYHOST`, `RELAY_PORT`, `RELAY_USER`, `RELAY_PASS`
- User credentials (small number of mailbox accounts)

## Testing / Validation
- Inbound SMTP from external server reaches Postfix.
- Outbound SMTP submission authenticates and relays.
- Roundcube login and mail actions work.
- TLS certs are provided and loaded.

## Deliverables
- Dockerfile and entrypoint script to build/run the server.
- Roundcube webmail component.
- Configuration docs with explicit steps for DNS/PTR/firewall.
- Runbook: start, stop, add user, rotate password.
