#!/bin/sh
# R2 : nginx ne doit jamais servir un fichier sous un segment caché (/recordings/.tls/server.key).
# Usage : test/hidden-paths.sh <nginx.conf> <expect-leak|expect-clean>
set -eu
conf=$1; mode=$2
rec=$(mktemp -d); mkdir -p "$rec/.tls" "$rec/live/x"
echo "SECRET-KEY-MARKER-R2" > "$rec/.tls/server.key"
echo "RECORDING-OK" > "$rec/live/x/seg.mp4"
chmod -R a+rX "$rec"
cid=$(docker run -d --rm --network host -v "$(realpath "$conf"):/etc/nginx/nginx.conf:ro" -v "$rec:/recordings:ro" nginx:alpine)
trap 'docker stop "$cid" >/dev/null 2>&1 || true; rm -rf "$rec"' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8888/playback/live/x/seg.mp4 && break; sleep 0.5; done
ok=$(curl -s -w ' %{http_code}' --path-as-is http://127.0.0.1:8888/playback/live/x/seg.mp4 | tr -d '\n')
echo "enregistrement normal -> $ok"
case "$ok" in *"RECORDING-OK 200") ;; *) echo "ÉCHEC : un enregistrement normal n'est plus servi"; exit 1;; esac
leaks=0
for p in \
  /playback/.tls/server.key \
  /playback/%2etls/server.key \
  /playback/%2Etls/server.key \
  /playback/%252etls/server.key \
  //playback//.tls//server.key \
  /playback/./.tls/server.key \
  /playback/live/../.tls/server.key \
  /playback/live/%2e%2e/.tls/server.key \
  /playback/live/..%2f.tls/server.key \
  /playback/.tls%2fserver.key \
  /playback/%2e%74%6c%73/server.key \
  /playback/live/x/../../.tls/server.key \
  /.tls/server.key \
  /playback/.tls/
do
  r=$(curl -s -w ' %{http_code}' --path-as-is "http://127.0.0.1:8888$p" | tr -d '\n')
  if echo "$r" | grep -q SECRET-KEY-MARKER-R2; then echo "FUITE  $p -> ${r##* }"; leaks=$((leaks+1)); else echo "ok     $p -> ${r##* }"; fi
done
case "$mode" in
  expect-leak)  [ $leaks -gt 0 ] && echo "ROUGE attendu : $leaks variante(s) servent la clé sur cette config" || { echo "ÉCHEC : fuite attendue mais absente"; exit 1; } ;;
  expect-clean) [ $leaks -eq 0 ] && echo "VERT : aucune variante ne sert la clé" || { echo "ÉCHEC : $leaks fuite(s)"; exit 1; } ;;
esac
