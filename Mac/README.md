# Mac setup (separate from Windows AHK)

This folder is a Mac-only workflow built on **[Hammerspoon](https://www.hammerspoon.org/)**. It does not change any Windows AutoHotkey files. The shared piece is the browser extension ([../content.js](../content.js) + [../manifest.json](../manifest.json)).

## What it does

Press **Option+Z** while your mouse is over a YouTube thumbnail in Brave/Chrome:

1. Activates the YouTube window (waits until that app is actually frontmost).
2. Posts a synthetic `mouseMoved` event at the current cursor position directly to the browser process so the page re-fires `mouseover` and `content.js` refreshes its `hoveredVideoUrl`. This is the macOS analog of the Windows `PostMessage WM_MOUSEMOVE` jitter. The OS cursor does **not** move.
3. Sends **Option+X** so `content.js` copies the hovered URL to the clipboard.
4. Polls the clipboard until a `youtube.com` URL appears (up to 2 s).
5. Activates the Gemini Safari WebApp / PWA (window title contains `Gemini`).
6. Pastes `<url><pasteSuffix>` via `Cmd+V` and presses Enter.
7. Restores the clipboard to the plain URL.

## Install

1. Install **Hammerspoon**: `brew install --cask hammerspoon`, then keep `Hammerspoon.app` in `/Applications`. Do **not** launch it from `~/Downloads` — macOS sandboxes it via App Translocation and your Accessibility grant won't stick across launches.
2. Launch Hammerspoon once.
3. **Grant Accessibility permission**: System Settings → Privacy & Security → Accessibility → enable Hammerspoon. If you previously granted it on a translocated path, remove that entry first, then re-add `/Applications/Hammerspoon.app`.
4. Copy the config:
   ```sh
   cp Mac/hammerspoon/init.lua ~/.hammerspoon/init.lua
   ```
5. Hammerspoon menu bar icon → **Reload Config**. You should see a `CopyURL vN …` toast.
6. Install Gemini as a PWA (Safari → gemini.google.com → Share → Add to Dock, or Chrome → Install Gemini). Keep its window open.
7. Load the unpacked extension in Brave/Chrome from this repo's root: `brave://extensions` → Developer mode → **Load unpacked**.

## Configuration

Variables at the top of [hammerspoon/init.lua](hammerspoon/init.lua):

| Variable | Default | Purpose |
|---|---|---|
| `hotkey` / `key` | `{"alt"}`, `"z"` | Trigger chord (Option+Z). |
| `youtubeApps` | `{"Brave Browser", "Google Chrome"}` | Browsers to search for a YouTube window, in priority order. |
| `geminiTitleNeedle` | `"gemini"` | Substring matched against window titles to find Gemini. |
| `pasteSuffix` | `" 한국어로 요약해 줘"` | Text appended after the URL before Cmd+V. Set `""` to paste just the URL. |
| `CONFIG_VERSION` | `"vN …"` | Stamp logged on load and shown in the ready toast — bumped on every script change so you can confirm the live build matches the file. |

## Live reload & logs

- **Auto-reload**: a `hs.pathwatcher` on `~/.hammerspoon/` reloads the config whenever `init.lua` changes (Google Drive sync edits also trigger it).
- **Log file**: `~/Library/Logs/CopyURL.log` (timestamped; every `notify(...)` and key flow step is written here). Use `tail -f ~/Library/Logs/CopyURL.log` while testing.

## URL handlers (for automated testing & scripting)

These can be triggered from any terminal without focusing Hammerspoon:

| URL | Effect |
|---|---|
| `open hammerspoon://copyurl-test` | Runs the full Option+Z flow programmatically. |
| `open hammerspoon://copyurl-test-paste` | Skips the YouTube hover/copy phase; puts a fake `TESTID_<HHMMSS>` URL on the clipboard and exercises only the Gemini focus+paste. Useful when you can't easily hover a thumbnail. |
| `open hammerspoon://copyurl-reload` | Reloads the config. |

`hs.allowAppleScript(true)` is also enabled, so you can drive arbitrary Lua via `osascript -e 'tell application "Hammerspoon" to execute lua code "..."'`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Option+Z does nothing, no toast on reload | Hammerspoon not running, or running from `~/Downloads` (App Translocation) | `pkill -f Hammerspoon`, move `Hammerspoon.app` to `/Applications`, re-grant Accessibility. |
| "URL copy failed" when the browser was not focused | `content.js` had stale `hoveredVideoUrl` because the page never saw a mousemove after coming to the front | v8+ posts a `mouseMoved` jitter to the browser process before sending Option+X. If it still misses, confirm the cursor is over a thumbnail (DevTools console: `window.__copyurlLog`). |
| `runFlow ERROR: ... nil value (method 'postToPid')` | Old Hammerspoon API | Update to v8+ which uses `event:post(app)`. |
| Paste lands nowhere on a fresh Gemini chat | Composer wasn't focused at Cmd+V time | Switch to an active Gemini chat (composer auto-focuses reliably there), or click the composer once before pressing Option+Z. |
| Gemini window comes to front but nothing is pasted | The Safari WebApp does **not** auto-focus its prompt composer on activation, so `Cmd+V` had no text field to land in. Log showed `send-key cmd+v ok=true` yet nothing appeared. | v21+ focuses the composer through the accessibility API (`focusGeminiComposer`) before pasting, then reads the composer back to verify the paste landed (`paste verify: landed=true`) before pressing Enter. Ensure Hammerspoon has **Accessibility** permission. |
| Paste lands in the browser instead of Gemini | The flow busy-waited with `hs.timer.usleep`, blocking the Hammerspoon runloop so app activation never completed and the browser stayed frontmost. Log showed `frontmost before paste: Brave Browser`. | v20+ activates Gemini asynchronously via `activateAndWait` (polls with `hs.timer.doAfter`, never blocks the runloop) and only sends keys once Gemini is confirmed frontmost. |
| Toast says `Option+Z fired` but Gemini gets no paste | Keystrokes didn't reach the Gemini app (focus race / macOS Automation permission drift) | v17+ sends `Cmd+V`/Enter via app-targeted `hs.eventtap` first (Accessibility only), then AppleScript fallback. Reload `~/.hammerspoon/init.lua`, then check `send-key cmd+v ok=...` in `~/Library/Logs/CopyURL.log`. |
| Toast says `Option+Z fired` but log stops before `pasting payload` | Lua error in the Gemini block (caught by `pcall`) | `tail -30 ~/Library/Logs/CopyURL.log` and look for `runFlow ERROR: ...`. |

For extension-side diagnostics see [../docs/troubleshooting.md](../docs/troubleshooting.md). The Windows section's content-script notes also apply to Mac because the extension is shared.

## Differences from Windows

| Aspect | Windows ([../copy.ahk](../copy.ahk)) | Mac ([hammerspoon/init.lua](hammerspoon/init.lua)) |
|---|---|---|
| Hotkey | **Alt+Z** | **Option+Z** |
| Internal extension trigger | **F24** (avoids Alt+X collision with CopyAnkitoChatGPT) | **Option+X** (no global binding on Mac) |
| Cursorless click on Gemini | `PostMessage WM_LBUTTONDOWN/UP` to `Chrome_RenderWidgetHostHWND` | None needed — Safari WebApp auto-focuses composer on activation |
| Hover refresh | `PostMessage WM_MOUSEMOVE` jitter | `hs.eventtap.event.newMouseEvent(mouseMoved):post(app)` |
| Verbose logging | `kVerboseLog := true` in `copy.ahk` | always on; written to `~/Library/Logs/CopyURL.log` |
