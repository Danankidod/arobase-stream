#!/bin/sh
# R2 : logique TLS de start.sh, dans alpine, avec un faux acme.sh (aucun appel réseau).
# Le faux acme.sh imite le vrai : --issue écrit account.conf avec SAVED_CF_Token dans
# son --home ; --install-cert écrit la clé et le certificat aux chemins demandés.
# Usage (dans alpine:3.20, dépôt monté en /w) : sh /w/test/tls-start.sh
set -eu
apk add -q --no-cache openssl findutils >/dev/null
B=/tmp/bin; mkdir -p $B
printf '#!/bin/sh\nexit 0\n' > $B/nginx; cp $B/nginx $B/mediamtx; chmod +x $B/*
TOKEN=ci-fake-cf-token-$$-should-never-reach-the-volume
cat > $B/acme-ok <<'ACME'
#!/bin/sh
home=""; mode=""
for a in "$@"; do
  case "$prev" in --home) home=$a;; --key-file) k=$a;; --fullchain-file) c=$a;; esac
  case "$a" in --issue) mode=issue;; --install-cert) mode=install;; esac
  prev=$a
done
if [ "$mode" = issue ]; then
  mkdir -p "$home" && echo "SAVED_CF_Token='$CF_Token'" > "$home/account.conf"
  sleep "${FAKE_ACME_SLEEP:-0}"
fi
[ "$mode" = install ] && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$k" -out "$c" -days 90 -subj "/CN=ingest.arobase-live.com" 2>/dev/null
exit 0
ACME
printf '#!/bin/sh\necho "faux acme : échec"; exit 1\n' > $B/acme-fail
chmod +x $B/acme-ok $B/acme-fail
fail() { echo "ÉCHEC : $1"; exit 1; }
run() { # <cas> <acme : none|fail|ok> [env...]
  cas=$1; acme=$2; shift 2
  rm -f $B/acme.sh; [ "$acme" != none ] && cp $B/acme-$acme $B/acme.sh
  t0=$(date +%s)
  env "$@" STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR=/tmp/rec ACME_HOME=/tmp/acme-$cas \
    MEDIAMTX_CONFIG=/w/mediamtx.yml RUNTIME_CONFIG=/tmp/rt-$cas.yml PATH=$B:$PATH sh /w/start.sh > /tmp/log-$cas.txt 2>&1 || true
  dt=$(( $(date +%s) - t0 ))
  enc=$(grep -E '^rtmpEncryption:' /tmp/rt-$cas.yml | tr -d '"' | awk '{print $2}')
  echo "== $cas : ${dt} s, rtmpEncryption=$enc | $(grep 'RTMPS:' /tmp/log-$cas.txt | tr '\n' ' ')"
}
fresh_volume() {
  rm -rf /tmp/rec; mkdir -p /tmp/rec/live/old /tmp/rec/.tls
  touch -d "@$(( $(date +%s) - 9*86400 ))" /tmp/rec/live/old/seg.mp4
  echo "ancien" > /tmp/rec/.tls/keep && touch -d "@$(( $(date +%s) - 9*86400 ))" /tmp/rec/.tls/keep
}

fresh_volume; run sans-cf none
[ "$enc" = no ] || fail "sans variables CF : rtmpEncryption devrait être no"
grep -q "__RTMP_ENCRYPTION__\|__TLS_DIR__" /tmp/rt-sans-cf.yml && fail "marqueur non remplacé"
[ ! -e /tmp/rec/live/old/seg.mp4 ] || fail "le nettoyage des 7 jours ne supprime plus les vieux enregistrements"
[ -e /tmp/rec/.tls/keep ] || fail "le nettoyage a supprimé un fichier de .tls"

fresh_volume; run emission-ko fail CF_Token=$TOKEN CF_Zone_ID=zone
[ "$enc" = no ] || fail "émission en échec : rtmpEncryption devrait rester no"
grep -q "issuance FAILED, starting with RTMP only" /tmp/log-emission-ko.txt || fail "l'échec d'émission n'est pas signalé"
grep -q "publish permissions configured" /tmp/log-emission-ko.txt || fail "start.sh ne va pas au bout en cas d'échec"

fresh_volume; run emission-ok ok CF_Token=$TOKEN CF_Zone_ID=zone
[ "$enc" = optional ] || fail "émission réussie : rtmpEncryption devrait être optional"
[ "$(stat -c %a /tmp/rec/.tls)" = 700 ] || fail "droits de .tls : $(stat -c %a /tmp/rec/.tls)"
[ "$(stat -c %a /tmp/rec/.tls/server.key)" = 600 ] || fail "droits de server.key : $(stat -c %a /tmp/rec/.tls/server.key)"
grep -q "^rtmpServerKey: /tmp/rec/.tls/server.key" /tmp/rt-emission-ok.yml || fail "chemin de clé non injecté"
grep -q "^rtmpAddress: :1935" /tmp/rt-emission-ok.yml || fail "le RTMP en clair a disparu"
grep -rqF "$TOKEN" /tmp/acme-emission-ok || fail "le faux acme.sh n'a pas écrit le jeton : contrôle non significatif"
if grep -rlF "$TOKEN" /tmp/rec; then fail "le jeton Cloudflare est écrit sur le volume"; fi
echo "   jeton : présent dans le dossier éphémère /tmp/acme-emission-ok, absent de tout fichier sous le volume"
[ -z "$(ls /tmp/rec/.tls | grep -v -x -e server.crt -e server.key -e keep)" ] || fail "fichiers inattendus dans .tls : $(ls /tmp/rec/.tls)"

fresh_volume
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /tmp/rec/.tls/server.key -out /tmp/rec/.tls/server.crt -days 10 -subj "/CN=ingest.arobase-live.com" 2>/dev/null
run expire-dans-10-jours ok CF_Token=$TOKEN CF_Zone_ID=zone FAKE_ACME_SLEEP=30
[ "$enc" = optional ] || fail "certificat valide à 10 jours : rtmpEncryption devrait être optional"
[ "$dt" -le 5 ] || fail "certificat valide à 10 jours : démarrage en $dt s (attendu immédiat, l'émission doit être en arrière-plan)"
grep -q "expires within 30 days, renewing in background" /tmp/log-expire-dans-10-jours.txt || fail "le renouvellement en arrière-plan n'est pas signalé"
grep -q "publish permissions configured" /tmp/log-expire-dans-10-jours.txt || fail "start.sh ne va pas au bout"
echo "TLS start.sh : OK (sans CF → RTMP seul ; échec → RTMP seul signalé ; émission → optional, 700/600, jeton hors volume ; certificat à 10 jours → démarrage immédiat, renouvellement en arrière-plan ; .tls épargné par le nettoyage)"
