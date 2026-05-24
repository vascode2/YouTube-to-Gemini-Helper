-- CopyURL Mac workflow (Hammerspoon)
-- Hotkey: Option+Z
-- Flow:
-- 1) Activate YouTube window (Brave or Chrome)
-- 2) Send Option+X so content.js copies hovered URL
-- 3) Activate Gemini window
-- 4) Paste "summarize this video: <url>" and press Enter
-- 5) Restore clipboard to plain URL

local CONFIG_VERSION = "v8 2026-05-23 hover-refresh-api-fix"

local hotkey = {"alt"}
local key = "z"

local youtubeApps = { "Brave Browser", "Google Chrome" }
local geminiTitleNeedle = "gemini"
local pastePrefix = "한국어로 요약해줘 "

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

  -- Remember what was on the clipboard before so we can detect a real change.
  local clipBefore = hs.pasteboard.getContents() or ""

  -- Triggers content.js in-page copy action (Option+X).
  hs.eventtap.keyStroke({ "alt" }, "x", 0)

  -- Wait up to 2 s for the clipboard to actually change.
  local copiedUrl = ""
  local deadline = hs.timer.secondsSinceEpoch() + 2
  while hs.timer.secondsSinceEpoch() < deadline do
    sleep(0.08)
    local cur = hs.pasteboard.getContents() or ""
    if cur ~= clipBefore and cur:find("youtube%.com") then
      copiedUrl = cur
      break
    end
  end

  if copiedUrl == "" then
    notify("URL copy failed. Hover a thumbnail, then try again.")
    return
  end

  local geminiWin = findWindowByTitleNeedle(geminiTitleNeedle)
  if not geminiWin then
    notify("Gemini window not found")
    return
  end

  geminiWin:focus()
  local geminiApp = geminiWin:application()
  geminiApp:activate(true)
  -- Wait until Gemini's app actually becomes frontmost so keystrokes land here.
  local fdl = hs.timer.secondsSinceEpoch() + 0.6
  while hs.timer.secondsSinceEpoch() < fdl do
    local f = hs.application.frontmostApplication()
    if f and f:pid() == geminiApp:pid() then break end
    sleep(0.03)
  end
  sleep(0.1)
  local frontGem = hs.application.frontmostApplication()
  logLine("frontmost before paste: " .. (frontGem and frontGem:name() or "?"))

  -- NO synthetic clicks, NO JS focus injection. Gemini (Safari WebApp) auto-
  -- focuses its composer on window activation; the earlier Chrome AppleScript
  -- `execute javascript` block was useless here because WebApps don't expose
  -- Chrome's scripting dictionary, and it just added ~300ms per run.

  -- Build payload and put it on clipboard.
  local payload = pastePrefix .. copiedUrl
  hs.pasteboard.setContents(payload)
  logLine("pasting payload len=" .. #payload)

  -- Paste + Enter. No Cmd+A.
  local script = [[
    tell application "System Events"
      keystroke "v" using command down
      delay 0.2
      key code 36
    end tell
  ]]
  hs.osascript.applescript(script)
  sleep(0.1)

  -- Restore clipboard to plain URL (same behavior as Windows flow).
  hs.pasteboard.setContents(copiedUrl)
  notify("Sent URL to Gemini")

  -- Optional: restore original clipboard instead.
  -- hs.pasteboard.setContents(originalClipboard)
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
  local geminiWin = findWindowByTitleNeedle(geminiTitleNeedle)
  if not geminiWin then
    notify("Gemini window not found")
    return
  end
  -- Reuse the second half of the main flow by setting the variable runFlowInner
  -- expects. Simplest path: just inline the focus+paste here.
  geminiWin:focus()
  local app = geminiWin:application()
  app:activate(true)
  local fdl = hs.timer.secondsSinceEpoch() + 0.6
  while hs.timer.secondsSinceEpoch() < fdl do
    local f = hs.application.frontmostApplication()
    if f and f:pid() == app:pid() then break end
    sleep(0.03)
  end
  sleep(0.1)
  local frontPaste = hs.application.frontmostApplication()
  logLine("paste-test frontmost=" .. (frontPaste and (frontPaste:name() .. " bundle=" .. (frontPaste:bundleID() or "?")) or "?")
    .. " gemini-pid=" .. app:pid() .. " gemini-name=" .. (app:name() or "?"))
  local payload = pastePrefix .. fakeUrl
  hs.pasteboard.setContents(payload)
  logLine("paste-test payload len=" .. #payload .. " url=" .. fakeUrl)
  hs.osascript.applescript([[
    tell application "System Events"
      keystroke "v" using command down
      delay 0.2
      key code 36
    end tell
  ]])
  notify("paste-test sent")
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
