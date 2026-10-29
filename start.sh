#!/bin/sh

# Volume safety net on boot — two-phase cleanup:
#   1) Hard delete anything older than 7 days (mirrors mediamtx recordDeleteAfter)
#   2) If volume usage > 80%, evict oldest files first until we drop below 60%
# This prevents a runaway scenario (e.g. unexpected high-frequency shows) from
# saturating the 5 GB Railway volume mid-event.
if [ -d /recordings ]; then
  echo "[start.sh] Phase 1: prune /recordings older than 7 days..."
  find /recordings -type f -mmin +10080 -delete 2>/dev/null
  find /recordings -type d -empty -delete 2>/dev/null

  USAGE_PCT=$(df /recordings 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
  if [ -n "$USAGE_PCT" ] && [ "$USAGE_PCT" -gt 80 ]; then
    echo "[start.sh] Phase 2: volume at ${USAGE_PCT}% — LRU eviction until <60%..."
    find /recordings -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | while read TS PATH_; do
      CUR=$(df /recordings | tail -1 | awk '{print $5}' | tr -d '%')
      [ "$CUR" -lt 60 ] && break
      rm -f "$PATH_"
    done
    find /recordings -type d -empty -delete 2>/dev/null
  fi

  echo "[start.sh] /recordings disk usage: $(du -sh /recordings 2>/dev/null | cut -f1) ($(df /recordings | tail -1 | awk '{print $5}') of volume)"
fi

# Inject the RTMP publish password (F2) into a runtime config. The committed
# mediamtx.yml only carries a placeholder, never the secret. Fail loudly if the
# env var is missing rather than silently running with a guessable password.
# Use an alphanumeric secret (e.g. `openssl rand -hex 24`) so the sed below is
# safe (no /, &, | or backslash to escape).
#
# Per-brand publishers: with STREAM_PUBLISH_MASTER set, each key of
# STREAM_PUBLISH_KEYS (comma-separated) gets its own user, allowed to publish on
# live/<key> only, plus one "operator" user for live/liveA|liveB|liveC.
# pass = HMAC-SHA256(master, "publish:<label>") hex[0:32], the derivation of
# arobase-live server/lib/stream-credentials.ts. Only its sha256 is written.
# Without STREAM_PUBLISH_PASSWORD the shared publisher gets a random, never
# shared password (end of the migration).
if [ -z "${STREAM_PUBLISH_MASTER:-}" ]; then
  : "${STREAM_PUBLISH_PASSWORD:?STREAM_PUBLISH_PASSWORD or STREAM_PUBLISH_MASTER env var is required}"
fi
LEGACY_PASS=${STREAM_PUBLISH_PASSWORD:-$(openssl rand -hex 32)}

publisher_user() { # <user> <label> <path>...
  _pass=$(printf '%s' "publish:$2" | openssl dgst -sha256 -hmac "$STREAM_PUBLISH_MASTER" -r | cut -c1-32)
  _hash=$(printf '%s' "$_pass" | openssl dgst -sha256 -binary | openssl base64 -A)
  printf '  - user: %s\n    pass: sha256:%s\n    ips: []\n    permissions:\n' "$1" "$_hash"
  shift 2
  for _p in "$@"; do printf '      - action: publish\n        path: %s\n' "$_p"; done
}

brand_publishers() {
  [ -n "${STREAM_PUBLISH_MASTER:-}" ] || return 0
  publisher_user operator multicam live/liveA live/liveB live/liveC
  for _key in $(printf '%s' "${STREAM_PUBLISH_KEYS:-}" | tr ',' ' '); do
    case "$_key" in
      ''|*[!A-Za-z0-9_-]*|liveA|liveB|liveC) echo "[start.sh] STREAM_PUBLISH_KEYS: invalid key skipped" >&2; continue ;;
    esac
    publisher_user "$_key" "live/$_key" "live/$_key"
  done
}

RUNTIME_CONFIG=${RUNTIME_CONFIG:-/tmp/mediamtx.runtime.yml}
PUBLISHERS_FILE=$(mktemp)
brand_publishers > "$PUBLISHERS_FILE"
sed -e "s|__STREAM_PUBLISH_PASSWORD__|${LEGACY_PASS}|g" \
    -e "/# __BRAND_PUBLISHERS__/{
r $PUBLISHERS_FILE
d
}" \
  "${MEDIAMTX_CONFIG:-/etc/mediamtx/mediamtx.yml}" > "$RUNTIME_CONFIG"
rm -f "$PUBLISHERS_FILE"
echo "[start.sh] $(grep -c 'action: publish' "$RUNTIME_CONFIG") publish permissions configured"

# Start nginx in background (reverse proxy: port 8888)
nginx &

# Start MediaMTX in foreground (HLS on 8889, playback on 9998, RTMP on 1935)
exec mediamtx "$RUNTIME_CONFIG"
