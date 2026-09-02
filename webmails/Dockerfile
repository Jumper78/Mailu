# syntax=docker/dockerfile-upstream:1.4.3

FROM base

ARG VERSION
LABEL version=$VERSION

COPY snappymail/pubkey.asc /tmp/snappymail.asc
COPY roundcube/pubkey.asc /tmp/roundcube.asc
COPY roundcube/roundcube.diff /tmp/roundcube.diff

# php84-pecl-imagick php84-pecl-uuid are missing
#
# alpine ships the unversioned /usr/bin/php only for whatever it currently
# treats as the default php, and that moves every release: php83 on 3.22, php84
# on 3.23, php85 already in edge (the _default_php flag in each php APKBUILD
# says which). Under 3.22 that left no "php" on PATH at all, and roundcube's
# bin/*.sh carry a "#!/usr/bin/env php" shebang -- the container came up but
# every start ended in "env: can't execute 'php'". The symlink below pins it to
# the php this image installs rather than to alpine's current pick; the php -v
# check right after fails the build if it ever points at something other
# than 8.4.
#
# PHP 8.4 moved pspell out of the core distribution, so roundcube spellchecks
# through enchant now (config.inc.php sets spellcheck_engine accordingly).
# enchant reads its dictionaries through a backend and reports none rather than
# failing when no backend can serve them, so a broken pairing would ship as a
# spellchecker that silently finds nothing. The php84 -r call below fails the
# build in that case. It deliberately checks only that enchant sees any
# dictionary at all: which languages are available follows from the aspell-*
# packages above, and duplicating that list here would just be a second place
# to forget. If it ever trips, those packages are what needs replacing --
# alpine's enchant2 also carries a hunspell backend wanting hunspell-* instead.
RUN set -euxo pipefail \
  ; apk add --no-cache \
    nginx gpg gpg-agent patch \
    php84 php84-fpm php84-mbstring php84-zip php84-xml php84-simplexml php84-pecl-apcu \
    php84-dom php84-curl php84-exif gd php84-gd php84-iconv php84-intl php84-openssl php84-ctype \
    php84-pdo_sqlite php84-pdo_mysql php84-pdo_pgsql php84-pdo php84-sodium libsodium php84-tidy \
    php84-enchant enchant2 php84-opcache php84-session php84-sockets php84-fileinfo php84-xmlreader php84-xmlwriter \
    aspell-uk aspell-ru aspell-fr aspell-de aspell-en \
  ; ln -sf /usr/bin/php84 /usr/bin/php \
  ; php -v | head -1 | grep -q '^PHP 8\.4\.' \
  ; php84 -r 'exit(enchant_broker_list_dicts(enchant_broker_init()) ? 0 : 1);' \
  ; rm /etc/nginx/http.d/default.conf \
  ; rm /etc/php84/php-fpm.d/www.conf \
  ; mkdir -m 700 /root/.gnupg/ \
  ; gpg --import /tmp/snappymail.asc \
  ; gpg --import /tmp/roundcube.asc \
  ; echo extension=snuffleupagus > /etc/php84/conf.d/snuffleupagus.ini \
  ; rm -f /tmp/roundcube.asc /tmp/snappymail.asc \
  ; mkdir -p /run/nginx /conf

# roundcube
ENV ROUNDCUBE_URL https://github.com/roundcube/roundcubemail/releases/download/1.6.18/roundcubemail-1.6.18-complete.tar.gz
ENV CARDDAV_URL https://github.com/mstilkerich/rcmcarddav/releases/download/v5.1.3/carddav-v5.1.3.tar.gz

RUN set -euxo pipefail \
  ; cd /var/www \
  ; curl -sLo /dev/shm/roundcube.tgz ${ROUNDCUBE_URL} \
  ; curl -sLo /dev/shm/roundcube.tgz.asc ${ROUNDCUBE_URL}.asc \
  ; gpg --status-fd 1 --verify /dev/shm/roundcube.tgz.asc /dev/shm/roundcube.tgz \
  ; tar xzf /dev/shm/roundcube.tgz \
  ; curl -sL ${CARDDAV_URL} | tar xz \
  ; mv roundcubemail-* roundcube \
  ; mkdir -p /var/www/roundcube/config \
  ; mv carddav roundcube/plugins/ \
  ; cd roundcube \
  ; rm -rf CHANGELOG.md SECURITY.md INSTALL LICENSE README.md UPGRADING composer.json-dist installer composer.* \
  ; ln -sf index.php /var/www/roundcube/public_html/sso.php \
  ; rm -rf plugins/{autologon,example_addressbook,http_authentication,krb_authentication,new_user_identity,password,redundant_attachments,squirrelmail_usercopy,userinfo,virtuser_file,virtuser_query} \
  ; patch -p0 < /tmp/roundcube.diff \
  ; rm /tmp/roundcube.diff

COPY roundcube/config/config.inc.php /conf/
COPY roundcube/login/ /var/www/roundcube/plugins/mailu/
COPY roundcube/config/config.inc.carddav.php /var/www/roundcube/plugins/carddav/config.inc.php

# snappymail

ENV SNAPPYMAIL_URL https://github.com/the-djmaze/snappymail/releases/download/v2.38.2/snappymail-2.38.2.tar.gz

RUN set -euxo pipefail \
  ; mkdir  /var/www/snappymail \
  ; cd /var/www/snappymail \
  ; curl -sLo /dev/shm/snappymail.tgz  ${SNAPPYMAIL_URL} \
  ; curl -sLo /dev/shm/snappymail.tgz.asc  ${SNAPPYMAIL_URL}.asc \
  ; gpg --status-fd 1 --verify /dev/shm/snappymail.tgz.asc /dev/shm/snappymail.tgz \
  ; cat /dev/shm/snappymail.tgz | tar xz

# SnappyMail login
COPY snappymail/login/include.php /var/www/snappymail/
COPY snappymail/login/sso.php /var/www/snappymail/

# Parsed and moved at startup
COPY snappymail/defaults/application.ini /defaults/
COPY snappymail/defaults/default.json /defaults/

# set perms
RUN set -euxo pipefail \
  ; chmod -R a+rX /var/www/snappymail \
  ; chown -R root:root /var/www/snappymail \
  ; chown -R mailu:mailu /var/www/snappymail/data \
  ; chown -R root:root /var/www/roundcube/ \
  ; chown -R mailu:mailu /var/www/roundcube/temp /var/www/roundcube/logs \
  ; chmod -R a+rX /var/www/roundcube

# common
COPY start.py /
COPY php.ini /defaults/
COPY php-webmail.conf /etc/php84/php-fpm.d/
COPY nginx-webmail.conf /conf/
COPY snuffleupagus.rules /etc/snuffleupagus.rules.tpl

# EXPOSE 80/tcp
VOLUME /data
VOLUME /overrides

CMD /start.py

HEALTHCHECK CMD curl -m3 -f -L http://localhost/ping || exit 1

RUN echo $VERSION >> /version
