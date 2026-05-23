#!/usr/bin/env bash
set -euo pipefail

# --- Initial Debug ---
printf '%s\n' "--- ENTRYPOINT START ---"
printf 'Initial HOSTNAME: %s\n' "${HOSTNAME:-UNSET}"
printf 'Initial HTTPS_HOST: %s\n' "${HTTPS_HOST:-UNSET}"
printf '%s\n' "------------------------"

DOMAIN=${DOMAIN:-}
HOSTNAME=${HOSTNAME:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
USERS=${USERS:-}
CERT_PATH=${CERT_PATH:-}
KEY_PATH=${KEY_PATH:-}
ENABLE_IMAP=${ENABLE_IMAP:-0}
ENABLE_ACME=${ENABLE_ACME:-0}
ACME_PORT=${ACME_PORT:-8080}
ENABLE_ACME_RENEW=${ENABLE_ACME_RENEW:-0}
ENABLE_ROUNDCUBE=${ENABLE_ROUNDCUBE:-0}
ROUNDCUBE_PORT=${ROUNDCUBE_PORT:-8081}
ROUNDCUBE_VERSION=${ROUNDCUBE_VERSION:-1.6.13}
ROUNDCUBE_ALLOW_SELF_SIGNED=${ROUNDCUBE_ALLOW_SELF_SIGNED:-1}
ENABLE_HTTPS_PROXY=${ENABLE_HTTPS_PROXY:-0}
HTTPS_PORT=${HTTPS_PORT:-8443}
HTTPS_HOST=${HTTPS_HOST:-$HOSTNAME}
ROUNDCUBE_PATH=${ROUNDCUBE_PATH:-/roundcube}
RELAYHOST=${RELAYHOST:-}
RELAY_PORT=${RELAY_PORT:-587}
RELAY_USER=${RELAY_USER:-}
RELAY_PASS=${RELAY_PASS:-}
CATCHALL_USER=${CATCHALL_USER:-catchall}
ENABLE_DKIM=${ENABLE_DKIM:-1}
DKIM_SELECTOR=${DKIM_SELECTOR:-mail}

if [[ -z "$DOMAIN" ]]; then
  echo "DOMAIN is required" >&2
  exit 1
fi

if [[ -z "$HOSTNAME" ]]; then
  echo "HOSTNAME is required" >&2
  exit 1
fi

if [[ -z "$ADMIN_EMAIL" ]]; then
  ADMIN_EMAIL="admin@${DOMAIN}"
fi

if [[ -z "$HTTPS_HOST" ]]; then
  HTTPS_HOST="$HOSTNAME"
fi

if [[ -z "$USERS" ]]; then
  echo "USERS is required (e.g., user1:pass1,user2:pass2)" >&2
  exit 1
fi

if [[ "$ENABLE_ACME" == "1" && -z "$ADMIN_EMAIL" ]]; then
  echo "ADMIN_EMAIL is required when ENABLE_ACME=1" >&2
  exit 1
fi

if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
  if [[ "$ENABLE_ACME" != "1" ]]; then
    echo "CERT_PATH/KEY_PATH not provided; will generate self-signed cert." >&2
  fi
fi

export DOMAIN HOSTNAME ADMIN_EMAIL

# Basic hostname setup
printf "%s\n" "$HOSTNAME" > /etc/hostname || true
hostname "$HOSTNAME" >/dev/null 2>&1 || true

# Ensure groups
if ! getent group sasl >/dev/null; then
  groupadd sasl
fi

# Create mail root
MAIL_ROOT="/var/mail/${DOMAIN}"
mkdir -p "$MAIL_ROOT"

# Create users and Maildir
USERS_FILE="/etc/lightmail/users"
# Always recreate the users from the environment variable to avoid stateful errors.
: > "$USERS_FILE"

IFS=',' read -ra USER_PAIRS <<< "$USERS"
for pair in "${USER_PAIRS[@]}"; do
  user="${pair%%:*}"
  pass="${pair#*:}"

  if [[ -z "$user" || -z "$pass" || "$user" == "$pass" ]]; then
    echo "Invalid user entry: $pair" >&2
    exit 1
  fi

  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -d "$MAIL_ROOT/$user" -s /usr/sbin/nologin "$user"
  fi

  echo "$user:$pass" | chpasswd

  maildir="$MAIL_ROOT/$user/Maildir"
  mkdir -p "$maildir/cur" "$maildir/new" "$maildir/tmp"
  chown -R "$user:$user" "$MAIL_ROOT/$user"

# Store hashed password for persistent user reuse
hash=$(openssl passwd -6 "$pass")

  printf "%s:%s\n" "$user" "$hash" >> "$USERS_FILE"

done

chmod 600 "$USERS_FILE"

# Ensure catchall user exists
if ! id "$CATCHALL_USER" >/dev/null 2>&1; then
  useradd -m -d "$MAIL_ROOT/$CATCHALL_USER" -s /usr/sbin/nologin "$CATCHALL_USER"
  echo "$CATCHALL_USER:$(openssl rand -base64 18)" | chpasswd
fi
catchall_maildir="$MAIL_ROOT/$CATCHALL_USER/Maildir"
mkdir -p "$catchall_maildir/cur" "$catchall_maildir/new" "$catchall_maildir/tmp"
chown -R "$CATCHALL_USER:$CATCHALL_USER" "$MAIL_ROOT/$CATCHALL_USER"

# SASL setup
usermod -aG sasl postfix || true
mkdir -p /var/run/saslauthd
chown root:sasl /var/run/saslauthd
chmod 755 /var/run/saslauthd

mkdir -p /etc/postfix/sasl
cat > /etc/postfix/sasl/smtpd.conf <<'EOF_CONF'
pwcheck_method: saslauthd
mech_list: PLAIN LOGIN
EOF_CONF

# Postfix config
postconf -e "myhostname=$HOSTNAME"
postconf -e "mydomain=$DOMAIN"
postconf -e "myorigin=$DOMAIN"
postconf -e "mydestination=$HOSTNAME, localhost.$DOMAIN, localhost, $DOMAIN"
postconf -e "virtual_alias_maps=hash:/etc/postfix/virtual"
postconf -e "inet_interfaces=all"
postconf -e "mynetworks=127.0.0.0/8 [::1]/128"
postconf -e "home_mailbox=Maildir/"
postconf -e "smtpd_sasl_auth_enable=yes"
postconf -e "smtpd_sasl_type=cyrus"
postconf -e "smtpd_sasl_path=smtpd"
postconf -e "smtpd_sasl_security_options=noanonymous"
postconf -e "broken_sasl_auth_clients=yes"
postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
postconf -e "smtpd_tls_cert_file=/etc/ssl/mail/fullchain.pem"
postconf -e "smtpd_tls_key_file=/etc/ssl/mail/privkey.pem"
postconf -e "smtpd_tls_security_level=may"
postconf -e "smtp_tls_security_level=may"

# Catch-all for unknown local users only
cat > /etc/postfix/virtual <<EOF_VIRTUAL
# (empty by default)
EOF_VIRTUAL
postmap /etc/postfix/virtual
if [[ -n "$CATCHALL_USER" ]]; then
  postconf -e "luser_relay=${CATCHALL_USER}@${DOMAIN}"
  postconf -e "local_recipient_maps=unix:passwd.byname"
fi

# Optional DKIM (OpenDKIM)
if [[ "$ENABLE_DKIM" == "1" ]]; then
  mkdir -p /etc/opendkim /etc/opendkim/keys /var/spool/postfix/opendkim

  if ! getent group opendkim >/dev/null; then
    groupadd opendkim
  fi
  if ! id opendkim >/dev/null 2>&1; then
    useradd -r -g opendkim -s /usr/sbin/nologin opendkim
  fi

  chown opendkim:opendkim /var/spool/postfix/opendkim
  chmod 0770 /var/spool/postfix/opendkim
  usermod -aG opendkim postfix || true

  key_dir="/etc/lightmail/dkim/${DOMAIN}"
  mkdir -p "$key_dir"

  if [[ ! -f "$key_dir/${DKIM_SELECTOR}.private" ]]; then
    opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN" -D "$key_dir"
    chown -R opendkim:opendkim "$key_dir"
    chmod 600 "$key_dir/${DKIM_SELECTOR}.private"
  fi

  cat > /etc/opendkim/opendkim.conf <<EOF_DKIM
Syslog                  yes
SyslogSuccess           no
LogWhy                  no
Canonicalization        relaxed/simple
Mode                    sv
UMask                   002
UserID                  opendkim:opendkim
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
Domain                  ${DOMAIN}
Selector                ${DKIM_SELECTOR}
KeyFile                 ${key_dir}/${DKIM_SELECTOR}.private
InternalHosts           /etc/opendkim/trusted.hosts
EOF_DKIM

  cat > /etc/opendkim/trusted.hosts <<EOF_TRUST
127.0.0.1
localhost
${HOSTNAME}
EOF_TRUST

  postconf -e "milter_default_action=accept"
  postconf -e "milter_protocol=6"
  postconf -e "smtpd_milters=unix:opendkim/opendkim.sock"
  postconf -e "non_smtpd_milters=unix:opendkim/opendkim.sock"

  opendkim -x /etc/opendkim/opendkim.conf
  for _ in 1 2 3 4 5; do
    if [[ -S /var/spool/postfix/opendkim/opendkim.sock ]]; then
      chmod 0770 /var/spool/postfix/opendkim/opendkim.sock
      break
    fi
    sleep 1
  done
fi

# Optional SMTP relay (for outbound when port 25 is blocked)
if [[ -n "$RELAYHOST" ]]; then
  postconf -e "relayhost=[$RELAYHOST]:$RELAY_PORT"
  postconf -e "smtp_sasl_auth_enable=yes"
  postconf -e "smtp_sasl_security_options=noanonymous"
  postconf -e "smtp_sasl_tls_security_options=noanonymous"
  postconf -e "smtp_tls_security_level=encrypt"
  if [[ -n "$RELAY_USER" && -n "$RELAY_PASS" ]]; then
    echo "[$RELAYHOST]:$RELAY_PORT $RELAY_USER:$RELAY_PASS" > /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    postconf -e "smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd"
    chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db || true
  else
    echo "RELAYHOST set but RELAY_USER/RELAY_PASS missing; relay may fail" >&2
  fi
fi

# Ensure chrooted Postfix processes can resolve DNS
mkdir -p /var/spool/postfix/etc
cp /etc/resolv.conf /var/spool/postfix/etc/resolv.conf
cp /etc/hosts /var/spool/postfix/etc/hosts
cp /etc/nsswitch.conf /var/spool/postfix/etc/nsswitch.conf

# Ensure smtpd not chroot to simplify saslauthd socket access
postconf -F "smtp/inet/chroot=n"

# Submission (587)
if ! grep -q '^submission ' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF_MAST'
submission inet n - n - - smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF_MAST
fi

# SMTPS (465)
if ! grep -q '^smtps ' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF_MAST'
smtps inet n - n - - smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF_MAST
fi

# Start syslog
rsyslogd

# Verify certs are provided
if [[ ! -f /etc/ssl/mail/fullchain.pem || ! -f /etc/ssl/mail/privkey.pem ]]; then
  echo "FATAL: Certificate and key not found in /etc/ssl/mail." >&2
  echo "Please ensure certificates are generated and available in the volume before starting." >&2
  exit 1
fi

# Ensure correct permissions
chmod 600 /etc/ssl/mail/privkey.pem || true

# Start saslauthd
saslauthd -a pam -m /var/run/saslauthd

# Start postfix
postfix start

# Optional IMAP (Dovecot)
if [[ "$ENABLE_IMAP" == "1" ]]; then
  cat > /etc/dovecot/conf.d/99-lightmail.conf <<EOF_DOV
protocols = imap
listen = *
ssl = required
ssl_server_cert_file = /etc/ssl/mail/fullchain.pem
ssl_server_key_file = /etc/ssl/mail/privkey.pem
mail_driver = maildir
mail_path = /var/mail/${DOMAIN}/%{user | username}/Maildir
mail_inbox_path = /var/mail/${DOMAIN}/%{user | username}/Maildir
auth_mechanisms = plain login
auth_username_format = %{user | username}
EOF_DOV

  dovecot -F >/var/log/dovecot.log 2>&1 &
fi

# Optional Roundcube (requires IMAP)
if [[ "$ENABLE_ROUNDCUBE" == "1" ]]; then
  if [[ "$ENABLE_IMAP" != "1" ]]; then
    echo "ENABLE_ROUNDCUBE requires ENABLE_IMAP=1" >&2
    exit 1
  fi

  rc_root="/var/www/roundcube"
  rc_data="/var/mail/roundcube"
  rc_db="${rc_data}/roundcube.sqlite"
  rc_config_dir="/etc/lightmail/roundcube"
  rc_config="${rc_config_dir}/config.inc.php"

  mkdir -p "$rc_root" "$rc_data" "$rc_config_dir"

  if [[ ! -f "${rc_root}/index.php" ]]; then
    rc_urls=()
    if [[ "$ROUNDCUBE_VERSION" == "latest" ]]; then
      rc_latest_url="$(curl -fsSL https://roundcube.net/download/ | grep -o 'https://github.com/roundcube/roundcubemail/releases/download/[0-9.]\+/roundcubemail-[0-9.]\+-complete\.tar\.gz' | head -n 1 || true)"
      if [[ -n "$rc_latest_url" ]]; then
        rc_urls+=("$rc_latest_url")
      fi
      rc_urls+=(
        "https://github.com/roundcube/roundcubemail/releases/latest/download/roundcubemail-latest-complete.tar.gz"
        "https://github.com/roundcube/roundcubemail/releases/latest/download/roundcubemail-latest.tar.gz"
      )
    else
      rc_urls+=(
        "https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"
        "https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}.tar.gz"
      )
    fi

    downloaded=0
    for url in "${rc_urls[@]}"; do
      if curl -fsSL -o /tmp/roundcube.tgz "$url"; then
        downloaded=1
        break
      fi
    done
    if [[ "$downloaded" != "1" ]]; then
      echo "Failed to download Roundcube archive from all known URLs" >&2
      exit 1
    fi
    tar -xzf /tmp/roundcube.tgz -C /tmp
    rc_extracted="$(find /tmp -maxdepth 1 -type d -name 'roundcubemail-*' | head -n 1)"
    if [[ -z "$rc_extracted" ]]; then
      echo "Failed to extract Roundcube archive" >&2
      exit 1
    fi
    rm -rf "$rc_root"
    mv "$rc_extracted" "$rc_root"
    rm -f /tmp/roundcube.tgz
  fi

  if [[ ! -f "$rc_db" ]]; then
    sqlite3 "$rc_db" < "$rc_root/SQL/sqlite.initial.sql"
  fi

  mkdir -p "${rc_data}/tmp" "${rc_data}/logs"

  if [[ ! -f "$rc_config" ]]; then
    des_key="$(openssl rand -hex 12)"
    cat > "$rc_config" <<EOF
<?php
\$config = [];
\$config['db_dsnw'] = 'sqlite:////var/mail/roundcube/roundcube.sqlite';
\$config['default_host'] = 'ssl://127.0.0.1';
\$config['default_port'] = 993;
\$config['smtp_server'] = 'tls://127.0.0.1';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['username_domain'] = '${DOMAIN}';
\$config['temp_dir'] = '/var/mail/roundcube/tmp';
\$config['log_dir'] = '/var/mail/roundcube/logs';
\$config['log_driver'] = 'file';
\$config['log_logins'] = true;
\$config['log_session'] = true;
\$config['debug_level'] = 1;
\$config['smtp_log'] = true;
\$config['imap_timeout'] = 5;
\$config['smtp_timeout'] = 5;
\$config['des_key'] = '${des_key}';
\$config['enable_installer'] = false;
EOF

    if [[ "$ROUNDCUBE_ALLOW_SELF_SIGNED" == "1" ]]; then
    cat >> "$rc_config" <<'EOF'
$config['imap_conn_options'] = [
  'ssl' => [
    'verify_peer' => false,
    'verify_peer_name' => false,
    'allow_self_signed' => true,
  ],
];
$config['smtp_conn_options'] = [
  'ssl' => [
    'verify_peer' => false,
    'verify_peer_name' => false,
    'allow_self_signed' => true,
  ],
];
EOF
    fi
  fi

  if ! grep -q "LIGHTMAIL_ROUNDCUBE_OVERRIDE" "$rc_config"; then
    cat >> "$rc_config" <<EOF_RC_OVERRIDE
// LIGHTMAIL_ROUNDCUBE_OVERRIDE
\$config['default_host'] = 'ssl://127.0.0.1';
\$config['default_port'] = 993;
\$config['username_domain'] = '${DOMAIN}';
\$config['temp_dir'] = '/var/mail/roundcube/tmp';
\$config['log_dir'] = '/var/mail/roundcube/logs';
\$config['log_driver'] = 'file';
\$config['log_logins'] = true;
\$config['log_session'] = true;
\$config['debug_level'] = 1;
\$config['smtp_log'] = true;
\$config['imap_timeout'] = 5;
\$config['smtp_timeout'] = 5;
EOF_RC_OVERRIDE
  fi

  ln -sf "$rc_config" "$rc_root/config/config.inc.php"

  php -S "0.0.0.0:${ROUNDCUBE_PORT}" -t "$rc_root" >/var/log/roundcube.log 2>&1 &
  ROUNDCUBE_PID=$!
fi

# Optional HTTPS reverse proxy (Caddy)
if [[ "$ENABLE_HTTPS_PROXY" == "1" ]]; then
  mkdir -p /etc/caddy
  caddyfile="/etc/caddy/Caddyfile"
  
  # Create a simple Caddyfile that always proxies to Roundcube.
  # This avoids the "Not found" error by not having a separate handler for the root path.
  cat > "$caddyfile" <<EOF
{
  auto_https off
}
https://${HTTPS_HOST}:${HTTPS_PORT} {
  tls /etc/ssl/mail/fullchain.pem /etc/ssl/mail/privkey.pem
  
  reverse_proxy 127.0.0.1:${ROUNDCUBE_PORT}
}
EOF

  caddy run --config "$caddyfile" --adapter caddyfile >/var/log/caddy.log 2>&1 &
  CADDY_PID=$!
fi

# ACME renewal loop (if enabled explicitly)
if [[ "$ENABLE_ACME_RENEW" == "1" ]]; then
  (
    while true; do
      /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/var/log/acme.log 2>&1 || true
      sleep 43200
    done
  ) &
fi

# Keep container alive and stream logs for debugging
echo "--- Services started, streaming logs ---"
touch /var/log/roundcube.log /var/log/caddy.log
tail -f /var/log/roundcube.log /var/log/caddy.log
