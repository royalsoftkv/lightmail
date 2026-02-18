# Build Notes (Step Log)

1. Initialized project folder and captured requirements in `REQUIREMENTS.md`.
2. Added Dockerfile with minimal dependencies: postfix, saslauthd, python3, rsyslog, curl/openssl.
3. Added entrypoint to configure domain/users, Postfix, SASL, ACME, and start services.
4. Added minimal webmail (Maildir reader + SMTP send) and ACME HTTP challenge handling.
5. Added README with run instructions and external DNS/firewall steps.
6. Added ACME failure fallback to self-signed cert with periodic retry for real cert.
7. Added ACME timeout to avoid blocking Postfix startup; added ACME_TIMEOUT to README.
8. Installed Docker Engine (docker.io) and started the Docker service.
9. Built image and ran container with ports mapped.
10. Verified Postfix running and local SMTP delivery to Maildir.
11. Updated docs to use image name "lightmail" and generic example domain.
12. Updated container to require provided TLS certs and moved webmail to HTTPS on configurable port (default 8443); removed ACME/80/443 usage.
13. Renamed project folder to /root/lightmail; switched internal config dir to /etc/lightmail; made users file persistent-friendly and documented volume mounts for /var/mail and /etc/lightmail.
14. Made TLS optional for webmail: if CERT_PATH/KEY_PATH not provided, generate self-signed cert.
15. Added chroot DNS files for Postfix (/var/spool/postfix/etc/*) to avoid MX lookup failures.
16. Added optional SMTP relay support (RELAYHOST/RELAY_PORT/RELAY_USER/RELAY_PASS) for outbound mail when port 25 is blocked.
17. When /etc/lightmail/users exists, recreate system users and set passwords from stored hashes (chpasswd -e) to ensure inbound delivery and SMTP auth.
18. Replaced Python webmail with PHP built-in server + stunnel TLS; added Tailwind/DaisyUI/Vue3 CDN UI.
19. Added simple Reply button that pre-fills compose with recipient, Re: subject, and quoted body.
20. Added Roundcube + Dovecot IMAP; updated configs and ports (993) and documentation.
21. Pinned Roundcube download to 1.6.13 complete tarball after latest URL returned 404.
22. Added Roundcube DB volume to README.
23. Set Dovecot auth_username_format to %n so users can log in as user or user@domain.
24. Disabled TLS peer verification for Roundcube IMAP/SMTP to allow self-signed certs.
25. Added Roundcube username_domain and enabled file logging for debug.
26. Switched Roundcube default_host to ssl://127.0.0.1 for IMAPS compatibility.
27. Fixed Roundcube log/temp directory ownership to allow PHP to write logs.
28. Reverted from Roundcube/IMAP back to minimal PHP webmail (Maildir + sendmail).
29. Removed stunnel; webmail now served over HTTP on port 8080.
30. Added folder dropdown (Inbox/Sent/Drafts/Trash) with backend stub (non-inbox returns empty for now).
31. Updated webmail layout to three-pane view: left folders, middle message list, right message view.
32. Added optional IMAP support (ENABLE_IMAP=1) with Dovecot on port 993.
33. Added optional ACME auto-SSL (ENABLE_ACME=1) using standalone HTTP-01 on port 80; updated docs.
34. Added optional Roundcube webmail (ENABLE_ROUNDCUBE=1) on port 8081 with SQLite storage; requires IMAP.
35. Added optional Caddy HTTPS reverse proxy (ENABLE_HTTPS_PROXY=1) on port 8443.
36. Added ENABLE_MIN_WEBMAIL to disable the minimal webmail UI and proxy only Roundcube.
37. ACME now only runs if no certs exist; added ENABLE_ACME_RENEW for optional in-container renewals.
38. Added catch-all support via CATCHALL_USER and Postfix virtual_alias_maps.
39. Added OpenDKIM signing (ENABLE_DKIM=1 by default) and docs for DKIM DNS.
34. Added socat to support acme.sh standalone mode.
40. Fixed DKIM signing by switching to KeyFile/Selector/Domain config and OpenDKIM socket permissions.
41. Changed catch-all to use luser_relay for unknown local recipients only.
42. Quieted OpenDKIM logging after DKIM validation.
43. Removed minimal PHP webmail and related ports/config.
