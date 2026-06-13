# End-to-end tests (real extension in a real browser)

`run_tests.sh` step 4 runs `tests/e2e/run_e2e.mjs`, which is the only test that
exercises the **actual cross-page handoff** that fails in the field:

```
hover a YouTube thumbnail
  -> content.js copies the URL + queues a payload in chrome.storage.local
    -> gemini.js (in another tab, same profile) reads it
      -> inserts the Korean prompt into the composer
        -> clicks Send
```

The older headless test (`scripts/gemini_paste_test.html`) mocks `chrome.*` and
loads `gemini.js` by hand, so it can only test the Gemini half in isolation.
This harness instead loads the **real unpacked extension** into Brave via
`puppeteer-core`, so `content.js`, `gemini.js`, and the genuine
`chrome.storage.local` event bridge all run exactly as they do in production.

## How it works

1. Serves `fixtures/youtube.html` and `fixtures/gemini.html` on `localhost`.
2. Copies the extension to a temp dir and rewrites the manifest's
   `content_scripts` matches to `http://localhost/youtube*` and
   `http://localhost/gemini*` (match patterns ignore the port).
3. Launches Brave with `--load-extension`, opens both fixtures in one profile,
   moves the mouse over the **second** thumbnail, presses `]` (the Linux
   trigger), and asserts:
   - the "Copied!" toast appears,
   - the Gemini composer receives the **live-hovered** URL (guards the
     stale-hover regression — it must be video B, not A),
   - Send is clicked exactly once, and never while disabled.

## Run it

```bash
npm install            # one-time: installs puppeteer-core (uses system Brave)
node tests/e2e/run_e2e.mjs
HEADFUL=1 node tests/e2e/run_e2e.mjs   # watch it run in a visible window
BRAVE_PATH=/usr/bin/google-chrome node tests/e2e/run_e2e.mjs   # different browser
```

Or via the full suite: `bash scripts/run_tests.sh` (skips this step gracefully
if `puppeteer-core` isn't installed).

## Full-system test (`run_full_system.mjs`)

`run_e2e.mjs` drives the trigger with CDP, so it proves the **extension** is
correct but bypasses the OS layer. `run_full_system.mjs` goes one level deeper:
it runs the **genuine** [Linux/copyurl.sh](../../Linux/copyurl.sh) orchestrator —
real `ydotool type "]"`, real `wl-paste` clipboard polling, real window
activation — against a real **headful** Brave + the real extension, and asserts
the hovered URL reaches **both** the OS clipboard and the Gemini composer + Send.
It also runs an A→B→A stale-hover guard through the real keystroke path.

This is the exact layer the field failures lived in (the stripped executable
bit, the GNOME key-grab, clipboard detection). It is **opt-in** because it needs
a real desktop session:

```bash
COPYURL_FULL_SYSTEM=1 node tests/e2e/run_full_system.mjs   # or: npm run test:full
COPYURL_FULL_SYSTEM=1 bash scripts/run_tests.sh            # as suite step 5
```

Requirements: a Wayland/X session, `ydotoold` running, and `wl-clipboard` +
`gdbus` (the same deps `copyurl.sh` needs). A browser window will flash open
while it runs, so it is not for headless CI.

