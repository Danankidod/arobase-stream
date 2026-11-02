#!/bin/sh
# D6 (02/11) : la rétention des replays se règle par REPLAY_RETENTION_HOURS, une seule
# valeur pour MediaMTX (recordDeleteAfter) et pour la purge de start.sh (phase 1).
# Un fichier de 10 jours est purgé avec la valeur par défaut (7 j) et gardé à 720 h (30 j).
# Usage : sh test/retention.sh <start.sh à tester> [chemin de mediamtx.yml]
set -eu
SCRIPT=$1; CONF=${2:-$(dirname "$0")/../mediamtx.yml}
B=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' > "$B/nginx"; cp "$B/nginx" "$B/mediamtx"; chmod +x "$B"/*
ago_10d() { if date -d "@0" >/dev/null 2>&1; then date -d "@$(( $(date +%s) - 864000 ))" +%Y%m%d%H%M.%S; else date -v-10d +%Y%m%d%H%M.%S; fi; }
fail() { echo "ÉCHEC : $1"; exit 1; }
run() { # $1 = valeur de REPLAY_RETENTION_HOURS ("" = défaut)
  REC=$(mktemp -d); mkdir -p "$REC/live/show"; f="$REC/live/show/old.mp4"; echo x > "$f"; touch -t "$(ago_10d)" "$f"
  RT=$(mktemp)
  env ${1:+REPLAY_RETENTION_HOURS=$1} STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR="$REC" \
    MEDIAMTX_CONFIG="$CONF" RUNTIME_CONFIG="$RT" PATH="$B:$PATH" sh "$SCRIPT" > "$RT.log" 2>&1 || true
  if [ -f "$f" ]; then KEPT=oui; else KEPT=non; fi
  DELETE_AFTER=$(sed -n 's/^ *recordDeleteAfter: //p' "$RT" | head -1)
  echo "REPLAY_RETENTION_HOURS=${1:-défaut} : fichier de 10 jours gardé=$KEPT ; recordDeleteAfter=${DELETE_AFTER:-absent}"
}
run ""; [ "$KEPT" = non ] || fail "par défaut, un fichier de 10 jours doit être purgé"; [ "$DELETE_AFTER" = 168h ] || fail "défaut : recordDeleteAfter=168h attendu"
run 720; [ "$KEPT" = oui ] || fail "à 720 h, un fichier de 10 jours doit être gardé"; [ "$DELETE_AFTER" = 720h ] || fail "recordDeleteAfter=720h attendu"
run abc; grep -q "must be a positive whole number" "$RT.log" || fail "une valeur invalide doit arrêter le démarrage"
echo "rétention réglable : OK"
