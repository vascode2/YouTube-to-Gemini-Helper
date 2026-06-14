# Linux setup (Ubuntu / GNOME Wayland — separate from Windows AHK & macOS)

This folder is a **Linux-only** orchestrator built on `ydotool` + `wl-clipboard`
+ a GNOME shell extension. It does not change any Windows AutoHotkey
([../copy.ahk](../copy.ahk)) or macOS ([../Mac/](../Mac/)) files. The shared
pieces are the browser extension scripts ([../content.js](../content.js),
[../gemini.js](../gemini.js), [../manifest.json](../manifest.json)).

> Target environment: **Ubuntu on Wayland (GNOME)**, **Brave** for YouTube,
> **Gemini installed as a Brave app** in the **same Brave profile** as the
> extension (see the next note).

> ## ⚠️ YouTube and Gemini must be in the **same browser + profile**
>
> Unlike Windows and macOS, the Linux port hands the URL from YouTube to Gemini
> **inside the browser** via the extension's `chrome.storage` (because Wayland
> `ydotool` cannot type Korean or paste at the OS level — see
> *Why this design* below). `chrome.storage` is **per browser and per profile**,
> so the YouTube tab and the Gemini window must run in the **same browser and
> the same profile** — the one where the CopyURL extension is installed.
>
> Concretely: if YouTube is in **Brave** (with the extension) but Gemini is a
> **Chrome** app, the copy succeeds (the OS clipboard is shared) but **nothing
> ever pastes** — `content.js` writes the payload to Brave's storage and the
> Chrome-hosted `gemini.js` can never read it. Run Gemini as a **Brave app**
> in the same profile (step 5).
>
> *(Windows/macOS don't have this constraint because there the paste is done at
> the OS level with synthetic keystrokes, which are browser-agnostic.)*

## What it does

Press **Alt+Z** while your mouse is over a YouTube thumbnail in Brave:

0. Activates the **Brave/YouTube** window (via the *Activate Window By Title*
   GNOME extension) so the trigger keystroke lands in Brave **even when Brave is
   not the focused window** — e.g. you are only *hovering* a thumbnail while a
   different window has focus. Your mouse does not move, so `content.js` still
   resolves the hovered video.
1. Types the trigger character **`]`** into the Brave window via
   `ydotool type`. [../content.js](../content.js) then:
   - copies the hovered video URL to the clipboard, **and**
   - queues a Gemini paste payload (`<PASTE_PREFIX><url>`) in the extension's
     `chrome.storage.local`.
2. Polls the clipboard until a `youtube.com` URL appears — this confirms the
   copy succeeded (and retries the trigger if it didn't).
3. Activates the **Gemini** PWA window (via the *Activate Window By Title*
   GNOME extension's D-Bus method) so the answer is visible.
4. Inside the browser, [../gemini.js](../gemini.js) sees the queued payload,
   inserts it into Gemini's composer **via the DOM**, and clicks send.

The Korean prompt prefix and the paste/submit both live in the **extension**,
not in the shell script. See [copyurl.sh](copyurl.sh) — the Linux analog of
[../copy.ahk](../copy.ahk).

## Why this design (Wayland constraints)

On this GNOME Wayland setup, OS-level input synthesis is largely broken, which
is why the paste was moved into the browser:

- **`ydotool key <code>` is unusable here** — mutter assigns the virtual device
  a broken keymap, so every keycode collapses to a digit and modifiers
  (Ctrl/Alt/Shift) are dropped. F24, `Ctrl+V`, and `Enter` cannot be sent by
  keycode.
- **`ydotool type` works for ASCII but cannot type Korean / non-ASCII.** So the
  Korean prompt can't be typed at the OS level.
- **`ydotool mousemove` is relative-only** (no absolute positioning in 0.1.8),
  so coordinate-based middle-click paste is not reliable.
- **`ydotool type "]"` is the one synthetic-input path confirmed to work**, so
  it is used purely as a trigger to reach `content.js`.

Everything else is done where it is reliable:

| Need | Tool | Why |
|---|---|---|
| Fire the content script | **`ydotool type "]"`** | Only working synthetic-input path; `]` has no YouTube shortcut and only acts while a thumbnail is hovered. |
| Read clipboard (copy confirmation) | **`wl-clipboard`** (`wl-paste`) | Native Wayland clipboard. No `GetClipboardSequenceNumber`, so success = **polling** for a youtube URL. |
| Insert the Korean prompt + submit | **[../gemini.js](../gemini.js)** content script | DOM insertion handles Unicode natively and needs no OS input; works even if the Gemini tab is in the background. |
| Focus the Brave & Gemini windows | **Activate Window By Title** GNOME extension | Wayland forbids apps from raising other windows; this trusted shell extension exposes a D-Bus method. Brave is raised **before** the trigger so Alt+Z works without clicking Brave first. |
| Global Alt+Z hotkey | **GNOME custom shortcut** | Wayland has no app-level global hotkey grab; GNOME runs the script. |

## Install

### 1. Helper tools

```sh
sudo apt update
sudo apt install -y ydotool wl-clipboard bc libnotify-bin
```

If your distro's `ydotool` package does not include `ydotoold`, build it from
source (https://github.com/ReimuNotMoe/ydotool) or use the snap. Confirm:

```sh
command -v ydotool ydotoold wl-copy wl-paste gdbus
```

### 2. Allow ydotoold to use /dev/uinput without root

```sh
sudo cp Linux/99-uinput.rules /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -aG input "$USER"
```

Log out and back in (group change needs a fresh session). Verify:

```sh
ls -l /dev/uinput      # expect: crw-rw---- root input
id -nG | tr ' ' '\n' | grep -x input
```

### 3. Run ydotoold as a user service

```sh
mkdir -p ~/.config/systemd/user
cp Linux/ydotoold.service ~/.config/systemd/user/ydotoold.service
systemctl --user daemon-reload
systemctl --user enable --now ydotoold.service
systemctl --user status ydotoold.service --no-pager
```

Quick smoke test (focus a text field first):

```sh
ydotool type "ydotool works"
```

> `ydotool` usually finds the running daemon on its own. If it can't, point it
> explicitly: `export YDOTOOL_SOCKET=$XDG_RUNTIME_DIR/ydotool/ydotoold.sock`
> (match your service's `--socket-path`). `copyurl.sh` auto-detects the common
> socket locations.

### 4. Activate Window By Title GNOME extension

Install from https://extensions.gnome.org/extension/5021/activate-window-by-title/
then enable it. (Freshly installed extensions may require a log out/in before
they can be enabled.) Verify the D-Bus method is present:

```sh
gdbus call --session --dest org.gnome.Shell \
  --object-path /de/lucaswerkmeister/ActivateWindowByTitle \
  --method de.lucaswerkmeister.ActivateWindowByTitle.activateBySubstring "Gemini"
```

A reply of `(true,)` means a window whose **active tab title** contains "Gemini"
was raised.

### 5. Gemini PWA (must be the **same browser + profile** as the extension)

The paste handoff goes through the extension's `chrome.storage`, which is
per-browser+profile, so Gemini must run in the **same Brave profile** that has
the CopyURL extension. **Do not use a Chrome-hosted Gemini app** — it cannot
see Brave's storage and the paste will silently never happen.

Install it as a Brave app:

```sh
brave-browser --profile-directory=Default --app=https://gemini.google.com/app
```

or: in Brave open `gemini.google.com` → menu → **Install page as app**. Keep
its window open; its title should contain "Gemini".

If you previously installed Gemini under Google Chrome, remove that launcher so
you don't open it by mistake:

```sh
rm -f ~/.local/share/applications/chrome-ojknolcoeheaaijgenghjfhhcohbmgkn-Default.desktop
```

### 6. Browser extension

`brave://extensions` → enable **Developer mode** → **Load unpacked** → select
this repo's root (where [../manifest.json](../manifest.json) lives).

> The extension now also runs a content script on `gemini.google.com`
> ([../gemini.js](../gemini.js)) and requests the `storage` permission. After
> pulling these changes you **must reload the extension** (the reload button on
> `brave://extensions`) so the new Gemini script and permission take effect.

### 7. Bind Alt+Z to the script

> **Spaces in the path:** GNOME splits a custom-shortcut command on whitespace,
> so a path like `.../Google Drive/...` breaks unless you wrap it. Run the
> script through `bash -c` with the path double-quoted (see `command` below).

```sh
SCRIPT="$(pwd)/Linux/copyurl.sh"   # run from the repo root
BASE=org.gnome.settings-daemon.plugins.media-keys
COPYURL_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyurl/"
KEY="$BASE.custom-keybinding:$COPYURL_PATH"

# Append copyurl to the existing list (this example keeps a pre-existing custom0;
# adjust to match your own `gsettings get $BASE custom-keybindings`).
gsettings set $BASE custom-keybindings "['$COPYURL_PATH']"
gsettings set $KEY name 'CopyURL'
gsettings set $KEY command "bash -c '\"$SCRIPT\"'"
gsettings set $KEY binding '<Alt>z'
```

> If you already have other custom shortcuts, **append** `$COPYURL_PATH` to the
> existing `custom-keybindings` list instead of replacing it — e.g.
> `"['.../custom0/', '$COPYURL_PATH']"`.

## Configuration

The Korean prompt prefix now lives in the **extension** as `PASTE_PREFIX` at the
top of [../content.js](../content.js) — edit it there and reload the extension.

The shell knobs below are environment variables read at the top of
[copyurl.sh](copyurl.sh):

| Variable | Default | Purpose |
|---|---|---|
| `COPYURL_TRIGGER_CHAR` | `]` | Character typed to fire `content.js`. |
| `COPYURL_GEMINI_NEEDLE` | `Gemini` | Substring matched against window titles to find the Gemini window. |
| `COPYURL_YOUTUBE_NEEDLE` | `YouTube` | Substring matched against window titles to find the Brave/YouTube window, raised before the trigger so Alt+Z works unfocused. |
| `COPYURL_CLIP_TIMEOUT` | `1.5` | Seconds to wait per attempt for the clipboard to change. |
| `COPYURL_COPY_ATTEMPTS` | `2` | Trigger retry count. |
| `COPYURL_BROWSER_FOCUS_DELAY` | `0.2` | Pause after raising Brave, before typing the trigger. |
| `COPYURL_GEMINI_FOCUS_DELAY` | `0.35` | Pause after raising Gemini. |
| `COPYURL_VERBOSE` | `1` | Verbose logging (analog of `kVerboseLog` in copy.ahk). |
| `COPYURL_LOG_FILE` | `~/.local/state/copyurl/copyurl_log.txt` | Log path. |

## Logs & testing

- Log file: `~/.local/state/copyurl/copyurl_log.txt` (rotates at ~1 MB).
  `tail -f ~/.local/state/copyurl/copyurl_log.txt` while testing.
- `Linux/copyurl.sh --check` — verify all dependencies are present.
- `Linux/copyurl.sh --focus-test` — just raise the Gemini window (focus sanity
  check). The paste itself is driven by the extension, so there is no
  standalone paste test — use the full **Alt+Z** flow on a real thumbnail.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ydotool could not type the trigger` | `ydotoold` not running, or no `/dev/uinput` access | `systemctl --user status ydotoold`; redo step 2 (udev rule + `input` group) and re-login. |
| `ydotool type` does nothing | Socket path mismatch | Ensure `YDOTOOL_SOCKET` matches the service's `--socket-path` (default `$XDG_RUNTIME_DIR/ydotool/ydotoold.sock`). |
| "URL copy failed" | The Brave/YouTube window couldn't be raised (title doesn't contain `YouTube`, or the *Activate Window By Title* extension is off), or `content.js` had a stale `hoveredVideoUrl` | Make sure a YouTube tab is frontmost in Brave and the extension is enabled. Override the match with `COPYURL_YOUTUBE_NEEDLE`. Check DevTools console: `window.__copyurlLog` (set `localStorage.__copyurlDebug="1"`). |
| Gemini not raised | Extension missing/disabled, or title needle wrong | Re-run the `gdbus` call in step 4; confirm `(true,)`. Adjust `COPYURL_GEMINI_NEEDLE`. |
| URL copied but nothing pasted into Gemini | **Gemini is in a different browser/profile than the extension** (most common: Gemini in Chrome, YouTube+extension in Brave), or `gemini.js` not loaded / composer selector changed | Run Gemini as a **Brave app in the same profile** (step 5) — `chrome.storage` is per browser+profile, so a Chrome Gemini can't see Brave's payload. Then reload the extension (step 6). Open the Gemini window's DevTools console and look for `[CopyURL/Gemini] ready` and any errors. |
| Pasted into the wrong field / not submitted | Gemini DOM changed | Update the composer/send selectors in [../gemini.js](../gemini.js). |
| Alt+Z does nothing | Shortcut not bound, or another app owns Alt+Z | Verify in Settings → Keyboard; try a different chord via the `binding` gsetting. |

For extension-side diagnostics see [../docs/troubleshooting.md](../docs/troubleshooting.md);
the content-script notes are shared across all platforms.

## Differences from Windows / macOS

| Aspect | Windows ([../copy.ahk](../copy.ahk)) | macOS ([../Mac/hammerspoon/init.lua](../Mac/hammerspoon/init.lua)) | Linux ([copyurl.sh](copyurl.sh)) |
|---|---|---|---|
| Hotkey | **Alt+Z** | **Option+Z** | **Alt+Z** (GNOME custom shortcut) |
| Internal trigger | **F24** | **Option+X** | **`]`** typed via `ydotool type` |
| Clipboard change detection | `GetClipboardSequenceNumber` | poll contents | poll `wl-paste` for a youtube URL |
| Window focus | `WinActivate` | `app:activate()` | *Activate Window By Title* extension via D-Bus |
| Gemini paste + submit | synthetic click + Ctrl+V | AppleScript Cmd+V | **in-browser DOM insert + click** ([../gemini.js](../gemini.js)) |
| Browser coupling | any (OS-level paste) | any (OS-level paste) | **YouTube + Gemini must share the same browser + profile** (in-browser `chrome.storage` handoff) |
| Korean prompt source | clipboard payload from AHK | clipboard payload from Lua | `PASTE_PREFIX` in [../content.js](../content.js) |
| Verbose logging | `kVerboseLog` | always on | `COPYURL_VERBOSE=1` |
