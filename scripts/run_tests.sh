#!/usr/bin/env bash
# CopyURL automated test runner.
#
# One command, no manual steps. It:
#   1) Syntax-checks the extension scripts (content.js, gemini.js) with node.
#   2) Validates manifest.json is parseable and reports its version.
#   3) Runs the gemini.js paste/submit logic headlessly against a faithful
#      mock of the real Gemini composer DOM (scripts/gemini_paste_test.html)
#      using Brave/Chrome --headless, and asserts pass==true.
#
# Exit code 0 = all green. Non-zero = something failed (and what).
#
# Usage:  scripts/run_tests.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
fail=0

note()  { printf '\n=== %s ===\n' "$*"; }
ok()    { printf '  PASS  %s\n' "$*"; }
bad()   { printf '  FAIL  %s\n' "$*"; fail=1; }

# ---- 1. JS syntax ----------------------------------------------------------
note "JavaScript syntax (node --check)"
if ! command -v node >/dev/null 2>&1; then
  bad "node not found (needed to syntax-check the extension scripts)"
else
  for f in content.js gemini.js; do
    if node --check "$f" 2>/tmp/cu_node_err; then ok "$f"; else
      bad "$f: $(cat /tmp/cu_node_err)"
    fi
  done
fi

# ---- 2. manifest -----------------------------------------------------------
note "manifest.json"
if command -v python3 >/dev/null 2>&1; then
  ver=$(python3 -c 'import json,sys; print(json.load(open("manifest.json"))["version"])' 2>/tmp/cu_man_err)
  if [[ -n "$ver" ]]; then ok "valid JSON, version $ver"; else
    bad "manifest.json invalid: $(cat /tmp/cu_man_err)"
  fi
else
  bad "python3 not found (needed to validate manifest.json)"
fi

# ---- 3. headless gemini.js paste test --------------------------------------
note "gemini.js paste/submit (headless, faithful Gemini DOM mock)"
BROWSER=""
for c in brave-browser brave google-chrome chromium chromium-browser; do
  if command -v "$c" >/dev/null 2>&1; then BROWSER="$(command -v "$c")"; break; fi
done
if [[ -z "$BROWSER" ]]; then
  bad "no Chromium-based browser found (brave/chrome/chromium) to run the headless test"
else
  dom=$(mktemp /tmp/cu_dom.XXXXXX.html)
  timeout 40 "$BROWSER" --headless=new --disable-gpu --no-sandbox \
    --virtual-time-budget=4000 \
    --dump-dom "file://$ROOT/scripts/gemini_paste_test.html" \
    >"$dom" 2>/dev/null
  result=$(python3 - "$dom" <<'PY'
import re, sys, json
d = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="result">(.*?)</pre>', d, re.S)
if not m:
    print("NO_RESULT"); sys.exit(0)
print(m.group(1).strip())
PY
)
  if [[ "$result" == "NO_RESULT" || -z "$result" ]]; then
    bad "headless test produced no result block (browser/headless issue)"
  else
    printf '%s\n' "$result" | sed 's/^/    /'
    if printf '%s' "$result" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("pass") else 1)' 2>/dev/null; then
      ok "Korean prompt inserted + send button clicked while enabled + payload cleared"
    else
      bad "paste/submit assertions did not all pass (see JSON above)"
    fi
  fi
  rm -f "$dom"
fi

# ---- 4. real-extension end-to-end (puppeteer) ------------------------------
# Loads the ACTUAL unpacked extension into Brave, opens a YouTube + a Gemini
# fixture in one profile, simulates a real hover + trigger keypress, and asserts
# the hovered URL flows content.js -> chrome.storage -> gemini.js -> Send click.
# This is the genuine cross-page handoff the single-page mock above cannot test.
# Skipped (not failed) when puppeteer-core isn't installed, so the core suite
# still runs in a bare checkout. Install with: npm install
note "real-extension end-to-end (puppeteer)"
if [[ ! -d node_modules/puppeteer-core ]]; then
  printf '  SKIP  puppeteer-core not installed (run: npm install)\n'
elif ! command -v node >/dev/null 2>&1; then
  printf '  SKIP  node not found\n'
else
  if node tests/e2e/run_e2e.mjs 2>&1 | sed 's/^/    /'; then
    ok "end-to-end flow (hover -> trigger -> Gemini paste + Send)"
  else
    bad "end-to-end flow failed (see output above)"
  fi
fi

# ---- summary ---------------------------------------------------------------
note "Summary"
if (( fail == 0 )); then
  echo "  ALL GREEN"
else
  echo "  FAILURES ABOVE"
fi
exit "$fail"