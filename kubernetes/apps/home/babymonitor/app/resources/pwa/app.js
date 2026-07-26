const AUDIO = { both: "/audio/both.mp3", sofia: "/audio/sofia.mp3", nicolo: "/audio/nicolo.mp3" };
const LABEL = { both: "Entrambe", sofia: "Sofia", nicolo: "Nicolò" };
const APP_VERSION = "v6";
document.getElementById("ver").textContent = APP_VERSION;
const au = document.getElementById("au");
const statusEl = document.getElementById("status");
let current = null;         // "both" | "sofia" | "nicolo" | null
let reconnectTimer = null;
let lastT = 0, lastAdv = 0; // stall watchdog

function setStatus(t){ statusEl.textContent = t; }

function highlight(){
  document.querySelectorAll("button[data-stream]").forEach(b =>
    b.classList.toggle("active", b.dataset.stream === current));
}

function playAudio(stream){
  clearTimeout(reconnectTimer);
  lastT = 0; lastAdv = Date.now();       // reset stall watchdog baseline
  // cache-bust so a stalled/broken connection is dropped, not resumed
  au.src = AUDIO[stream] + "?t=" + Date.now();
  au.play().then(() => setStatus("In ascolto: " + LABEL[stream]))
           .catch(err => { setStatus("Errore, riprovo…"); scheduleReconnect(); });
  updateMediaSession(stream);
}

function scheduleReconnect(){
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => { if (current) playAudio(current); }, 2000);
}

// Reconnect ONLY on a genuine media error. 'waiting'/'stalled' fire during normal
// startup buffering; reacting to them resets src and aborts the load in a tight loop.
au.addEventListener("error", () => { if (current) { setStatus("Riconnessione…"); scheduleReconnect(); } });
au.addEventListener("playing", () => { if (current) setStatus("In ascolto: " + LABEL[current]); });

// Stall watchdog: reconnect only if playback is genuinely stuck (no progress for 8s).
setInterval(() => {
  if (!current || au.paused) return;
  if (au.currentTime > lastT) { lastT = au.currentTime; lastAdv = Date.now(); }
  else if (Date.now() - lastAdv > 8000) { setStatus("Riconnessione…"); playAudio(current); }
}, 3000);

function updateMediaSession(stream){
  if (!("mediaSession" in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: "Baby Monitor — " + LABEL[stream], artist: "Casa" });
  navigator.mediaSession.playbackState = "playing";
  navigator.mediaSession.setActionHandler("pause", stop);
  navigator.mediaSession.setActionHandler("play", () => current && playAudio(current));
  // Lockscreen next/prev cycles rooms
  const order = ["both","sofia","nicolo"];
  const cyc = d => { const i = order.indexOf(current); select(order[(i+d+3)%3]); };
  navigator.mediaSession.setActionHandler("nexttrack", () => cyc(1));
  navigator.mediaSession.setActionHandler("previoustrack", () => cyc(-1));
}

function stop(){
  clearTimeout(reconnectTimer);
  current = null; au.pause(); au.removeAttribute("src"); au.load();
  if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "none";
  setStatus("In pausa"); highlight();
}

function select(stream){
  current = stream; highlight(); playAudio(stream);
}

document.querySelectorAll("button[data-stream]").forEach(b =>
  b.addEventListener("click", () => current === b.dataset.stream ? stop() : select(b.dataset.stream)));

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(()=>{});

// --- Foreground video (go2rtc WebRTC component, DIRECT ws) + per-camera zoom ----
// WS goes straight to go2rtc (WS isn't CORS-blocked; the nginx WS proxy didn't relay
// the signaling). The video-stream JS module is still loaded same-origin (/go2rtc/).
const GO2RTC_WS = "wss://go2rtc." + location.hostname.split(".").slice(1).join(".") + "/api/ws";
const SRC = { sofia: "sofias-room", nicolo: "nicolos-room" };
const videoBox = document.getElementById("video");

function roomsFor(stream){ return stream === "both" ? ["sofia","nicolo"] : [stream]; }

function makeTile(room){
  const tile = document.createElement("div");
  tile.className = "tile";

  const vs = document.createElement("video-stream");
  vs.setAttribute("src", GO2RTC_WS + "?src=" + SRC[room]);
  vs.setAttribute("mode", "webrtc");
  vs.setAttribute("media", "video");   // video only -> no audio track (Icecast carries sound)
  vs.setAttribute("background", "true");

  const label = document.createElement("div");
  label.className = "label"; label.textContent = LABEL[room];

  // Per-camera zoom region, persisted. s=scale, x/y=pan (% of tile).
  const key = "zoom_" + room;
  let z = { s: 1, x: 0, y: 0 };
  try { z = Object.assign(z, JSON.parse(localStorage.getItem(key) || "{}")); } catch (e) {}
  const apply = () => {
    vs.style.setProperty("--z", z.s);
    vs.style.setProperty("--x", z.x + "%");
    vs.style.setProperty("--y", z.y + "%");
    localStorage.setItem(key, JSON.stringify(z));
  };

  const ctl = document.createElement("div"); ctl.className = "zctl";
  const btn = (t, fn) => {
    const b = document.createElement("button"); b.className = "zbtn"; b.textContent = t;
    b.addEventListener("click", e => { e.stopPropagation(); fn(); });
    return b;
  };
  ctl.append(
    btn("＋", () => { z.s = Math.min(4, +(z.s + 0.5).toFixed(2)); apply(); }),
    btn("－", () => { z.s = Math.max(1, +(z.s - 0.5).toFixed(2)); if (z.s === 1) { z.x = 0; z.y = 0; } apply(); }),
    btn("⟲", () => { z = { s: 1, x: 0, y: 0 }; apply(); })
  );

  // Drag to pan when zoomed in.
  let drag = null;
  tile.addEventListener("pointerdown", e => {
    if (z.s > 1) { drag = { x: e.clientX, y: e.clientY, ox: z.x, oy: z.y }; try { tile.setPointerCapture(e.pointerId); } catch (_) {} }
  });
  tile.addEventListener("pointermove", e => {
    if (!drag) return;
    const lim = 50 * (1 - 1 / z.s);
    z.x = Math.max(-lim, Math.min(lim, drag.ox + (e.clientX - drag.x) / tile.clientWidth * 100 / z.s));
    z.y = Math.max(-lim, Math.min(lim, drag.oy + (e.clientY - drag.y) / tile.clientHeight * 100 / z.s));
    apply();
  });
  const end = () => { drag = null; };
  tile.addEventListener("pointerup", end);
  tile.addEventListener("pointercancel", end);

  tile.append(vs, label, ctl);
  apply();
  return tile;
}

function showVideo(stream){
  videoBox.innerHTML = "";
  for (const r of roomsFor(stream)) videoBox.appendChild(makeTile(r));
}
function hideVideo(){ videoBox.innerHTML = ""; }

// When visible: show WebRTC video (its own audio) and mute the Icecast audio to avoid doubling.
// When hidden: kill video, unmute + ensure Icecast audio is playing (the reliable path).
function applyVisibility(){
  if (!current) { hideVideo(); return; }
  if (document.visibilityState === "visible") showVideo(current);
  else hideVideo();
  au.muted = false;                    // Icecast audio ALWAYS plays (never rely on WebRTC for sound)
  if (au.paused) playAudio(current);
}
document.addEventListener("visibilitychange", applyVisibility);

// hook into select()/stop(): re-run visibility after each
const _select = select; select = s => { _select(s); applyVisibility(); };
const _stop = stop; stop = () => { _stop(); hideVideo(); };
