#!/bin/sh
# R2 : l'image officielle MediaMTX 1.19.1 démarre avec la config générée par start.sh,
# en "no" (sans fichiers de certificat) puis en "optional" (certificat auto-signé),
# et accepte RTMP en clair et RTMPS (operator) en optional. Réseau hôte du runner CI.
set -eu
w=$(mktemp -d); mkdir -p "$w/.tls" "$w/bin"
printf '#!/bin/sh\nexit 0\n' > "$w/bin/nginx"; cp "$w/bin/nginx" "$w/bin/mediamtx"; chmod +x "$w/bin/"*
gen() { # <encryption>
  docker run --rm -v "$PWD:/w:ro" -v "$w:/out" alpine:3.20 sh -euc "
    apk add -q --no-cache openssl >/dev/null
    STREAM_PUBLISH_MASTER=ci-master STREAM_PUBLISH_KEYS=brand-a MEDIAMTX_CONFIG=/w/mediamtx.yml RUNTIME_CONFIG=/out/rt.yml \
      PATH=/out/bin:\$PATH sh /w/start.sh >/dev/null 2>&1 || true
    sed -i -e 's|^rtmpEncryption: .*|rtmpEncryption: \"$1\"|' -e 's|^rtmpServerKey: .*|rtmpServerKey: /tls/server.key|' -e 's|^rtmpServerCert: .*|rtmpServerCert: /tls/server.crt|' \
      -e 's|^recordPath: .*|recordPath: /tmp/rec/%path/%Y-%m-%d_%H-%M-%S_%f|' -e '/^  runOn/d' /out/rt.yml"
}
start() { docker run -d --rm --network host -v "$w/rt.yml:/mediamtx.yml:ro" -v "$w/.tls:/tls:ro" bluenviron/mediamtx:1.19.1 /mediamtx.yml; }
pw=$(printf '%s' "publish:multicam" | openssl dgst -sha256 -hmac ci-master -r | cut -c1-32)
gen no; c=$(start); sleep 3
logs=$(docker logs "$c" 2>&1); docker stop "$c" >/dev/null
echo "$logs" | grep -E "RTMP|ERR" | sed 's/^/   no : /'
echo "$logs" | grep -q "\[RTMP\] started" || { echo "ÉCHEC : MediaMTX ne démarre pas en no sans certificat"; exit 1; }
echo "$logs" | grep -q "\[RTMPS\]" && { echo "ÉCHEC : RTMPS actif en no"; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$w/.tls/server.key" -out "$w/.tls/server.crt" -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
chmod 644 "$w/.tls/server.key"
gen optional; c=$(start); sleep 3
docker logs "$c" 2>&1 | grep -E "RTMP|ERR" | sed 's/^/   optional : /'
docker logs "$c" 2>&1 | grep -q "\[RTMPS\] started" || { docker stop "$c" >/dev/null; echo "ÉCHEC : RTMPS ne démarre pas en optional"; exit 1; }
push() { timeout 12 ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc=size=320x240:rate=15 -t 6 -c:v libx264 -preset ultrafast -tune zerolatency "$@" > /dev/null 2>&1; }
push -f flv "rtmp://127.0.0.1:1935/live/liveA?user=operator&pass=$pw" && echo "   RTMP en clair (operator) : ACCEPTÉ" || { docker stop "$c" >/dev/null; echo "ÉCHEC : RTMP en clair refusé en optional"; exit 1; }
push -tls_verify 1 -ca_file "$w/.tls/server.crt" -f flv "rtmps://localhost:1936/live/liveB?user=operator&pass=$pw" && echo "   RTMPS vérifié (operator)  : ACCEPTÉ" || { docker stop "$c" >/dev/null; echo "ÉCHEC : RTMPS refusé"; exit 1; }
docker stop "$c" >/dev/null; rm -rf "$w"
echo "MediaMTX 1.19.1 : OK (no → RTMP seul sans certificat ; optional → RTMP + RTMPS)"
