// Renders scene.html with headless Chrome over CDP (no npm deps; Node 22+ has WebSocket).
//   node render.mjs stills            -> ../docs/*.png
//   node render.mjs video             -> ../docs/claude-hud.mp4 (+ demo.gif)
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const docs = join(here, "../docs");
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const port = 9333;
const profile = join(tmpdir(), "hud-render-profile");
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1920,1080", "about:blank"], { stdio: "ignore" });

let target;
for (let i = 0; i < 50 && !target; i++) {
  await new Promise((r) => setTimeout(r, 200));
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let seq = 0;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise((r) => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });

async function load(w, h, scale) {
  await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: scale, mobile: false });
  await send("Page.navigate", { url: "file://" + join(here, "scene.html") });
  await new Promise((r) => setTimeout(r, 800));
}
async function shot(t, file) {
  await send("Runtime.evaluate", { expression: `render(${t})` });
  const { result } = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(file, Buffer.from(result.data, "base64"));
}

const mode = process.argv[2] || "stills";
mkdirSync(docs, { recursive: true });
if (mode === "stills") {
  await load(1920, 1080, 1);
  for (const [t, name] of [[1.2, "hero"], [5.5, "sessions"], [10.0, "permission"], [15.4, "limits"], [17.6, "heavy-session"], [24.0, "toast-reply"], [27.5, "install"]])
    await shot(t, join(docs, `${name}.png`));
} else {
  const fps = 30, dur = 29, dir = join(tmpdir(), "hud-frames");
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir);
  await load(1920, 1080, 1);
  for (let f = 0; f < fps * dur; f++) await shot((f / fps).toFixed(4), join(dir, `${String(f).padStart(4, "0")}.png`));
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-framerate", `${fps}`, "-i", join(dir, "%04d.png"),
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "slow", "-movflags", "+faststart", join(docs, "claude-hud.mp4")]);
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", join(docs, "claude-hud.mp4"), "-vf",
    "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a", join(docs, "demo.gif")]);
}
ws.close();
chrome.kill();
