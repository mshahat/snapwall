// Pulse front-end: polls the pod, animates state, and narrates rollouts.
(() => {
  const $ = (id) => document.getElementById(id);
  const stage = $("stage");
  const PAGE_HASH = stage.dataset.configHash;
  const POLL_MS = 1000;
  const STORE_KEY = "pulse:last";

  let last = null;          // last successful /api/state payload
  let failures = 0;
  let offlineSince = null;
  let shownWrites = 0;
  let seenNotes = new Set();
  let seenBoots = new Set();

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

  function ago(ts, now) {
    const s = now - ts;
    return s < 5 ? "just now" : `${duration(s).split(" ")[0]} ago`;
  }

  const shortPod = (pod) => pod.split("-").slice(-1)[0];

  function time(ts) {
    return new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /* ---------- Clock ---------- */

  function tickClock() {
    $("clock").textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
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

  function renderPod(data) {
    const parts = data.pod.split("-");
    const tail = parts.pop();
    const pod = $("pod");
    pod.replaceChildren(document.createTextNode(parts.length ? parts.join("-") + "-" : ""), el("span", "hi", tail));
    pod.title = data.pod;
    $("namespace").textContent = `namespace/${data.namespace}`;
    $("node").textContent = data.node;
    $("node").title = data.node;
    $("uptime").textContent = duration(data.uptime);
    $("generation").textContent = `Generation ${data.boots_total}`;
    $("image").textContent = data.image;
  }

  function renderStorage(data) {
    const s = data.storage;
    animateCounter(s.writes);
    $("first-write").textContent = new Date(s.first_write_at * 1000)
      .toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
    $("used").textContent = bytes(s.used_bytes);
    $("capacity").textContent = bytes(s.capacity_bytes);
    $("pvc").textContent = `pvc/${s.pvc}`;
    $("usage-fill").style.width = `${Math.min(100, (s.used_bytes / s.capacity_bytes) * 100)}%`;

    const tl = $("timeline");
    if (tl.children.length !== 60) tl.replaceChildren(...Array.from({ length: 60 }, () => el("div", "bar")));
    data.timeline.forEach((pod, i) => {
      const bar = tl.children[i];
      bar.className = "bar" + (pod ? (pod === data.pod ? " on" : " prev") : "") + (i === 59 && pod ? " new" : "");
    });
  }

  function renderNotes(data) {
    const list = $("notes");
    if (!data.notes.length) return;
    const now = data.server_time;
    list.replaceChildren(...data.notes.map((n) => {
      const key = `${n.created_at}`;
      const li = el("li", seenNotes.size && !seenNotes.has(key) ? "fresh" : "");
      li.append(el("span", "note-text", n.text), el("span", "note-meta", `${shortPod(n.pod)} · ${ago(n.created_at, now)}`));
      return li;
    }));
    data.notes.forEach((n) => seenNotes.add(`${n.created_at}`));
  }

  function renderLineage(data) {
    const track = $("lineage");
    const firstRender = seenBoots.size === 0;
    const items = data.boots.map((b, i) => {
      const key = `${b.pod}@${b.started_at}`;
      const li = el("li", "gen" + (i === 0 ? " current" : "") + (!firstRender && !seenBoots.has(key) ? " fresh" : ""));
      const life = i === 0 ? `live ${duration(data.server_time - b.started_at)}` : `lived ${duration(b.last_seen - b.started_at)}`;
      li.append(el("span", "gen-dot"), el("span", "gen-name", shortPod(b.pod)), el("span", "gen-meta", `v${b.version} · ${time(b.started_at)} · ${life}`));
      seenBoots.add(key);
      return li;
    });
    const hidden = data.boots_total - data.boots.length;
    if (hidden > 0) items.push(el("li", "gen-more", `+${hidden} earlier`));
    track.replaceChildren(...items);
    const n = data.boots_total;
    $("lineage-sub").textContent = n === 1 ? "The first pod to own this volume" : `${n} pods have owned this volume`;
  }

  /* ---------- Moments: narrate what just happened on stage ---------- */

  const ICONS = {
    check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    arrow: '<svg viewBox="0 0 24 24"><path d="M12 19V5M5.5 11.5L12 5l6.5 6.5"/></svg>',
    spark: '<svg viewBox="0 0 24 24"><path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6"/></svg>',
  };
  let momentTimer = null;

  function showMoment(icon, title, text, ms = 6500) {
    const m = $("moment");
    $("moment-icon").innerHTML = ICONS[icon];
    $("moment-title").textContent = title;
    $("moment-text").textContent = text;
    m.classList.remove("leaving");
    m.hidden = false;
    // restart animations
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
    const writes = nf.format(data.storage.writes);
    if (prev.version !== data.version) {
      showMoment("arrow", `Now running v${data.version}`, `Rolled out from Git by Flux · ${writes} writes preserved`);
    } else if (prev.config_hash !== data.config_hash) {
      showMoment("spark", "New configuration live", `Committed to Git, reconciled by Flux · ${writes} writes preserved`);
    } else if (prev.pod !== data.pod) {
      showMoment("check", "New pod. Same data.", `${data.pod} took over the volume · ${writes} writes intact`);
    }
  }

  function loadPrev() {
    try { return JSON.parse(sessionStorage.getItem(STORE_KEY)); } catch { return null; }
  }
  function savePrev(data) {
    try {
      sessionStorage.setItem(STORE_KEY, JSON.stringify({ pod: data.pod, version: data.version, config_hash: data.config_hash }));
    } catch { /* storage unavailable: moments after reload are skipped */ }
  }

  /* ---------- Connection state ---------- */

  function setStatus(state, label) {
    $("status").dataset.state = state;
    $("status-label").textContent = label;
    stage.classList.toggle("offline", state === "offline");
  }

  /* ---------- Poll loop ---------- */

  async function poll() {
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
        const lastReload = Number(sessionStorage.getItem("pulse:reload") || 0);
        if (Date.now() - lastReload > 10000) {
          sessionStorage.setItem("pulse:reload", Date.now());
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
      renderPod(data);
      renderStorage(data);
      renderNotes(data);
      renderLineage(data);
    } catch (err) {
      failures++;
      if (failures >= 2) {
        offlineSince = offlineSince || Date.now() - POLL_MS * 2;
        setStatus("offline", `Pod unavailable · ${Math.round((Date.now() - offlineSince) / 1000)}s`);
      }
    } finally {
      setTimeout(poll, POLL_MS);
    }
  }

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
    } catch { /* the poll loop will show the pod as unavailable */ }
  });

  /* ---------- Presenter keys ---------- */

  document.addEventListener("keydown", (e) => {
    if (!sheet.hidden) { if (e.key === "Escape") closeSheet(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key.toLowerCase();
    if (key === "n") { e.preventDefault(); openSheet(); }
    else if (key === "f") { document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen(); }
    else if (key === "escape") hideMoment();
  });

  /* ---------- Go ---------- */

  document.querySelectorAll(".topbar, .hero > *, .side > *, .lineage").forEach((node, i) => {
    node.classList.add("reveal");
    node.style.animationDelay = `${80 + i * 70}ms`;
  });
  poll();
})();
