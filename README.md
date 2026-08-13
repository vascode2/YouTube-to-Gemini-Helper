# Alt+Z: turn any YouTube thumbnail into a Gemini summary.

![Sample output](docs/sample-output.png)

> 📖 **[See this for a visually explained README](https://vascode2.github.io/CopyYoutubeURL/docs/CopyYoutubeURL-explainer.html)**

**How it was built:** [docs/project-build-presentation.html](docs/project-build-presentation.html) — narrative from the Cursor chat that shaped the extension, AutoHotkey, and Gemini workflow.

**macOS?** A Hammerspoon port with the same workflow (cursorless, auto-test URL handlers, file logging at `~/Library/Logs/CopyURL.log`) lives in [Mac/](Mac/) — see [Mac/README.md](Mac/README.md). Hotkey is **Option+Z**.

**Linux?** An Ubuntu / GNOME Wayland port (`ydotool` + `wl-clipboard` + the *Activate Window By Title* GNOME extension) lives in [Linux/](Linux/) — see [Linux/README.md](Linux/README.md). Hotkey is **Alt+Z** (bound via a GNOME custom shortcut). It raises the Brave/YouTube window before sending the trigger, so Alt+Z works even when Brave isn't the focused window.

**Repo hooks:** This repo ships a `pre-commit` hook in [.githooks/pre-commit](.githooks/pre-commit) that auto-refreshes a "Recent activity" footer in `README.md`, `CLAUDE.md`, and `docs/troubleshooting.md` on every commit. After cloning, run once:
```sh
git config core.hooksPath .githooks
```

## Workflow

1. Open **YouTube** in **Google Chrome** (or **Brave**) with this extension enabled.
2. Point at the **thumbnail** of the video you care about — the extension remembers which video that is.
3. Press **Alt+Z** (with **AutoHotkey v2** and **`copy.ahk`** on Windows). The script briefly brings the YouTube window forward, copies that video's **YouTube URL**, switches to the **Gemini** app, focuses the composer input, pastes a short "summarize" line plus the link, and sends it. Afterward the **clipboard is set back to the plain URL**. The OS mouse cursor never moves — the click is posted directly to the Chromium render widget.
4. **Gemini** replies with a **summary** (and you can follow up in the same chat).

**Why this works:** **Gemini** can use a **YouTube URL** as real video context for summaries and Q&A. Many other assistants only treat links as plain text.

**Implementation note:** `copy.ahk` sends **F24** *inside* the YouTube tab so the extension can copy the URL. F24 is used as the internal AutoHotkey↔extension signal because it has no default browser binding and can't collide with other tools' global hotkeys (e.g. CopyAnkitoChatGPT owns Alt+X system-wide). **Alt+Z is the only user-facing hotkey.** The extension copies **synchronously** (`execCommand`) so the OS clipboard is ready before AutoHotkey continues; the script also waits for a **Windows clipboard update** before reading the URL, so Gemini should not receive a stale link.

| Hotkey | Action |
|--------|--------|
| **Alt+Z** | Copy hovered URL from YouTube (Brave) → Gemini (Chrome app) → paste prompt + URL → Enter |

---

## Requirements

- **Brave** (default in `copy.ahk`) or **Google Chrome** as an alternative for YouTube and this extension.
- **Windows** + **[AutoHotkey v2](https://www.autohotkey.com/)** + **`copy.ahk`** for global **Alt+Z**.
- **Google Chrome** with **Gemini installed as an app** (window title contains `Gemini`).

**Script notes:** `copy.ahk` activates **Brave** (`brave.exe`) for the YouTube step; switch to **`chrome.exe`** in `FindBraveWindow` if YouTube lives only in Chrome. Edit **`kGeminiPastePrefix`** at the top of `copy.ahk` to change or clear the text before the URL (`""` = URL only).

This flow is **Windows-only** as documented above. For **macOS**, use the Hammerspoon port in [Mac/](Mac/) (**Option+Z**). For **Linux** (Ubuntu / GNOME Wayland), use the port in [Linux/](Linux/) (**Alt+Z**, via `ydotool` + `wl-clipboard`).

---

## 1. Load the extension in Google Chrome

1. Download or clone this repository.
2. Open **Google Chrome** (or **Brave**).
3. Go to **`chrome://extensions`** (Brave: **`brave://extensions`**).
4. Turn **Developer mode** on (top right).
5. Click **Load unpacked** and select this folder (`manifest.json` lives here).
6. Open [YouTube](https://www.youtube.com) and allow the extension if prompted.

---

## 2. Install AutoHotkey v2 and run `copy.ahk`

1. Install **AutoHotkey v2** from [autohotkey.com](https://www.autohotkey.com/).
2. Double-click **`copy.ahk`** in this repo.
3. Confirm the **H** tray icon appears.
4. **Optional — run at sign-in:** **Win+R** → **`shell:startup`** → Enter, then create a
   **shortcut** whose target is `AutoHotkey64.exe "<path to this repo>\copy.ahk"` (point it at
   the repo copy so login runs the version you edit — no need to copy the file into Startup).

Reload the script after editing `copy.ahk` (tray → **Reload Script**).

To **regenerate** the demo GIF: `python scripts/generate_workflow_demo_gif.py` (requires `pillow` and `imageio`).

---

## 3. Install Gemini as a Chrome app

**Alt+Z** expects a Chrome window whose title includes **`Gemini`**. The installed **PWA** is most reliable.

1. Open **Google Chrome**.
2. Go to [gemini.google.com](https://gemini.google.com) and sign in.
3. Install via the address bar **install** icon, or **⋮** → **Save and share** → **Install Gemini** (labels vary).
4. Keep that app window available when you use **Alt+Z**.

---

## Usage

1. **YouTube** open in **Chrome** or **Brave**; pointer over a thumbnail.
2. **Alt+Z** — full flow above.

If several Gemini windows are open, AutoHotkey uses the first match; one window is simplest.


<!-- AUTO:RECENT-ACTIVITY:BEGIN -->
<!-- This block is regenerated by .githooks/pre-commit on every commit.
     Do not edit by hand — your changes will be overwritten. -->

**Last updated:** `2026-08-13T18:57:38Z`

**Recent commits (last 5 on HEAD):**

- `a3eece5` Merge linux-port-pr: Linux (Ubuntu/GNOME Wayland) port + macOS Gemini paste/submit hardening + native Gemini.app _(8 minutes ago)_
- `c063ba5` feat(mac): switch Gemini target from Safari-WebApp PWA to native Gemini.app _(2 weeks ago)_
- `2ed4bd1` docs: record 2026-07-26 finding — live macOS init.lua diverged from repo, lost keyStroke targeting + Gemini paste/submit hardening fixes _(3 weeks ago)_
- `47255a9` fix(mac): harden Gemini paste by using AXValue set before Cmd+V _(4 weeks ago)_
- `7a5c149` fix(mac): submit Gemini prompt via AX Send button, not synthetic Return _(4 weeks ago)_

**Files in the pending commit:**

- `CLAUDE.md`
- `.githooks/pre-commit`
<!-- AUTO:RECENT-ACTIVITY:END -->
