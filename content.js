(() => {
  "use strict";

  let hoveredVideoUrl = null;
  let hoveredElement = null;
  let lastClientX = -1;
  let lastClientY = -1;

  // Prompt prefix prepended to the copied URL when handing off to Gemini on Linux.
  // The Linux flow cannot type non-ASCII/Korean via ydotool, so the Gemini content
  // script (gemini.js) reads this payload from chrome.storage.local and inserts it
  // into the composer via the DOM instead of relying on OS-level paste.
  const PASTE_PREFIX = "한국말로 요약해줘 - ";
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
        [PENDING_KEY]: { text: PASTE_PREFIX + url, url, ts: Date.now() },
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
  const BEACON_TTL_MS = 300;
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
          tag === "ytd-playlist-video-renderer"
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
  // Option+X trigger: sent by Hammerspoon on macOS (hs.eventtap.keyStroke({"alt"}, "x")).
  // e.code === "KeyX" + e.altKey is used instead of e.key because Option+X on a US
  // keyboard produces the Unicode character "≈" rather than the letter "x".
  // "]" (BracketRight) trigger: sent by Linux/copyurl.sh via `ydotool type "]"`.
  // On GNOME Wayland, `ydotool key <code>` mangles keycodes (broken virtual-device
  // keymap), but `ydotool type` reliably emits a character. "]" has no YouTube
  // shortcut, and we only act on it while a thumbnail is hovered (so normal "]"
  // typing elsewhere passes straight through). We deliberately do NOT require
  // !altKey here: the GNOME hotkey is Alt+Z, so the user is often still holding
  // Alt when copyurl.sh types "]" microseconds later — requiring !altKey made the
  // first press fail (it only worked once Alt was released). Ctrl/Meta are still
  // excluded so it won't collide with browser/OS chords.
  document.addEventListener(
    "keydown",
    (e) => {
      const isF24 = (e.key === "F24" || e.code === "F24") && !e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey;
      const isOptionX = e.code === "KeyX" && e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey;
      // Linux "]" trigger: match by key only here, decide whether to act below.
      const isBracketKey = e.code === "BracketRight" && !e.ctrlKey && !e.metaKey;
      if (isF24 || isOptionX || isBracketKey) {
        // Recover hover from the last pointer position. YouTube's hover overlay
        // can fire a stray "mouseout" that clears hoveredVideoUrl even though the
        // cursor is still parked on the thumbnail; without this, the very common
        // "press Alt+Z while hovering" case intermittently copies nothing.
        if (!hoveredVideoUrl) refreshHoverFromLastPointer();

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
   * Show a small "Copied!" toast near the hovered element.
   */
  function showToast(anchor, message) {
    // Remove any existing toast first
    const existing = document.getElementById("copyurl-toast");
    if (existing) existing.remove();

    const toast = document.createElement("div");
    toast.id = "copyurl-toast";
    toast.textContent = message;
    Object.assign(toast.style, {
      position: "fixed",
      zIndex: "2147483647",
      background: "#323232",
      color: "#fff",
      padding: "6px 14px",
      borderRadius: "6px",
      fontSize: "13px",
      fontFamily: "Roboto, Arial, sans-serif",
      fontWeight: "500",
      boxShadow: "0 2px 8px rgba(0,0,0,.35)",
      pointerEvents: "none",
      opacity: "0",
      transition: "opacity 0.2s ease",
    });

    document.body.appendChild(toast);

    // Position near the anchor element
    if (anchor) {
      const rect = anchor.getBoundingClientRect();
      toast.style.top = `${rect.top - toast.offsetHeight - 8}px`;
      toast.style.left = `${rect.left + rect.width / 2 - toast.offsetWidth / 2}px`;

      // Clamp to viewport
      const toastRect = toast.getBoundingClientRect();
      if (toastRect.left < 8) toast.style.left = "8px";
      if (toastRect.right > window.innerWidth - 8)
        toast.style.left = `${window.innerWidth - toast.offsetWidth - 8}px`;
      if (toastRect.top < 8) toast.style.top = `${rect.bottom + 8}px`;
    } else {
      toast.style.bottom = "24px";
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
