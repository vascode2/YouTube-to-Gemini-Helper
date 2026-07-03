-- CopyURL Mac workflow (Hammerspoon)
-- Hotkey: Option+Z
-- Flow:
-- 1) Activate YouTube window (Brave or Chrome)
-- 2) Send Option+X so content.js copies hovered URL
-- 3) Activate Gemini window
-- 4) Paste "summarize this video: <url>" and press Enter
-- 5) Restore clipboard to plain URL

local CONFIG_VERSION = "v21 2026-07-03 ax-focus-composer"

local hotkey = {"alt"}
local key = "z"

local youtubeApps = { "Brave Browser", "Google Chrome" }
local geminiTitleNeedle = "gemini"
-- Bundle ID of the installed Gemini Safari Web App (PWA). When set, the Gemini
-- window lookup prefers any window from this app over title-substring matching.
-- Title-substring matching alone is unsafe: a YouTube video whose title contains
-- "Gemini" (e.g. tutorials) lives in a Brave window and would otherwise be
-- selected as the "Gemini" target — causing the paste to land in Brave.
local geminiBundleId = "com.apple.Safari.WebApp.0D968D29-0354-49AB-9CD2-1B1FA685FFBB"
local pastePrefix = "한국어로 요약해줘 "

-- Seconds to keep the YouTube window frontmost after a successful copy, before
-- switching to Gemini, so the content.js "Copied!" bubble is actually visible.
-- macOS analog of kToastDwellMs in copy.ahk. Set to 0 to skip the dwell.
local toastDwell = 0.8

local logPath = os.getenv("HOME") .. "/Library/Logs/CopyURL.log"

local function logLine(text)
  local f = io.open(logPath, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. text .. "\n")
    f:close()
  end
  print("[CopyURL] " .. text)
end

local function notify(text)
  hs.alert.show(text, 2)
  logLine("notify: " .. text)
end

local function lower(s)
  if not s then return "" end
  return string.lower(s)
end

local function findWindowByTitleNeedle(needle)
  local needleLower = lower(needle)
  for _, win in ipairs(hs.window.orderedWindows()) do
    local title = lower(win:title())
    if string.find(title, needleLower, 1, true) then
      return win
    end
  end
  return nil
end

local function findGeminiWindow()
  if geminiBundleId and geminiBundleId ~= "" then
    local app = hs.application.applicationsForBundleID(geminiBundleId)[1]
    if app then
      local win = app:mainWindow() or app:focusedWindow()
      if win then return win end
      local wins = app:allWindows()
      if wins[1] then return wins[1] end
    end
  end
  -- Fallback: title-substring scan, but skip any window owned by the browsers
  -- (a YouTube video whose title contains "Gemini" would otherwise match).
  local needleLower = lower(geminiTitleNeedle)
  for _, win in ipairs(hs.window.orderedWindows()) do
    local app = win:application()
    local appName = app and app:name() or ""
    local isBrowser = false
    for _, b in ipairs(youtubeApps) do
      if appName == b then isBrowser = true; break end
    end
    if not isBrowser then
      local title = lower(win:title())
      if string.find(title, needleLower, 1, true) then
        return win
      end
    end
  end
  return nil
end

local function findYoutubeWindow()
  for _, appName in ipairs(youtubeApps) do
    local app = hs.appfinder.appFromName(appName)
    if app then
      local wins = app:allWindows()
      for _, win in ipairs(wins) do
        local title = lower(win:title())
        local looksLikeYoutube = string.find(title, "youtube", 1, true)
        if looksLikeYoutube then
          return win
        end
      end
      local front = app:mainWindow() or app:focusedWindow()
      if front then
        return front
      end
    end
  end
  return nil
end

local function sleep(seconds)
  hs.timer.usleep(math.floor(seconds * 1000000))
end

-- Find Gemini's prompt composer (a contenteditable exposed as AXTextArea) by
-- walking the app's accessibility tree. Prefer the one whose description looks
-- like the prompt field ("Enter a prompt for Gemini"); fall back to the first
-- AXTextArea. Returns the axuielement or nil.
local function findGeminiComposer(gapp)
  if not gapp then return nil end
  local ok, axapp = pcall(function() return hs.axuielement.applicationElement(gapp) end)
  if not ok or not axapp then return nil end
  local composer = nil
  local function walk(el, depth)
    if depth > 30 or composer then return end
    local role = el:attributeValue("AXRole")
    if role == "AXTextArea" then
      local desc = tostring(el:attributeValue("AXDescription") or "")
      if desc:lower():find("prompt") or desc:lower():find("gemini") then
        composer = el
        return
      end
      if not composer then composer = el end
    end
    local kids = el:attributeValue("AXChildren")
    if kids then for _, k in ipairs(kids) do walk(k, depth + 1) end end
  end
  walk(axapp, 0)
  return composer
end

-- Focus Gemini's composer via the accessibility API. This is far more reliable
-- than a coordinate-based click (no cursor movement, independent of window
-- size/position). The Safari WebApp does NOT auto-focus the composer on
-- activation, so without this the paste has nowhere to land. Returns true if a
-- composer was found and focus was requested.
local function focusGeminiComposer(gapp)
  local composer = findGeminiComposer(gapp)
  if not composer then
    logLine("composer: not found via AX")
    return false, nil
  end
  local ok = pcall(function() composer:setAttributeValue("AXFocused", true) end)
  logLine("composer: AX-focus requested ok=" .. tostring(ok))
  return true, composer
end

-- Activate an app WITHOUT blocking the Hammerspoon runloop, then invoke cb(ok).
-- This is critical: hs.timer.usleep (used by sleep()) busy-blocks the runloop,
-- so a requested app activation never actually completes while we spin — the
-- frontmost app stays stale and the flow wrongly concludes "not frontmost".
-- Polling via hs.timer.doAfter lets the runloop turn so the switch really lands.
local function activateAndWait(app, win, timeoutSec, cb)
  if win then win:focus() end
  app:activate(true)
  local deadline = hs.timer.secondsSinceEpoch() + timeoutSec
  local function poll()
    local f = hs.application.frontmostApplication()
    if f and f:pid() == app:pid() then cb(true); return end
    if hs.timer.secondsSinceEpoch() >= deadline then cb(false); return end
    hs.timer.doAfter(0.05, poll)
  end
  hs.timer.doAfter(0.05, poll)
end

local function sendKey(mods, key, label)
  -- Global keystroke (no app arg). We only call this once Gemini is confirmed
  -- frontmost AND its composer is AX-focused, so the event lands in the prompt.
  -- Testing showed app-targeted keyStroke reports ok but does not reach the
  -- Safari WebApp's web content, whereas a global keyStroke does.
  local ok, err = pcall(function()
    hs.eventtap.keyStroke(mods, key, 0)
  end)
  logLine(string.format("send-key %s ok=%s err=%s", label, tostring(ok), tostring(err)))
  return ok
end

-- Paste the clipboard payload into Gemini's composer and submit. Assumes the
-- caller has already brought Gemini frontmost (activateAndWait) and focused the
-- composer (focusGeminiComposer). Verifies the paste actually landed by reading
-- the composer value back via the accessibility API, then presses Return.
local function pasteAndSubmitToGemini(geminiApp)
  -- Final safety check so Cmd+V can never leak into another app.
  local frontNow = hs.application.frontmostApplication()
  logLine("frontmost before paste: " .. (frontNow and frontNow:name() or "?"))
  if not (frontNow and geminiApp and frontNow:pid() == geminiApp:pid()) then
    logLine("paste ABORT: Gemini not frontmost; refusing to send keys")
    return false
  end

  local expected = hs.pasteboard.getContents() or ""
  -- Select any existing composer text first so the paste REPLACES it (prevents
  -- accumulation if a previous run's text was never submitted).
  sendKey({ "cmd" }, "a", "cmd+a")
  sleep(0.05)
  sendKey({ "cmd" }, "v", "cmd+v")
  sleep(0.25)

  -- Verify the paste landed in the composer before submitting.
  local composer = findGeminiComposer(geminiApp)
  local landed = false
  if composer then
    local val = tostring(composer:attributeValue("AXValue") or "")
    -- The composer often reports a trailing newline; compare on a trimmed core.
    local core = expected:gsub("%s+$", "")
    landed = core ~= "" and val:find(core, 1, true) ~= nil
    logLine("paste verify: landed=" .. tostring(landed) ..
      " composerLen=" .. #val)
  else
    logLine("paste verify: composer not found; assuming landed")
    landed = true
  end

  if not landed then
    logLine("paste did NOT land; not submitting")
    return false
  end

  sendKey({}, "return", "return")
  return true
end

local function runFlowInner()
  local originalClipboard = hs.pasteboard.getContents() or ""

  local youtubeWin = findYoutubeWindow()
  if not youtubeWin then
    notify("No YouTube window found in Brave or Chrome")
    return
  end

  -- Bring the browser to the front and WAIT until it's actually frontmost,
  -- otherwise our synthetic Option+X is delivered to whatever app currently
  -- owns key focus (most often this VS Code window) and the extension never
  -- sees it.
  local ytApp = youtubeWin:application()
  ytApp:activate(true)
  youtubeWin:focus()
  local focusDeadline = hs.timer.secondsSinceEpoch() + 0.6
  while hs.timer.secondsSinceEpoch() < focusDeadline do
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() == ytApp:bundleID() then break end
    sleep(0.03)
  end
  sleep(0.05)
  local frontNow = hs.application.frontmostApplication()
  logLine("frontmost before Option+X: " .. (frontNow and frontNow:name() or "?"))

  -- Refresh hover state: when Brave was backgrounded, content.js may have lost
  -- its hoveredVideoUrl. Post a mouseMoved event at the current cursor position
  -- directly to Brave's PID. This makes the page fire mousemove -> mouseover
  -- on whatever's under the cursor (the thumbnail the user is still pointing at)
  -- WITHOUT moving the OS cursor. macOS analog of the Windows PostMessage
  -- WM_MOUSEMOVE jitter in copy.ahk.
  local mousePos = hs.mouse.absolutePosition()
  local et = hs.eventtap.event
  -- Two tiny jitter events so the page sees a real movement delta.
  -- event:post(app) targets a specific app without moving the global cursor.
  et.newMouseEvent(et.types.mouseMoved, hs.geometry.point(mousePos.x + 1, mousePos.y)):post(ytApp)
  sleep(0.02)
  et.newMouseEvent(et.types.mouseMoved, mousePos):post(ytApp)
  sleep(0.05)
  logLine(string.format("hover-refresh at %.0f,%.0f to %s", mousePos.x, mousePos.y, ytApp:name()))

  -- Remember pasteboard changeCount so we can detect ANY write, even if the new
  -- value equals the previous one. (After a prior run we restore the clipboard
  -- to the plain URL on line ~183; if the user copies the same hovered thumbnail
  -- again, a string-equality check would never see a change and the flow would
  -- spuriously report "URL copy failed".)
  local changeBefore = hs.pasteboard.changeCount()
  local clipBefore = hs.pasteboard.getContents() or ""

  -- Triggers content.js in-page copy action (Option+X).
  hs.eventtap.keyStroke({ "alt" }, "x", 0)

  -- Wait up to 2 s for the clipboard to actually change.
  local copiedUrl = ""
  local deadline = hs.timer.secondsSinceEpoch() + 2
  while hs.timer.secondsSinceEpoch() < deadline do
    sleep(0.08)
    local changedNow = hs.pasteboard.changeCount() ~= changeBefore
    local cur = hs.pasteboard.getContents() or ""
    if cur:find("youtube%.com") and (changedNow or cur ~= clipBefore) then
      copiedUrl = cur
      break
    end
  end
  logLine(string.format("copy-wait done: changed=%s len=%d",
    tostring(hs.pasteboard.changeCount() ~= changeBefore),
    #(hs.pasteboard.getContents() or "")))

  if copiedUrl == "" then
    notify("URL copy failed. Hover a thumbnail, then try again.")
    return
  end

  -- Keep YouTube frontmost briefly so the content.js "Copied!" bubble is seen
  -- before Gemini steals focus. Skipped when toastDwell is 0.
  if toastDwell > 0 then
    logLine(string.format("toast dwell %.2fs", toastDwell))
    sleep(toastDwell)
  end

  local geminiWin = findGeminiWindow()
  if not geminiWin then
    notify("Gemini window not found")
    return
  end

  local geminiApp = geminiWin:application()
  local gemTitle = geminiWin:title() or "?"
  logLine("gemini found: " .. geminiApp:name() .. " win=" .. gemTitle)

  -- Build payload and put it on clipboard BEFORE touching Gemini's focus,
  -- so the clipboard is ready the moment Cmd+V lands.
  local payload = pastePrefix .. copiedUrl
  hs.pasteboard.setContents(payload)
  logLine("pasting payload len=" .. #payload)

  -- Bring Gemini to the front, then paste — asynchronously. We must NOT
  -- busy-wait here: hs.timer.usleep blocks the runloop and the activation would
  -- never actually complete (front stays Brave). activateAndWait polls via
  -- doAfter so the switch really lands, then runs the paste in its callback.
  activateAndWait(geminiApp, geminiWin, 2.0, function(ok)
    local okRun, err = pcall(function()
      if not ok then
        local f = hs.application.frontmostApplication()
        logLine("gemini activate FAILED; front=" .. (f and f:name() or "?"))
        notify("Gemini didn't come to front. Try again.")
        return
      end
      -- Focus the composer via AX (the WebApp does NOT auto-focus it), give
      -- the focus a beat to settle, then paste + submit inside another async
      -- step so the runloop can process the focus change.
      focusGeminiComposer(geminiApp)
      hs.timer.doAfter(0.2, function()
        local ok2, err2 = pcall(function()
          local pasteOk = pasteAndSubmitToGemini(geminiApp)
          if not pasteOk then
            notify("Gemini paste failed (see CopyURL.log)")
            return
          end
          hs.timer.doAfter(0.3, function()
            hs.pasteboard.setContents(copiedUrl)
          end)
          notify("Sent URL to Gemini")
        end)
        if not ok2 then
          logLine("gemini-paste ERROR: " .. tostring(err2))
          notify("Gemini step error - see log")
        end
      end)
    end)
    if not okRun then
      logLine("gemini-callback ERROR: " .. tostring(err))
      notify("Gemini step error - see log")
    end
  end)
end

local function runFlow()
  print("[CopyURL] Option+Z fired at " .. os.date("%H:%M:%S"))
  notify("Option+Z fired")
  local ok, err = pcall(runFlowInner)
  if not ok then
    logLine("runFlow ERROR: " .. tostring(err))
    notify("runFlow error - see log")
  end
end

-- Paste-only path for automated testing: skips the YouTube hover+copy phase,
-- puts a fake URL on the clipboard, and exercises only the Gemini focus+paste.
local function runPasteOnlyTest()
  logLine("runPasteOnlyTest start")
  local fakeUrl = "https://www.youtube.com/watch?v=TESTID_" .. os.date("%H%M%S")
  hs.pasteboard.setContents(fakeUrl)
  local geminiWin = findGeminiWindow()
  if not geminiWin then
    notify("Gemini window not found")
    return
  end
  local app = geminiWin:application()
  local payload = pastePrefix .. fakeUrl
  hs.pasteboard.setContents(payload)
  logLine("paste-test payload len=" .. #payload .. " url=" .. fakeUrl)
  activateAndWait(app, geminiWin, 2.0, function(ok)
    if not ok then
      notify("paste-test: Gemini didn't come to front")
      return
    end
    focusGeminiComposer(app)
    hs.timer.doAfter(0.2, function()
      if pasteAndSubmitToGemini(app) then
        hs.timer.doAfter(0.3, function() hs.pasteboard.setContents(fakeUrl) end)
        notify("paste-test sent")
      else
        notify("paste-test failed (see CopyURL.log)")
      end
    end)
  end)
end

hs.hotkey.bind(hotkey, key, runFlow)

-- Enable `osascript -e 'tell application "Hammerspoon" to execute lua code "..."'`
hs.allowAppleScript(true)

-- Auto-reload this file when it changes on disk.
configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function()
  hs.reload()
end):start()

-- URL-triggered hooks for automated testing (no Accessibility needed):
--   open hammerspoon://copyurl-test    -> runs runFlow()
--   open hammerspoon://copyurl-reload  -> reloads this config
hs.urlevent.bind("copyurl-test", function() logLine("url-event: copyurl-test"); runFlow() end)
hs.urlevent.bind("copyurl-test-paste", function() logLine("url-event: copyurl-test-paste"); runPasteOnlyTest() end)
hs.urlevent.bind("copyurl-reload", function() logLine("url-event: copyurl-reload"); hs.reload() end)

logLine("config loaded; version=" .. CONFIG_VERSION .. "; Option+Z bound")
notify("CopyURL " .. CONFIG_VERSION)
