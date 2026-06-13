# CLAUDE.md — CopyYoutubeURL handoff

> Living handoff doc. Update at every phase boundary. Future agent sessions should read this first.

## ⚠️ Runtime location of copy.ahk (read this first)
The user runs [copy.ahk](copy.ahk) from the **Windows Startup folder**, not from this repo. After every edit to the workspace copy you MUST mirror it to:

```
C:\Users\Yoon\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\copy.ahk
```

and verify by SHA256 match. The running log [copyurl_log.txt](copyurl_log.txt) also lives next to that Startup copy (`A_ScriptDir`), not in this repo — read it from the Startup folder when diagnosing. Reload after copying: tray icon → Reload Script (workspace `copyurl_log.txt` will usually be absent/stale).

PowerShell one-liner (validate → sync → hash-check):

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate "g:\My Drive\Projects\CopyYoutubeURL\copy.ahk"
if ($LASTEXITCODE -eq 0) {
    Copy-Item "g:\My Drive\Projects\CopyYoutubeURL\copy.ahk" `
              "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\copy.ahk" -Force
    (Get-FileHash "g:\My Drive\Projects\CopyYoutubeURL\copy.ahk" -Algorithm SHA256).Hash
    (Get-FileHash "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\copy.ahk" -Algorithm SHA256).Hash
}
```

## What this project does
Hover a YouTube thumbnail in Brave/Chrome → press **Alt+Z** (only user-facing hotkey) → AutoHotkey activates the YouTube window, sends **F24** inside the tab as the internal extension trigger (F24 chosen to avoid collision with other tools' global hotkeys, e.g. CopyAnkitoChatGPT owns Alt+X), the extension copies the hovered video's URL to the OS clipboard, then AHK switches to the Gemini Chrome app and pastes a "Summarize this YouTube video:" prompt + URL and presses Enter.

## Architecture (3 cooperating processes)
1. **Browser content script** ([content.js](content.js)) — tracks hovered video, listens for Alt+X, writes URL to clipboard via synchronous `document.execCommand("copy")` (with async `navigator.clipboard.writeText` fallback).
2. **AutoHotkey v2 script** ([copy.ahk](copy.ahk)) — global Alt+Z handler. Activates Brave, syncs hover (PostMessage WM_MOUSEMOVE jitter), sends Alt+X, polls `GetClipboardSequenceNumber` until it changes, then drives Gemini paste.
3. **Gemini Chrome PWA** — receives synthetic click + Ctrl+A/Ctrl+V/Enter.

No background script, no native messaging, no host permissions beyond the YouTube content-script match.

## Reported problem
"Copy feature sometimes works but sometimes does not." Logs in [copyurl_log.txt](copyurl_log.txt) show clusters of `Copy attempt N timed out` with no diagnostic about *which* leg failed (extension didn't fire? `hoveredVideoUrl` null? execCommand returned false? OS clipboard never updated?).

## Suspected root causes (ranked)
0. **(FIXED 2026-05-02) Alt+X collision with CopyAnkitoChatGPT**: that app's global Alt+X hook intercepted the synthetic Alt+X before it reached Brave, so the extension never received the keydown. Replaced with **F24** (no global binding).
1. **execCommand → async fallback race**: `execCommand` returns false; code calls `navigator.clipboard.writeText` (async); AHK's per-attempt 1500 ms clipboard-sequence wait can expire before the promise resolves.
2. **Stale `hoveredVideoUrl`**: `mouseout` cleared it; `refreshHoverFromLastPointer()` couldn't re-find from stale coordinates after window activate.
3. **Pre-copy `SendInput("{Escape}")`** ([copy.ahk](copy.ahk)) blurs/cancels page state in unhelpful ways.
4. **MV3 re-injection race**: tab reload / SPA navigation before listener attached.

## Plan (6 phases — see [/memories/session/plan.md](.) in agent memory)
- **Phase 0** *(this commit)*: handoff scaffolding — `CLAUDE.md`, `docs/troubleshooting.md`.
- **Phase 1**: opt-in instrumentation — content.js ring-buffer + `document.title` beacon `[CU:ok|null|err|busy]`; copy.ahk pre/post-title logging + per-stage timing; log rotation.
- **Phase 2**: stress harness — `scripts/stress_copy.ahk` + `scripts/analyze_stress.py`.
- **Phase 3**: targeted fixes A–E (async-clipboard race, stale hover, Escape, MV3 readiness, Alt collision) — each independently revertable, each gated by N=200 stress run.
- **Phase 4**: validation (≥99% success, zero "no-beacon" outcomes).
- **Phase 5**: default flags OFF, instrumentation stays.

## Decision log
| Date | Decision | Rationale |
|---|---|---|
| 2026-05-02 | Cross-process telemetry via `document.title` suffix beacon | Zero new permissions, no native messaging, AHK can read via `WinGetTitle`. |
| 2026-05-02 | All instrumentation behind flags, default OFF after Phase 5 | Keep code paths intact; zero behavior change. |
| 2026-05-02 | Stress target = a fixed YouTube watch page with autoplay off | Reduce environmental variance during A/B testing. |

## Diagnostic flags
- **Extension**: set `localStorage.__copyurlDebug = "1"` on a youtube.com page (persisted). Enables ring buffer at `window.__copyurlLog` (last 200 events) and `console.debug("[CopyURL]", ...)` output. Title beacon is **always on** (cheap, invisible suffix using zero-width char + tag).
- **AutoHotkey**: `kVerboseLog := true` at top of [copy.ahk](copy.ahk) — adds per-stage timing + pre/post title in the log.

## Title beacon protocol (contract)
After every F24 keydown the extension processes, it appends ` ​[CU:STATE]` (zero-width-space + tag) to `document.title` for ~300 ms, then restores. STATE ∈ `ok | null | execfail | asyncok | asyncfail`. AHK reads via `WinGetTitle` immediately after sending F24 and parses the tag with `RegExMatch`.

## Current status
- Phase 0 + Phase 1 implemented.
- Gemini click path now cursorless: `PostClickAtScreen` posts `WM_MOUSEMOVE` + `WM_LBUTTONDOWN/UP` directly to the largest `Chrome_RenderWidgetHostHWND` (no `Click()` / `MouseMove`). OS cursor stays put through the entire flow.
- Composer Y is found via native `PixelSearch` (BitBlt) instead of a per-pixel `PixelGetColor` loop — scan dropped from ~11 s to <200 ms on the user's display.
- `#MaxThreadsBuffer true` so a second Alt+Z press while the first handler is still running gets queued instead of dropped.
- Awaiting first stress-harness run.

## Next steps (resume here)
1. Reload extension in Brave/Chrome (`brave://extensions` → reload).
2. Reload [copy.ahk](copy.ahk) (tray → Reload Script).
3. Trigger Alt+Z 3–5×; confirm new log lines (`pre_title`, `post_title`, `beacon`) in [copyurl_log.txt](copyurl_log.txt).
4. Move to Phase 2 (stress harness).

## Files touched per phase
- **Phase 0**: `CLAUDE.md`, `docs/troubleshooting.md`.
- **Phase 1**: `content.js`, `copy.ahk`.
- **Phase 2** (planned): `scripts/stress_copy.ahk`, `scripts/analyze_stress.py`.
- **Phase 3** (planned): `content.js`, `copy.ahk`.

## Platform ports (kept in separate folders, extension is shared)
- macOS port: `Mac/` (Hammerspoon, **Option+Z**).
- Linux port: `Linux/` (Ubuntu/GNOME Wayland; `ydotool` + `wl-clipboard` + *Activate Window By Title* GNOME extension; **Alt+Z** via GNOME custom shortcut). Orchestrator: `Linux/copyurl.sh`. On this Wayland setup `ydotool key`/`mousemove` are unreliable, so the trigger is `ydotool type "]"` (content.js also fires on `]`/BracketRight while hovering) and the **paste is done in-browser**: content.js queues `PASTE_PREFIX`+URL into `chrome.storage.local`, and a Gemini content script (`gemini.js`, matches `gemini.google.com`) inserts it into the composer via the DOM and clicks send. Copy success is detected by polling `wl-paste` (no clipboard sequence number on Wayland). Requires the `storage` permission. See `Linux/README.md`.

## Out of scope
- Gemini paste/Enter rewrite (separate test_enter*.ahk experiments).
- Native-messaging / background-script architecture.


<!-- AUTO:RECENT-ACTIVITY:BEGIN -->
<!-- This block is regenerated by .githooks/pre-commit on every commit.
     Do not edit by hand — your changes will be overwritten. -->

**Last updated:** `2026-05-24T01:38:14Z`

**Recent commits (last 5 on HEAD):**

- `8f88a66` feat(ahk): cursorless Gemini click + fast PixelSearch composer scan _(3 days ago)_
- `95fe02d` Add Korean summary prefix to Gemini paste _(2 weeks ago)_
- `cefe868` Remove 'Summarize this YouTube video:' prefix from Gemini paste _(2 weeks ago)_
- `8f07262` fix(ahk): try-guard ReadTitleBeacon; loosen URL validator; grace-loop clipboard re-read _(3 weeks ago)_
- `aeaf429` perf(ahk): sticky last-winner browser + fast-fail on beacon=none + tighter timeout (800ms) _(3 weeks ago)_

**Files in the pending commit:**

- `.githooks/pre-commit`
- `.gitignore`
- `CLAUDE.md`
- `Mac/README.md`
- `Mac/hammerspoon/init.lua`
- `README.md`
- `content.js`
- `copy.ahk`
- `docs/CopyYoutubeURL-explainer.html`
- `docs/troubleshooting.md`
- `scripts/chrome_test.ahk`
<!-- AUTO:RECENT-ACTIVITY:END -->
