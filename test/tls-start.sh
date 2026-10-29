#!/bin/sh
# R2 : logique TLS de start.sh, dans alpine, avec un faux acme.sh (aucun appel réseau).
# Usage (dans alpine:3.20, dépôt monté en /w) : sh /w/test/tls-start.sh
set -eu
apk add -q --no-cache openssl findutils >/dev/null
B=/tmp/bin; mkdir -p $B
printf '#!/bin/sh\nexit 0\n' > $B/nginx; cp $B/nginx $B/mediamtx; chmod +x $B/*
run() { # <cas> <comportement du faux acme : none|fail|ok> [env...]
  cas=$1; acme=$2; shift 2
  rm -rf /tmp/rec; mkdir -p /tmp/rec/live/old /tmp/rec/.tls
  case $acme in
    none) rm -f $B/acme.sh ;;
    fail) printf '#!/bin/sh\necho "faux acme : échec"; exit 1\n' > $B/acme.sh; chmod +x $B/acme.sh ;;
    ok) cat > $B/acme.sh <<'ACME'
#!/bin/sh
for a in "$@"; do case "$prev" in --key-file) k=$a;; --fullchain-file) c=$a;; esac; prev=$a; done
[ -n "${k:-}" ] && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$k" -out "$c" -days 90 -subj "/CN=ingest.arobase-live.com" 2>/dev/null
exit 0
ACME
        chmod +x $B/acme.sh ;;
  esac
  touch -d "@$(( $(date +%s) - 9*86400 ))" /tmp/rec/live/old/seg.mp4 2>/dev/null || touch -t 202001010000 /tmp/rec/live/old/seg.mp4
  echo "ancien" > /tmp/rec/.tls/keep && touch -t 202001010000 /tmp/rec/.tls/keep
  env "$@" STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR=/tmp/rec \
    MEDIAMTX_CONFIG=/w/mediamtx.yml RUNTIME_CONFIG=/tmp/rt-$cas.yml PATH=$B:$PATH sh /w/start.sh > /tmp/log-$cas.txt 2>&1 || true
  enc=$(grep -E '^rtmpEncryption:' /tmp/rt-$cas.yml | tr -d '"' | awk '{print $2}')
  echo "== $cas : rtmpEncryption=$enc | $(grep 'RTMPS:' /tmp/log-$cas.txt | tr '\n' ' ')"
}
fail() { echo "ÉCHEC : $1"; exit 1; }
run sans-cf none
[ "$enc" = no ] || fail "sans variables CF, rtmpEncryption devrait être no"
grep -q "__RTMP_ENCRYPTION__\|__TLS_DIR__" /tmp/rt-sans-cf.yml && fail "marqueur non remplacé"
[ ! -e /tmp/rec/live/old/seg.mp4 ] || fail "le nettoyage des 7 jours ne supprime plus les vieux enregistrements"
[ -e /tmp/rec/.tls/keep ] || fail "le nettoyage a supprimé un fichier de .tls"
run emission-ko fail CF_Token=faux CF_Zone_ID=faux
[ "$enc" = no ] || fail "émission en échec : rtmpEncryption devrait rester no"
grep -q "issuance FAILED, starting with RTMP only" /tmp/log-emission-ko.txt || fail "l'échec d'émission n'est pas signalé"
grep -q "publish permissions configured" /tmp/log-emission-ko.txt || fail "start.sh ne va pas au bout en cas d'échec"
run emission-ok ok CF_Token=faux CF_Zone_ID=faux
[ "$enc" = optional ] || fail "émission réussie : rtmpEncryption devrait être optional"
[ "$(stat -c %a /tmp/rec/.tls)" = 700 ] || fail "droits de .tls : $(stat -c %a /tmp/rec/.tls)"
[ "$(stat -c %a /tmp/rec/.tls/server.key)" = 600 ] || fail "droits de server.key : $(stat -c %a /tmp/rec/.tls/server.key)"
grep -q "^rtmpServerKey: /tmp/rec/.tls/server.key" /tmp/rt-emission-ok.yml || fail "chemin de clé non injecté"
grep -q "^rtmpAddress: :1935" /tmp/rt-emission-ok.yml || fail "le RTMP en clair a disparu"
echo "TLS start.sh : OK (sans CF → RTMP seul ; échec → RTMP seul signalé ; succès → optional, 700/600 ; .tls épargné par le nettoyage)"
