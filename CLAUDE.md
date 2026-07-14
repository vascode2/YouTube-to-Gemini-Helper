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
3. **Gemini Chrome PWA** — receives a synthetic "New chat" click (left-rail pencil), then a composer click + Ctrl+A/Ctrl+V/Enter. The new-chat click (since v2026-06-25.7) starts a fresh thread each time so a previously-refused conversation doesn't keep refusing the same URL.

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
| 2026-06-23 | Alt+Z fast path: copy the hovered video immediately when YouTube is already foreground (release Alt synthetically, send F24, no activation/jitter) before the Gemini handoff | Pins the copy to the thumbnail under the cursor at press time (moving the mouse afterward no longer changes what's copied), and lets the content-script "Copied!" toast render on the still-focused YouTube tab. `kToastDwellMs` (default 450) keeps YouTube in front briefly so the toast is visible. Slow/activation path unchanged as fallback. |
| 2026-06-23 | Slow/activation path now syncs hover at the PRESS-TIME cursor (origX,origY captured at handler start) via `SyncChromiumHoverAtScreenPoint` instead of the live cursor; toast dwell (`kToastDwellMs`, now 900) moved to the common section so BOTH paths show the bubble | The slow path is hit on every copy after the first (focus moves to Gemini, so YouTube isn't foreground next press). It previously jittered at the live cursor → copied the moved-onto video and showed no toast. Syncing at the captured press-time point copies the originally-hovered video; PostMessage-only so the user's real cursor isn't snapped back. |
| 2026-06-25 | AHK-native "Copied!" toast (`ShowCopiedToast`, `kAhkToast`) drawn by the script near the press-time cursor on every successful copy; `kToastDwellMs` defaulted back to 0 | The page's content-script bubble never reliably appeared once the flow switched to Gemini: it depends on a fresh content.js in the open tab AND the tab staying focused. Logs showed copy succeeding but `beacon=none` every time. A script-drawn click-through GUI is independent of browser/extension state, so the confirmation always shows; dwell no longer needed → no added Gemini latency. |
| 2026-06-26 | Reverted to a SINGLE confirmation = the content-script bubble above the thumbnail. Disabled the AHK cursor toast (`kAhkToast := false`, code retained) and restored `kToastDwellMs` (0 → 700) so the page bubble is visible again on both paths. Restyled the content.js bubble to a modern rounded pill (12px radius, `rgba(28,28,30,.96)` fill, blur, green `✓` for success). | User reported two bubbles on the watch page (redundant) and the preferred upper/page bubble vanishing on the YouTube home page. Geometry confirmed upper = content.js page toast (above thumbnail), lower = AHK cursor toast. The home-page regression traced to `kToastDwellMs` 900→0 (YouTube dropped to background before the bubble was seen). Restoring dwell + disabling the AHK toast yields one nice bubble where the user wants it. Trade-off: dwell re-adds ~700ms before the Gemini paste; tunable (lower if YouTube is on a separate monitor). |
| 2026-06-26 | Reverted per-paste new-chat (`kGeminiNewChatEachTime := false`, v2026-06-25.8). | User prefers keeping related summaries in ONE Gemini thread so the conversation builds on itself (videos are often on a related topic). The new-chat mechanism is retained behind the flag; flip back to true if a stale thread starts refusing videos again. |
| 2026-06-26 | content.js `showToast` positioning hardened: new `bestVisibleRect(anchor)` climbs up to 6 ancestors to find a non-degenerate on-screen rect, and the no-anchor fallback moved from bottom-center (`bottom:24px`) to top-center (`top:76px`). | User: the "Copied!" bubble shows on the watch-page right panel but NOT on the YouTube home page; it used to appear "at the top of the screen." Root cause: on the home page, hovering a thumbnail makes YouTube swap in an inline video-preview overlay that collapses the `a#thumbnail` anchor to a 0-size rect → old `anchorVisible` check failed → toast fell back to bottom-center (off the user's view). Climbing to the still-solid renderer container (`ytd-rich-item-renderer` etc.) restores the above-thumbnail bubble; the top-center fallback keeps it visible even with no usable anchor. Watch-page case unchanged (anchor rect valid at depth 0). Requires extension reload in brave://extensions. |
| 2026-07-13 | (macOS) `findVideoAnchor` now recognizes the home-page inline preview overlay (`ytd-video-preview` / `#video-preview`) as a container; its `#media-container-link` (`/watch?v=…`) is resolved by the existing container fallback query. Mac `init.lua` (v22) reads the content.js title beacon during the copy-wait loop and logs `beacon=STATE`, with distinct notifications for `null` (no thumbnail under cursor) vs `no-beacon` (extension didn't respond → reload tab). `BEACON_TTL_MS` 300→700 so the macOS document.title→window-title propagation doesn't lose the beacon read. | User reported "URL copy failed" on the YouTube **home page**; log showed `copy-wait done: changed=false len=7526` (clipboard never written). On the home page the inline muted preview steals the element under the cursor out of the thumbnail's renderer, so the ancestor walk found no `<a>` → `hoveredVideoUrl` null → early return, no copy. Watch pages resolve the anchor directly, hence the intermittency. Beacon logging makes future failures self-diagnosing on macOS (previously only Windows/AHK surfaced it). Requires extension reload in brave://extensions + YouTube tab reload to pick up content.js. |

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

**Last updated:** `2026-07-14T17:26:29Z`

**Recent commits (last 5 on HEAD):**

- `1b1fe28` fix(mac): reliable Gemini paste via AX composer focus + async activate _(11 days ago)_
- `c7f86f8` feat(mac): restore live v15 config + add toast-dwell (v16) _(13 days ago)_
- `fe14906` fix(gemini+toast): dark-theme composer scan, faster paste, single home-page bubble _(3 weeks ago)_
- `9b35990` fix(gemini): robust, self-verifying composer insertion (v1.2.8) _(4 weeks ago)_
- `6fa4348` docs: document unfocused-Brave Alt+Z behaviour (Linux) _(4 weeks ago)_

**Files in the pending commit:**

- `CLAUDE.md`
- `Mac/hammerspoon/init.lua`
- `content.js`
<!-- AUTO:RECENT-ACTIVITY:END -->
