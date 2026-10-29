#!/bin/sh
# B9 : l'API playback de MediaMTX ne doit pas révéler de chemin disque à travers nginx.
# Usage : test/replay-errors.sh <nginx.conf> <expect-leak|expect-clean>
# Lance un faux playback sur 127.0.0.1:9998 et nginx (docker, réseau hôte) sur 8888.
set -eu
conf=$1; mode=$2
python3 - <<'PY' &
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if "path=live/ok" in self.path:
            body, code = b'[{"start":"2026-10-29T10:00:00Z","duration":60}]', 200
        else:
            body, code = b'{"status":"error","error":"lstat /recordings/live/x: no such file or directory"}', 400
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 9998), H).serve_forever()
PY
stub=$!
cid=$(docker run -d --rm --network host -v "$(realpath "$conf"):/etc/nginx/nginx.conf:ro" nginx:alpine)
trap 'docker stop "$cid" >/dev/null 2>&1 || true; kill $stub 2>/dev/null || true' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8888/replay/list 2>/dev/null && break; sleep 0.5; done
bad=$(curl -s -w '\n%{http_code}' 'http://127.0.0.1:8888/replay/list?path=live/x')
ok=$(curl -s -w '\n%{http_code}' 'http://127.0.0.1:8888/replay/list?path=live/ok')
echo "erreur  -> $(echo "$bad" | tr '\n' ' ')"
echo "succès  -> $(echo "$ok" | tr '\n' ' ')"
echo "$ok" | tail -1 | grep -qx 200 || { echo "ÉCHEC : une réponse 200 de l'API playback ne passe plus"; exit 1; }
if echo "$bad" | grep -q -e lstat -e /recordings; then leak=yes; else leak=no; fi
case "$mode" in
  expect-leak)  [ "$leak" = yes ] && echo "ROUGE attendu : la fuite est bien présente sur cette config" || { echo "ÉCHEC : fuite attendue mais absente"; exit 1; } ;;
  expect-clean) [ "$leak" = no ] && echo "$bad" | tail -1 | grep -qx 404 && echo "VERT : aucune fuite, 404 générique" || { echo "ÉCHEC : fuite ou code inattendu"; exit 1; } ;;
esac
