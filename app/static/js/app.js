// SnapWall front-end: polls the pod, animates state, and narrates rollouts.
(() => {
  const $ = (id) => document.getElementById(id);
  const stage = $("stage");
  const PAGE_HASH = stage.dataset.configHash;
  const POLL_MS = 1000;
  const STORE_KEY = "snapwall:last";
  const MAX_EDGE = 2560;            // photos are downscaled in the browser before upload

  let last = null;                  // last successful /api/state payload
  let failures = 0;
  let offlineSince = null;
  let shownWrites = 0;
  let wallKey = null;
  const seenNotes = new Set();
  const seenBoots = new Set();
  const photoTiles = new Map();     // photo id -> <figure>, reused so images never reload

  /* ---------- Stage scaling: 1920×1080 canvas fits any screen ---------- */

  function fit() {
    const scale = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    document.documentElement.style.setProperty("--scale", scale);
  }
  window.addEventListener("resize", fit);
  fit();

  /* ---------- Formatting ---------- */

  const nf = new Intl.NumberFormat("en-US");

  function bytes(n) {
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`;
  }

  function duration(s) {
    s = Math.max(0, Math.floor(s));
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60), sec = s % 60;
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${String(m).padStart(2, "0")}m`;
    if (m) return `${m}m ${String(sec).padStart(2, "0")}s`;
    return `${sec}s`;
  }

  const ago = (ts, now) => (now - ts < 5 ? "just now" : `${duration(now - ts).split(" ")[0]} ago`);
  const shortPod = (pod) => pod.split("-").slice(-1)[0];
  const clock = (ts) => new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /* ---------- Clock ---------- */

  const tickClock = () => { $("clock").textContent = clock(Date.now() / 1000); };
  setInterval(tickClock, 5000);
  tickClock();

  /* ---------- Counter animation ---------- */

  function animateCounter(target) {
    const from = shownWrites;
    if (from === target) return;
    const start = performance.now();
    const span = from === 0 ? 1400 : 700;
    const step = (t) => {
      // rAF timestamps can precede performance.now(); clamp so the tween never overshoots.
      const p = Math.max(0, Math.min(1, (t - start) / span));
      const eased = 1 - Math.pow(1 - p, 4);
      $("writes").textContent = nf.format(Math.round(from + (target - from) * eased));
      if (p < 1) requestAnimationFrame(step);
    };
    shownWrites = target;
    requestAnimationFrame(step);
  }

  /* ---------- Render ---------- */

  function renderFacts(data) {
    const parts = data.pod.split("-");
    const tail = parts.pop();
    $("pod").replaceChildren(document.createTextNode(parts.length ? parts.join("-") + "-" : ""), el("span", "hi", tail));
    $("pod").title = `${data.namespace}/${data.pod}`;
    $("cluster").textContent = data.cluster;
    $("url").textContent = data.ingress_host;
    $("url").hidden = !data.ingress_host;
    $("node").textContent = data.node;
    $("node").title = data.node;
    $("uptime").replaceChildren(document.createTextNode(duration(data.uptime)), el("span", "dim", ` · Generation ${data.boots_total}`));
    $("image").textContent = data.image;
  }

  function renderDisk(data) {
    const s = data.storage;
    animateCounter(s.writes);
    $("used").textContent = bytes(s.used_bytes);
    $("capacity").textContent = bytes(s.capacity_bytes);
    $("pvc").textContent = `pvc/${s.pvc} · RWO`;

    const bars = $("timeline");
    const recent = data.timeline.slice(-30);
    if (bars.children.length !== recent.length) bars.replaceChildren(...recent.map(() => el("div", "bar")));
    recent.forEach((pod, i) => {
      const isNew = i === recent.length - 1 && pod;
      bars.children[i].className = "bar" + (pod ? (pod === data.pod ? " on" : " prev") : "") + (isNew ? " new" : "");
    });
  }

  function renderWall(data) {
    const wall = $("wall");
    const total = data.photos_total;
    $("photo-count").textContent = total ? `${total} photo${total === 1 ? "" : "s"} on disk` : "";

    const key = data.photos.map((p) => p.id).join(",") + `|${total}`;
    if (key !== wallKey) {
      const firstRender = wallKey === null;
      wallKey = key;
      wall.dataset.count = data.photos.length;
      $("wall-empty").hidden = data.photos.length > 0;

      const ids = new Set(data.photos.map((p) => p.id));
      for (const [id, tile] of photoTiles) {
        if (!ids.has(id)) { tile.remove(); photoTiles.delete(id); }
      }

      data.photos.forEach((p, i) => {
        let tile = photoTiles.get(p.id);
        if (!tile) {
          tile = el("figure", "photo" + (firstRender ? "" : " fresh"));
          tile.addEventListener("animationend", () => tile.classList.remove("fresh"), { once: true });
          const img = el("img");
          img.src = p.url;
          img.alt = p.name;
          img.decoding = "async";
          const meta = el("figcaption", "photo-tag photo-meta");
          meta.dataset.created = p.created_at;
          meta.dataset.pod = p.pod;
          tile.append(img, meta);
          tile.addEventListener("click", () => openSpotlight(p.id));
          photoTiles.set(p.id, tile);
        }
        tile.querySelector(".photo-more")?.remove();
        if (i === data.photos.length - 1 && total > data.photos.length) {
          tile.append(el("span", "photo-tag photo-more", `+${total - data.photos.length} more`));
        }
        wall.append(tile);   // appending an existing tile only moves it into order
      });
    }

    wall.querySelectorAll(".photo-meta").forEach((tag) => {
      tag.replaceChildren(el("span", "mono", shortPod(tag.dataset.pod)), document.createTextNode(`· ${ago(Number(tag.dataset.created), data.server_time)}`));
    });
  }

  function renderNotes(data) {
    if (!data.notes.length) return;
    const now = data.server_time;
    $("notes").replaceChildren(...data.notes.map((n) => {
      const key = String(n.created_at);
      const li = el("li", seenNotes.size && !seenNotes.has(key) ? "fresh" : "");
      li.append(el("span", "note-text", n.text), el("span", "note-meta", `${shortPod(n.pod)} · ${ago(n.created_at, now)}`));
      return li;
    }));
    data.notes.forEach((n) => seenNotes.add(String(n.created_at)));
  }

  function renderLineage(data) {
    const firstRender = seenBoots.size === 0;
    const items = data.boots.map((b, i) => {
      const key = `${b.pod}@${b.started_at}`;
      const older = data.boots[i + 1];
      const moved = older && older.cluster && b.cluster && older.cluster !== b.cluster;
      const li = el("li", "gen" + (i === 0 ? " current" : "") + (moved ? " moved" : "") + (!firstRender && !seenBoots.has(key) ? " fresh" : ""));
      const life = duration((i === 0 ? data.server_time : b.last_seen) - b.started_at);
      li.append(
        el("span", "gen-dot"),
        el("span", "gen-name", shortPod(b.pod)),
        el("span", "gen-cluster", b.cluster || "—"),
        el("span", "gen-meta", `v${b.version} · ${clock(b.started_at)} · ${life}`),
      );
      seenBoots.add(key);
      return li;
    });
    const hidden = data.boots_total - data.boots.length;
    if (hidden > 0) items.push(el("li", "gen-more", `+${hidden} earlier`));
    $("lineage").replaceChildren(...items);
    const n = data.boots_total;
    $("lineage-sub").textContent = n === 1 ? "First pod on this volume" : `${n} pods on this volume`;
  }

  /* ---------- Toast ---------- */

  const TOAST_ICONS = {
    done: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    error: '<svg viewBox="0 0 24 24"><path d="M12 7v6M12 17h.01"/></svg>',
    busy: "",
  };
  let toastTimer = null;

  function toast(text, state = "done", ms = 3200) {
    const t = $("toast");
    t.dataset.state = state;
    $("toast-icon").innerHTML = TOAST_ICONS[state];
    $("toast-text").textContent = text;
    t.hidden = false;
    t.style.animation = "none"; t.offsetHeight; t.style.animation = "";
    clearTimeout(toastTimer);
    if (state !== "busy") toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  }

  /* ---------- Moments: narrate what just happened on stage ---------- */

  const ICONS = {
    check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    arrow: '<svg viewBox="0 0 24 24"><path d="M12 19V5M5.5 11.5L12 5l6.5 6.5"/></svg>',
    spark: '<svg viewBox="0 0 24 24"><path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6"/></svg>',
    globe: '<svg viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c2.5 2.5 3.8 5.5 3.8 9s-1.3 6.5-3.8 9M12 3c-2.5 2.5-3.8 5.5-3.8 9s1.3 6.5 3.8 9"/></svg>',
  };
  let momentTimer = null;

  function showMoment(icon, title, text, ms = 6500) {
    const m = $("moment");
    $("moment-icon").innerHTML = ICONS[icon];
    $("moment-title").textContent = title;
    $("moment-text").textContent = text;
    m.classList.remove("leaving");
    m.hidden = false;
    m.querySelectorAll(".moment-card, path").forEach((n) => { n.style.animation = "none"; n.offsetHeight; n.style.animation = ""; });
    clearTimeout(momentTimer);
    momentTimer = setTimeout(hideMoment, ms);
  }

  function hideMoment() {
    const m = $("moment");
    if (m.hidden) return;
    m.classList.add("leaving");
    setTimeout(() => { m.hidden = true; m.classList.remove("leaving"); }, 550);
  }
  $("moment").addEventListener("click", hideMoment);

  function narrate(prev, data) {
    const photos = data.photos_total;
    const kept = `${photos} photo${photos === 1 ? "" : "s"} · ${nf.format(data.storage.writes)} writes`;
    if (prev.cluster && prev.cluster !== data.cluster) {
      showMoment("globe", "New cluster. Same data.", `Now on ${data.cluster} · ${kept} intact`);
    } else if (prev.version !== data.version) {
      showMoment("arrow", `Now running v${data.version}`, `Rolled out from Git by Flux · ${kept} preserved`);
    } else if (prev.config_hash !== data.config_hash) {
      showMoment("spark", "New configuration live", `Committed to Git, reconciled by Flux · ${kept} preserved`);
    } else if (prev.pod !== data.pod) {
      showMoment("check", "New pod. Same data.", `${shortPod(data.pod)} took over the volume · ${kept} intact`);
    }
  }

  function loadPrev() {
    try { return JSON.parse(sessionStorage.getItem(STORE_KEY)); } catch { return null; }
  }
  function savePrev(data) {
    try {
      sessionStorage.setItem(STORE_KEY, JSON.stringify({ pod: data.pod, cluster: data.cluster, version: data.version, config_hash: data.config_hash }));
    } catch { /* storage unavailable: moments after reload are skipped */ }
  }

  /* ---------- Connection state & polling ---------- */

  function setStatus(state, label) {
    $("status").dataset.state = state;
    $("status-label").textContent = label;
    stage.classList.toggle("offline", state === "offline");
  }

  async function refresh() {
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 2500);
      const res = await fetch("/api/state", { cache: "no-store", signal: ctrl.signal });
      clearTimeout(timer);
      if (!res.ok) throw new Error(res.status);
      const data = await res.json();

      // New code or config delivered: reload to pick up templates/CSS/JS.
      // The previous snapshot stays in sessionStorage so the new page can narrate it.
      if (data.config_hash !== PAGE_HASH) {
        const lastReload = Number(sessionStorage.getItem("snapwall:reload") || 0);
        if (Date.now() - lastReload > 10000) {
          sessionStorage.setItem("snapwall:reload", Date.now());
          location.reload();
          return;
        }
      }

      const prev = last || loadPrev();
      if (prev) narrate(prev, data);
      last = data;
      savePrev(data);

      failures = 0;
      offlineSince = null;
      setStatus("live", "Live");
      renderFacts(data);
      renderWall(data);
      renderDisk(data);
      renderNotes(data);
      renderLineage(data);
    } catch (err) {
      failures++;
      if (failures >= 2) {
        offlineSince = offlineSince || Date.now() - POLL_MS * 2;
        setStatus("offline", `Pod unavailable · ${Math.round((Date.now() - offlineSince) / 1000)}s`);
      }
    }
  }

  async function loop() {
    await refresh();
    setTimeout(loop, POLL_MS);
  }

  /* ---------- Photo upload ---------- */

  const DIRECT_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];

  // Large photos (and formats like HEIC where the browser can decode them) are
  // re-encoded as JPEG so uploads stay fast over a port-forward on stage.
  async function prepare(file) {
    const direct = DIRECT_TYPES.includes(file.type);
    if (file.type === "image/gif" || (direct && file.size < 1.5 * 1024 * 1024)) return file;
    try {
      const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
      const scale = Math.min(1, MAX_EDGE / Math.max(bmp.width, bmp.height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(bmp.width * scale);
      canvas.height = Math.round(bmp.height * scale);
      canvas.getContext("2d").drawImage(bmp, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.9));
      if (blob && (!direct || blob.size < file.size)) {
        return new File([blob], file.name.replace(/\.[^.]+$/, "") + ".jpg", { type: "image/jpeg" });
      }
    } catch { /* browser can't decode it; let the server decide */ }
    return file;
  }

  async function upload(fileList) {
    const files = [...fileList].filter((f) => f.type.startsWith("image/") || /\.(jpe?g|png|webp|gif|heic)$/i.test(f.name));
    if (!files.length) { toast("Only photos can go on the wall", "error"); return; }

    const label = files.length === 1 ? "photo" : `${files.length} photos`;
    toast(`Saving ${label} to the volume…`, "busy");
    try {
      const form = new FormData();
      for (const f of files) {
        const ready = await prepare(f);
        form.append("photo", ready, ready.name);
      }
      const res = await fetch("/api/photos", { method: "POST", body: form });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error || `upload failed (${res.status})`);
      const pvc = last ? `pvc/${last.storage.pvc}` : "the volume";
      const skipped = body.rejected && body.rejected.length ? ` · ${body.rejected.length} skipped` : "";
      toast(`Saved to ${pvc}${skipped}`, "done");
      refresh();
    } catch (err) {
      toast(err.message === "Failed to fetch" ? "Pod unavailable, try again" : err.message, "error", 4500);
    }
  }

  const fileInput = $("file-input");
  const choosePhotos = () => fileInput.click();
  fileInput.addEventListener("change", () => { if (fileInput.files.length) upload(fileInput.files); fileInput.value = ""; });
  $("add-photo").addEventListener("click", choosePhotos);
  $("wall-empty").addEventListener("click", choosePhotos);

  // Drag & drop anywhere on the page.
  let dragDepth = 0;
  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files");
  window.addEventListener("dragenter", (e) => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; $("drop").hidden = false; });
  window.addEventListener("dragover", (e) => { if (hasFiles(e)) e.preventDefault(); });
  window.addEventListener("dragleave", (e) => { if (!hasFiles(e)) return; if (--dragDepth <= 0) { dragDepth = 0; $("drop").hidden = true; } });
  window.addEventListener("drop", (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth = 0;
    $("drop").hidden = true;
    upload(e.dataTransfer.files);
  });

  /* ---------- Spotlight ---------- */

  const spot = { list: [], index: 0 };

  async function openSpotlight(id) {
    try {
      const res = await fetch("/api/photos", { cache: "no-store" });
      spot.list = (await res.json()).photos;
    } catch { return; }
    spot.index = Math.max(0, spot.list.findIndex((p) => p.id === id));
    $("spotlight").hidden = false;
    showSpot();
  }

  function showSpot() {
    const p = spot.list[spot.index];
    if (!p) { closeSpotlight(); return; }
    const img = $("spot-img");
    img.src = p.url;
    img.alt = p.name;
    img.style.animation = "none"; img.offsetHeight; img.style.animation = "";
    const now = last ? last.server_time : Date.now() / 1000;
    $("spot-caption").replaceChildren(
      el("strong", "", `${spot.index + 1} of ${spot.list.length}`),
      document.createTextNode(`  ·  saved by ${shortPod(p.pod)} ${ago(p.created_at, now)}  ·  ${bytes(p.bytes)} on disk`),
    );
    $("spot-prev").hidden = $("spot-next").hidden = spot.list.length < 2;
    $("spot-delete").classList.remove("armed");
  }

  function stepSpot(delta) {
    if (spot.list.length < 2) return;
    spot.index = (spot.index + delta + spot.list.length) % spot.list.length;
    showSpot();
  }

  function closeSpotlight() { $("spotlight").hidden = true; }

  async function deleteSpot() {
    const btn = $("spot-delete");
    if (!btn.classList.contains("armed")) { btn.classList.add("armed"); return; }
    const p = spot.list[spot.index];
    try {
      await fetch(`/api/photos/${p.id}`, { method: "DELETE" });
    } catch { toast("Pod unavailable, try again", "error"); return; }
    spot.list.splice(spot.index, 1);
    spot.index = Math.min(spot.index, spot.list.length - 1);
    showSpot();
    refresh();
  }

  $("spot-prev").addEventListener("click", () => stepSpot(-1));
  $("spot-next").addEventListener("click", () => stepSpot(1));
  $("spot-close").addEventListener("click", closeSpotlight);
  $("spot-delete").addEventListener("click", deleteSpot);
  $("spotlight").addEventListener("click", (e) => { if (e.target.classList.contains("canvas")) closeSpotlight(); });

  /* ---------- Note composer ---------- */

  const sheet = $("sheet"), input = $("note-input");

  function openSheet() {
    sheet.hidden = false;
    input.value = "";
    setTimeout(() => input.focus(), 50);
  }
  function closeSheet() { sheet.hidden = true; }

  $("add-note").addEventListener("click", openSheet);
  $("note-cancel").addEventListener("click", closeSheet);
  sheet.addEventListener("click", (e) => { if (e.target === sheet) closeSheet(); });

  $("note-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    closeSheet();
    try {
      await fetch("/api/notes", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      refresh();
    } catch { /* the poll loop will show the pod as unavailable */ }
  });

  /* ---------- Presenter keys ---------- */

  document.addEventListener("keydown", (e) => {
    if (!sheet.hidden) { if (e.key === "Escape") closeSheet(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key.toLowerCase();

    if (!$("spotlight").hidden) {
      if (key === "escape") closeSpotlight();
      else if (key === "arrowleft") stepSpot(-1);
      else if (key === "arrowright" || key === " ") { e.preventDefault(); stepSpot(1); }
      else if (key === "backspace" || key === "delete") deleteSpot();
      return;
    }

    if (key === "n") { e.preventDefault(); openSheet(); }
    else if (key === "u") choosePhotos();
    else if (key === "f") { document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen(); }
    else if (key === "escape") hideMoment();
  });

  /* ---------- Go ---------- */

  document.querySelectorAll(".topbar, .intro, .facts, .notes, .wall, .lineage, .disk").forEach((node, i) => {
    node.classList.add("reveal");
    node.style.animationDelay = `${80 + i * 70}ms`;
  });
  loop();
})();
