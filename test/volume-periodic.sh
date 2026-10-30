#!/bin/sh
# A4b : le nettoyage tourne aussi pendant que le conteneur vit (toutes les
# CLEANUP_INTERVAL secondes), pas seulement au démarrage. Volume vide au démarrage,
# rempli à environ 90 % ensuite (faux df, 1000 Ko) : sans redémarrage, il doit
# redescendre sous 60 %, les plus anciens d'abord, .tls intact.
# Usage (dans alpine:3.20, dépôt monté en /w) :
#   sh /w/test/volume-periodic.sh <start.sh à tester> expect-evict|expect-stuck
set -eu
SCRIPT=$1; EXPECT=$2
apk add -q --no-cache $(sed -n 's/^RUN apk add --no-cache //p' /w/Dockerfile) >/dev/null
B=/tmp/bin; mkdir -p $B
printf '#!/bin/sh\nexit 0\n' > $B/nginx
printf '#!/bin/sh\nexec sleep 60\n' > $B/mediamtx
cat > $B/df <<'DF'
#!/bin/sh
used=$(du -sk "$1" | cut -f1)
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "fake 1000 $used $((1000 - used)) $((used * 100 / 1000))% /recordings"
DF
chmod +x $B/*
export PATH=$B:$PATH
REC=/tmp/rec; rm -rf $REC /tmp/stage; mkdir -p $REC/live $REC/.tls /tmp/stage
echo cle > $REC/.tls/server.key
STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a RECORDINGS_DIR=$REC CLEANUP_INTERVAL=2 \
  MEDIAMTX_CONFIG=/w/mediamtx.yml RUNTIME_CONFIG=/tmp/rt.yml sh "$SCRIPT" > /tmp/log.txt 2>&1 &
sleep 1
grep -q "publish permissions configured" /tmp/log.txt || { cat /tmp/log.txt; echo "ÉCHEC : démarrage"; exit 1; }
now=$(date +%s)
age() { touch -t "$(date -d "@$((now - $2 * 60))" +%Y%m%d%H%M.%S)" "$1"; }
for i in $(seq 1 11); do
  f=/tmp/stage/f$(printf %02d $i).mp4
  dd if=/dev/zero of="$f" bs=1024 count=80 2>/dev/null; age "$f" $((i * 10))
done
age $REC/.tls/server.key 600
# Un seul renommage : le volume passe d'un coup à ~90 %, sans course avec le nettoyage.
mv /tmp/stage $REC/live/show
filled=$(df $REC | tail -1 | awk '{print $5}')
sleep 6
after=$(df $REC | tail -1 | awk '{print $5}' | tr -d %)
left=$(ls $REC/live/show | tr '\n' ' ')
echo "== $SCRIPT : rempli après démarrage à $filled, 6 s plus tard $after% ; restants : $left"
grep 'Phase 2' /tmp/log.txt || true
fail() { echo "ÉCHEC : $1"; exit 1; }
[ -f $REC/.tls/server.key ] || fail ".tls touché"
case $EXPECT in
  expect-stuck)
    [ "$after" -gt 80 ] || fail "attendu : rien d'évincé sans redémarrage (référence), occupation $after%"
    echo "rouge confirmé : sans redémarrage, rien n'est évincé" ;;
  expect-evict)
    [ "$after" -lt 60 ] || fail "occupation encore à $after%"
    n=$(ls $REC/live/show | wc -l)
    [ "$left" = "$(seq 1 $n | while read i; do printf 'f%02d.mp4 ' $i; done)" ] || fail "ordre d'éviction : $left"
    echo "vert : $((11 - n)) plus anciens évincés sans redémarrage, .tls intact" ;;
  *) fail "usage" ;;
esac
