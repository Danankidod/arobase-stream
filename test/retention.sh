#!/bin/sh
# D6 / 02/11 : la rétention des replays se règle par REPLAY_RETENTION_HOURS, une seule
# valeur pour MediaMTX (recordDeleteAfter) et pour la purge de start.sh (phase 1).
# Défaut : 720 h (30 jours). Un fichier de 10 jours est gardé, un fichier de 31 jours purgé ;
# à 168 h (7 jours), le fichier de 10 jours est purgé ; une valeur invalide arrête le démarrage.
# Usage : sh test/retention.sh <start.sh à tester> [chemin de mediamtx.yml]
set -eu
SCRIPT=$1; CONF=${2:-$(dirname "$0")/../mediamtx.yml}
B=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' > "$B/nginx"; cp "$B/nginx" "$B/mediamtx"; chmod +x "$B"/*
ago_days() { if date -d "@0" >/dev/null 2>&1; then date -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y%m%d%H%M.%S; else date -v-"$1"d +%Y%m%d%H%M.%S; fi; }
fail() { echo "ÉCHEC : $1"; exit 1; }
run() { # $1 = valeur de REPLAY_RETENTION_HOURS ("" = défaut)
  REC=$(mktemp -d); mkdir -p "$REC/live/show"
  echo x > "$REC/live/show/d10.mp4"; touch -t "$(ago_days 10)" "$REC/live/show/d10.mp4"
  echo x > "$REC/live/show/d31.mp4"; touch -t "$(ago_days 31)" "$REC/live/show/d31.mp4"
  RT=$(mktemp)
  env ${1:+REPLAY_RETENTION_HOURS=$1} STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR="$REC" \
    MEDIAMTX_CONFIG="$CONF" RUNTIME_CONFIG="$RT" PATH="$B:$PATH" sh "$SCRIPT" > "$RT.log" 2>&1 || true
  if [ -f "$REC/live/show/d10.mp4" ]; then K10=oui; else K10=non; fi
  if [ -f "$REC/live/show/d31.mp4" ]; then K31=oui; else K31=non; fi
  DELETE_AFTER=$(sed -n 's/^ *recordDeleteAfter: //p' "$RT" | head -1)
  echo "REPLAY_RETENTION_HOURS=${1:-défaut} : 10 jours gardé=$K10 ; 31 jours gardé=$K31 ; recordDeleteAfter=${DELETE_AFTER:-absent}"
}
run "";  [ "$K10" = oui ] && [ "$K31" = non ] || fail "défaut (30 j) : 10 jours gardé, 31 jours purgé"; [ "$DELETE_AFTER" = 720h ] || fail "défaut : recordDeleteAfter=720h attendu"
run 168; [ "$K10" = non ] || fail "à 168 h, un fichier de 10 jours doit être purgé"; [ "$DELETE_AFTER" = 168h ] || fail "recordDeleteAfter=168h attendu"
run abc; grep -q "must be a positive whole number" "$RT.log" || fail "une valeur invalide doit arrêter le démarrage"
echo "rétention réglable, 30 jours par défaut : OK"
