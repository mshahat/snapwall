"""SnapWall — a tiny stateful app built to show off cloud native delivery.

Code and config arrive from Git (GitOps). State — photos, guestbook notes and a
per-second heartbeat — lives on a ReadWriteOnce volume, so the audience can
watch it survive pod deletions, rescheduling and upgrades.
"""

import hashlib
import os
import shutil
import socket
import sqlite3
import threading
import time
import uuid
from contextlib import closing
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, render_template, request, send_from_directory

# ---------------------------------------------------------------------------
# Configuration (injected by the Helm chart as environment variables)
# ---------------------------------------------------------------------------

DATA_DIR = os.environ.get("DATA_DIR", "./data")
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
APP_NAME = os.environ.get("APP_NAME", "SnapWall")
EVENT_NAME = os.environ.get("EVENT_NAME", ".NEXT on Tour 🇿🇦")
HEADLINE = os.environ.get("HEADLINE", "Run NKP")
TAGLINE = os.environ.get("TAGLINE", "Built in minutes. Shipped by Git. Running anywhere.")
ACCENT = os.environ.get("ACCENT", "#0A84FF")
THEME = os.environ.get("THEME", "dark")
IMAGE = os.environ.get("IMAGE", "local/snapwall:dev")
# Per-cluster identity comes from a ConfigMap in the pod's namespace (see the chart),
# so a snapshot restored into another cluster picks up that cluster's values.
CLUSTER_NAME = os.environ.get("CLUSTER_NAME") or "unknown"
INGRESS_HOST = os.environ.get("INGRESS_HOST", "")
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "local")
NODE_NAME = os.environ.get("NODE_NAME", "localhost")
PVC_NAME = os.environ.get("PVC_NAME", "local-disk")
WRITE_INTERVAL = float(os.environ.get("WRITE_INTERVAL", "1"))

DB_PATH = os.path.join(DATA_DIR, "snapwall.db")
LOG_PATH = os.path.join(DATA_DIR, "heartbeat.log")
PHOTO_DIR = os.path.join(DATA_DIR, "photos")
LOG_MAX_BYTES = 20 * 1024 * 1024
HEARTBEAT_RETENTION = 24 * 3600
WALL_SIZE = 4
STARTED_AT = time.time()

# Changes whenever anything delivered through Git changes; the UI uses it to
# notice a new rollout and refresh itself.
CONFIG_HASH = hashlib.sha1(
    "|".join([APP_VERSION, HEADLINE, TAGLINE, ACCENT, THEME, EVENT_NAME, APP_NAME]).encode()
).hexdigest()[:12]

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024 * 1024
_db_lock = threading.Lock()
_boot_id = None


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def init_storage():
    global _boot_id
    os.makedirs(PHOTO_DIR, exist_ok=True)
    with _db_lock, closing(db()) as conn, conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS boots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pod TEXT NOT NULL, node TEXT NOT NULL, version TEXT NOT NULL,
                started_at REAL NOT NULL, last_seen REAL NOT NULL,
                cluster TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS heartbeats (ts INTEGER NOT NULL, pod TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS heartbeats_ts ON heartbeats (ts);
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL, pod TEXT NOT NULL, created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS photos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL UNIQUE, name TEXT NOT NULL, bytes INTEGER NOT NULL,
                pod TEXT NOT NULL, created_at REAL NOT NULL
            );
            INSERT OR IGNORE INTO meta (key, value) VALUES ('writes', '0');
            """
        )
        conn.execute(
            "INSERT OR IGNORE INTO meta (key, value) VALUES ('created_at', ?)", (str(time.time()),)
        )
        # Volumes written by earlier versions gain the cluster column in place.
        if "cluster" not in {r["name"] for r in conn.execute("PRAGMA table_info(boots)")}:
            conn.execute("ALTER TABLE boots ADD COLUMN cluster TEXT NOT NULL DEFAULT ''")
        cur = conn.execute(
            "INSERT INTO boots (pod, node, version, started_at, last_seen, cluster) VALUES (?, ?, ?, ?, ?, ?)",
            (POD_NAME, NODE_NAME, APP_VERSION, STARTED_AT, STARTED_AT, CLUSTER_NAME),
        )
        _boot_id = cur.lastrowid
    append_log(f"boot pod={POD_NAME} node={NODE_NAME} cluster={CLUSTER_NAME} version={APP_VERSION}")


def append_log(message):
    if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
        os.replace(LOG_PATH, LOG_PATH + ".1")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(f"{stamp} {message}\n")
        fh.flush()
        os.fsync(fh.fileno())


def write_heartbeat():
    now = time.time()
    with _db_lock, closing(db()) as conn, conn:
        conn.execute("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'writes'")
        conn.execute("INSERT INTO heartbeats (ts, pod) VALUES (?, ?)", (int(now), POD_NAME))
        conn.execute("UPDATE boots SET last_seen = ? WHERE id = ?", (now, _boot_id))
        writes = int(conn.execute("SELECT value FROM meta WHERE key = 'writes'").fetchone()[0])
        if writes % 600 == 0:
            conn.execute("DELETE FROM heartbeats WHERE ts < ?", (int(now) - HEARTBEAT_RETENTION,))
    append_log(f"write #{writes} pod={POD_NAME}")


def writer_loop():
    while True:
        try:
            write_heartbeat()
        except Exception as exc:  # keep writing even if one tick fails
            app.logger.error("heartbeat failed: %s", exc)
        time.sleep(WRITE_INTERVAL)


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass  # file removed mid-walk
    return total


def sniff_image(head):
    """Trust the bytes, not the filename or the client's content type."""
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return None


def photo_json(row):
    return dict(
        id=row["id"], url=f"/photos/{row['filename']}", name=row["name"],
        bytes=row["bytes"], pod=row["pod"], created_at=row["created_at"],
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.after_request
def harden(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@app.get("/")
def index():
    return render_template(
        "index.html",
        app_name=APP_NAME, event_name=EVENT_NAME, headline=HEADLINE, tagline=TAGLINE,
        accent=ACCENT, theme=THEME, version=APP_VERSION, config_hash=CONFIG_HASH,
    )


@app.get("/api/state")
def state():
    now = time.time()
    with closing(db()) as conn:
        writes = int(conn.execute("SELECT value FROM meta WHERE key = 'writes'").fetchone()[0])
        created_at = float(conn.execute("SELECT value FROM meta WHERE key = 'created_at'").fetchone()[0])
        boots_total = conn.execute("SELECT COUNT(*) FROM boots").fetchone()[0]
        boots = [dict(r) for r in conn.execute(
            "SELECT pod, node, cluster, version, started_at, last_seen FROM boots ORDER BY id DESC LIMIT 4"
        )]
        rows = conn.execute(
            "SELECT ts, pod FROM heartbeats WHERE ts > ? ORDER BY ts", (int(now) - 60,)
        ).fetchall()
        notes = [dict(r) for r in conn.execute(
            "SELECT text, pod, created_at FROM notes ORDER BY id DESC LIMIT 3"
        )]
        photos = [photo_json(r) for r in conn.execute(
            "SELECT * FROM photos ORDER BY id DESC LIMIT ?", (WALL_SIZE,)
        )]
        photos_total = conn.execute("SELECT COUNT(*) FROM photos").fetchone()[0]

    # One slot per second for the last 60 seconds: which pod (if any) wrote.
    by_second = {r["ts"]: r["pod"] for r in rows}
    timeline = [by_second.get(int(now) - i) for i in range(59, -1, -1)]

    fs = os.statvfs(DATA_DIR)
    return jsonify(
        pod=POD_NAME, namespace=POD_NAMESPACE, node=NODE_NAME, cluster=CLUSTER_NAME,
        ingress_host=INGRESS_HOST, image=IMAGE,
        version=APP_VERSION, config_hash=CONFIG_HASH, uptime=now - STARTED_AT,
        storage=dict(
            pvc=PVC_NAME, path=os.path.abspath(DATA_DIR), writes=writes,
            used_bytes=dir_size(DATA_DIR), capacity_bytes=fs.f_blocks * fs.f_frsize,
            first_write_at=created_at,
        ),
        timeline=timeline, boots=boots, boots_total=boots_total,
        notes=notes, photos=photos, photos_total=photos_total, server_time=now,
    )


@app.post("/api/notes")
def add_note():
    text = (request.get_json(silent=True) or {}).get("text", "").strip()[:80]
    if not text:
        return jsonify(error="empty note"), 400
    with _db_lock, closing(db()) as conn, conn:
        conn.execute(
            "INSERT INTO notes (text, pod, created_at) VALUES (?, ?, ?)", (text, POD_NAME, time.time())
        )
    append_log(f"note pod={POD_NAME} text={text!r}")
    return jsonify(ok=True), 201


@app.get("/api/photos")
def list_photos():
    with closing(db()) as conn:
        return jsonify(photos=[photo_json(r) for r in conn.execute("SELECT * FROM photos ORDER BY id DESC")])


@app.post("/api/photos")
def upload_photos():
    files = request.files.getlist("photo")
    if not files:
        return jsonify(error="no photos in request"), 400

    saved, rejected = 0, []
    for upload in files:
        ext = sniff_image(upload.stream.read(16))
        upload.stream.seek(0)
        if not ext:
            rejected.append(upload.filename)
            continue
        filename = f"{int(time.time())}-{uuid.uuid4().hex[:8]}.{ext}"
        path = os.path.join(PHOTO_DIR, filename)
        with open(path, "wb") as out:
            shutil.copyfileobj(upload.stream, out)
            out.flush()
            os.fsync(out.fileno())
        size = os.path.getsize(path)
        with _db_lock, closing(db()) as conn, conn:
            conn.execute(
                "INSERT INTO photos (filename, name, bytes, pod, created_at) VALUES (?, ?, ?, ?, ?)",
                (filename, (upload.filename or filename)[:120], size, POD_NAME, time.time()),
            )
        append_log(f"photo pod={POD_NAME} file={filename} bytes={size}")
        saved += 1

    if not saved:
        return jsonify(error="only JPEG, PNG, WebP or GIF images", rejected=rejected), 415
    return jsonify(saved=saved, rejected=rejected), 201


@app.delete("/api/photos/<int:photo_id>")
def delete_photo(photo_id):
    with _db_lock, closing(db()) as conn, conn:
        row = conn.execute("SELECT filename FROM photos WHERE id = ?", (photo_id,)).fetchone()
        if not row:
            abort(404)
        conn.execute("DELETE FROM photos WHERE id = ?", (photo_id,))
    try:
        os.remove(os.path.join(PHOTO_DIR, row["filename"]))
    except FileNotFoundError:
        pass
    append_log(f"photo-deleted pod={POD_NAME} file={row['filename']}")
    return jsonify(ok=True)


@app.get("/photos/<path:filename>")
def photo_file(filename):
    # Filenames are unique and never rewritten, so browsers may cache them forever.
    return send_from_directory(PHOTO_DIR, filename, max_age=31536000)


@app.errorhandler(413)
def too_large(_err):
    return jsonify(error="upload too large (64 MB max per request)"), 413


@app.get("/healthz")
def healthz():
    return "ok"


@app.get("/readyz")
def readyz():
    with closing(db()) as conn:
        conn.execute("SELECT 1").fetchone()
    return "ready"


init_storage()
threading.Thread(target=writer_loop, name="heartbeat-writer", daemon=True).start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), debug=False)
