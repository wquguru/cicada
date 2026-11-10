#!/usr/bin/env python3
"""An iPhone as a person in the room, played from the shell, like the ESP32's tv.py.

  phone.py serve            serve the page on :8765 (open http://<mac-ip>:8765 in Safari, tap 开始)
  phone.py play <wav> [--at <unix seconds>]   play a clip on the phone; prints START/END, blocks until END

The page fetches each clip, waits for the given time (its clock offset to the Mac measured at start)
and plays it through Web Audio; Safari needs one tap before it will make a sound."""
import json, os, sys, threading, time, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

PORT = 8765
PAGE = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>Cicada phone</title><body style="font:20px -apple-system;margin:24px;background:#F3F4F6;color:#15171C">
<button id=b style="font-size:28px;padding:20px 40px;background:#E8552B;color:#fff;border:0;border-radius:12px">开始</button>
<p id=s>点开始，然后保持这个页面在前台、屏幕常亮。</p><script>
let ctx, off = 0, last = 0;
const s = document.getElementById('s');
async function sync() {  // phone clock minus Mac clock, from the fastest of 8 round trips
  let best = 1e9;
  for (let i = 0; i < 8; i++) {
    const t0 = Date.now(); const r = await (await fetch('/time')).json(); const t1 = Date.now();
    if (t1 - t0 < best) { best = t1 - t0; off = (t0 + t1) / 2 - r.now * 1000; }
  }
  s.textContent = `已连接，往返 ${best} ms`;
}
async function loop() {
  for (;;) {
    try {
      const c = await (await fetch('/next?after=' + last)).json();
      if (c.id) {
        last = c.id;
        const buf = await ctx.decodeAudioData(await (await fetch('/clip/' + c.id)).arrayBuffer());
        const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination);
        const wait = Math.max(0, (c.at * 1000 + off - Date.now()) / 1000);
        src.start(ctx.currentTime + wait);
        const startMac = (Date.now() + wait * 1000 - off) / 1000;
        fetch('/started?id=' + c.id + '&t=' + startMac);
        s.textContent = '播放 ' + c.name;
        src.onended = () => { fetch('/ended?id=' + c.id + '&t=' + (Date.now() - off) / 1000); s.textContent = '等待中'; };
      }
    } catch (e) { s.textContent = '出错：' + e; await new Promise(r => setTimeout(r, 1000)); }
  }
}
document.getElementById('b').onclick = async () => {
  // Web Audio follows the silent switch unless the session is playback (Safari 17+).
  try { navigator.audioSession.type = 'playback'; } catch (e) {}
  ctx = new AudioContext(); await ctx.resume();
  const o = ctx.createOscillator(); o.connect(ctx.destination); o.start(); o.stop(ctx.currentTime + 0.01);
  try { await navigator.wakeLock.request('screen'); } catch (e) {}
  await sync(); loop();
};
</script>"""

state = {"next": int(time.time()),  # ids grow across restarts: the page skips ids it has seen
          "clips": {}, "cmd": None, "events": {}}
cond = threading.Condition()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, body, ctype="application/json"):
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def q(self):
        from urllib.parse import urlparse, parse_qs
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/": return self.send(PAGE.encode(), "text/html; charset=utf-8")
        if p == "/time": return self.send(json.dumps({"now": time.time()}).encode())
        if p == "/next":  # long poll: the next command after `after`
            after = int(self.q().get("after", 0))
            with cond:
                cond.wait_for(lambda: state["cmd"] and state["cmd"]["id"] > after, timeout=20)
                c = state["cmd"] if state["cmd"] and state["cmd"]["id"] > after else {}
            return self.send(json.dumps(c).encode())
        if p.startswith("/clip/"):
            return self.send(state["clips"][int(p[6:])], "audio/wav")
        if p in ("/started", "/ended"):
            q = self.q()
            with cond:
                state["events"].setdefault(int(q["id"]), {})[p[1:]] = float(q["t"]); cond.notify_all()
            return self.send(b"{}")
        if p == "/wait":  # blocks until the clip ended (the `play` side)
            i = int(self.q()["id"])
            with cond:
                cond.wait_for(lambda: "started" in state["events"].get(i, {}), timeout=30)
                ev = state["events"].get(i, {})
                if "started" in ev:
                    cond.wait_for(lambda: "ended" in state["events"].get(i, {}), timeout=max(1, ev["started"] - time.time()) + 90)
                return self.send(json.dumps(state["events"].get(i, {})).encode())
        self.send_response(404); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        q = self.q()
        with cond:
            state["next"] += 1; i = state["next"]
            state["clips"][i] = body
            state["cmd"] = {"id": i, "at": float(q.get("at", 0)), "name": q.get("name", "")}
            cond.notify_all()
        self.send(json.dumps({"id": i}).encode())

if sys.argv[1] == "serve":
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
elif sys.argv[1] == "play":
    wav = sys.argv[2]
    at = float(sys.argv[sys.argv.index("--at") + 1]) if "--at" in sys.argv else time.time() + 0.5
    base = f"http://127.0.0.1:{PORT}"
    r = urllib.request.urlopen(urllib.request.Request(f"{base}/?at={at}&name={os.path.basename(wav)}", data=open(wav, "rb").read(), method="POST"))
    i = json.load(r)["id"]
    ev = json.load(urllib.request.urlopen(f"{base}/wait?id={i}", timeout=130))
    if "started" not in ev: print("phone: no reply (page closed or asleep?)"); sys.exit(2)
    if "ended" not in ev:  # Safari didn't report the end: the clip's length says it
        import wave
        with wave.open(wav) as w: ev["ended"] = ev["started"] + w.getnframes() / w.getframerate()
    print(f"START {ev['started']:.3f}\nEND {ev['ended']:.3f}")
