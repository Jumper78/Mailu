# syntax=docker/dockerfile-upstream:1.4.3

# rspamd image
FROM base

ARG VERSION=local
LABEL version=$VERSION

RUN set -euxo pipefail \
  ; apk add --no-cache rspamd rspamd-controller rspamd-fuzzy rspamd-proxy \
  ; mkdir /run/rspamd \
  ; mkdir /overrides

# TEMPORARY PATCH -- remove this comment and the RUN block below, nothing else.
#
# Where rspamd is built against PUC-Rio Lua rather than LuaJIT, dmarc.lua hands
# the fractional double from task:get_date() to os.date(), which Lua 5.3+
# rejects. The exception aborts the DNS callback before any report data reaches
# redis, so DMARC reporting silently collects nothing while policy evaluation
# keeps working.
#
# Fixed in rspamd 4.1.0; no alpine release carries it yet (3.23 ships 3.14.0,
# 3.24 ships 4.0.1). Alpine chooses luajit per architecture, and on 3.23 armv7
# is on the non-luajit list -- an architecture Mailu publishes, so this is not
# insurance.
#
# HOW THIS ENDS: the build fails as soon as the packaged dmarc.lua already
# carries the fix. When that happens, delete this comment and the RUN block --
# no other file participates in this workaround.
RUN set -euxo pipefail \
  ; f=/usr/share/rspamd/plugins/dmarc.lua \
  ; if grep -q 'math.floor(task:get_date' "$f" ; then \
      echo "rspamd ships the DMARC reporting fix: delete this RUN block" >&2 ; exit 1 ; \
    fi \
  ; sed -i "s#^\( *\)task:get_date({ format = 'connect', gmt = false }))#\1math.floor(task:get_date({ format = 'connect', gmt = false })))#" "$f" \
  ; grep -q 'math.floor(task:get_date' "$f"

COPY conf/ /conf/
COPY start.py /

RUN echo $VERSION >/version

#EXPOSE 11332/tcp 11334/tcp 11335/tcp
HEALTHCHECK --start-period=350s CMD curl -m3 -skfLo /dev/null http://localhost:11334/

VOLUME ["/var/lib/rspamd"]

CMD /start.py
