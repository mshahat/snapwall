"""Pulse — a tiny stateful app built to show off cloud native delivery.

Code and config arrive from Git (GitOps). State lives on a ReadWriteOnce
volume. Every second the app writes a heartbeat to disk, so the audience can
watch the data survive pod deletions, rescheduling and upgrades.
"""

import hashlib
import os
import socket
import sqlite3
import threading
import time
from contextlib import closing
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request

# ---------------------------------------------------------------------------
# Configuration (injected by the Helm chart as environment variables)
# ---------------------------------------------------------------------------

DATA_DIR = os.environ.get("DATA_DIR", "./data")
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
APP_NAME = os.environ.get("APP_NAME", "Pulse")
EVENT_NAME = os.environ.get("EVENT_NAME", "Live Demo")
HEADLINE = os.environ.get("HEADLINE", "Hello, Kubernetes.")
TAGLINE = os.environ.get("TAGLINE", "Built in minutes. Shipped by Git. Running anywhere.")
ACCENT = os.environ.get("ACCENT", "#0A84FF")
THEME = os.environ.get("THEME", "dark")
IMAGE = os.environ.get("IMAGE", "local/pulse:dev")
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "local")
NODE_NAME = os.environ.get("NODE_NAME", "localhost")
PVC_NAME = os.environ.get("PVC_NAME", "local-disk")
WRITE_INTERVAL = float(os.environ.get("WRITE_INTERVAL", "1"))

DB_PATH = os.path.join(DATA_DIR, "pulse.db")
LOG_PATH = os.path.join(DATA_DIR, "heartbeat.log")
LOG_MAX_BYTES = 20 * 1024 * 1024
HEARTBEAT_RETENTION = 24 * 3600
STARTED_AT = time.time()

# Changes whenever anything delivered through Git changes; the UI uses it to
# notice a new rollout and refresh itself.
CONFIG_HASH = hashlib.sha1(
    "|".join([APP_VERSION, HEADLINE, TAGLINE, ACCENT, THEME, EVENT_NAME, APP_NAME]).encode()
).hexdigest()[:12]

app = Flask(__name__)
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
    os.makedirs(DATA_DIR, exist_ok=True)
    with _db_lock, closing(db()) as conn, conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS boots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pod TEXT NOT NULL, node TEXT NOT NULL, version TEXT NOT NULL,
                started_at REAL NOT NULL, last_seen REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS heartbeats (ts INTEGER NOT NULL, pod TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS heartbeats_ts ON heartbeats (ts);
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL, pod TEXT NOT NULL, created_at REAL NOT NULL
            );
            INSERT OR IGNORE INTO meta (key, value) VALUES ('writes', '0');
            """
        )
        conn.execute(
            "INSERT OR IGNORE INTO meta (key, value) VALUES ('created_at', ?)", (str(time.time()),)
        )
        cur = conn.execute(
            "INSERT INTO boots (pod, node, version, started_at, last_seen) VALUES (?, ?, ?, ?, ?)",
            (POD_NAME, NODE_NAME, APP_VERSION, STARTED_AT, STARTED_AT),
        )
        _boot_id = cur.lastrowid
    append_log(f"boot pod={POD_NAME} node={NODE_NAME} version={APP_VERSION}")


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
    for entry in os.scandir(path):
        if entry.is_file(follow_symlinks=False):
            total += entry.stat().st_size
    return total


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

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
            "SELECT pod, node, version, started_at, last_seen FROM boots ORDER BY id DESC LIMIT 6"
        )]
        rows = conn.execute(
            "SELECT ts, pod FROM heartbeats WHERE ts > ? ORDER BY ts", (int(now) - 60,)
        ).fetchall()
        notes = [dict(r) for r in conn.execute(
            "SELECT text, pod, created_at FROM notes ORDER BY id DESC LIMIT 3"
        )]
        notes_total = conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0]

    # One slot per second for the last 60 seconds: which pod (if any) wrote.
    by_second = {r["ts"]: r["pod"] for r in rows}
    timeline = [by_second.get(int(now) - i) for i in range(59, -1, -1)]

    fs = os.statvfs(DATA_DIR)
    return jsonify(
        pod=POD_NAME, namespace=POD_NAMESPACE, node=NODE_NAME, image=IMAGE,
        version=APP_VERSION, config_hash=CONFIG_HASH, uptime=now - STARTED_AT,
        storage=dict(
            pvc=PVC_NAME, path=os.path.abspath(DATA_DIR), writes=writes,
            used_bytes=dir_size(DATA_DIR), capacity_bytes=fs.f_blocks * fs.f_frsize,
            first_write_at=created_at,
        ),
        timeline=timeline, boots=boots, boots_total=boots_total,
        notes=notes, notes_total=notes_total, server_time=now,
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
