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
# Alpine 3.22 built rspamd against PUC-Rio Lua instead of LuaJIT. dmarc.lua
# hands the fractional double from task:get_date() to os.date(); LuaJIT truncates
# it, Lua 5.3+ rejects it. The exception aborts the DNS callback before any report
# data reaches redis, so DMARC reporting silently collects nothing. Policy
# evaluation is unaffected -- the symbols are inserted earlier in the function.
#
# Fixed upstream in rspamd 4.1.0, "dmarc: Floor connect timestamp before os.date
# for PUC Lua compatibility". No alpine release carries that yet:
#
#   3.22  rspamd 3.11.1   3.23  rspamd 3.14.0   3.24  rspamd 4.0.1   edge  4.1.5
#
# Which lua rspamd is built against is a per-architecture decision in alpine's
# APKBUILD, and it moved twice:
#
#   2025-04-07  luajit turned off on *every* arch, to work around the punycode
#               test failures under icu 76.1 (rspamd#5263)
#   2025-05-30  alpine 3.22 is branched, freezing that global "off"
#   2025-09-27  the per-arch case block returns with the 3.13.0 bump
#   2025-11-17  the 3.14.0 bump adds arm* to the non-luajit list
#
# So 3.22 is not an outlier, it is a stable branch cut during the five months
# edge had luajit off everywhere. On 3.23 the non-luajit list reads
# "arm*|riscv64|s390x|x86|loongarch64", and alpine's CARCH for 64-bit arm is
# aarch64, not arm*: amd64 and arm64 get luajit, armv7 does not.
#
# Mailu publishes linux/arm/v7 (docs/releases.rst), so on that platform this is
# not insurance -- without it the armv7 image collects no DMARC reports at all,
# exactly as 3.22 did on every arch. A silent regression here costs a year of
# missing reports before anyone notices.
#
# Both halves of the guard are verified on aarch64: silent against 3.23
# (rspamd 3.14.0, no fix), aborts against edge (rspamd 4.1.5, fix present).
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
