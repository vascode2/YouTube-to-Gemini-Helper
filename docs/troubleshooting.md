# Troubleshooting CopyYoutubeURL

## Quick repro
1. Open YouTube in Brave; hover a thumbnail; press **Alt+Z**.
2. Watch [../copyurl_log.txt](../copyurl_log.txt) tail and the extension's DevTools console (Inspect on the youtube.com tab).

## Enable extension diagnostics
In the YouTube tab DevTools console:
```js
localStorage.__copyurlDebug = "1";
location.reload();
```
Then inspect after each Alt+Z:
```js
window.__copyurlLog   // ring buffer of last 200 events
```
Disable with `localStorage.removeItem("__copyurlDebug")`.

## Enable AHK verbose log
Edit top of [../copy.ahk](../copy.ahk): `kVerboseLog := true`. Tray → Reload Script.

## Title beacon (always on)
After every F24 the extension processes (F24 is AHK's internal trigger — Alt+Z is the user-facing hotkey), the page title gets a transient zero-width-space + tag suffix:

| Beacon | Meaning |
|---|---|
| `[CU:ok]` | execCommand wrote the URL synchronously. |
| `[CU:null]` | Extension fired but `hoveredVideoUrl` was null (stale hover). |
| `[CU:execfail]` | execCommand returned false; falling back to async API. |
| `[CU:asyncok]` | Async `navigator.clipboard.writeText` resolved. |
| `[CU:asyncfail]` | Async clipboard write rejected. |
| *(no beacon)* | Content script didn't process the keydown. Causes: extension not loaded, listener detached, JS error, page navigated, modifier mismatch. |

AHK reads the title right after Alt+X and logs it.

## Failure-signature → cause map
| Log signature | Likely cause | Fix |
|---|---|---|
| `beacon=null` | Hover state cleared before Alt+X arrived | Phase 3 Fix B (stale-hover retry) |
| `beacon=execfail` then timeout | execCommand denied; async didn't resolve in 1500 ms | Phase 3 Fix A (await async + raise timeout) |
| `beacon=asyncfail` | Browser clipboard API rejected | Check focus/permissions; consider falling back to ClipboardItem |
| no beacon at all, repeated | Content script not running | Reload extension; check `chrome://extensions` for errors |
| beacon=ok but `clipboard not a YouTube URL` | Clipboard sequence saw an unrelated update | Rare; investigate other clipboard writers |
| All 3 attempts time out, no beacon, then recovers minutes later | Tab crashed / reloaded mid-session | Phase 3 Fix D (readiness gate) |

## Health checks
- Extension loaded? In DevTools console on youtube.com: `typeof window.__copyurlReady` should be `"boolean"` and `true`.
- AHK running? Tray icon **H** present.
- Gemini PWA window? `WinGetTitle` of any chrome.exe window must contain `Gemini`.

## Reset checklist
1. Reload extension (`brave://extensions` → reload).
2. Reload AHK (tray → Reload Script).
3. Refresh YouTube tab.
4. Hover thumbnail, retry Alt+Z.

## Gemini composer focus (cursorless click)
The Gemini click is sent via `PostClickAtScreen` — it converts the screen coord to render-widget client coords with `ScreenToClient` and posts `WM_MOUSEMOVE` + `WM_LBUTTONDOWN/UP` to the largest `Chrome_RenderWidgetHostHWND`. The OS cursor doesn't move.

| Symptom | Likely cause | Fix |
|---|---|---|
| Paste lands in the wrong app / nothing focused | Render widget not found, or Gemini window changed class | Check log for `gemini_scan_pixelsearch_miss`; verify `WinGetClass` of Gemini still resolves a `Chrome_RenderWidgetHostHWND` child. |
| `Gemini pass1 layout=active(fallback)` on a new chat | Composer color not in candidate list `[0x2A2B2D, 0x1F2022, 0x303134, 0x252628]` | Add the actual `gemini_bottom_pixel=0x...` value from the log to `composerColors` in `FindGeminiComposerScreenY`. |
| Click registers but composer never focuses | Heavy JS frame intercepting posted-message clicks | Last-resort fallback: revert that one section to `Click()` + immediate `MouseMove` restore. |

---

## macOS (Hammerspoon) — `Mac/hammerspoon/init.lua`

The Mac port has its own log and URL-driven test handlers. Most fields below assume v8+ of [../Mac/hammerspoon/init.lua](../Mac/hammerspoon/init.lua).

### Log file
`~/Library/Logs/CopyURL.log` — timestamped. Tail while testing:
```sh
tail -f ~/Library/Logs/CopyURL.log
```
Every `notify(...)` and key step (`Option+Z fired`, `frontmost before Option+X`, `hover-refresh`, `pasting payload`, `Sent URL to Gemini`, `runFlow ERROR`) is written here.

### Verify the live build
Top of `init.lua` defines `CONFIG_VERSION = "vN <date> <tag>"`. On every reload the log writes `config loaded; version=vN ...` and a Hammerspoon toast `CopyURL vN ...` appears. If the toast/log version doesn't match the file, the pathwatcher didn't pick it up — manually click Hammerspoon menu → Reload Config.

### URL handlers (no Accessibility needed)
| URL | Effect |
|---|---|
| `open hammerspoon://copyurl-test` | Runs the full Option+Z flow. |
| `open hammerspoon://copyurl-test-paste` | Skips YouTube; puts `TESTID_<HHMMSS>` on the clipboard and runs only the Gemini focus+paste leg. |
| `open hammerspoon://copyurl-reload` | Reloads the config. |

### Failure-signature → cause map (Mac)
| Log signature | Likely cause | Fix |
|---|---|---|
| No `config loaded` line ever appears | Hammerspoon not running, or `init.lua` not at `~/.hammerspoon/init.lua` | `pgrep -lf Hammerspoon`; `ls ~/.hammerspoon/init.lua`; relaunch `/Applications/Hammerspoon.app`. |
| `Option+Z fired` doesn't fire on key press | Hammerspoon lacks Accessibility, or app is running from a translocated path (`/private/var/folders/.../AppTranslocation/...`) | Move `Hammerspoon.app` to `/Applications`, remove + re-add the Accessibility entry pointing at the new path. |
| `frontmost before Option+X: <not browser>` | `app:activate()` race; another app stole focus | Increase the `focusDeadline` value in `init.lua`. |
| `hover-refresh ...` then `URL copy failed` | `content.js` didn't run, or cursor wasn't over a thumbnail | On the YouTube tab: `localStorage.__copyurlDebug='1'; location.reload()`, then inspect `window.__copyurlLog` after pressing Option+Z. |
| `gemini frame: ...` then nothing until `runFlow ERROR` | Lua error in the Gemini block (caught by `pcall`) | The error line follows in the log; the most common in early builds was `nil value (method 'postToPid')` — use `event:post(app)`. |
| `Sent URL to Gemini` but Gemini composer is empty | Composer wasn't focused at Cmd+V — typical on a brand-new chat in some Gemini layouts | Open an active chat (composer auto-focuses there), or click the composer once before pressing Option+Z. |
| `paste-test sent` but nothing appears in Gemini | Same as above; use the test URL handler with an active chat first to confirm the paste leg works in isolation | Run `open hammerspoon://copyurl-test-paste` and look for `TESTID_<HHMMSS>` in the Gemini chat. |

### Notable design choices (Mac)
- **No synthetic mouse click on Gemini.** Gemini's PWA auto-focuses its composer on window activation; an earlier attempt to click the composer via `postToPid` crashed silently because that method doesn't exist on Hammerspoon's event class (correct API is `event:post(app)`).
- **`mouseMoved` jitter** posted at the current cursor position is what refreshes content.js's stale hover state when the browser was backgrounded. The hardware cursor doesn't move.
- **Auto-reload** via `hs.pathwatcher` on `~/.hammerspoon/` — works for Google Drive synced edits too.

---

## Linux (Ubuntu / GNOME Wayland) — `Linux/copyurl.sh`

The Linux port types the trigger character `]` with `ydotool`, confirms the copy
by polling `wl-paste`, and raises windows via the *Activate Window By Title*
GNOME extension. The Korean prompt + paste are done **in the browser** by
[../gemini.js](../gemini.js). See [../Linux/README.md](../Linux/README.md) for
the full setup.

### Log file
`~/.local/state/copyurl/copyurl_log.txt` (rotates at ~1 MB). Tail while testing:
```sh
tail -f ~/.local/state/copyurl/copyurl_log.txt
```
Every key step (`Alt+Z fired (version=...)`, `activate_window_by_title(...)`,
`copy attempt N`, `clipboard changed -> ...`, `done; sent url=...`) is logged.

### Verify the live build
Top of `copyurl.sh` defines `CONFIG_VERSION="vN <date> <tag>"`, written to the
log on every run as `Alt+Z fired (version=vN ...)`. GNOME runs the script fresh
on each keypress, so there is no reload step — editing the file is enough.

### Works even when Brave is NOT focused
As of `v5` (`linux-activate-brave-before-trigger`), `copyurl.sh` raises the
Brave/YouTube window via `activate_youtube` **before** typing the trigger, so
Alt+Z works while you are only *hovering* a thumbnail with another window
focused. Activation is non-fatal: if it fails the script still types into the
focused window (old behaviour). The window is matched by the title substring
`COPYURL_YOUTUBE_NEEDLE` (default `YouTube`).

### Failure-signature → cause map (Linux)
| Log signature | Likely cause | Fix |
|---|---|---|
| `bash: .../copyurl.sh: Permission denied` (in `journalctl --user -u org.gnome.SettingsDaemon.MediaKeys`) | Script lost its `+x` bit (Insync/Google Drive strips it) | `chmod +x Linux/copyurl.sh`; bind the GNOME shortcut to `bash "<abs path>"` so it survives future stripping. |
| Alt+Z does nothing, no new log lines at all | GNOME dropped the key grab (often after suspend/resume) | `systemctl --user restart org.gnome.SettingsDaemon.MediaKeys.target`. |
| `WARN: could not activate YouTube/Brave window` then `URL copy failed` | No window title contains `YouTube`, or the *Activate Window By Title* extension is off | Make sure a YouTube tab is frontmost in Brave and the extension is enabled; override with `COPYURL_YOUTUBE_NEEDLE`. |
| `copy attempt N: timed out` (×2) | Trigger landed in the wrong window, or `content.js` had no hovered video | Confirm Brave activation worked (see the `activate_window_by_title` log line); set `localStorage.__copyurlDebug='1'` and inspect `window.__copyurlLog`. |
| URL copied but nothing pasted into Gemini | Gemini is in a **different browser/profile** than the extension | `chrome.storage` is per browser+profile — run Gemini as a Brave app in the **same** profile, then reload the extension. |
| `ydotool could not type the trigger` | `ydotoold` not running, or wrong socket | `systemctl --user start ydotoold`; see `Linux/README.md` for the socket path. |

### Notable design choices (Linux)
- **`ydotool type "]"` is the only reliable synthetic input** on this Wayland
  setup — `ydotool key <code>` mangles keycodes and can't send F24/Ctrl+V/Enter.
  So `]` is a pure trigger and the paste happens in the browser via `gemini.js`.
- **Window raising before the trigger** is what makes Alt+Z work unfocused; the
  mouse is never moved, so `content.js` still resolves the hovered thumbnail.
- **Automated coverage:** [../tests/e2e/run_full_system.mjs](../tests/e2e/run_full_system.mjs)
  runs the genuine `copyurl.sh` + `ydotool` + `wl-clipboard` against a real Brave
  and asserts the unfocused-Brave path (`COPYURL_FULL_SYSTEM=1 npm run test:full`).

<!-- AUTO:RECENT-ACTIVITY:BEGIN -->
<!-- This block is regenerated by .githooks/pre-commit on every commit.
     Do not edit by hand — your changes will be overwritten. -->

**Last updated:** `2026-07-14T21:21:09Z`

**Recent commits (last 5 on HEAD):**

- `ee51033` fix(mac): home-page hover preview anchor + v22 beacon diagnostics _(4 hours ago)_
- `1b1fe28` fix(mac): reliable Gemini paste via AX composer focus + async activate _(12 days ago)_
- `c7f86f8` feat(mac): restore live v15 config + add toast-dwell (v16) _(13 days ago)_
- `fe14906` fix(gemini+toast): dark-theme composer scan, faster paste, single home-page bubble _(3 weeks ago)_
- `9b35990` fix(gemini): robust, self-verifying composer insertion (v1.2.8) _(4 weeks ago)_

**Files in the pending commit:**

- `Mac/hammerspoon/init.lua`
<!-- AUTO:RECENT-ACTIVITY:END -->
