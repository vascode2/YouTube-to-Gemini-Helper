#!/usr/bin/env node
// End-to-end test for the CopyURL Linux flow using the REAL extension.
//
// Unlike scripts/run_tests.sh (which mocks chrome.* and loads gemini.js by
// hand), this harness loads the actual unpacked extension into a real Brave
// instance via puppeteer-core, opens a YouTube fixture and a Gemini fixture in
// the SAME browser profile, simulates a real hover + trigger keypress, and
// asserts the hovered video's URL flows content.js -> chrome.storage.local ->
// gemini.js -> composer -> Send click. This is the genuine cross-page handoff
// that fails in the field, which a single-page mock cannot exercise.
//
// Usage:  node tests/e2e/run_e2e.mjs            (headless)
//         HEADFUL=1 node tests/e2e/run_e2e.mjs  (watch it run)
//
// Exit 0 = pass, non-zero = failure (with a diagnostic dump).

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..", "..");
const FIXTURES = path.join(__dirname, "fixtures");
const PASTE_PREFIX = "한국말로 요약해줘 - ";

// ---- tiny helpers ----------------------------------------------------------
const log = (...a) => console.log("[e2e]", ...a);
const fail = (msg) => { console.error("\n  FAIL  " + msg + "\n"); process.exitCode = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findBrave() {
  const candidates = [
    process.env.BRAVE_PATH,
    "/usr/bin/brave-browser",
    "/usr/bin/brave",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch {}
  }
  throw new Error("No Chromium-based browser found (set BRAVE_PATH).");
}

// ---- 1. static fixture server ---------------------------------------------
// /youtube -> youtube.html, /gemini -> gemini.html. Served on localhost so the
// rewritten content-script match patterns (http://localhost/youtube* etc) hit.
function startServer() {
  const routes = {
    "/youtube": path.join(FIXTURES, "youtube.html"),
    "/gemini": path.join(FIXTURES, "gemini.html"),
  };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/favicon.ico") { res.writeHead(204); res.end(); return; }
    const file = routes[url.pathname];
    if (!file) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(fs.readFileSync(file));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

// ---- 2. temp extension with localhost-rewritten manifest -------------------
function buildTempExtension() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "copyurl-ext-"));
  // Copy the scripts AND the icon files — Brave refuses to load an unpacked
  // extension whose manifest references missing icons.
  for (const f of ["content.js", "gemini.js", "icon16.png", "icon48.png", "icon128.png"]) {
    const src = path.join(ROOT, f);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dir, f));
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, "manifest.json"), "utf8"));
  // Repoint content-script matches at the local fixture server. Match patterns
  // ignore the port, so http://localhost/youtube* matches any localhost port.
  manifest.content_scripts = [
    { matches: ["http://localhost/youtube*"], js: ["content.js"], run_at: "document_idle", all_frames: false },
    { matches: ["http://localhost/gemini*"], js: ["gemini.js"], run_at: "document_idle", all_frames: false },
  ];
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify(manifest, null, 2));
  return dir;
}

async function main() {
  const { server, port } = await startServer();
  const extDir = buildTempExtension();
  const headful = process.env.HEADFUL === "1";
  log(`fixture server on :${port}, extension at ${extDir}, headful=${headful}`);

  const browser = await puppeteer.launch({
    executablePath: findBrave(),
    headless: headful ? false : "new",
    args: [
      `--disable-extensions-except=${extDir}`,
      `--load-extension=${extDir}`,
      "--no-sandbox",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
    ],
  });

  const results = {};
  try {
    const base = `http://localhost:${port}`;

    // Open Gemini FIRST so gemini.js is registered as a storage listener before
    // the payload is queued (mirrors "Gemini tab already open" in real use).
    const gemini = await browser.newPage();
    gemini.on("console", (m) => log("gemini.console:", m.text()));
    gemini.on("pageerror", (e) => log("gemini.pageerror:", e.message));
    await gemini.goto(`${base}/gemini`, { waitUntil: "domcontentloaded" });
    await sleep(800); // let gemini.js attach listeners

    // Open YouTube and perform a real hover + trigger.
    const yt = await browser.newPage();
    yt.on("console", (m) => log("yt.console:", m.text()));
    yt.on("pageerror", (e) => log("yt.pageerror:", e.message));
    await yt.goto(`${base}/youtube`, { waitUntil: "domcontentloaded" });
    await yt.bringToFront();
    await sleep(400);

    // Hover the FIRST card, then the SECOND — the trigger must copy the SECOND
    // (live hover), guarding the stale-hover regression.
    const boxA = await yt.$eval('[data-testid="overlay-a"]', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    });
    const boxB = await yt.$eval('[data-testid="overlay-b"]', (el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    });
    await yt.mouse.move(boxA.x, boxA.y, { steps: 4 });
    await sleep(150);
    await yt.mouse.move(boxB.x, boxB.y, { steps: 4 });
    await sleep(150);

    // Fire the Linux trigger key.
    await yt.keyboard.press("BracketRight");
    await sleep(300);

    // Assert the "Copied!" toast appeared.
    const toastText = await yt.evaluate(() => {
      const t = document.getElementById("copyurl-toast");
      return t ? t.textContent : null;
    });
    results.toast = toastText;
    // content.js renders a success toast as a green "✓" span + a "Copied!"
    // label span, so textContent is "✓Copied!". Assert the label is present
    // rather than exact-matching (which broke when the checkmark was added).
    if (toastText && toastText.includes("Copied!")) log("  PASS  'Copied!' toast shown on YouTube");
    else fail(`toast not shown (got ${JSON.stringify(toastText)})`);

    // Give gemini.js time to receive the storage change, insert, and submit.
    await sleep(1500);
    const gem = await gemini.evaluate(() => window.__geminiState());
    results.gemini = gem;

    const expected = PASTE_PREFIX + "https://www.youtube.com/watch?v=VIDEO_BBBBBBB";
    if (gem.editorText === expected) log("  PASS  Gemini composer got the correct (live-hover) URL");
    else fail(`Gemini editor text wrong.\n        expected: ${JSON.stringify(expected)}\n        got:      ${JSON.stringify(gem.editorText)}`);

    if (gem.sendClicked === 1) log("  PASS  Gemini Send clicked exactly once");
    else fail(`Send click count = ${gem.sendClicked} (expected 1)`);

    if (gem.sendClickedWhileDisabled === 0) log("  PASS  Send was never clicked while disabled");
    else fail(`Send clicked while disabled ${gem.sendClickedWhileDisabled}x`);
  } catch (err) {
    fail("harness error: " + err.stack);
  } finally {
    log("results:", JSON.stringify(results));
    await browser.close().catch(() => {});
    server.close();
    fs.rmSync(extDir, { recursive: true, force: true });
  }

  console.log("\n=== E2E Summary ===");
  console.log(process.exitCode ? "  FAILURES ABOVE" : "  ALL GREEN");
}

main().catch((e) => { console.error(e); process.exit(2); });
