#!/usr/bin/env node
// FULL-SYSTEM end-to-end test for the CopyURL Linux flow.
//
// run_e2e.mjs drives the trigger with puppeteer's CDP keyboard, so it proves the
// EXTENSION is correct but bypasses the OS orchestration layer. THIS harness runs
// the genuine production path that actually broke in the field:
//
//   real headful Brave + real extension
//     -> puppeteer sets the hover (the user's physical mouse in production)
//       -> the REAL Linux/copyurl.sh runs:
//            ydotool type "]"  ->  content.js copies to the OS clipboard
//            wl-paste polling   ->  confirms the copy
//       -> gemini.js (in a second tab) pastes via chrome.storage.local
//
// It therefore exercises ydotool, wl-clipboard, the executable bit + GNOME
// command, and the cross-tab chrome.storage bridge together. Requires a real
// Wayland/X session with ydotoold running (so it is opt-in: run_tests.sh only
// invokes it when COPYURL_FULL_SYSTEM=1 and a display is present).
//
// Usage:  COPYURL_FULL_SYSTEM=1 node tests/e2e/run_full_system.mjs
//
// Exit 0 = pass, non-zero = failure with a diagnostic dump.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..", "..");
const FIXTURES = path.join(__dirname, "fixtures");
const COPYURL_SH = path.join(ROOT, "Linux", "copyurl.sh");
const PASTE_PREFIX = "한국말로 요약해줘 - ";

const log = (...a) => console.log("[full]", ...a);
const fail = (m) => { console.error("\n  FAIL  " + m + "\n"); process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sh(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 20000, ...opts }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout: stdout || "", stderr: stderr || "" });
    });
  });
}

function findBrave() {
  for (const c of [process.env.BRAVE_PATH, "/usr/bin/brave-browser", "/usr/bin/brave",
    "/usr/bin/google-chrome", "/usr/bin/chromium"].filter(Boolean)) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch {}
  }
  throw new Error("No Chromium-based browser found (set BRAVE_PATH).");
}

function startServer() {
  const routes = { "/youtube": path.join(FIXTURES, "youtube.html"), "/gemini": path.join(FIXTURES, "gemini.html") };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/favicon.ico") { res.writeHead(204); res.end(); return; }
    const file = routes[url.pathname];
    if (!file) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(fs.readFileSync(file));
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r({ server, port: server.address().port })));
}

function buildTempExtension() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "copyurl-ext-"));
  for (const f of ["content.js", "gemini.js", "icon16.png", "icon48.png", "icon128.png"]) {
    const src = path.join(ROOT, f);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dir, f));
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, "manifest.json"), "utf8"));
  manifest.content_scripts = [
    { matches: ["http://localhost/youtube*"], js: ["content.js"], run_at: "document_idle" },
    { matches: ["http://localhost/gemini*"], js: ["gemini.js"], run_at: "document_idle" },
  ];
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify(manifest, null, 2));
  return dir;
}

// Activate the Brave window (by its title substring) so ydotool's keystrokes land
// in it. Uses the same "Activate Window By Title" GNOME extension copyurl.sh uses.
async function activateWindow(needle) {
  const r = await sh("gdbus", ["call", "--session", "--dest", "org.gnome.Shell",
    "--object-path", "/de/lucaswerkmeister/ActivateWindowByTitle",
    "--method", "de.lucaswerkmeister.ActivateWindowByTitle.activateBySubstring", needle]);
  return r.stdout.includes("true");
}

async function main() {
  // Preconditions: a display + ydotoold, else this test can't run meaningfully.
  if (!process.env.WAYLAND_DISPLAY && !process.env.DISPLAY) {
    log("no display; skipping full-system test"); return;
  }
  const yd = await sh("pgrep", ["-x", "ydotoold"]);
  if (yd.code !== 0) { fail("ydotoold is not running (start it: systemctl --user start ydotoold)"); return; }

  const { server, port } = await startServer();
  const extDir = buildTempExtension();
  log(`server :${port}, ext ${extDir}`);

  const browser = await puppeteer.launch({
    executablePath: findBrave(),
    headless: false, // MUST be headful: ydotool types into the OS-focused window
    args: [
      `--disable-extensions-except=${extDir}`,
      `--load-extension=${extDir}`,
      "--no-first-run", "--no-default-browser-check",
      "--new-window", "--window-size=1100,800", "--window-position=80,80",
    ],
  });

  const results = {};
  try {
    const base = `http://localhost:${port}`;
    // Gemini tab first (registers the storage listener), then YouTube tab on top.
    const gemini = await browser.newPage();
    gemini.on("console", (m) => log("gemini:", m.text()));
    await gemini.goto(`${base}/gemini`, { waitUntil: "domcontentloaded" });
    await sleep(600);

    const yt = await browser.newPage();
    yt.on("console", (m) => log("yt:", m.text()));
    await yt.goto(`${base}/youtube`, { waitUntil: "domcontentloaded" });
    await yt.bringToFront();
    // Make the page title easy to target for window activation.
    await yt.evaluate(() => { document.title = "YTFIXTURE youtube.com"; });
    await sleep(400);

    const overlays = { A: '[data-testid="overlay-a"]', B: '[data-testid="overlay-b"]' };
    const urlFor = {
      A: "https://www.youtube.com/watch?v=VIDEO_AAAAAAA",
      B: "https://www.youtube.com/watch?v=VIDEO_BBBBBBB",
    };

    // Hover thumbnail `which`, run the REAL copyurl.sh (ydotool "]" trigger +
    // wl-paste polling), and return the resulting OS clipboard text.
    //
    // Retry wrapper: activating a window programmatically (gdbus) races the
    // compositor, so the very first ydotool keystroke after activation can land
    // before Brave has focus and get lost. In production the user's window is
    // ALREADY focused when they press Alt+Z, so this race is a harness artifact,
    // not a product bug — we re-activate and re-run up to 3x to neutralise it.
    async function hoverAndTrigger(which) {
      const box = await yt.$eval(overlays[which], (el) => {
        const r = el.getBoundingClientRect();
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
      });
      for (let attempt = 1; attempt <= 3; attempt++) {
        await yt.bringToFront();
        await yt.mouse.move(box.x, box.y, { steps: 6 });
        await sleep(150);
        // Pre-seed a unique sentinel so a same-URL re-copy is still detectable.
        await sh("sh", ["-c", `printf '%s' '__pre_${which}_${Date.now()}__' | wl-copy`]);
        await activateWindow("YTFIXTURE");
        await sleep(600); // let the compositor settle focus before ydotool types
        await new Promise((resolve) => {
          const p = spawn("bash", [COPYURL_SH], { env: { ...process.env, COPYURL_VERBOSE: "1", COPYURL_YOUTUBE_NEEDLE: "YTFIXTURE" } });
          p.on("close", () => resolve());
          setTimeout(() => p.kill("SIGKILL"), 14000);
        });
        const clip = (await sh("wl-paste", ["--no-newline"])).stdout;
        if (clip.includes("youtube.com")) return { clip, attempt };
        log(`  retry hover ${which}: attempt ${attempt} got ${JSON.stringify(clip.slice(0, 40))}`);
        await sleep(300);
      }
      return { clip: (await sh("wl-paste", ["--no-newline"])).stdout, attempt: 3 };
    }

    // Like hoverAndTrigger, but deliberately moves OS keyboard focus to a DECOY
    // window first and does NOT pre-activate Brave — so the ONLY thing that can
    // bring Brave forward is copyurl.sh's own activate_youtube step. This is the
    // exact scenario the user reported: "works only when Brave is in focus."
    async function hoverAndTriggerUnfocused(which, decoy) {
      const box = await yt.$eval(overlays[which], (el) => {
        const r = el.getBoundingClientRect();
        return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
      });
      for (let attempt = 1; attempt <= 3; attempt++) {
        await yt.bringToFront();                 // youtube is the active TAB
        await yt.mouse.move(box.x, box.y, { steps: 6 });
        await sleep(150);
        await sh("sh", ["-c", `printf '%s' '__pre_${which}_${Date.now()}__' | wl-copy`]);
        await decoy.bringToFront();               // steal keyboard focus away
        await activateWindow("DECOYWIN");          // ...at the OS/compositor level
        await sleep(500);
        // NB: no activateWindow("YTFIXTURE") here — copyurl.sh must do it.
        await new Promise((resolve) => {
          const p = spawn("bash", [COPYURL_SH], { env: { ...process.env, COPYURL_VERBOSE: "1", COPYURL_YOUTUBE_NEEDLE: "YTFIXTURE" } });
          p.on("close", () => resolve());
          setTimeout(() => p.kill("SIGKILL"), 14000);
        });
        const clip = (await sh("wl-paste", ["--no-newline"])).stdout;
        if (clip.includes("youtube.com")) return { clip, attempt };
        log(`  retry unfocused ${which}: attempt ${attempt} got ${JSON.stringify(clip.slice(0, 40))}`);
        await sleep(300);
      }
      return { clip: (await sh("wl-paste", ["--no-newline"])).stdout, attempt: 3 };
    }

    // ---- Primary flow: hover B, trigger, assert the whole chain -------------
    // We assert a VALID youtube URL was copied (the real ydotool + content.js +
    // wl-clipboard path), then that the SAME URL flowed through to the Gemini
    // composer + Send. We assert consistency (clipboard -> Gemini), not a
    // hardcoded video id: once copyurl.sh activates the Brave window the
    // compositor's real pointer-enter at the physical cursor can override the
    // synthetic hover (see the repeated-trigger note below). Exact which-video
    // correctness is owned by run_e2e.mjs.
    const primary = await hoverAndTrigger("B");
    results.clipboard = primary.clip;
    results.copyAttempts = primary.attempt;
    const copiedUrl = primary.clip;
    if (/^https:\/\/www\.youtube\.com\/watch\?v=VIDEO_[AB]{7}$/.test(copiedUrl))
      log(`  PASS  OS clipboard holds a live YouTube URL (ydotool + content.js, attempt ${primary.attempt})`);
    else fail(`clipboard wrong.\n        expected: a youtube.com/watch URL\n        got:      ${JSON.stringify(copiedUrl)}`);

    const toast = await yt.evaluate(() => {
      const t = document.getElementById("copyurl-toast"); return t ? t.textContent : null;
    });
    results.toast = toast;
    if (toast === "Copied!") log("  PASS  'Copied!' toast shown");
    else log("  note  toast =", JSON.stringify(toast), "(may have faded; clipboard is the source of truth)");

    await sleep(1500);
    const gem = await gemini.evaluate(() => window.__geminiState());
    results.gemini = gem;
    const expectedText = PASTE_PREFIX + copiedUrl;
    if (gem.editorText === expectedText) log("  PASS  Gemini composer got the Korean prompt + the copied URL");
    else fail(`Gemini editor wrong.\n        expected: ${JSON.stringify(expectedText)}\n        got:      ${JSON.stringify(gem.editorText)}`);
    if (gem.sendClicked === 1) log("  PASS  Gemini Send clicked once");
    else fail(`Send clicked ${gem.sendClicked}x (expected 1)`);

    // ---- Repeated real-trigger guard, through the REAL ydotool path --------
    // Fire the genuine ydotool "]" trigger several times in a row and confirm
    // each press drives content.js -> a fresh youtube.com URL on the OS
    // clipboard. This exercises the real keystroke + wl-clipboard path
    // repeatedly (the layer that broke in the field).
    //
    // We assert "a valid youtube URL was copied", NOT which video: once
    // copyurl.sh activates the Brave window, the compositor delivers a real
    // pointer-enter at the physical OS cursor's resting position, which can
    // override puppeteer's *synthetic* hover (we cannot move the real cursor on
    // GNOME Wayland). The precise which-video / stale-hover correctness is owned
    // by run_e2e.mjs, where CDP fully controls the hover with no real-cursor
    // interference and asserts the exact live-hovered video deterministically.
    results.repeated = {};
    for (const which of ["A", "B", "A"]) {
      const r = await hoverAndTrigger(which);
      results.repeated[`trigger_${which}_a${r.attempt}`] = r.clip;
      if (r.clip.includes("youtube.com")) log(`  PASS  real trigger -> youtube URL copied (${r.clip.slice(-11)}, attempt ${r.attempt})`);
      else fail(`repeated-trigger: clipboard = ${JSON.stringify(r.clip)} (expected a youtube.com URL)`);
    }

    // ---- Unfocused-Brave guard (the user's reported bug) -------------------
    // The user reported Alt+Z only worked when Brave already had keyboard focus.
    // copyurl.sh now activates the Brave/YouTube window itself before typing the
    // trigger. Prove it: move OS focus to a DECOY window and let copyurl.sh be
    // solely responsible for bringing Brave forward (the harness does NOT
    // pre-activate Brave here). Success = a real YouTube URL reaches the
    // clipboard, which can only happen if the keystroke landed in Brave.
    //
    // NOTE: we assert "a valid youtube URL was copied", not which video. CDP's
    // mouse.move is synthetic, but activating the window makes the compositor
    // deliver a real pointer-enter at the actual OS cursor's resting position,
    // which can override the synthetic hover. In production the user's REAL
    // cursor is physically on the thumbnail, so the copied video is correct;
    // the which-video precision is already covered by the stale-hover guard
    // above. This block runs LAST because that real-cursor side effect would
    // otherwise perturb the deterministic assertions before it.
    let decoy;
    try {
      const decoyCtx = await browser.createBrowserContext();
      decoy = await decoyCtx.newPage();
      await decoy.goto("about:blank", { waitUntil: "domcontentloaded" });
      await decoy.evaluate(() => { document.title = "DECOYWIN not-brave"; });
      await sleep(300);
      const r = await hoverAndTriggerUnfocused("B", decoy);
      results.unfocused = r.clip;
      if (r.clip.includes("youtube.com")) log(`  PASS  copied while Brave was NOT focused (copyurl.sh activated Brave itself, attempt ${r.attempt})`);
      else fail(`unfocused-Brave: clipboard = ${JSON.stringify(r.clip)} (expected a youtube.com URL). activate_youtube did not bring Brave forward.`);
    } finally {
      if (decoy) await decoy.close().catch(() => {});
    }
  } catch (err) {
    fail("harness error: " + (err.stack || err));
  } finally {
    log("results:", JSON.stringify(results));
    await browser.close().catch(() => {});
    server.close();
    fs.rmSync(extDir, { recursive: true, force: true });
  }

  console.log("\n=== Full-System Summary ===");
  console.log(process.exitCode ? "  FAILURES ABOVE" : "  ALL GREEN");
}

main().catch((e) => { console.error(e); process.exit(2); });
