#!/bin/sh

# Volume safety net on boot — two-phase cleanup:
#   1) Hard delete anything older than 7 days (mirrors mediamtx recordDeleteAfter)
#   2) If volume usage > 80%, evict oldest files first until we drop below 60%
# This prevents a runaway scenario (e.g. unexpected high-frequency shows) from
# saturating the 5 GB Railway volume mid-event.
REC=${RECORDINGS_DIR:-/recordings}
if [ -d "$REC" ]; then
  # .tls (certificat RTMPS, compte ACME) est exclu des deux phases : le supprimer
  # forcerait une réémission à chaque démarrage (limite Let's Encrypt).
  echo "[start.sh] Phase 1: prune $REC older than 7 days..."
  find "$REC" -path "$REC/.tls" -prune -o -type f -mmin +10080 -exec rm -f {} + 2>/dev/null
  find "$REC" -path "$REC/.tls" -prune -o -type d -empty -exec rmdir {} + 2>/dev/null

  USAGE_PCT=$(df "$REC" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
  if [ -n "$USAGE_PCT" ] && [ "$USAGE_PCT" -gt 80 ]; then
    echo "[start.sh] Phase 2: volume at ${USAGE_PCT}% — LRU eviction until <60%..."
    # busybox find has no -printf: mtimes come from stat (busybox and GNU).
    find "$REC" -path "$REC/.tls" -prune -o -type f -exec stat -c '%Y %n' {} + 2>/dev/null | sort -n | while read -r TS PATH_; do
      CUR=$(df "$REC" | tail -1 | awk '{print $5}' | tr -d '%')
      [ "$CUR" -lt 60 ] && break
      rm -f "$PATH_"
    done
    find "$REC" -path "$REC/.tls" -prune -o -type d -empty -exec rmdir {} + 2>/dev/null
  fi

  echo "[start.sh] $REC disk usage: $(du -sh "$REC" 2>/dev/null | cut -f1) ($(df "$REC" | tail -1 | awk '{print $5}') of volume)"
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

# RTMPS (R2) : certificat Let's Encrypt de STREAM_TLS_DOMAIN par défi DNS-01
# Cloudflare (CF_Token, CF_Zone_ID). RTMPS s'AJOUTE au RTMP en clair
# (rtmpEncryption optional). Règles :
# - seuls server.crt et server.key sont conservés sur le volume ($REC/.tls,
#   dossier 700, fichiers 600 ; nginx refuse tout segment caché) ;
# - la config d'acme.sh (compte, account.conf qui enregistre le jeton, logs)
#   vit sur le disque éphémère du conteneur ($ACME_HOME) : le jeton n'est
#   jamais écrit sur le volume, il vient de l'environnement à chaque exécution ;
# - un certificat encore valide → démarrage IMMÉDIAT en optional ; s'il expire
#   dans moins de 30 jours, renouvellement en arrière-plan, rechargé à chaud par
#   MediaMTX (mesuré en labo le 29/10, 1.19.1). Un redémarrage pendant un live
#   n'attend jamais Let's Encrypt ;
# - aucun certificat valide → émission bloquante (240 s max) ; en cas d'échec,
#   démarrage en RTMP seul, échec signalé.
TLS_DIR=${TLS_DIR:-$REC/.tls}
ACME_HOME=${ACME_HOME:-/tmp/acme}
TLS_DOMAIN=${STREAM_TLS_DOMAIN:-ingest.arobase-live.com}
RTMP_ENCRYPTION=no
cert_valid_for() { # <secondes> : le certificat existe et reste valide au moins ce délai
  [ -s "$TLS_DIR/server.crt" ] && [ -s "$TLS_DIR/server.key" ] \
    && openssl x509 -in "$TLS_DIR/server.crt" -noout -checkend "$1" >/dev/null 2>&1
}
issue_cert() {
  mkdir -p "$ACME_HOME" && chmod 700 "$ACME_HOME"
  timeout 240 acme.sh --home "$ACME_HOME" --issue --force --dns dns_cf -d "$TLS_DOMAIN" \
      --server letsencrypt --keylength ec-256 > "$ACME_HOME/last-issue.log" 2>&1 \
    && acme.sh --home "$ACME_HOME" --install-cert -d "$TLS_DOMAIN" --ecc \
      --key-file "$TLS_DIR/server.key" --fullchain-file "$TLS_DIR/server.crt" \
      >> "$ACME_HOME/last-issue.log" 2>&1
  rc=$?
  chmod 600 "$TLS_DIR/server.key" "$TLS_DIR/server.crt" 2>/dev/null
  return $rc
}
renew_loop() { # en arrière-plan : vérifie chaque jour, réémet à moins de 30 jours
  while :; do
    if ! cert_valid_for 2592000; then
      if issue_cert; then echo "[start.sh] RTMPS: certificate renewed (hot reload by MediaMTX)"
      else echo "[start.sh] RTMPS: certificate renewal FAILED (see $ACME_HOME/last-issue.log)" >&2; fi
    fi
    sleep 86400
  done
}
if [ -n "${CF_Token:-}" ] && [ -n "${CF_Zone_ID:-}" ]; then
  mkdir -p "$TLS_DIR" && chmod 700 "$TLS_DIR"
  if cert_valid_for 0; then
    RTMP_ENCRYPTION=optional
    cert_valid_for 2592000 || echo "[start.sh] RTMPS: certificate expires within 30 days, renewing in background"
  else
    echo "[start.sh] RTMPS: no valid certificate, issuing for $TLS_DOMAIN (DNS-01)..."
    if issue_cert; then
      echo "[start.sh] RTMPS: certificate issued"
      RTMP_ENCRYPTION=optional
    else
      echo "[start.sh] RTMPS: certificate issuance FAILED, starting with RTMP only (see $ACME_HOME/last-issue.log)" >&2
    fi
  fi
  [ "$RTMP_ENCRYPTION" = optional ] && renew_loop &
else
  echo "[start.sh] RTMPS: CF_Token/CF_Zone_ID not set, RTMP only"
fi
echo "[start.sh] RTMPS: rtmpEncryption=$RTMP_ENCRYPTION (domain $TLS_DOMAIN, certificate expires: $(openssl x509 -in "$TLS_DIR/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2))"

RUNTIME_CONFIG=${RUNTIME_CONFIG:-/tmp/mediamtx.runtime.yml}
PUBLISHERS_FILE=$(mktemp)
brand_publishers > "$PUBLISHERS_FILE"
sed -e "s|__STREAM_PUBLISH_PASSWORD__|${LEGACY_PASS}|g" \
    -e "s|__RTMP_ENCRYPTION__|${RTMP_ENCRYPTION}|g" \
    -e "s|__TLS_DIR__|${TLS_DIR}|g" \
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
