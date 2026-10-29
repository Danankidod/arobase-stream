#!/bin/sh
# Hook MediaMTX (runOnReady / runOnNotReady) : prévient l'app d'un événement de flux.
# MediaMTX lance la commande sans shell : la logique de repli vit donc ici.
# Essaie STREAM_EVENT_URL (ex. réseau privé Railway) s'il est défini, puis le
# domaine public. L'app ignore un doublon. Ne fait jamais échouer MediaMTX.
# Usage : notify.sh <ready|disconnect>   (MTX_PATH fourni par MediaMTX)
event=$1
body="{\"event\":\"$event\",\"path\":\"$MTX_PATH\"}"
for url in ${STREAM_EVENT_URL:+"$STREAM_EVENT_URL"} https://www.arobase-live.com/api/stream/event; do
  if wget -q -T 5 -O /dev/null --post-data "$body" \
       --header='Content-Type: application/json' \
       --header="x-stream-secret: $STREAM_WEBHOOK_SECRET" "$url"; then
    exit 0
  fi
  echo "[notify.sh] $event $MTX_PATH : échec vers ${url%%/api/*}" >&2
done
exit 0
