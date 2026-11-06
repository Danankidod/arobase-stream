#!/bin/sh
# 06/11, prototype : multidiffusion du programme vers plusieurs plateformes (YouTube,
# Instagram, TikTok…) sans réencodage. Lit le programme publié sur MediaMTX et le pousse
# vers chaque destination RTMP de MULTISTREAM_TARGETS (séparées par des espaces).
# Une destination qui tombe ne coupe pas les autres (tee, onfail=ignore).
# Usage : MULTISTREAM_SOURCE=rtmp://127.0.0.1:1935/live/<clé> MULTISTREAM_TARGETS="rtmp://… rtmp://…" sh multistream/push.sh
set -eu
: "${MULTISTREAM_SOURCE:?MULTISTREAM_SOURCE manquant}"
: "${MULTISTREAM_TARGETS:?MULTISTREAM_TARGETS manquant}"
OUT=""
for t in $MULTISTREAM_TARGETS; do
  case "$t" in rtmp://*|rtmps://*) ;; *) echo "[multistream] destination refusée (rtmp:// ou rtmps:// attendu)"; exit 1 ;; esac
  OUT="${OUT:+$OUT|}[f=flv:onfail=ignore]$t"
done
exec ffmpeg -hide_banner -loglevel warning -rw_timeout 10000000 -i "$MULTISTREAM_SOURCE" \
  -map 0:v -map 0:a? -c copy -f tee -flags +global_header "$OUT"
