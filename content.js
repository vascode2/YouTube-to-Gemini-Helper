(() => {
  "use strict";

  let hoveredVideoUrl = null;
  let hoveredElement = null;
  let lastClientX = -1;
  let lastClientY = -1;

  // Prompt suffix appended after the copied URL when handing off to Gemini on Linux.
  // The Linux flow cannot type non-ASCII/Korean via ydotool, so the Gemini content
  // script (gemini.js) reads this payload from chrome.storage.local and inserts it
  // into the composer via the DOM instead of relying on OS-level paste.
  const PASTE_SUFFIX = " 한국말로 요약해줘";
  const PENDING_KEY = "copyurlPendingPaste";

  /**
   * Queue a Gemini paste payload for the Linux flow. The Gemini content script
   * (gemini.js) consumes it from chrome.storage.local and submits it. No-op if the
   * extension storage API is unavailable (e.g. older browsers or denied permission).
   */
  function queueGeminiPaste(url) {
    // An orphaned content script (extension reloaded while this tab stayed open)
    // still has a `chrome.storage` object, but calling it throws "Extension
    // context invalidated". The copy half keeps working (execCommand is DOM-level),
    // so without a visible signal the user sees "Copied!" but no paste. Surface it.
    const orphaned = (() => {
      try { return !(chrome && chrome.runtime && chrome.runtime.id); } catch { return true; }
    })();
    if (orphaned || typeof chrome === "undefined" || !chrome.storage || !chrome.storage.local) {
      console.warn(
        "[CopyURL] storage unavailable (orphaned/updated extension) — reload this YouTube tab (Ctrl+R) to re-enable Gemini paste."
      );
      showToast(null, "Reload this YouTube tab (extension updated)");
      return;
    }
    try {
      chrome.storage.local.set({
        [PENDING_KEY]: { text: url + PASTE_SUFFIX, url, ts: Date.now() },
      });
      console.log("[CopyURL] queued Gemini paste for", url);
      diag("queued_gemini_paste", { url });
    } catch (err) {
      console.warn("[CopyURL] failed to queue Gemini paste:", err);
      showToast(null, "Reload this YouTube tab (extension updated)");
      diag("queue_gemini_paste_fail", { err: String(err) });
    }
  }

  // ---- Diagnostics: ring buffer + title beacon ----------------------------
  // Ring buffer is gated behind localStorage.__copyurlDebug = "1" (cheap when off).
  // Title beacon is ALWAYS on: a transient zero-width-space + "[CU:STATE]" suffix
  // appended to document.title for ~300 ms so AutoHotkey can read it via WinGetTitle.
  // STATE values: ok | null | execfail | asyncpending | asyncok | asyncfail | notready
  const BEACON_PREFIX = "\u200B[CU:";
  const BEACON_SUFFIX = "]";
  // 700 ms (not 300): on macOS the Hammerspoon flow reads this beacon via the
  // Brave WINDOW title (youtubeWin:title()), and Brave's document.title ->
  // window-title propagation can lag a few hundred ms. A short TTL made the read
  // race and report a false "no-beacon". Windows/AHK reads it immediately, so the
  // longer TTL is harmless there (the suffix is an invisible zero-width tag).
  const BEACON_TTL_MS = 700;
  let _beaconTimer = null;
  let _beaconBaseTitle = null;
  const _ringEnabled = (() => {
    try { return localStorage.getItem("__copyurlDebug") === "1"; } catch { return false; }
  })();
  const _ring = [];
  function diag(event, data) {
    if (!_ringEnabled) return;
    const entry = { t: Date.now(), event, ...(data || {}) };
    _ring.push(entry);
    if (_ring.length > 200) _ring.shift();
    try { console.debug("[CopyURL]", event, data || ""); } catch {}
  }
  function setBeacon(state) {
    try {
      // Strip any prior beacon first.
      const cur = document.title || "";
      const base = stripBeacon(cur);
      if (_beaconBaseTitle === null) _beaconBaseTitle = base;
      document.title = base + " " + BEACON_PREFIX + state + BEACON_SUFFIX;
      if (_beaconTimer) clearTimeout(_beaconTimer);
      _beaconTimer = setTimeout(() => {
        const now = stripBeacon(document.title || "");
        // Only restore if YouTube hasn't changed the title in the meantime.
        if (now === base) document.title = base;
        _beaconTimer = null;
        _beaconBaseTitle = null;
      }, BEACON_TTL_MS);
    } catch {}
  }
  function stripBeacon(title) {
    const i = title.indexOf(BEACON_PREFIX);
    if (i === -1) return title;
    // Trim trailing space we added before the beacon.
    return title.slice(0, i).replace(/\s+$/, "");
  }
  // Expose for live inspection and macOS Hammerspoon integration.
  try {
    Object.defineProperty(window, "__copyurlLog", {
      get() { return _ring.slice(); },
      configurable: true,
    });
    // __copyurlHoveredUrl: read by Hammerspoon via AppleScript JS execution on macOS.
    Object.defineProperty(window, "__copyurlHoveredUrl", {
      get() { return hoveredVideoUrl; },
      configurable: true,
    });
    window.__copyurlReady = true;
    window.dispatchEvent(new CustomEvent("copyurl-ready"));
  } catch {}
  diag("loaded", { url: location.href, ringEnabled: _ringEnabled });

  function refreshHoverFromLastPointer() {
    if (lastClientX < 0 || lastClientY < 0) return;
    const el = document.elementFromPoint(lastClientX, lastClientY);
    if (!el) return;
    const result = findVideoAnchor(el);
    if (result) {
      hoveredVideoUrl = result.url;
      hoveredElement = result.anchor;
    }
  }

  /**
   * Extract a clean YouTube video URL from an anchor element's href.
   * Handles /watch?v=ID and /shorts/ID formats.
   * Returns null if no video ID is found.
   */
  function extractVideoUrl(href) {
    try {
      const url = new URL(href, location.origin);

      // Standard watch URL
      const videoId = url.searchParams.get("v");
      if (videoId) {
        return `https://www.youtube.com/watch?v=${videoId}`;
      }

      // Shorts URL: /shorts/VIDEO_ID
      const shortsMatch = url.pathname.match(/^\/shorts\/([a-zA-Z0-9_-]+)/);
      if (shortsMatch) {
        return `https://www.youtube.com/watch?v=${shortsMatch[1]}`;
      }
    } catch {
      // ignore malformed URLs
    }
    return null;
  }

  /**
   * Walk up the DOM from an element to find the closest <a> with a video href.
   * If the direct ancestor walk fails (e.g. YouTube's hover preview overlay is
   * a sibling of the <a>, not a child), fall back to finding the nearest
   * renderer/thumbnail container and searching within it.
   */
  function findVideoAnchor(el) {
    let current = el;
    let depth = 0;
    let container = null;

    while (current && depth < 20) {
      // Direct ancestor match
      if (current.tagName === "A" && current.href) {
        const clean = extractVideoUrl(current.href);
        if (clean) return { anchor: current, url: clean };
      }

      // Remember the closest thumbnail/renderer container for fallback
      if (!container) {
        const tag = current.tagName?.toLowerCase() || "";
        if (
          tag === "ytd-thumbnail" ||
          tag === "ytd-rich-item-renderer" ||
          tag === "ytd-compact-video-renderer" ||
          tag === "ytd-grid-video-renderer" ||
          tag === "ytd-video-renderer" ||
          tag === "ytd-rich-grid-media" ||
          tag === "ytd-playlist-video-renderer" ||
          // Home/subscription-page inline hover preview. When YouTube plays the
          // muted preview, the cursor sits over this shared overlay (moved out of
          // the thumbnail's renderer), so the normal ancestor walk finds no <a>.
          // The overlay contains a#media-container-link -> /watch?v=…, which the
          // container fallback query below resolves.
          tag === "ytd-video-preview" ||
          current.id === "video-preview"
        ) {
          container = current;
        }
      }

      current = current.parentElement;
      depth++;
    }

    // Fallback: search within the container for a video link
    if (container) {
      const link = container.querySelector(
        'a#thumbnail[href], a[href*="/watch?v="], a[href*="/shorts/"]'
      );
      if (link && link.href) {
        const clean = extractVideoUrl(link.href);
        if (clean) return { anchor: link, url: clean };
      }
    }

    return null;
  }

  // --- Hover tracking via event delegation on document ---

  document.addEventListener(
    "pointermove",
    (e) => {
      lastClientX = e.clientX;
      lastClientY = e.clientY;
    },
    true
  );

  document.addEventListener(
    "mouseover",
    (e) => {
      const result = findVideoAnchor(e.target);
      if (result) {
        hoveredVideoUrl = result.url;
        hoveredElement = result.anchor;
      }
    },
    true
  );

  document.addEventListener(
    "mousemove",
    (e) => {
      const result = findVideoAnchor(e.target);
      if (result) {
        hoveredVideoUrl = result.url;
        hoveredElement = result.anchor;
      }
    },
    true
  );

  window.addEventListener("focus", () => {
    requestAnimationFrame(() => refreshHoverFromLastPointer());
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible")
      requestAnimationFrame(() => refreshHoverFromLastPointer());
  });

  document.addEventListener(
    "mouseout",
    (e) => {
      // Only clear if we're leaving the tracked anchor (or its children)
      if (hoveredElement && !hoveredElement.contains(e.relatedTarget)) {
        hoveredVideoUrl = null;
        hoveredElement = null;
      }
    },
    true
  );

  // F24 trigger: sent by copy.ahk (SendInput "{F24}") on Windows.
  // F19 trigger: kept for potential future use, but NOT currently sent by
  // Hammerspoon (see below) — no harm in leaving the check in place.
  // "]" (BracketRight) trigger: sent by Linux/copyurl.sh via `ydotool type "]"`,
  // AND (as of 2026-07) by Hammerspoon on macOS via hs.eventtap.keyStroke({}, "]").
  // macOS previously used Option+X (e.code === "KeyX" && e.altKey), but as of
  // 2026-07 that combo stopped reaching this listener at all on Brave/macOS
  // (reproducibly confirmed: a real hover + synthetic Option+X never fired
  // trigger_keydown, while an unmodified key like "]" fired every time) —
  // most likely a Chromium change in how Option+letter composed-character key
  // events are dispatched. F19 was tried next (no printable character, no
  // OS/Karabiner binding on this keyboard) but synthetic F13-F20 keydowns sent
  // via Hammerspoon never reached this listener either (no beacon, no clipboard
  // change) — macOS appears to consume them as system-defined/media-key events
  // before Chromium ever sees a normal keydown. "]" is what actually works
  // reliably on both platforms, so Hammerspoon now sends it too.
  // On GNOME Wayland, `ydotool key <code>` mangles keycodes (broken virtual-device
  // keymap), but `ydotool type` reliably emits a character. "]" has no YouTube
  // shortcut, and we only act on it while a thumbnail is hovered (so normal "]"
  // typing elsewhere passes straight through). We deliberately do NOT require
  // !altKey here: the GNOME hotkey is Alt+Z, so the user is often still holding
  // Alt when copyurl.sh types "]" microseconds later — requiring !altKey made the
  // first press fail (it only worked once Alt was released). Ctrl/Meta are still
  // excluded so it won't collide with browser/OS chords. On macOS, Gemini runs
  // as a separate Safari Web App (see Hammerspoon's geminiBundleId), which never
  // loads this extension, so isBracketKey's queueGeminiPaste() call (Linux-only,
  // writes to chrome.storage.local for gemini.js) is an inert no-op there.
  document.addEventListener(
    "keydown",
    (e) => {
      const isF24 = (e.key === "F24" || e.code === "F24") && !e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey;
      const isF19 = (e.key === "F19" || e.code === "F19") && !e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey;
      // Linux "]" trigger: match by key only here, decide whether to act below.
      const isBracketKey = e.code === "BracketRight" && !e.ctrlKey && !e.metaKey;
      if (isF24 || isF19 || isBracketKey) {
        // Always re-derive the hovered video from the live cursor position at
        // trigger time. YouTube's hover overlay can leave a STALE hoveredVideoUrl
        // (a stray "mouseout" that didn't clear, or a detached element after the
        // grid re-renders), which previously made every press copy the same old
        // URL and anchored the "Copied!" toast to an off-screen element. Refreshing
        // unconditionally keeps the copied URL and the toast anchor correct.
        refreshHoverFromLastPointer();

        // For the "]" trigger, only act when we actually have a hovered video so
        // normal "]" typing (search box, comments) is never swallowed.
        if (isBracketKey && !hoveredVideoUrl) {
          return; // let the keystroke through
        }

        const ctx = {
          hovered: hoveredVideoUrl,
          x: lastClientX,
          y: lastClientY,
          focused: document.hasFocus(),
          visible: document.visibilityState,
        };
        diag("trigger_keydown", ctx);

        if (!hoveredVideoUrl) {
          setBeacon("null");
          diag("trigger_no_hover", ctx);
          return;
        }

        e.preventDefault();
        e.stopPropagation();

        // Linux flow: queue the Korean prompt + URL for the Gemini content script,
        // which inserts and submits it via the DOM (ydotool cannot type Korean).
        if (isBracketKey) {
          queueGeminiPaste(hoveredVideoUrl);
        }

        // Synchronous copy first: navigator.clipboard.writeText is async and AutoHotkey often
        // reads the clipboard before the promise resolves, pasting a stale URL into Gemini.
        if (copyViaExecCommand(hoveredVideoUrl)) {
          setBeacon("ok");
          diag("exec_ok", { url: hoveredVideoUrl });
          showToast(hoveredElement, "Copied!");
          return;
        }
        setBeacon("execfail");
        diag("exec_fail", { url: hoveredVideoUrl });
        const urlAtFire = hoveredVideoUrl;
        void navigator.clipboard
          .writeText(urlAtFire)
          .then(() => {
            setBeacon("asyncok");
            diag("async_ok", { url: urlAtFire });
            showToast(hoveredElement, "Copied!");
          })
          .catch((err) => {
            setBeacon("asyncfail");
            diag("async_fail", { err: String(err) });
            showToast(hoveredElement, "Copy failed");
          });
      }
    },
    true
  );

  /**
   * Synchronous clipboard write (execCommand). Returns true if the command reported success.
   * Required for reliable handoff to external automation that polls the OS clipboard.
   */
  function copyViaExecCommand(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    ta.style.top = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    ta.setSelectionRange(0, text.length);
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch {
      ok = false;
    }
    ta.remove();
    return ok;
  }

  /**
   * Return a usable on-screen bounding rect for the toast anchor. Starts at the
   * given element and climbs up to a few ancestors until it finds one whose rect
   * is non-degenerate and at least partly inside the viewport. This makes the
   * toast survive YouTube's home-page inline-preview overlay, which collapses the
   * a#thumbnail anchor to a 0-size rect (the renderer container above it is still
   * solid). Returns null if nothing usable is found.
   */
  function bestVisibleRect(anchor) {
    let el = anchor;
    let depth = 0;
    while (el && el.getBoundingClientRect && depth < 6) {
      if (el.isConnected) {
        const r = el.getBoundingClientRect();
        const visible =
          r.width > 0 &&
          r.height > 0 &&
          r.bottom > 0 &&
          r.right > 0 &&
          r.top < window.innerHeight &&
          r.left < window.innerWidth;
        if (visible) return r;
      }
      el = el.parentElement;
      depth++;
    }
    return null;
  }

  /**
   * Show a small "Copied!" toast near the hovered element.
   */
  function showToast(anchor, message) {
    // Remove any existing toast first
    const existing = document.getElementById("copyurl-toast");
    if (existing) existing.remove();

    const isSuccess = message === "Copied!";

    const toast = document.createElement("div");
    toast.id = "copyurl-toast";
    Object.assign(toast.style, {
      position: "fixed",
      zIndex: "2147483647",
      display: "inline-flex",
      alignItems: "center",
      gap: "7px",
      background: "rgba(28,28,30,0.96)",
      color: "#F2F2F7",
      padding: "9px 16px",
      borderRadius: "12px",
      fontSize: "13px",
      lineHeight: "1",
      fontFamily: "Roboto, 'Segoe UI', Arial, sans-serif",
      fontWeight: "600",
      letterSpacing: "0.2px",
      boxShadow: "0 8px 24px rgba(0,0,0,.45)",
      backdropFilter: "blur(8px)",
      WebkitBackdropFilter: "blur(8px)",
      border: "1px solid rgba(255,255,255,0.08)",
      pointerEvents: "none",
      opacity: "0",
      transition: "opacity 0.2s ease",
      whiteSpace: "nowrap",
    });

    if (isSuccess) {
      const check = document.createElement("span");
      check.textContent = "✓";
      Object.assign(check.style, {
        color: "#30D158",
        fontWeight: "700",
        fontSize: "14px",
      });
      toast.appendChild(check);
    }
    const label = document.createElement("span");
    label.textContent = message;
    toast.appendChild(label);

    document.body.appendChild(toast);

    // Position the toast above the hovered video. The anchor we were handed is
    // usually the <a> thumbnail link, but on the YouTube HOME page hovering a
    // thumbnail makes YouTube swap in an inline video-preview overlay, which
    // collapses a#thumbnail to a 0-size (or off-screen) rect. In that case we
    // climb to the nearest ancestor that still has a real on-screen rect (the
    // renderer/thumbnail container, which stays solid under the preview) so the
    // bubble still appears right above the item instead of disappearing.
    const rect = bestVisibleRect(anchor);
    if (rect) {
      toast.style.top = `${rect.top - toast.offsetHeight - 8}px`;
      toast.style.left = `${rect.left + rect.width / 2 - toast.offsetWidth / 2}px`;

      // Clamp to viewport
      const toastRect = toast.getBoundingClientRect();
      if (toastRect.left < 8) toast.style.left = "8px";
      if (toastRect.right > window.innerWidth - 8)
        toast.style.left = `${window.innerWidth - toast.offsetWidth - 8}px`;
      if (toastRect.top < 8) toast.style.top = `${rect.bottom + 8}px`;
    } else {
      // No usable anchor at all — show it pinned near the TOP-center of the
      // viewport (where the bubble historically appeared), not the bottom, so
      // it's where the user is looking right after pressing the hotkey.
      toast.style.top = "76px";
      toast.style.left = "50%";
      toast.style.transform = "translateX(-50%)";
    }

    // Fade in
    requestAnimationFrame(() => {
      toast.style.opacity = "1";
    });

    // Fade out and remove after 1.5s
    setTimeout(() => {
      toast.style.opacity = "0";
      setTimeout(() => toast.remove(), 250);
    }, 1500);
  }

  // ---- Orphan watchdog ------------------------------------------------------
  // Reloading the unpacked extension orphans THIS content script while the tab
  // stays open: chrome.* stops working, so queueGeminiPaste can no longer hand
  // the URL to Gemini even though execCommand copy still succeeds. Detect the
  // invalidation (chrome.runtime.id becomes undefined) and show a persistent
  // banner so the "Copied! but nothing pasted" failure is never silent.
  let _orphanBannerShown = false;
  function showReloadBanner() {
    if (_orphanBannerShown) return;
    _orphanBannerShown = true;
    try {
      const el = document.createElement("div");
      el.textContent = "CopyURL: extension was updated — reload this YouTube tab (Ctrl+R) to re-enable Gemini paste.";
      Object.assign(el.style, {
        position: "fixed",
        zIndex: "2147483647",
        top: "0",
        left: "0",
        right: "0",
        background: "#b3261e",
        color: "#fff",
        padding: "10px 14px",
        font: "600 13px Roboto, Arial, sans-serif",
        textAlign: "center",
        boxShadow: "0 2px 10px rgba(0,0,0,.35)",
        cursor: "pointer",
      });
      el.title = "Click to dismiss";
      el.addEventListener("click", () => el.remove());
      document.body.appendChild(el);
    } catch {}
  }
  const _orphanWatch = setInterval(() => {
    let alive = false;
    try { alive = !!(chrome && chrome.runtime && chrome.runtime.id); } catch { alive = false; }
    if (!alive) {
      clearInterval(_orphanWatch);
      showReloadBanner();
    }
  }, 1500);
})();
