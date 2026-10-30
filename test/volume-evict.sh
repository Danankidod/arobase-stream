#!/bin/sh
# A4 : phase 2 du nettoyage du volume (au-delà de 80 %, éviction des plus anciens
# jusqu'à moins de 60 %), dans les paquets de l'image (Dockerfile), sans findutils.
# Le volume est simulé : un faux df calcule l'occupation de $REC sur une capacité
# de 1000 Ko. 11 fichiers de 80 Ko d'âges différents (≈ 90 %), plus .tls, le plus
# ancien de tous, qui ne doit jamais être touché.
# Usage (dans alpine:3.20, dépôt monté en /w) :
#   sh /w/test/volume-evict.sh <start.sh à tester> expect-evict|expect-stuck
set -eu
SCRIPT=$1; EXPECT=$2
apk add -q --no-cache $(sed -n 's/^RUN apk add --no-cache //p' /w/Dockerfile) >/dev/null
B=/tmp/bin; mkdir -p $B
printf '#!/bin/sh\nexit 0\n' > $B/nginx; cp $B/nginx $B/mediamtx
cat > $B/df <<'DF'
#!/bin/sh
used=$(du -sk "$1" | cut -f1)
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "fake 1000 $used $((1000 - used)) $((used * 100 / 1000))% /recordings"
DF
chmod +x $B/*
export PATH=$B:$PATH
REC=/tmp/rec; rm -rf $REC; mkdir -p $REC/live/show $REC/.tls
now=$(date +%s)
age() { touch -t "$(date -d "@$((now - $2 * 60))" +%Y%m%d%H%M.%S)" "$1"; }
for i in $(seq 1 11); do # f01 = le plus récent (10 min), f11 = le plus ancien (110 min)
  f=$REC/live/show/f$(printf %02d $i).mp4
  dd if=/dev/zero of="$f" bs=1024 count=80 2>/dev/null; age "$f" $((i * 10))
done
echo cle > $REC/.tls/server.key; age $REC/.tls/server.key 600
before=$(df $REC | tail -1 | awk '{print $5}')
STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR=$REC \
  MEDIAMTX_CONFIG=/w/mediamtx.yml RUNTIME_CONFIG=/tmp/rt.yml sh "$SCRIPT" > /tmp/log.txt 2>&1 || true
after=$(df $REC | tail -1 | awk '{print $5}' | tr -d %)
left=$(ls $REC/live/show | tr '\n' ' ')
echo "== $SCRIPT : avant $before, après $after% ; restants : $left"
grep 'Phase 2' /tmp/log.txt || true
fail() { echo "ÉCHEC : $1"; exit 1; }
[ -f $REC/.tls/server.key ] || fail ".tls touché"
case $EXPECT in
  expect-stuck)
    [ "$after" -gt 80 ] || fail "attendu : rien d'évincé (bug de référence), occupation $after%"
    echo "rouge confirmé : rien n'est évincé" ;;
  expect-evict)
    [ "$after" -lt 60 ] || fail "occupation encore à $after%"
    # Les plus anciens partent en premier : les restants sont exactement f01..fN.
    n=$(ls $REC/live/show | wc -l)
    [ "$left" = "$(seq 1 $n | while read i; do printf 'f%02d.mp4 ' $i; done)" ] || fail "ordre d'éviction : $left"
    [ "$n" -ge 6 ] || fail "trop d'éviction : $n restants"
    echo "vert : $((11 - n)) plus anciens évincés, .tls intact" ;;
  *) fail "usage" ;;
esac
