(() => {
  "use strict";

  // gemini.js — Gemini-side half of the CopyURL Linux flow.
  //
  // The Linux orchestrator (Linux/copyurl.sh) cannot reliably synthesize keyboard
  // input on GNOME Wayland (ydotool `key` mangles keycodes and cannot type Korean,
  // and `mousemove` is relative-only so coordinate paste is unreliable). So instead
  // of pasting at the OS level, the YouTube content script (content.js) writes a
  // payload to chrome.storage.local and this script inserts it into the Gemini
  // composer and submits it — entirely via the DOM. Works even in a background tab.

  const PENDING_KEY = "copyurlPendingPaste";
  const MAX_AGE_MS = 30000; // ignore stale payloads (e.g. left over across reloads)
  const COMPOSER_WAIT_MS = 8000; // how long to wait for the composer to appear
  const SUBMIT_DELAY_MS = 250; // let the composer register the inserted text first

  // Use console.log (not console.debug) so it shows at the default console level;
  // console.debug is hidden unless "Verbose" is enabled, which made the paste half
  // impossible to diagnose in the field.
  function log(...args) {
    try { console.log("[CopyURL/Gemini]", ...args); } catch {}
  }

  // Small, self-removing on-page toast so the user can SEE what gemini.js did
  // without opening DevTools. Visible feedback is the primary field diagnostic.
  function toast(message, ok) {
    try {
      const el = document.createElement("div");
      el.textContent = "CopyURL: " + message;
      Object.assign(el.style, {
        position: "fixed",
        zIndex: "2147483647",
        top: "12px",
        right: "12px",
        background: ok === false ? "#b3261e" : "#1a73e8",
        color: "#fff",
        padding: "8px 14px",
        borderRadius: "8px",
        font: "500 13px Roboto, Arial, sans-serif",
        boxShadow: "0 2px 10px rgba(0,0,0,.35)",
        pointerEvents: "none",
        opacity: "0",
        transition: "opacity .15s ease",
      });
      document.body.appendChild(el);
      requestAnimationFrame(() => { el.style.opacity = "1"; });
      setTimeout(() => {
        el.style.opacity = "0";
        setTimeout(() => el.remove(), 250);
      }, 2200);
    } catch {}
  }

  /** Find the Gemini message composer element, trying the most specific first. */
  function findComposer() {
    const selectors = [
      "rich-textarea .ql-editor[contenteditable='true']",
      ".ql-editor[contenteditable='true']",
      "div[contenteditable='true'][role='textbox']",
      "textarea[aria-label]",
      "textarea",
    ];
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) return el;
    }
    return null;
  }

  /** Wait for the composer to exist (the SPA may still be loading). */
  function waitForComposer(timeoutMs) {
    return new Promise((resolve) => {
      const existing = findComposer();
      if (existing) return resolve(existing);
      const deadline = Date.now() + timeoutMs;
      const obs = new MutationObserver(() => {
        const el = findComposer();
        if (el) {
          obs.disconnect();
          resolve(el);
        } else if (Date.now() > deadline) {
          obs.disconnect();
          resolve(null);
        }
      });
      obs.observe(document.documentElement, { childList: true, subtree: true });
      // Safety timeout in case no mutations fire.
      setTimeout(() => {
        obs.disconnect();
        resolve(findComposer());
      }, timeoutMs);
    });
  }

  /** Insert text into the composer, firing the events the editor expects. */
  function insertText(composer, text) {
    composer.focus();
    const isTextarea = composer.tagName === "TEXTAREA";
    if (isTextarea) {
      composer.value = text;
      composer.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    }
    // contenteditable (Quill / rich-textarea): execCommand fires proper input events.
    try {
      const sel = window.getSelection();
      sel.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      sel.addRange(range);
    } catch {}
    let ok = false;
    try {
      ok = document.execCommand("insertText", false, text);
    } catch {
      ok = false;
    }
    if (!ok) {
      // Fallback: set textContent and dispatch input.
      composer.textContent = text;
      composer.dispatchEvent(
        new InputEvent("input", { bubbles: true, data: text, inputType: "insertText" })
      );
    }
    return true;
  }

  /** Find an enabled send button using several strategies; null if none yet. */
  function findSendButton() {
    const selectors = [
      "button.send-button",
      "button[aria-label='Send message']",
      "button[aria-label='메시지 보내기']",
      "button[aria-label='보내기']",
      "button[mattooltip='Send message']",
      "button[data-test-id='send-button']",
      "button[aria-label*='Send']",
      "button[aria-label*='보내']",
    ];
    const enabled = (btn) =>
      btn &&
      btn.offsetParent !== null &&
      !btn.disabled &&
      btn.getAttribute("aria-disabled") !== "true";

    for (const sel of selectors) {
      const btn = document.querySelector(sel);
      if (enabled(btn)) return { btn, via: sel };
    }
    // Fallback: a button whose mat-icon / text says "send".
    const buttons = document.querySelectorAll("button");
    for (const btn of buttons) {
      const icon = btn.querySelector("mat-icon");
      const label = (icon && icon.textContent ? icon.textContent : btn.textContent || "")
        .trim()
        .toLowerCase();
      if (label === "send" && enabled(btn)) return { btn, via: "mat-icon[send]" };
    }
    return null;
  }

  /**
   * Submit the composer. Gemini's send button only enables once it registers the
   * inserted text, so poll briefly for an enabled button and click it. Synthetic
   * Enter events usually don't submit (isTrusted=false), so the click is primary
   * and Enter is only a last resort.
   */
  function submit(composer) {
    const deadline = Date.now() + 3000;
    const tryClick = () => {
      const found = findSendButton();
      if (found) {
        found.btn.click();
        log("submitted via", found.via);
        toast("sent to Gemini");
        return;
      }
      if (Date.now() < deadline) {
        setTimeout(tryClick, 150);
        return;
      }
      // Last resort: dispatch Enter on the composer.
      const opts = {
        bubbles: true,
        cancelable: true,
        key: "Enter",
        code: "Enter",
        keyCode: 13,
        which: 13,
      };
      composer.dispatchEvent(new KeyboardEvent("keydown", opts));
      composer.dispatchEvent(new KeyboardEvent("keyup", opts));
      log("send button never enabled; tried Enter fallback");
      toast("inserted, but no Send button found", false);
    };
    tryClick();
  }

  async function consumePending(payload) {
    if (!payload || !payload.text) return;
    if (typeof payload.ts === "number" && Date.now() - payload.ts > MAX_AGE_MS) {
      log("ignoring stale payload", payload.ts);
      clearPending();
      return;
    }
    // Clear immediately so the payload is consumed exactly once even if multiple
    // Gemini tabs are open or a storage event fires twice.
    clearPending();

    log("payload received; locating composer");
    const composer = await waitForComposer(COMPOSER_WAIT_MS);
    if (!composer) {
      log("composer not found; aborting");
      toast("composer not found (selectors may need updating)", false);
      return;
    }
    insertText(composer, payload.text);
    log("inserted text", payload.text);
    setTimeout(() => submit(composer), SUBMIT_DELAY_MS);
  }

  function clearPending() {
    try {
      chrome.storage.local.remove(PENDING_KEY);
    } catch {}
  }

  // React to new payloads queued while this tab is already open.
  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== "local" || !changes[PENDING_KEY]) return;
      const next = changes[PENDING_KEY].newValue;
      if (next) consumePending(next);
    });
  } catch (err) {
    log("storage listener unavailable", err);
  }

  // Also check on load in case the payload was queued just before this tab focused.
  try {
    chrome.storage.local.get(PENDING_KEY, (res) => {
      if (res && res[PENDING_KEY]) consumePending(res[PENDING_KEY]);
    });
  } catch (err) {
    log("initial storage read unavailable", err);
  }

  // ---- Orphan watchdog ------------------------------------------------------
  // When the extension is reloaded/updated, the content script in any ALREADY-OPEN
  // tab becomes "orphaned": its chrome.* APIs stop working and chrome.storage
  // onChanged never fires again, so queued pastes silently go nowhere until the
  // tab is reloaded. DOM access still works, so detect the invalidation and show
  // a persistent, actionable banner instead of failing invisibly.
  let _orphanBannerShown = false;
  function showReloadBanner() {
    if (_orphanBannerShown) return;
    _orphanBannerShown = true;
    try {
      const el = document.createElement("div");
      el.textContent = "CopyURL: extension was updated — reload this tab (Ctrl+R) to re-enable paste.";
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
    // chrome.runtime.id becomes undefined once the context is invalidated.
    let alive = false;
    try { alive = !!(chrome && chrome.runtime && chrome.runtime.id); } catch { alive = false; }
    if (!alive) {
      clearInterval(_orphanWatch);
      showReloadBanner();
    }
  }, 1500);

  log("ready (v1.2.6) on", location.href);
})();
