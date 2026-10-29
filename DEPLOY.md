# Déploiement ARObase STREAM — checklist (F1 + F2 + F7)

> ⚠️ Ce repo introduit l'**auth RTMP** (F2) et le **secret webhook par env** (F1).
> Déployer sans cette prépa **casse le stream**. À faire sur un **stream de
> répétition** avant un vrai défilé.

## Ce qui change vs l'ancienne version

| Avant | Après |
|---|---|
| RTMP ouvert (n'importe qui peut pousser) | RTMP exige l'utilisateur `publisher` + mot de passe |
| Secret webhook `[valeur retirée — sha256 de271117f3ce…]` en clair dans `mediamtx.yml` | lu depuis `$STREAM_WEBHOOK_SECRET` (env) |
| API MediaMTX `:9997` joignable | API liée à `127.0.0.1` (interne) |
| `autoindex on` sur `/playback/` | désactivé, CORS restreint à l'app |

## 1. Générer les secrets (une fois)

```bash
# Mot de passe de publication RTMP (alphanumérique — requis par le sed de start.sh)
openssl rand -hex 24    # → STREAM_PUBLISH_PASSWORD
# Nouveau secret webhook (l'ancien est compromis : il reste dans l'historique git)
openssl rand -hex 24    # → STREAM_WEBHOOK_SECRET
```

Note-les : tu en as besoin sur **deux** services Railway.

## 2. Variables d'environnement Railway

### Service **stream** (ce repo)
| Variable | Valeur | Effet si absente |
|---|---|---|
| `STREAM_PUBLISH_PASSWORD` | mot de passe généré (étape 1) | `start.sh` **refuse de booter** (fail loud) |
| `STREAM_WEBHOOK_SECRET` | secret webhook généré (étape 1) | header webhook vide → backend renvoie 403 → pas de passage en Replay |

### Service **live** (backend, repo arobase-live)
| Variable | Valeur | Effet si désaligné |
|---|---|---|
| `STREAM_WEBHOOK_SECRET` | **exactement la même** valeur que côté stream | mismatch → webhook 403 → pas de Replay/emails |

```bash
# Via Railway CLI (vérifier d'abord le bon service/workspace : railway status)
railway variables --set "STREAM_PUBLISH_PASSWORD=<valeur>" --set "STREAM_WEBHOOK_SECRET=<valeur>"   # service stream
railway variables --set "STREAM_WEBHOOK_SECRET=<valeur>"                                            # service live
```

## 3. Reconfigurer OBS

| Champ OBS | Valeur |
|---|---|
| Serveur | `rtmp://<host-stream>:1935/live` |
| Clé de stream | `<stream_key>?user=publisher&pass=<STREAM_PUBLISH_PASSWORD>` |

> Sans `?user=publisher&pass=…` dans la clé, MediaMTX **refuse la publication**.
> Encoder OBS **sans B-frames** (gotcha muxing HLS, cf. `CLAUDE.md`).

## 4. Ordre de déploiement

1. Poser les variables d'env (étape 2) sur **stream** ET **live**.
2. Déployer **stream** (merge `dev` → `main` ou deploy direct).
3. Vérifier le boot : `railway logs` → MediaMTX démarre (pas d'erreur
   `STREAM_PUBLISH_PASSWORD env var is required`).
4. Reconfigurer OBS (étape 3) et lancer un **stream de test**.
5. Vérifier dans l'ordre (étape 5).
6. Déployer **live** + **clip** (sûrs, indépendants).

## 5. Tests de validation (stream de répétition)

- [ ] OBS se connecte et publie (pas d'erreur "Failed to connect" / auth refusée).
- [ ] HLS lisible côté viewer **anonyme** : `https://<host>:8888/live/<key>/index.m3u8` répond.
- [ ] Lecture vidéo OK sur `/live/<show-id>` dans l'app (pas d'écran noir).
- [ ] Push **non authentifié** refusé : OBS sans `?user=publisher&pass=…` → connexion rejetée.
- [ ] Webhook OK : à l'arrêt du stream, le show passe en `Replay` (logs backend
      `Stream ended — shows set to Replay`), pas de 403.
- [ ] API interne fermée : `curl http://<host-public>:9997/v3/paths/list` → injoignable.
- [ ] Replay lisible : `/replay/<show-id>` joue la rediffusion.

## 6. Rollback rapide

Si l'ingest casse en répétition :
- Le plus rapide : remettre OBS avec une clé sans auth **ne marchera pas** (auth active). Donc soit corriger la clé OBS (`?user=publisher&pass=…`), soit revert le service stream sur le déploiement précédent (Railway → Deployments → Redeploy l'ancien).
- Si seul le webhook échoue (403) : c'est un désalignement `STREAM_WEBHOOK_SECRET` entre stream et live → réaligner les deux valeurs.

## 7. Après bascule réussie

- Roter définitivement l'ancien secret `[valeur retirée — sha256 de271117f3ce…]` (déjà fait via l'env, mais il reste dans l'historique git — ne jamais le réutiliser).
- F3 (RLS `brand_accounts`) est indépendant et suit son propre runbook
  (`arobase-live/docs/SECURITY-AUDIT-2026-06.md` §Runbook F3).
