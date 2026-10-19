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
: "${STREAM_PUBLISH_PASSWORD:?STREAM_PUBLISH_PASSWORD env var is required}"
RUNTIME_CONFIG=/tmp/mediamtx.runtime.yml
sed "s|__STREAM_PUBLISH_PASSWORD__|${STREAM_PUBLISH_PASSWORD}|g" \
  /etc/mediamtx/mediamtx.yml > "$RUNTIME_CONFIG"

# Start nginx in background (reverse proxy: port 8888)
nginx &

# Start MediaMTX in foreground (HLS on 8889, playback on 9998, RTMP on 1935)
exec mediamtx "$RUNTIME_CONFIG"
