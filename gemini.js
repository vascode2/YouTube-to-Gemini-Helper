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
      "div[contenteditable='true'][aria-label]",
      "[contenteditable='true'][aria-label]",
      "rich-textarea [contenteditable='true']",
      "div[contenteditable='true']",
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

  /** Read the composer's current text, for textarea or contenteditable. */
  function composerText(composer) {
    if (!composer) return "";
    if (composer.tagName === "TEXTAREA") return composer.value || "";
    return (composer.innerText || composer.textContent || "").replace(/\u00A0/g, " ");
  }

  /** Select the composer's whole content so the next insertion replaces it. */
  function selectAllInComposer(composer) {
    try {
      const sel = window.getSelection();
      sel.removeAllRanges();
      const range = document.createRange();
      range.selectNodeContents(composer);
      sel.addRange(range);
    } catch {}
  }

  /**
   * Insert text into the composer, firing the events the editor expects, and
   * VERIFY it landed. Gemini's composer DOM/behaviour changes periodically, so
   * we try several strategies and confirm the text is actually present before
   * declaring success (the old code returned true unconditionally, which made a
   * silent Gemini DOM change look like "copied but nothing pasted").
   *
   * Strategies, in order:
   *   1. textarea: set .value + input event.
   *   2. contenteditable: execCommand("insertText") (replaces current selection).
   *   3. synthetic paste carrying a DataTransfer (Quill/ProseMirror honour paste).
   *   4. direct textContent + InputEvent (last resort).
   * After each, we read the composer back and stop as soon as the text is there.
   *
   * Returns true only if the composer actually contains the inserted text.
   */
  function insertText(composer, text) {
    composer.focus();
    const present = () => composerText(composer).indexOf(text) !== -1;

    if (composer.tagName === "TEXTAREA") {
      try {
        composer.value = text;
        composer.dispatchEvent(new Event("input", { bubbles: true }));
      } catch {}
      return present();
    }

    // contenteditable (Quill / rich-textarea). Select existing content first so a
    // re-trigger replaces the previous prompt instead of appending to it.
    selectAllInComposer(composer);
    try { document.execCommand("insertText", false, text); } catch {}
    if (present()) return true;

    // Fallback 1: synthetic paste event with a DataTransfer payload. Rich editors
    // (Quill/ProseMirror, which Gemini uses) implement their own paste handler,
    // so this is the most robust cross-version insertion path.
    try {
      selectAllInComposer(composer);
      const dt = new DataTransfer();
      dt.setData("text/plain", text);
      composer.dispatchEvent(
        new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: dt })
      );
    } catch {}
    if (present()) return true;

    // Fallback 2: set textContent directly and dispatch an input event.
    try {
      composer.textContent = text;
      composer.dispatchEvent(
        new InputEvent("input", { bubbles: true, data: text, inputType: "insertText" })
      );
    } catch {}
    return present();
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
    const inserted = insertText(composer, payload.text);
    if (!inserted) {
      // The composer exists but none of the insertion strategies stuck — almost
      // always a Gemini editor DOM/behaviour change. Make it loud instead of the
      // old silent "copied but nothing pasted".
      log("insert failed: composer found but text did not land", composer.tagName, composer.className);
      toast("could not type into Gemini composer (DOM changed?)", false);
      return;
    }
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

  log("ready (v1.2.8) on", location.href);
})();
