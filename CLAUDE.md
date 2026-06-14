# CLAUDE.md — ARObase STREAM (infra streaming)

> Doc de reprise pour Claude Code. Lue automatiquement à chaque session dans ce repo.

## 1. C'est quoi

Couche **ingest + diffusion vidéo** du produit ARObase LIVE (live shopping de défilés).
- **Ingest** : OBS (backstage) pousse en **RTMP** → MediaMTX.
- **Diffusion** : MediaMTX transmuxe en **HLS** ; nginx expose le tout sur un port public unique ; hls.js le lit côté navigateur.
- **Replay** : MediaMTX enregistre chaque stream (fMP4, 7 j) et sert la rediffusion.
- **Webhook** : à chaque start/stop de stream, MediaMTX notifie le backend Node (`arobase-live` `/api/stream/event`).

> Repos liés : **arobase-live** (backend qui proxy `/hls` → ce serveur:8888 et résout les URLs replay), **arobase-clip** (lit le HLS pour la reco). Flux global : `arobase-live/CLAUDE.md`.

## 2. Composants

| Fichier | Rôle |
|---|---|
| `mediamtx` | binaire MediaMTX **v1.9.3** (téléchargé au build, ne pas lire/éditer) |
| `mediamtx.yml` | config MediaMTX (protocoles, ports, recording, hooks webhook) |
| `nginx.conf` | reverse-proxy port public `8888` → HLS/replay + service direct des recordings |
| `start.sh` | nettoyage disque (LRU si >80%) puis lance nginx (bg) + MediaMTX (fg) |
| `Dockerfile` | `alpine:3.20` + nginx + MediaMTX ; ports `8888` (public) et `1935` (RTMP) |

## 3. Ports & protocoles (`mediamtx.yml`)

| Port | Protocole | Exposé | Note |
|---|---|---|---|
| `1935` | RTMP ingest | public (Railway TCP proxy) | OBS push `rtmp://host/live/<stream_key>` |
| `8889` | HLS | interne (proxifié par nginx) | `hlsSegmentCount: 8`, `hlsSegmentDuration: 1s`, `hlsAllowOrigin: '*'` |
| `9998` | Playback/replay | interne (proxy nginx `/replay/`) | mux MP4 progressif on-the-fly |
| `9997` | API REST MediaMTX | **localhost only** | `apiAddress: 127.0.0.1:9997` (F7) — non joignable de l'extérieur |
| `8888` | nginx public | public | route `/` → HLS, `/replay/` → :9998, `/playback/` → fichiers recordings |

RTSP / WebRTC / SRT : désactivés.

**Recording** : `record: yes`, `recordPath: /recordings/%path/...`, `recordFormat: fmp4`, segments 60 min, `recordDeleteAfter: 168h` (7 j). Volume Railway 5 GB ; `start.sh` purge en LRU si >80%.

## 4. Webhook backend (`mediamtx.yml` paths.all_others)

- `runOnReady` → POST `{"event":"ready","path":"$MTX_PATH"}` à `https://www.arobase-live.com/api/stream/event`.
- `runOnNotReady` → POST `{"event":"disconnect",...}` (le backend passe le show en `Replay` + envoie les emails recap/replay).
- En-tête d'auth : `x-stream-secret: <secret>` (comparé à `STREAM_WEBHOOK_SECRET` côté backend).

## 5. nginx (`nginx.conf`)

- `location /` → proxy `127.0.0.1:8889` (HLS live).
- `location /replay/` → proxy `127.0.0.1:9998` (API playback MediaMTX) ; CORS `*`.
- `location /playback/` → `alias /recordings/` ; sert directement les fMP4 ; `autoindex on` (listing JSON) ; CORS `*` ; cache 1 j.

## 6. Commandes

```bash
# Env requis : STREAM_PUBLISH_PASSWORD (auth RTMP) + STREAM_WEBHOOK_SECRET (webhook)
docker build -t arobase-stream .
docker run -p 8888:8888 -p 1935:1935 \
  -e STREAM_PUBLISH_PASSWORD="$(openssl rand -hex 24)" \
  -e STREAM_WEBHOOK_SECRET="$(openssl rand -hex 24)" \
  -v $(pwd)/recordings:/recordings arobase-stream
# OBS : Serveur rtmp://<host>:1935/live  |  Clé: <stream_key>?user=publisher&pass=<STREAM_PUBLISH_PASSWORD>
# Lecture HLS (viewers, anonyme) : http://<host>:8888/live/<stream_key>/index.m3u8
```

## 7. Sécurité (détail + audit : `../arobase-live/docs/SECURITY-AUDIT-2026-06.md`)

**Corrigé** :
- ✅ **F1** secret webhook → env `STREAM_WEBHOOK_SECRET` (plus de hardcode ; l'ancien `arobase_stream_webhook_2026` reste dans l'historique git → **à roter**).
- ✅ **F2** auth RTMP : `authMethod: internal` + user `publisher` (mot de passe injecté au boot par `start.sh` depuis `STREAM_PUBLISH_PASSWORD`). Les viewers gardent un accès HLS/replay anonyme (`read`+`playback`).
- ✅ **F7** API/metrics/pprof → `apiAddress: 127.0.0.1:9997` (localhost only).
- ✅ **F11** `autoindex off` sur `/playback/`.
- ✅ **F15** CORS restreint à `https://www.arobase-live.com` + en-têtes de sécurité nginx.

**Variables d'env requises au déploiement** : `STREAM_PUBLISH_PASSWORD` (alphanumérique, ex. `openssl rand -hex 24`) et `STREAM_WEBHOOK_SECRET`. Sans `STREAM_PUBLISH_PASSWORD`, `start.sh` **refuse de démarrer** (fail loud volontaire).

**⚠️ Coordination déploiement** : activer l'auth RTMP **casse l'ingest OBS tant qu'OBS n'est pas reconfiguré** avec `?user=publisher&pass=<password>` dans la clé. Déployer + reconfigurer OBS **ensemble** et **tester sur un stream de répétition** avant un vrai défilé.

**Reste ouvert** : F3 (RLS `brand_accounts`/`stream_key` côté Supabase, dans arobase-live — le `stream_key` reste lisible en anon tant que F3 n'est pas fait, ce qui affaiblit l'intérêt de garder le mot de passe publish secret).

## 8. Gotchas

- **B-frames cassent le muxing** HLS depuis OBS → encoder OBS sans B-frames (mémoire `feedback_obs_mediamtx_gotchas`).
- `hlsSegmentCount: 8` (8 s de buffer) : ne pas redescendre à 3 — provoquait des freezes viewers (404 sur segments déjà purgés).
- Plusieurs shows d'une même marque **partagent le `stream_key`** → le backend choisit la session replay la plus proche de la date du show.
- MediaMTX 1.9.3 est **pinné** dans le Dockerfile (`ARG MEDIAMTX_VERSION`) — vérifier les CVE avant bump.
