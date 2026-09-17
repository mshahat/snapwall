# SnapWall

A stateful Flask photo wall for live cloud native demos. Designed for a 16:9 projector.

- **Code & config come from Git.** Flux deploys the Helm chart. Change a value, push, and the screen announces the rollout.
- **State lives on a ReadWriteOnce volume.** Photos, guestbook notes and a per-second heartbeat are all stored on disk. Delete the pod, and all of it is still there.

No CDNs, no web fonts, no external calls. It works on stage Wi‑Fi (or with none).

```
app/                 Flask app (app.py, templates, static)
charts/snapwall/     Helm chart (Deployment · Recreate, PVC · RWO, Service, Ingress)
deploy/flux/         GitRepository + HelmRelease
.github/workflows/   Builds the image to ghcr.io
```

## Run locally

**VS Code:** open this folder, press **F5**, and choose **SnapWall (Flask)**. Open http://localhost:8080.
(The interpreter is preset to `.venv`. If it's missing, create it with the terminal steps below.)

**Terminal:**

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
DATA_DIR=./data .venv/bin/python app/app.py      # http://localhost:8080
```

Data is written to `./data` (`snapwall.db`, `photos/`, `heartbeat.log`). Delete that folder to start fresh.

## Ship it

1. Push the repo to GitHub. The workflow builds `ghcr.io/<owner>/snapwall` on every push to `main`, and a `v1.1.0` tag publishes `:1.1.0`.
   Make the package public, or add an `imagePullSecret`.
2. Create the per-cluster ConfigMap: `kubectl apply -f deploy/cluster-config/nkp-onprem-joburg.yaml`
3. `kubectl apply -f deploy/flux/snapwall.yaml`

Why one replica with the `Recreate` strategy? A RWO volume attaches to one node at a time. A rolling update would start the new pod before the old one releases the disk, and the rollout would get stuck. `Recreate` stops the old pod first.

## Stage runbook

| # | Beat | Do | Screen |
|---|------|----|--------|
| 1 | *"We vibe-coded this app."* | Show the repo in VS Code | — |
| 2 | *"Git is the only interface."* | Show `deploy/flux/snapwall.yaml`; `flux get helmreleases -A` | Live · cluster, node, pod |
| 3 | *"Let's put something on the disk."* | Drag two photos onto the page (or press **U**) | Photos fill the wall |
| 4 | *"And the room signs the guestbook."* | Press **N** and type a note | Note appears |
| 5 | *"Proof it's a real disk."* | `kubectl -n snapwall exec deploy/snapwall -- ls -lh /data/photos` | — |
| 6 | *"Now let's break it."* | `kubectl -n snapwall delete pod -l app.kubernetes.io/name=snapwall` | Amber **Pod unavailable · 6s**, then **New pod. Same data.** Photos still there, lineage adds a generation |
| 7 | *"Ship a change with a commit."* | Edit `app.accent` to `"#BF5AF2"` in `values.yaml`, then commit and push. For speed: `flux reconcile source git snapwall` | **New configuration live** |
| 8 | *"Ship new code."* | Tag `v1.1.0`, then set `image.tag: "1.1.0"` | **Now running v1.1.0** |

Rehearse once: the first pull of a new image on a node takes a few seconds.

**Presenter keys:** `F` fullscreen · `U` upload photos · `N` new note · `Esc` close.
Click a photo to view it full screen. In that view, `←` `→` switch photos, and `Delete` (pressed twice) removes one.

The 🇿🇦 flag emoji renders on macOS but not on Windows. Present from a Mac.

## Configuration

Everything under `app:` in [values.yaml](charts/snapwall/values.yaml) is shown on screen: `name`, `eventName`, `headline`, `tagline`, `accent`, `theme` (`dark`/`light`), `writeInterval`.

### Per-cluster identity

`cluster.name` and `ingress.host` are not Helm values. They come from ConfigMap `snapwall-cluster` in the `snapwall` namespace, which the pod reads when it starts. The Deployment is therefore identical in every cluster, and an app snapshot restored into another cluster shows *that* cluster's name. See the examples in [deploy/cluster-config/](deploy/cluster-config/).

- Create the ConfigMap in each cluster before the app arrives, and keep it out of app snapshots. It's labelled `snapwall-cluster-config: "true"`.
- After editing it, run `kubectl -n snapwall rollout restart deploy/snapwall` to update the screen, and `flux reconcile hr snapwall -n kommander-flux --force` to update the Ingress host.
- Helm reads `ingress.host` from the ConfigMap at install/upgrade and sets it as the Ingress host. A non-empty `ingress.host` Helm value overrides it. If neither is set, the Ingress answers on any hostname.
- A restored app snapshot brings the Ingress with the *source* cluster's host. It only answers that name until Flux upgrades the release in the new cluster.
- Pod lineage records each pod's cluster, so after a restore the wall reads `nkp-onprem-joburg → nkp-nc2-azure`.
Set `persistence.enabled: false` to use an `emptyDir` instead. Deleting the pod then wipes the wall, which is a useful contrast.

Photos: JPEG, PNG, WebP or GIF. Large photos are downscaled to 2560px in the browser before upload. Safari can also convert HEIC.

| Endpoint | Purpose |
|----------|---------|
| `/` | Stage UI |
| `/api/state` | JSON the UI polls every second |
| `GET/POST /api/photos` | List photos / upload (`photo` form field, multiple allowed) |
| `DELETE /api/photos/<id>` | Remove a photo |
| `POST /api/notes` | `{"text": "..."}` writes a guestbook note |
| `/healthz`, `/readyz` | Probes |


-- 

Steps 
1. Apply the configmaps in each cluster
2. Apply the ingress in the second cluster
3. Deploy NDK
4. Configure NDK for SnapWall
5. Deploy Snapwall using FluxCD in ns snapwall
6. Deploy podinfo as SnapWall Backend (snapwall-be) in ns snapwall-be