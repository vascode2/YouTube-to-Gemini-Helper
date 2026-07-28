# CLAUDE.md — CopyYoutubeURL handoff

> Living handoff doc. Update at every phase boundary. Future agent sessions should read this first.

## ⚠️ Runtime location of copy.ahk (read this first)
As of 2026-07-14 the project lives in a **local Git clone** and Startup launches it
**directly** — there is **no more mirror/copy step**:

- **Authoritative working copy (edit here):** `C:\Users\Yoon\Projects\CopyYoutubeURL\copy.ahk`
- **How it starts at login:** `...\Startup\copy.ahk.lnk` (a shortcut) runs
  `AutoHotkey64.exe "C:\Users\Yoon\Projects\CopyYoutubeURL\copy.ahk"`.
  There is **no raw `copy.ahk` in the Startup folder anymore** (the old one was
  archived as `Startup\copy.ahk.pre-migration-backup`).
- **Running log:** `copyurl_log.txt` now sits **next to the clone's copy.ahk**
  (`A_ScriptDir` = the clone). It is **gitignored**, so it never dirties the repo.
  Read it from `C:\Users\Yoon\Projects\CopyYoutubeURL\copyurl_log.txt` when diagnosing.

**Edit loop (no copying):** edit `copy.ahk` in the clone → tray icon → **Reload Script**
(or `/validate` first). That's it.

Optional validate before reloading:

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate `
  "C:\Users\Yoon\Projects\CopyYoutubeURL\copy.ahk"
```

> Historical note: this repo used to run from Google Drive
> (`G:\My Drive\Projects\CopyYoutubeURL`) and required a validate → copy-to-Startup →
> SHA256 hash-check mirror ritual. That folder's `.git` became corrupted, so the
> project was re-cloned fresh from GitHub into `C:\Users\Yoon\Projects` and the
> Drive copy retired (renamed `..._backup`). If you see references to `My Drive` /
> `g:\...\copy.ahk` anywhere, they are stale.

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
| 2026-07-14 | Migrated Windows dev out of Google Drive to a fresh GitHub clone at `C:\Users\Yoon\Projects\CopyYoutubeURL`. Startup now runs the clone directly via `Startup\copy.ahk.lnk` (shortcut → `AutoHotkey64.exe "<clone>\copy.ahk"`); the old raw `Startup\copy.ahk` was archived as `copy.ahk.pre-migration-backup`. Added `.gitattributes` (LF policy) + fixed the stale E2E toast assertion (`✓Copied!`). Git identity set globally (`vascode2`). | The Drive folder's `.git` was corrupted (`git fsck`: bad objects/refs, no resolvable HEAD) and Google Drive's CRLF/exec-bit churn kept dirtying the tree. GitHub already had the newest state (Drive copy only differed by an OLDER package-lock 1.2.6 vs 1.2.8 + line endings), so nothing needed recovery. Running from the clone removes the fragile validate→copy→hash-check mirror ritual: edit in the clone, tray → Reload Script. |
| 2026-07-17 | macOS internal copy trigger changed from Option+X to `]` (BracketRight, no modifiers) — same key Linux already uses. `hs.eventtap.keyStroke({}, "]", 0, ytApp)` in `init.lua`'s `runFlowInner`, now explicitly targeted at the YouTube app (4th arg) instead of the untargeted global form. content.js's `isBracketKey` branch already existed (for Linux) and needed no changes; only comments were updated. | Live debugging (real mouse hover + synthetic keystrokes via Hammerspoon's AppleScript bridge) reproducibly showed Option+X keydowns never reaching content.js's listener at all on the current Brave/macOS combo, while `]` always did. Tried F19 (no printable char, no known OS/Karabiner binding) as an intermediate fix, but synthetic F13-F20 keydowns sent via Hammerspoon never reached content.js either (no title beacon, no clipboard change) — macOS appears to swallow them as system-defined/media-key events before Chromium sees a normal keydown, at least via this synthesis path. Confirmed `]` is safe to reuse on macOS: Gemini runs as a separate Safari Web App (see `geminiBundleId`), which never loads the Brave extension, so `]`'s Linux-only `queueGeminiPaste()` side effect is an inert no-op on this Mac. Also found the untargeted `hs.eventtap.keyStroke({}, "]", 0)` occasionally failed to reach Brave even when it was frontmost; passing the app explicitly as the 4th argument was reliable across repeated tests. Verified full real-hotkey (Option+Z) end-to-end: real hover → copy succeeds → Gemini paste lands → submits → correct Korean summary of the actually-hovered video. |
| 2026-07-17 | (macOS) Gemini paste path hardened again after live failure (`Gemini paste failed` with `copy-wait changed=true`). `pasteAndSubmitToGemini` now prefers direct AX insertion (`composer:setAttributeValue("AXValue", payload)`) over Cmd+V, with Cmd+V retained as fallback. Added pre-paste idle wait when Gemini is still generating, and richer diagnostics (`preSend` / `lastSend`). | User report + log evidence: copy succeeded (`changed=true len=43`) but paste verification failed twice with `lastLen=1` and submission was skipped. Root cause: Cmd+V into Gemini's web composer is intermittently ignored/late in the Safari Web App, and the AX tree can expose near-empty composer text while still in a transient state. Direct AX value-set is deterministic on this build and avoids keyboard-event delivery flakiness. Verified immediately after patch: `paste: AXValue set ok`, `paste verify: landed=true urlMatch=true`, `send-button: AXPress ok=true`, `submit confirmed empty composer`, `notify: paste-test sent`. |
| 2026-07-17 | (macOS) Gemini **submit** hardened in `pasteAndSubmitToGemini` (Mac `init.lua`, both repo v22 + runtime v26). Three linked fixes: (1) **Submit via the AX "Send message" button** (`pressGeminiSendButton`: walk the AX tree for an enabled `AXButton` whose `AXDescription`/`AXTitle` is "Send message", `performAction("AXPress")`) instead of a synthetic Return; Return is kept only as a fallback. The button reports `AXEnabled=true` the instant the paste lands but its click handler isn't wired until the composer settles, so the press is done after a 0.35s settle and **retried up to 3×, each time confirming the composer actually emptied**. (2) **Paste verification polls** for up to ~1.6s (6×0.25s) for the composer to become non-empty, and matches on the stable `expectedUrl` param passed straight from `runFlowInner` (URL match OR non-empty-composer fallback ≥10 chars) — no longer compares against a fresh `hs.pasteboard.getContents()` snapshot. (3) **2s debounce** on `runFlow` (`lastFlowAt`) so a rapid second Option+Z can't race on the clipboard. | User: "paste landed but Enter wasn't pressed" (composer showed `URL 한국어로 요약해 줘` un-submitted). Live testing (Hammerspoon bridge + AX reads + screenshots) proved the real cause: a global `hs.eventtap.keyStroke({}, "return")` reports `ok=true` but Gemini's Safari WebApp simply ignores it — the composer keeps its text. AXPress on the send button submits every time. Two secondary failure modes surfaced during A/B runs and are also handled: the old clipboard-snapshot verify could disagree with what was pasted when runs overlapped (→ landed=false, Return skipped), and when Gemini was still generating a prior answer the composer read `composerLen=1` at the single 0.25s mark even though the paste landed a beat later (→ verify skipped submit, prompt left un-sent). Note: on Mac the title **beacon read is unreliable** — `beacon=no-beacon` appears in the log even on *successful* copies (14:30/15:18 `changed=true`), so `changed=` is the real copy signal, not the beacon. The synthetic-mouse hover in the test harness never establishes content.js's `hoveredVideoUrl` (mouseover isn't triggered by eventtap), so copy could only be verified via physical-hover log history, not automated hover. |
| 2026-07-26 | **Discovered the live `~/.hammerspoon/init.lua` (CONFIG_VERSION v42) had silently diverged from the repo's `Mac/hammerspoon/init.lua` (v22) and regressed two previously-fixed reliability bugs.** It is a real file, not a symlink to the repo (an old symlink backup `init.lua.link.bak.20260714_192409` shows one existed once but was replaced), and is also used for unrelated personal automation (display/window layout management), so it evolves independently and can silently lose CopyURL fixes. Fixed in the live file only (repo's `Mac/hammerspoon/init.lua` already had both fixes): (1) `hs.eventtap.keyStroke({}, "]", 0)` was missing the `ytApp` 4th-arg target from the 2026-07-17 fix — reverted to the untargeted/global form, so the "]" trigger silently failed to reach Brave's content.js on every press regardless of hover state (`beacon=no-beacon`, `changed=false`). (2) `pasteAndSubmitToGemini` had reverted to the pre-2026-07-17 version (Cmd+V only, single 0.25s verify, submit via global Return) — missing `pressGeminiSendButton`/`isGeminiSendEnabled`/`isGeminiGenerating` and the AXValue-direct-set + retrying-AX-submit logic entirely. | User reported "Alt+Z 눌러도 아무것도 안 됨" / "Extension didn't respond" on every press, tab-reload did not help. `~/Library/Logs/CopyURL.log` showed 100% `beacon=no-beacon` even right after a fresh reload — inconsistent with an orphaned-content-script theory (that would be intermittent, not deterministic). Diffing the live file against the repo's tracked version (`diff Mac/hammerspoon/init.lua ~/.hammerspoon/init.lua`) revealed large unrelated additions (fixdisplays, layout-memory, wake-mouse) AND the missing `ytApp` arg AND the missing paste/submit hardening — i.e. the live file had been rolled back to (or never received) the fixes described in the two entries directly above, despite reporting a *higher* CONFIG_VERSION number (v42 > v26/v22). Ported both fixes verbatim from the repo into the live file (auto-reloads via `hs.pathwatcher` on `~/.hammerspoon/`); verified via `open "hammerspoon://copyurl-test"` immediately after: `changed=true len=43` confirmed the copy step now works end-to-end when a real thumbnail is actually hovered. **Actionable takeaway for future sessions**: when diagnosing "it doesn't work" on macOS, always `diff` the repo's `Mac/hammerspoon/init.lua` against the live `~/.hammerspoon/init.lua` first — CONFIG_VERSION alone does not prove the CopyURL-relevant code is current, since that file also tracks unrelated personal-automation history. |
| 2026-07-27 | **Switched macOS Gemini target from the Safari Web App (PWA) to the official native Gemini macOS app** (`com.google.GeminiMacOS`, installed from https://gemini.google/mac/, both `/Applications/Gemini.app` and `~/Applications/Gemini.app` existed — the PWA and native app coexist as separate bundle IDs, no conflict). `geminiBundleId` in `Mac/hammerspoon/init.lua` updated; old PWA ID kept commented for rollback. Investigated the native app's live accessibility tree via a temporary `hs.urlevent`-triggered AX-dump handler (composer filled via direct `AXValue` set, then re-dumped to reveal the send button) rather than guessing: confirmed it embeds its chat UI in a **WKWebView** (`CanvasWKWebView` string found in the binary), so the existing AX-driven composer/paste/submit architecture carries over — only label/identifier strings differ. Native app's composer is `AXTextArea desc="Ask Gemini"` (already matched by the existing `:find("gemini")` check, no change needed); its Send button is `AXButton id="send_button" desc="Submit"` (**did not** match the PWA's `desc=="Send message"` check — this was the one real code change: `pressGeminiSendButton`/`isGeminiSendEnabled` now also match `AXIdentifier=="send_button"` or `desc/title=="Submit"`, alongside the old PWA strings so both remain supported); its "generating" indicator is `AXButton id="stop_button" desc="Stop response"` (already matched by the existing `"stop response"` substring check, `AXIdentifier=="stop_button"` added anyway for robustness). **Also re-discovered the same live-file divergence pattern as 2026-07-26**: `~/.hammerspoon/init.lua` (CONFIG_VERSION v43) had *again* regressed to pre-2026-07-17 Gemini logic (missing `pressGeminiSendButton`/`isGeminiSendEnabled`/`isGeminiGenerating`, old `pasteAndSubmitToGemini(geminiApp)` signature without `expectedUrl`, `hs.eventtap.keyStroke({}, "]", 0)` missing the `ytApp` 4th arg) — this had clearly reverted again sometime after the 2026-07-26 fix, independent of this session's changes. Fully re-synced by replacing the entire CopyURL section (lines 1 through the `copyurl-*` url-event bindings) in the live file with the updated repo content, byte-for-byte except `CONFIG_VERSION`, while leaving all unrelated live-only automation (zoom, fixdisplays, layout-memory, uBar nudge, English-study `dofile`) untouched; a full backup was saved as `~/.hammerspoon/init.lua.bak_before_gemini_switch`. Verified via `open "hammerspoon://copyurl-test-paste"` (bypasses the YouTube hover/copy step, exercises only the Gemini paste+submit): log showed `frontmost before paste: Gemini` → `paste: AXValue set ok len=72` → `paste verify: landed=true urlMatch=true sendEnabled=true` → `send-button: AXPress ok=true` → `submit confirmed empty composer on attempt 1` — full success against the native app. | User wanted to stop relying on the thin Safari-WebApp wrapper and use the officially-supported native Gemini app instead, but asked to compare the two installs and investigate the native app's structure *before* committing to any code changes, given the AX-tree-dependent nature of this integration. Investigating via a live, disposable `hs.urlevent` debug handler (rather than reading Apple/Google docs, which don't expose AX internals) was the only way to get ground truth on the exact identifiers/labels Send/Stop buttons use — guessing wrong here would have silently broken submission (composer fills fine via AXValue regardless of app, so a naive test could look like partial success while never actually sending). The recurrence of the live-file divergence (2nd time in ~24h) confirms the 2026-07-26 entry's takeaway holds: this is a structural risk of the live file being real-not-symlinked and shared with unrelated automation, not a one-off fluke — **future sessions should proactively diff `Mac/hammerspoon/init.lua` vs `~/.hammerspoon/init.lua` at the start of any macOS CopyURL work**, not just when troubleshooting a reported failure, since the live file can silently regress without any user-visible trigger. |

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
- Linux port: `Linux/` (Ubuntu/GNOME Wayland; `ydotool` + `wl-clipboard` + *Activate Window By Title* GNOME extension; **Alt+Z** via GNOME custom shortcut). Orchestrator: `Linux/copyurl.sh`. On this Wayland setup `ydotool key`/`mousemove` are unreliable, so the trigger is `ydotool type "]"` (content.js also fires on `]`/BracketRight while hovering) and the **paste is done in-browser**: content.js queues URL+`PASTE_SUFFIX` into `chrome.storage.local`, and a Gemini content script (`gemini.js`, matches `gemini.google.com`) inserts it into the composer via the DOM and clicks send. Copy success is detected by polling `wl-paste` (no clipboard sequence number on Wayland). Requires the `storage` permission. See `Linux/README.md`.

## Out of scope
- Gemini paste/Enter rewrite (separate test_enter*.ahk experiments).
- Native-messaging / background-script architecture.


<!-- AUTO:RECENT-ACTIVITY:BEGIN -->
<!-- This block is regenerated by .githooks/pre-commit on every commit.
     Do not edit by hand — your changes will be overwritten. -->

**Last updated:** `2026-07-17T16:13:55Z`

**Recent commits (last 5 on HEAD):**

- `ac4cabd` docs: reflect Google-Drive->local-clone migration + Startup shortcut _(3 days ago)_
- `a00001e` chore: enforce LF line endings + fix stale E2E toast assertion _(3 days ago)_
- `f35efb5` chore: sync package-lock version to 1.2.8 (regenerated by npm install) _(3 days ago)_
- `186813d` chore: track package-lock.json, untrack generated test log, tidy .gitignore _(3 days ago)_
- `d00a3fa` feat(mac): add Cmd/Ctrl+scroll-wheel page zoom to Hammerspoon config _(3 days ago)_

**Files in the pending commit:**

- `copy.ahk`
<!-- AUTO:RECENT-ACTIVITY:END -->
