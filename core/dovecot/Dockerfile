# syntax=docker/dockerfile-upstream:1.4.3

# dovecot image
FROM base

ARG VERSION
LABEL version=$VERSION

# The <2.4 pin is gone: conf/dovecot.conf is written in 2.4 syntax and dovecot
# 2.4 refuses to start on a 2.3 configuration (and vice versa). That is what
# ties this image to the alpine release DISTRO points at in core/base, since
# 3.21 has no dovecot 2.4 and 3.22 has no 2.3.
#
# Which alpine releases were tried, and why the later ones were not taken - the
# reasons are both in core/base, not in this image:
#   3.22  dovecot 2.4.1, python 3.12  - in use
#   3.23  dovecot 2.4.4, python 3.12  - base fails: snuffleupagus calls the
#         unversioned "phpize", which php83-dev no longer provides there
#   3.24  dovecot 2.4.4, python 3.14  - base fails: the pinned cffi, greenlet
#         and psycopg2-binary do not compile against cpython 3.14
RUN set -euxo pipefail \
  ; apk add --no-cache dovecot dovecot-lua dovecot-lmtpd dovecot-pigeonhole-plugin dovecot-pop3d dovecot-submissiond rspamd-client dovecot-fts-flatcurve lua-json4 \
  ; mkdir /var/lib/dovecot

COPY conf/ /conf/
COPY start.py /

RUN echo $VERSION >/version

# EXPOSE 110/tcp 143/tcp 993/tcp 4190/tcp 2525/tcp
HEALTHCHECK CMD kill -0 `cat /run/dovecot/master.pid`

VOLUME ["/mail"]

CMD /start.py
