#!/bin/bash
# 06/11 : multidiffusion vers 3 destinations RTMP, sur 4 serveurs MediaMTX locaux (127.0.0.1) :
# un « programme » et trois serveurs qui jouent YouTube, Instagram et TikTok. Aucune vraie clé.
# Une mire 1080p30 (H.264 4 Mb/s, AAC) est publiée sur le programme, multistream/push.sh la
# pousse vers les trois. Toutes les 10 s : octets reçus par chaque destination, CPU de push.sh.
# Réussite : chaque destination reçoit des octets à chaque intervalle, sur toute la durée.
# Usage : bash test/multistream.sh <binaire mediamtx> <durée en s> <dossier de sortie>
set -u
BIN=$1; DUR=$2; OUT=$3; mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

serve() { # $1 nom, $2 port RTMP, $3 port API
  cat > "$OUT/$1.yml" <<EOF
logLevel: warn
api: yes
apiAddress: 127.0.0.1:$3
rtmp: yes
rtmpAddress: 127.0.0.1:$2
rtsp: no
hls: no
webrtc: no
srt: no
playback: no
moq: no
authInternalUsers:
  - user: any
    pass:
    ips: ['127.0.0.1']
    permissions:
      - action: publish
      - action: read
      - action: api
paths:
  all_others:
EOF
  "$BIN" "$OUT/$1.yml" > "$OUT/$1.log" 2>&1 & PIDS+=($!)
}
serve programme 19400 19500
serve youtube 19401 19501
serve instagram 19402 19502
serve tiktok 19403 19503
sleep 2

ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -c:v libx264 -preset veryfast -b:v 4000k -maxrate 4000k -bufsize 8000k -g 60 -pix_fmt yuv420p -c:a aac -b:a 128k \
  -f flv rtmp://127.0.0.1:19400/live/programme > "$OUT/source.log" 2>&1 & PIDS+=($!)
sleep 4

MULTISTREAM_SOURCE=rtmp://127.0.0.1:19400/live/programme \
MULTISTREAM_TARGETS="rtmp://127.0.0.1:19401/live/youtube rtmp://127.0.0.1:19402/live/instagram rtmp://127.0.0.1:19403/live/tiktok" \
  sh "$HERE/multistream/push.sh" > "$OUT/push.log" 2>&1 & PUSH=$!; PIDS+=($PUSH)
sleep 3

bytes() { curl -s "http://127.0.0.1:$1/v3/paths/get/live/$2" | sed -n 's/.*"bytesReceived":\([0-9]*\).*/\1/p'; }
echo "t_s,youtube_octets,instagram_octets,tiktok_octets,cpu_push_pct" > "$OUT/mesures.csv"
prev=(0 0 0); stalls=0; n=0
for ((t = 0; t <= DUR; t += 10)); do
  y=$(bytes 19501 youtube); i=$(bytes 19502 instagram); k=$(bytes 19503 tiktok)
  cpu=$(ps -o %cpu= -p "$PUSH" | tr -d ' ')
  echo "$t,${y:-0},${i:-0},${k:-0},${cpu:-0}" >> "$OUT/mesures.csv"
  cur=(${y:-0} ${i:-0} ${k:-0})
  if [ "$t" -gt 0 ]; then
    for j in 0 1 2; do [ "${cur[$j]}" -gt "${prev[$j]}" ] || { stalls=$((stalls + 1)); echo "arrêt : destination $j à t=$t s"; }; done
    n=$((n + 1))
  fi
  prev=("${cur[@]}")
  [ "$t" -lt "$DUR" ] && sleep 10
done
kill -0 "$PUSH" 2>/dev/null || { echo "ÉCHEC : push.sh s'est arrêté"; exit 1; }
echo "intervalles mesurés : $n ; arrêts : $stalls"
[ "$stalls" -eq 0 ] && [ "$n" -gt 0 ] || { echo "ÉCHEC : au moins une destination a cessé de recevoir"; exit 1; }
echo "multidiffusion 3 destinations, ${DUR} s sans coupure : OK"
