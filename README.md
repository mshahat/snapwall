# Pulse

A tiny stateful Flask app for live cloud native demos. Designed for a 16:9 projector.

- **Code & config come from Git.** Flux deploys the Helm chart. Change a value, push, and the screen announces the rollout.
- **State lives on a ReadWriteOnce volume.** A heartbeat is written to disk every second. Delete the pod, and the counter, the guestbook and the pod lineage are all still there.

No CDNs, no web fonts, no external calls. It works on stage Wi‑Fi (or with none).

```
app/                 Flask app (app.py, templates, static)
charts/pulse/        Helm chart (Deployment · Recreate, PVC · RWO, Service, Ingress)
deploy/flux/         GitRepository + HelmRelease
.github/workflows/   Builds the image to ghcr.io
```

## Run locally

**VS Code:** open this folder, pick the `.venv` interpreter (`⌘⇧P` → *Python: Select Interpreter*), then press **F5** and choose **Pulse (Flask)**. Open http://localhost:8080.

**Terminal:**

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
DATA_DIR=./data .venv/bin/python app/app.py      # http://localhost:8080
```

Data is written to `./data` (`pulse.db` + `heartbeat.log`). Delete that folder to start fresh.

## Ship it

1. Push the repo to GitHub. The workflow builds `ghcr.io/<owner>/pulse` on every push to `main`, and a `v1.1.0` tag publishes `:1.1.0`.
   Make the package public, or add an `imagePullSecret`.
2. Replace `OWNER` in [deploy/flux/pulse.yaml](deploy/flux/pulse.yaml) and [charts/pulse/values.yaml](charts/pulse/values.yaml).
3. `kubectl apply -f deploy/flux/pulse.yaml`

Why one replica with the `Recreate` strategy? A RWO volume attaches to one node at a time. A rolling update would start the new pod before the old one releases the disk, and the rollout would get stuck. `Recreate` stops the old pod first.

## Stage runbook

| # | Beat | Do | Screen |
|---|------|----|--------|
| 1 | *"We vibe-coded this app."* | Show the repo in VS Code | — |
| 2 | *"Git is the only interface."* | Show `deploy/flux/pulse.yaml`; `flux get helmreleases -A` | Pulse is live, Generation 1 |
| 3 | *"It writes to a real disk."* | `kubectl -n pulse exec deploy/pulse -- tail -f /data/heartbeat.log` | Counter ticking, bars filling |
| 4 | *"Let the room write to it."* | Press **N** and type a note from the audience | Note appears in the guestbook |
| 5 | *"Now let's break it."* | `kubectl -n pulse delete pod -l app.kubernetes.io/name=pulse` | Screen dims to amber **Pod unavailable · 6s**, then **New pod. Same data.** A gap shows in the bars, and lineage adds a generation |
| 6 | *"Ship a change with a commit."* | Edit `app.accent` to `"#BF5AF2"` and `app.headline` in `values.yaml`, then commit and push. For speed: `flux reconcile source git pulse` | **New configuration live**: new color, same counter |
| 7 | *"Ship new code."* | Tag `v1.1.0`, then set `image.tag: "1.1.0"` | **Now running v1.1.0** |

Rehearse once: the first pull of a new image on a node takes a few seconds.

**Presenter keys:** `F` fullscreen · `N` new note · `Esc` dismiss the overlay. Click anywhere on an overlay to close it.

## Configuration

Everything under `app:` in [values.yaml](charts/pulse/values.yaml) is shown on screen: `name`, `eventName`, `headline`, `tagline`, `accent`, `theme` (`dark`/`light`), `writeInterval`.
Set `persistence.enabled: false` to use an `emptyDir` instead. Deleting the pod then resets everything, which is a useful contrast.

| Endpoint | Purpose |
|----------|---------|
| `/` | Stage UI |
| `/api/state` | JSON the UI polls every second |
| `POST /api/notes` | `{"text": "..."}` writes a guestbook note |
| `/healthz`, `/readyz` | Probes |
