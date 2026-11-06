#!/bin/sh
# 06/11 : les 3 angles multicam (liveA, liveB, liveC) sont enregistrés, comme la clé de marque.
# Lance un vrai MediaMTX sur des ports libres, pousse 4 s de mire sur liveA et sur brand-a,
# puis regarde ce qui est écrit sous recordPath.
# Usage : sh test/angles-recorded.sh <mediamtx.yml> <binaire mediamtx> expect-recorded|expect-not-recorded
set -eu
CONF=$1; BIN=$2; EXPECT=$3
T=$(mktemp -d); REC="$T/rec"; mkdir -p "$REC"
sed -e "s|__STREAM_PUBLISH_PASSWORD__|ci-pass|" -e 's|__RTMP_ENCRYPTION__|no|' \
    -e '/rtmpsAddress\|rtmpServerKey\|rtmpServerCert\|runOnReady\|runOnNotReady/d' \
    -e 's|^apiAddress: .*|apiAddress: 127.0.0.1:19997|' -e 's|^hlsAddress: .*|hlsAddress: :18889|' \
    -e 's|^rtmpAddress: .*|rtmpAddress: :19350|' -e 's|^playbackAddress: .*|playbackAddress: :19998|' \
    -e "s|recordPath: /recordings/|recordPath: $REC/|" "$CONF" > "$T/m.yml"
"$BIN" "$T/m.yml" > "$T/mediamtx.log" 2>&1 & PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
for key in liveA brand-a; do
  ffmpeg -loglevel error -re -f lavfi -i testsrc=size=320x240:rate=30 -t 4 -c:v libx264 -preset ultrafast -g 30 \
    -f flv "rtmp://127.0.0.1:19350/live/$key?user=publisher&pass=ci-pass" &
done
wait %2 %3 2>/dev/null || true; sleep 1
has() { [ -n "$(find "$REC/live/$1" -type f -size +0 2>/dev/null | head -1)" ] && echo oui || echo non; }
A=$(has liveA); B=$(has brand-a)
echo "liveA enregistré=$A ; brand-a enregistré=$B"
[ "$B" = oui ] || { echo "ÉCHEC : la clé de marque doit être enregistrée (témoin)"; cat "$T/mediamtx.log"; exit 1; }
case "$EXPECT" in
  expect-recorded) [ "$A" = oui ] || { echo "ÉCHEC : liveA doit être enregistré"; exit 1; } ;;
  expect-not-recorded) [ "$A" = non ] || { echo "ÉCHEC : liveA ne devrait pas être enregistré"; exit 1; } ;;
esac
echo "angles multicam ($EXPECT) : OK"
