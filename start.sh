#!/bin/sh

# Volume cleanup on boot — MediaMTX recordDeleteAfter only purges files written
# AFTER its config takes effect. Old recordings predating the policy change stay
# forever. This sweep deletes anything in /recordings older than 24h on every
# container start so we recover from past over-retention bloat.
if [ -d /recordings ]; then
  echo "[start.sh] Pruning /recordings older than 24h..."
  find /recordings -type f -mmin +1440 -delete 2>/dev/null
  find /recordings -type d -empty -delete 2>/dev/null
  echo "[start.sh] /recordings disk usage: $(du -sh /recordings 2>/dev/null | cut -f1)"
fi

# Start nginx in background (reverse proxy: port 8888)
nginx &

# Start MediaMTX in foreground (HLS on 8889, playback on 9998, RTMP on 1935)
exec mediamtx /etc/mediamtx/mediamtx.yml
