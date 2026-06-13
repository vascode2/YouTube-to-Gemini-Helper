#!/usr/bin/env bash
# CopyURL Linux workflow (Ubuntu / GNOME Wayland)
# Hotkey: Alt+Z  (bound via a GNOME custom keyboard shortcut -> this script)
#
# Flow (analog of the Windows copy.ahk / macOS init.lua):
#   1) Send the trigger character "]" to the focused window (Brave, where you
#      are hovering a YouTube thumbnail) via `ydotool type`. content.js copies
#      the hovered URL to the clipboard AND queues a Gemini paste payload in the
#      extension's chrome.storage.local.
#   2) Poll the clipboard (wl-paste) until a youtube.com URL appears, to confirm
#      the copy succeeded (and retry the trigger if not).
#   3) Activate the Gemini PWA window (via the "Activate Window By Title" GNOME
#      extension's D-Bus method) so the result is visible.
#
# The actual paste + submit into Gemini is done entirely inside the browser by
# the Gemini content script (../gemini.js): it reads the queued payload and
# inserts it into the composer via the DOM, then clicks send. This avoids OS-
# level input synthesis, which is unreliable on GNOME Wayland:
#   * `ydotool key <code>` mangles keycodes (broken virtual-device keymap), so
#     F24 / Ctrl+V / Enter cannot be sent by keycode.
#   * `ydotool type` works for ASCII but CANNOT type Korean/non-ASCII.
#   * `ydotool mousemove` is relative-only (no absolute), so coordinate-based
#     middle-click paste is not reliable.
# `ydotool type "]"` is the one synthetic-input path confirmed to work here.
#
# This file is Linux-only and changes nothing in the Windows (copy.ahk) or
# macOS (Mac/) workflows. The shared pieces are the browser extension scripts
# (../content.js + ../gemini.js + ../manifest.json).
#
# Setup, dependencies, and the GNOME shortcut binding are documented in
# ./README.md.

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
CONFIG_VERSION="v4 2026-06-11 linux-first-press-alt-fix"

# Substring matched (case-insensitive on the extension side) against window
# titles to find the Gemini window. The PWA's title contains "Gemini".
GEMINI_TITLE_NEEDLE="${COPYURL_GEMINI_NEEDLE:-Gemini}"

# Trigger character typed into the browser to fire content.js. "]" has no
# YouTube shortcut and content.js only acts on it while a thumbnail is hovered.
# (The Korean prompt prefix lives in ../content.js as PASTE_PREFIX; the paste
# itself is performed by ../gemini.js, not by this script.)
TRIGGER_CHAR="${COPYURL_TRIGGER_CHAR:-]}"

# Settle delay (seconds) before the first trigger. The GNOME hotkey is Alt+Z, so
# the user is usually still holding Alt for a moment after it fires; this also
# lets ydotool's first injection warm up. content.js no longer requires Alt to
# be released, but a small pause makes the very first press more reliable.
TRIGGER_SETTLE_DELAY="${COPYURL_TRIGGER_SETTLE_DELAY:-0.12}"

# How long (seconds) to wait for the clipboard to change after the trigger,
# and how often to poll. Two attempts total (mirrors copy.ahk retry).
CLIP_TIMEOUT="${COPYURL_CLIP_TIMEOUT:-1.5}"
CLIP_POLL="${COPYURL_CLIP_POLL:-0.05}"
COPY_ATTEMPTS="${COPYURL_COPY_ATTEMPTS:-2}"

# Delay (seconds) after activating the Gemini window, to let it come forward.
GEMINI_FOCUS_DELAY="${COPYURL_GEMINI_FOCUS_DELAY:-0.35}"

# Verbose logging (1 = on). Mirrors kVerboseLog in copy.ahk.
VERBOSE="${COPYURL_VERBOSE:-1}"

# Log file. Defaults under XDG state dir (not synced, not in the repo).
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/copyurl"
LOG_FILE="${COPYURL_LOG_FILE:-$LOG_DIR/copyurl_log.txt}"
LOG_MAX_BYTES="${COPYURL_LOG_MAX_BYTES:-1048576}"  # rotate at ~1 MB

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # Rotate if the log grew too large.
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

vlog() { [[ "$VERBOSE" == "1" ]] && log "$@"; }

notify() {
  log "notify: $*"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -t 2500 "CopyURL" "$*" 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $*"
  notify "$*"
  exit 1
}

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
# Locate the ydotoold socket so ydotool can talk to the daemon. ydotool can
# usually find the daemon on its own, so we only set YDOTOOL_SOCKET if it is
# unset AND we find a real socket at one of the common locations. We never
# point it at a non-existent path (that would break the auto-discovery).
if [[ -z "${YDOTOOL_SOCKET:-}" ]]; then
  _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  for _cand in "$_rt/ydotool/ydotoold.sock" "$_rt/.ydotool_socket" "/tmp/.ydotool_socket"; do
    if [[ -S "$_cand" ]]; then
      export YDOTOOL_SOCKET="$_cand"
      break
    fi
  done
  unset _rt _cand
fi

check_deps() {
  local missing=()
  for cmd in ydotool wl-copy wl-paste gdbus; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "See Linux/README.md for installation (ydotool, wl-clipboard, glib2)." >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Clipboard helpers (wl-clipboard)
# ----------------------------------------------------------------------------
clip_get() {
  # Prints current clipboard text; empty string if clipboard is empty.
  wl-paste --no-newline 2>/dev/null || true
}

clip_set() {
  printf '%s' "$1" | wl-copy 2>/dev/null || log "WARN: wl-copy failed"
}

# ----------------------------------------------------------------------------
# Trigger injection (ydotool). `ydotool type` is the only synthetic-input path
# that works reliably on this GNOME Wayland setup (see header notes).
# ----------------------------------------------------------------------------
send_trigger() {
  ydotool type "$TRIGGER_CHAR" 2>/dev/null \
    || die "ydotool could not type the trigger (is ydotoold running? see README)."
}

# ----------------------------------------------------------------------------
# Gemini window activation (Activate Window By Title GNOME extension)
# ----------------------------------------------------------------------------
activate_gemini() {
  local result
  result=$(gdbus call --session \
    --dest org.gnome.Shell \
    --object-path /de/lucaswerkmeister/ActivateWindowByTitle \
    --method de.lucaswerkmeister.ActivateWindowByTitle.activateBySubstring \
    "$GEMINI_TITLE_NEEDLE" 2>&1)
  vlog "activate_gemini('$GEMINI_TITLE_NEEDLE') -> $result"
  if [[ "$result" == *"true"* ]]; then
    return 0
  fi
  log "WARN: could not activate Gemini window (extension installed/enabled? title contains '$GEMINI_TITLE_NEEDLE'?): $result"
  return 1
}

# ----------------------------------------------------------------------------
# Copy phase: send F24, wait for clipboard to change to a youtube URL.
# ----------------------------------------------------------------------------
# Copy phase: reset the clipboard to a unique sentinel, type the trigger, then
# wait for the clipboard to become a youtube URL. Resetting to a sentinel first
# is what lets us detect copying the SAME video twice in a row — otherwise the
# clipboard value never "changes" and the poll would falsely time out.
# Stores the copied URL in the global COPIED_URL on success.
# ----------------------------------------------------------------------------
COPIED_URL=""
copy_url_from_browser() {
  COPIED_URL=""
  local sentinel="__copyurl_sentinel_$$_$(date +%s%N)"
  local attempt cur start now
  # Brief settle so a still-held Alt (from Alt+Z) is released and ydotool warms up.
  sleep "$TRIGGER_SETTLE_DELAY"
  for (( attempt = 1; attempt <= COPY_ATTEMPTS; attempt++ )); do
    # Clear to the sentinel so a same-URL re-copy is still detectable.
    clip_set "$sentinel"
    vlog "copy attempt $attempt: typing trigger '$TRIGGER_CHAR'"
    send_trigger
    start=$(date +%s.%N)
    while :; do
      sleep "$CLIP_POLL"
      cur="$(clip_get)"
      if [[ "$cur" != "$sentinel" && "$cur" == *"youtube.com"* ]]; then
        vlog "copy attempt $attempt: clipboard changed -> $cur"
        COPIED_URL="$cur"
        return 0
      fi
      now=$(date +%s.%N)
      if (( $(echo "$now - $start > $CLIP_TIMEOUT" | bc -l) )); then
        vlog "copy attempt $attempt: timed out after ${CLIP_TIMEOUT}s"
        break
      fi
    done
  done
  return 1
}

# ----------------------------------------------------------------------------
# Bring Gemini forward. The actual paste + submit is performed by ../gemini.js
# inside the browser (it consumes the payload queued by content.js), so this
# only needs to surface the Gemini window for the user.
# ----------------------------------------------------------------------------
focus_gemini() {
  activate_gemini || true
  sleep "$GEMINI_FOCUS_DELAY"
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
run_flow() {
  log "Alt+Z fired (version=$CONFIG_VERSION)"
  local original_clip
  original_clip="$(clip_get)"

  if ! copy_url_from_browser; then
    # Restore whatever the user had before we wrote the sentinel.
    [[ -n "$original_clip" ]] && clip_set "$original_clip"
    die "URL copy failed. Hover a YouTube thumbnail in Brave, then press Alt+Z again."
  fi

  # content.js has now also queued the Korean prompt + URL for gemini.js, which
  # inserts and submits it in the browser. We just bring Gemini to the front.
  notify "Got URL, sending to Gemini"
  focus_gemini
  log "done; sent url=$COPIED_URL"
}

# Focus test: just activate the Gemini window. The paste itself is exercised
# by the browser extension (content.js queues a payload, gemini.js inserts it),
# which this script cannot trigger directly, so there is no standalone paste
# test on Linux — use the full Alt+Z flow on a real thumbnail to test paste.
run_focus_test() {
  log "focus-test start"
  notify "focus-test: activating Gemini"
  focus_gemini
  log "focus-test done"
}

usage() {
  cat <<EOF
CopyURL Linux orchestrator ($CONFIG_VERSION)

Usage: copyurl.sh [command]

Commands:
  (none)        Run the full Alt+Z flow: type "]" -> copy URL -> focus Gemini
                (the browser extension inserts + submits the prompt).
  --focus-test  Just activate the Gemini window (focus sanity check).
  --check       Verify required dependencies are installed.
  --help        Show this help.

Configuration is via environment variables (see top of this script), e.g.
  COPYURL_TRIGGER_CHAR, COPYURL_GEMINI_NEEDLE, COPYURL_VERBOSE.
Logs: $LOG_FILE
EOF
}

main() {
  case "${1:-}" in
    --help|-h) usage ;;
    --check)   check_deps && echo "All dependencies present." ;;
    --focus-test)
      check_deps || die "Missing dependencies (run: copyurl.sh --check)."
      run_focus_test
      ;;
    "")
      check_deps || die "Missing dependencies (run: copyurl.sh --check)."
      run_flow
      ;;
    *)
      echo "Unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
