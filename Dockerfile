FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     ca-certificates \
     curl \
     openssl \
     postfix \
     dovecot-imapd \
     sasl2-bin \
     libsasl2-modules \
     rsyslog \
     php-cli \
     php-curl \
     php-gd \
     php-intl \
     php-mbstring \
     php-sqlite3 \
     php-xml \
     php-zip \
     sqlite3 \
     caddy \
     opendkim \
     opendkim-tools \
     socat \
     tzdata \
  && rm -rf /var/lib/apt/lists/*

# Minimal directories
RUN mkdir -p /etc/lightmail /var/mail /etc/ssl/mail

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 25 80 465 587 8080 8081 8443 993

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
