#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-lightmail}

usage() {
  cat <<USAGE
Usage:
  userctl.sh add <user> <password>      Add or update a user
  userctl.sh passwd <user> <password>   Update password
  userctl.sh disable <user>             Disable login (keeps maildir)
  userctl.sh enable <user>              Enable login
  userctl.sh list                       List users

Env:
  CONTAINER=lightmail   Docker container name
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

cmd=$1
shift

case "$cmd" in
  add|passwd)
    if [[ $# -ne 2 ]]; then usage; exit 1; fi
    user=$1
    pass=$2
    docker exec "$CONTAINER" bash -lc "set -euo pipefail
      domain=\"\$(postconf -h mydomain)\";
      if [[ -z \"\$domain\" ]]; then echo 'Cannot determine domain' >&2; exit 1; fi
      mail_root=\"/var/mail/\$domain\";
      users_file=\"/etc/lightmail/users\";
      hash=\"\$(doveadm pw -s SHA512-CRYPT -p \"$pass\")\";
      if ! id \"$user\" >/dev/null 2>&1; then
        useradd -m -d \"\$mail_root/$user\" -s /usr/sbin/nologin \"$user\";
      fi
      echo \"$user:$pass\" | chpasswd;
      maildir=\"\$mail_root/$user/Maildir\";
      mkdir -p \"\$maildir/cur\" \"\$maildir/new\" \"\$maildir/tmp\";
      chown -R \"$user:$user\" \"\$mail_root/$user\";
      if grep -q \"^$user:\" \"\$users_file\"; then
        sed -i \"s|^$user:.*|$user:\$hash|\" \"\$users_file\";
      else
        echo \"$user:\$hash\" >> \"\$users_file\";
      fi
      chown root:dovecot \"\$users_file\" || true;
      chmod 640 \"\$users_file\";
    "
    ;;
  disable)
    if [[ $# -ne 1 ]]; then usage; exit 1; fi
    user=$1
    docker exec "$CONTAINER" bash -lc "set -euo pipefail
      users_file=\"/etc/lightmail/users\";
      if id \"$user\" >/dev/null 2>&1; then
        usermod -L \"$user\" || true;
      fi
      if [[ -f \"\$users_file\" ]]; then
        sed -i \"/^$user:/d\" \"\$users_file\";
        chown root:dovecot \"\$users_file\" || true;
        chmod 640 \"\$users_file\";
      fi
    "
    ;;
  enable)
    if [[ $# -ne 1 ]]; then usage; exit 1; fi
    user=$1
    docker exec "$CONTAINER" bash -lc "set -euo pipefail
      if id \"$user\" >/dev/null 2>&1; then
        usermod -U \"$user\" || true;
      else
        echo 'User does not exist' >&2; exit 1;
      fi
    "
    ;;
  list)
    docker exec "$CONTAINER" bash -lc "set -euo pipefail
      users_file=\"/etc/lightmail/users\";
      if [[ -f \"\$users_file\" ]]; then
        cut -d: -f1 \"\$users_file\";
      fi
    "
    ;;
  *)
    usage
    exit 1
    ;;
esac
