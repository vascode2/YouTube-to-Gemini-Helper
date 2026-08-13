#Requires AutoHotkey v2.0

; =============================================================================
;  CopyYoutubeURL  —  Alt+Z: copy hovered YouTube video URL, then paste to Gemini
; -----------------------------------------------------------------------------
;  VERSION: 2026-06-25.8
;  CHANGES: Disabled per-paste new-chat (kGeminiNewChatEachTime := false) by user
;           preference — keep related summaries in ONE Gemini thread so the
;           conversation builds on itself. The new-chat code is retained; flip the
;           flag back to true if a stale thread starts refusing videos.
;  PRIOR (2026-06-25.7): added the new-chat-each-time mechanism (clicks Gemini's
;           left-rail "New chat" pencil, verified by the title dropping its topic).
;  PRIOR (2026-06-25.6): single "Copied!" bubble — disabled the AHK cursor toast
;           and restored kToastDwellMs so the content-script bubble shows again.
;  HOW TO CHECK WHICH VERSION IS LIVE:
;    1. This line (open the file in a text editor).
;    2. Hover the AHK tray icon — tooltip shows "CopyURL <version>".
;    3. copyurl_log.txt — a "Script loaded. version=..." line is written on (re)load.
; =============================================================================
kScriptVersion := "2026-06-25.8"

; Buffer one extra Alt+Z press while a handler is running (otherwise it's silently dropped
; on a slow Gemini activation, which makes consecutive copies look like "the wrong URL pasted").
#MaxThreadsBuffer true

; Gemini composer target (fractions of top-level Chrome PWA client size). Tune if posted click misses "Ask Gemini".
kGeminiInputXFrac := 0.5
kGeminiInputYFrac := 0.92
; On a brand-new Gemini chat the composer is vertically centered (~0.54), not pinned to the bottom.
kGeminiNewChatYFrac := 0.54

; Start a BRAND-NEW Gemini chat before every paste. Without this, each Alt+Z
; appends to whatever chat is already open; once Gemini refuses a video in that
; thread ("현재 시스템 제한... 영상을 직접 요약할 수 없습니다"), the refusal stays in
; the conversation context and it keeps refusing the SAME url — which is exactly
; why opening a new window and asking again works. A fresh chat each time avoids
; that context contamination (and lets Gemini's YouTube tool re-fire). Trade-off:
; no automatic follow-up continuity in the same thread (each copy = its own chat).
; DISABLED by user preference: keeping summaries in ONE thread is useful when the
; videos are on a related topic and the conversation builds on itself. Flip to
; true to force a clean chat per copy if Gemini starts refusing in a stale thread.
kGeminiNewChatEachTime := false
; "New chat" pencil icon position, in DEVICE PIXELS from the Gemini window's
; top-left corner (the top icon in the left rail, just under the Gemini logo).
; Calibrated for the user's display/DPI; re-measure if the new-chat click misses.
kGeminiNewChatBtnX := 30
kGeminiNewChatBtnY := 102

; Text appended AFTER the URL in Gemini (Alt+Z). "" = URL only. Clipboard is restored to the plain URL after send.
kGeminiPasteSuffix := " 한국어로 요약해 줘"

; Set true to append diagnostic lines to copyurl_log.txt next to this script.
kDebugLog := true
; Set true for extra per-stage timing and title-beacon lines (Phase 1 instrumentation).
kVerboseLog := true
; Rotate copyurl_log.txt when it exceeds this size (bytes). Set 0 to disable.
kLogMaxBytes := 524288

; Per-attempt clipboard-update timeout (ms) and number of F24 retries per candidate.
; A successful copy returns in ~30 ms (see logs). 800 ms is plenty for a real
; round-trip; if we hit timeout it almost certainly means the extension isn't
; listening on this browser, in which case more retries don't help.
kCopyAttemptTimeoutMs := 800
kCopyMaxAttempts := 2
; If the first attempt on a candidate returns beacon=none (extension didn't
; even fire), skip the remaining retries on that candidate and fall through
; to the next browser immediately. This is the main speed-up when one
; browser doesn't have the extension installed.
kFastFailOnNoBeacon := true

; Keep the YouTube tab in the foreground this long (ms) after a successful copy
; before switching to Gemini, so the content-script "Copied!" bubble (the one
; anchored just above the hovered thumbnail) is actually visible. The bubble
; fades in over ~200 ms, so values below ~500 ms only flash briefly. Applied in
; the common section, so BOTH the fast path and the slow/activation path show it.
; This is the user's preferred confirmation (it appears right over the thumbnail).
; Trade-off: this adds the dwell to the time-to-paste. Lower it if your YouTube
; tab sits on a separate monitor (then the bubble is visible without any dwell).
kToastDwellMs := 700

; Draw an AHK-native "Copied!" toast near the press-time cursor on every
; successful copy. Disabled by default: it duplicated the content-script bubble
; above the thumbnail (the one the user wants to keep). The code is retained so
; it can be re-enabled as a fallback if the page bubble ever stops firing.
kAhkToast := false
; How long the AHK toast stays on screen (ms).
kAhkToastMs := 1300

; Surface the running version so you can confirm which build is live without
; opening the file: tray-icon tooltip + a log line on every (re)load.
A_IconTip := "CopyURL " . kScriptVersion
DebugLog("Script loaded. version=" . kScriptVersion)

; File where we cache the exe of the most recent successful copy. Tried first
; on subsequent invocations so a working browser doesn't get stuck behind a
; non-working one in Z-order.
LastWinnerPath() {
    return A_ScriptDir "\copyurl_last_winner.txt"
}
ReadLastWinner() {
    p := LastWinnerPath()
    if !FileExist(p)
        return ""
    try {
        s := Trim(FileRead(p))
        return s
    }
    return ""
}
WriteLastWinner(exe) {
    p := LastWinnerPath()
    try {
        try FileDelete(p)
        FileAppend(exe, p)
    }
}

LogPath() {
    return A_ScriptDir "\copyurl_log.txt"
}

RotateLogIfNeeded() {
    global kLogMaxBytes
    if (kLogMaxBytes <= 0)
        return
    p := LogPath()
    if !FileExist(p)
        return
    try {
        sz := FileGetSize(p)
        if (sz > kLogMaxBytes) {
            old := p . ".1"
            try FileDelete(old)
            try FileMove(p, old)
        }
    }
}

DebugLog(msg) {
    global kDebugLog
    if !kDebugLog
        return
    RotateLogIfNeeded()
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " t=" . A_TickCount . " | " . msg . "`n", LogPath())
}

VerboseLog(msg) {
    global kVerboseLog
    if !kVerboseLog
        return
    DebugLog("[v] " . msg)
}

; --- AHK-native "Copied!" toast ------------------------------------------
; A small dark bubble drawn by the script itself near a screen point. Unlike the
; page's content-script toast, this always appears: it doesn't depend on the
; YouTube tab running a fresh content.js or on that tab staying in front. It's
; click-through (+E0x20) and shown NoActivate, so it never steals focus or blocks
; the Gemini handoff that runs right after.
;
; Style: rounded-corner pill, near-black translucent fill, a green check accent
; and semibold white label — a modern "toast" look rather than a flat box.
gCopiedToast := 0
ShowCopiedToast(text, sx, sy) {
    global gCopiedToast, kAhkToastMs
    CloseCopiedToast()
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
    g.BackColor := "1C1C1E"
    g.MarginX := 18
    g.MarginY := 11
    ; Green check accent + white label, vertically aligned on the same baseline.
    ; Font is set BEFORE each Add so the control auto-sizes to the rendered text
    ; (setting it afterward would size to the default font and clip the label).
    g.SetFont("s12 w700", "Segoe UI")
    g.Add("Text", "y12 c30D158", Chr(0x2713))           ; ✓
    g.SetFont("s12 w600", "Segoe UI")
    g.Add("Text", "x+8 yp cF2F2F7", text)
    gCopiedToast := g
    ; Offset a little down-right of the cursor so it doesn't sit under the pointer.
    g.Show("x" . (sx + 14) . " y" . (sy + 16) . " NoActivate")
    ; Round the corners and add a soft, glassy translucency.
    WinGetPos(, , &gw, &gh, g.Hwnd)
    rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", gw + 1, "Int", gh + 1, "Int", 22, "Int", 22, "Ptr")
    if (rgn)
        DllCall("SetWindowRgn", "Ptr", g.Hwnd, "Ptr", rgn, "Int", true)
    WinSetTransparent(238, g.Hwnd)
    SetTimer(CloseCopiedToast, -Abs(kAhkToastMs))
}
CloseCopiedToast() {
    global gCopiedToast
    try {
        if (gCopiedToast) {
            gCopiedToast.Destroy()
            gCopiedToast := 0
        }
    }
}

/**
 * Parse the title-beacon suffix written by content.js (zero-width-space + "[CU:STATE]").
 * Returns the STATE string (e.g. "ok", "null", "execfail", "asyncok", "asyncfail")
 * or "" if no beacon present.
 */
ReadTitleBeacon(hwnd) {
    title := ""
    try title := WinGetTitle(hwnd)
    if (title = "")
        return ""
    if RegExMatch(title, "\[CU:([A-Za-z]+)\]", &m)
        return m[1]
    return ""
}

WM_MOUSEMOVE := 0x200
WM_LBUTTONDOWN := 0x201
WM_LBUTTONUP := 0x202
MK_LBUTTON := 0x1

; Browsers we'll search for the YouTube tab, in priority order. Brave first so
; existing setups keep behaving identically; Chrome added so the same script
; works when the extension is installed in Chrome instead.
kYouTubeBrowsers := ["brave.exe", "chrome.exe"]

/**
 * Return an ordered list of candidate browser windows (most-likely first).
 * Replaces the old FindYouTubeWindow which returned only one. The Alt+Z
 * handler walks this list and tries each in turn, so e.g. if Brave is more
 * recently active but the extension isn't installed there, we automatically
 * fall through to Chrome's YouTube tab.
 *
 * Order:
 *   1. Foreground window if it's a YouTube browser tab.
 *   2. All matching windows across both browsers in WinGetList order
 *      (per-exe Z-order; "YouTube" titles before others).
 *
 * Chrome's Gemini PWA window is excluded.
 */
FindYouTubeCandidates() {
    global kYouTubeBrowsers
    list := []
    seen := Map()

    ; 0. Sticky preference: if a browser worked last time, try it first.
    lastExe := ReadLastWinner()

    ; 1. Foreground first.
    fg := WinExist("A")
    if (fg) {
        try {
            fgExe := WinGetProcessName(fg)
            fgTitle := WinGetTitle(fg)
            fgCls := WinGetClass(fg)
            for _i, exe in kYouTubeBrowsers {
                if (fgExe = exe && fgCls = "Chrome_WidgetWin_1"
                    && fgTitle != "" && InStr(fgTitle, "YouTube")
                    && !(exe = "chrome.exe" && InStr(fgTitle, "Gemini"))) {
                    seen[fg] := true
                    list.Push({ hwnd: fg, title: fgTitle, exe: exe })
                    break
                }
            }
        }
    }

    ; 2. Collect all YouTube-titled windows from each browser, then non-YouTube fallbacks.
    youtubeOnly := []
    others := []
    for _i, exe in kYouTubeBrowsers {
        for _j, hwnd in WinGetList("ahk_exe " . exe) {
            try {
                cls := WinGetClass(hwnd)
                title := WinGetTitle(hwnd)
                visible := DllCall("IsWindowVisible", "Ptr", hwnd)
                if !(visible && cls = "Chrome_WidgetWin_1" && title != "")
                    continue
                if (exe = "chrome.exe" && InStr(title, "Gemini"))
                    continue
                if InStr(title, "YouTube")
                    youtubeOnly.Push({ hwnd: hwnd, title: title, exe: exe })
                else
                    others.Push({ hwnd: hwnd, title: title, exe: exe })
            }
        }
    }

    ; Within YouTube-titled candidates, push lastExe-matching ones first.
    if (lastExe != "") {
        priority := []
        rest := []
        for _i, c in youtubeOnly
            (c.exe = lastExe ? priority : rest).Push(c)
        for _i, c in priority
            if !seen.Has(c.hwnd) {
                seen[c.hwnd] := true
                list.Push(c)
            }
        for _i, c in rest
            if !seen.Has(c.hwnd) {
                seen[c.hwnd] := true
                list.Push(c)
            }
    } else {
        for _i, c in youtubeOnly
            if !seen.Has(c.hwnd) {
                seen[c.hwnd] := true
                list.Push(c)
            }
    }
    for _i, c in others {
        if !seen.Has(c.hwnd) {
            seen[c.hwnd] := true
            list.Push(c)
        }
    }
    return list
}

; Backwards-compatible single-pick wrapper (kept in case anything else calls it).
FindYouTubeWindow() {
    cands := FindYouTubeCandidates()
    return cands.Length ? cands[1].hwnd : 0
}

/**
 * If the current foreground window is a YouTube tab in one of our browsers,
 * return { hwnd, exe }; otherwise 0.
 *
 * Used by the Alt+Z "fast path": when YouTube is already in front, we copy the
 * thumbnail under the cursor immediately — before any window activation, mouse
 * jitter, or KeyWait. That captures the video the user was hovering at the exact
 * instant they pressed Alt+Z (so moving the mouse afterward no longer changes
 * what gets copied) and lets the content-script "Copied!" toast render on the
 * still-focused YouTube tab.
 */
ForegroundYouTubeWindow() {
    global kYouTubeBrowsers
    fg := WinExist("A")
    if !fg
        return 0
    try {
        exe := WinGetProcessName(fg)
        title := WinGetTitle(fg)
        cls := WinGetClass(fg)
    } catch {
        return 0
    }
    for _i, e in kYouTubeBrowsers {
        if (exe = e && cls = "Chrome_WidgetWin_1" && title != ""
            && InStr(title, "YouTube")
            && !(e = "chrome.exe" && InStr(title, "Gemini"))) {
            return { hwnd: fg, exe: e }
        }
    }
    return 0
}

FindBraveWindow() {
    allWins := WinGetList("ahk_exe brave.exe")
    for index, hwnd in allWins {
        title := WinGetTitle(hwnd)
        cls := WinGetClass(hwnd)
        visible := DllCall("IsWindowVisible", "Ptr", hwnd)
        if (visible && cls = "Chrome_WidgetWin_1" && title != "") {
            return hwnd
        }
    }
    return 0
}

FindGeminiWindow() {
    allWins := WinGetList("ahk_exe chrome.exe")
    for index, hwnd in allWins {
        title := WinGetTitle(hwnd)
        cls := WinGetClass(hwnd)
        visible := DllCall("IsWindowVisible", "Ptr", hwnd)
        if (visible && cls = "Chrome_WidgetWin_1" && title != "" && InStr(title, "Gemini")) {
            return hwnd
        }
    }
    return 0
}

/**
 * Recursively find the largest Chrome_RenderWidgetHostHWND under a top-level Chromium window.
 */
ChromeScanForRender(h, &best, &bestArea) {
    if (WinGetClass(h) = "Chrome_RenderWidgetHostHWND") {
        WinGetClientPos(, , &cw, &ch, h)
        area := cw * ch
        if (area > bestArea) {
            bestArea := area
            best := h
        }
    }
    child := 0
    Loop 256 {
        child := DllCall("FindWindowEx", "Ptr", h, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
        if !child
            break
        ChromeScanForRender(child, &best, &bestArea)
    }
}

ChromeLargestRenderHwnd(rootHwnd) {
    best := 0
    bestArea := -1
    ChromeScanForRender(rootHwnd, &best, &bestArea)
    return best
}

MakeLParam(x, y) {
    return (y << 16) | (x & 0xFFFF)
}

PostMouseMove(renderHwnd, cx, cy) {
    lParam := MakeLParam(cx, cy)
    PostMessage(WM_MOUSEMOVE, 0, lParam, , "ahk_id " renderHwnd)
}

PostLClick(renderHwnd, cx, cy) {
    lParam := MakeLParam(cx, cy)
    PostMessage(WM_LBUTTONDOWN, MK_LBUTTON, lParam, , "ahk_id " renderHwnd)
    PostMessage(WM_LBUTTONUP, 0, lParam, , "ahk_id " renderHwnd)
}

/**
 * Click at a screen coordinate by posting WM_MOUSEMOVE + WM_LBUTTONDOWN/UP
 * directly to the Chromium render widget — no OS cursor movement.
 */
PostClickAtScreen(topHwnd, sx, sy) {
    render := ChromeLargestRenderHwnd(topHwnd)
    if !render
        return false
    pt := Buffer(8, 0)
    NumPut("Int", sx, pt, 0)
    NumPut("Int", sy, pt, 4)
    if !DllCall("ScreenToClient", "Ptr", render, "Ptr", pt)
        return false
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    PostMouseMove(render, cx, cy)
    Sleep(10)
    PostLClick(render, cx, cy)
    return true
}

/**
 * Map a point from top-level Chromium client coords to Chrome_RenderWidgetHostHWND client coords.
 */
ParentClientToRenderClient(parentHwnd, renderHwnd, pcx, pcy) {
    pt := Buffer(8, 0)
    NumPut("Int", pcx, pt, 0)
    NumPut("Int", pcy, pt, 4)
    if !DllCall("ClientToScreen", "Ptr", parentHwnd, "Ptr", pt)
        return 0
    if !DllCall("ScreenToClient", "Ptr", renderHwnd, "Ptr", pt)
        return 0
    return { x: NumGet(pt, 0, "Int"), y: NumGet(pt, 4, "Int") }
}

/**
 * Post WM_MOUSEMOVE at the physical cursor, in render-widget client space (no system cursor move).
 */
PostMouseMoveAtCursor(renderHwnd) {
    pt := Buffer(8, 0)
    if !DllCall("GetCursorPos", "Ptr", pt)
        return false
    if !DllCall("ScreenToClient", "Ptr", renderHwnd, "Ptr", pt)
        return false
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    PostMouseMove(renderHwnd, cx, cy)
    PostMouseMove(renderHwnd, cx + 1, cy)
    PostMouseMove(renderHwnd, cx, cy)
    return true
}

SyncChromiumHoverAtCursor(topHwnd) {
    render := ChromeLargestRenderHwnd(topHwnd)
    if !render
        return false
    return PostMouseMoveAtCursor(render)
}

/**
 * Real OS-level cursor jitter (1 px out and back). PostMessage(WM_MOUSEMOVE) is
 * enough for Chromium's input plumbing in most cases, but YouTube's hover
 * state (and thus content.js `hoveredVideoUrl`) sometimes requires a genuine
 * OS mouse event to update after a foreground-window switch. The visible
 * cursor only moves 1 px and snaps back, so it's effectively invisible.
 */
RealMouseJitter() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&cx0, &cy0)
    MouseMove(cx0 + 1, cy0, 0)
    Sleep(15)
    MouseMove(cx0, cy0, 0)
}

/**
 * Locate the Gemini "Ask Gemini" composer's vertical center by scanning a
 * vertical line at the window's horizontal middle for the composer's medium-
 * dark gray fill. Works for both new-chat (centered composer) and active-chat
 * (bottom-pinned composer) layouts.
 *
 * Returns the screen Y to click, or 0 if not found (caller should fall back).
 */
FindGeminiComposerScreenY(gemHwnd, clickX, &viaStrip) {
    viaStrip := false
    WinGetPos(&wx, &wy, &ww, &wh, gemHwnd)
    yTop := wy + Round(wh * 0.30)
    yBottom := wy + wh - 16
    CoordMode("Pixel", "Screen")
    composerColors := [0x1E1F20, 0x2A2B2D]

    ; The composer is bottom-pinned in an active chat, so we scan the BOTTOM
    ; STRIP first and fall back to the whole window only for a new (centered)
    ; chat. The strip (~220 px) is sized to contain the composer while excluding
    ; most reply text above it. We still verify a tall continuous fill run inside
    ; the strip, because anti-aliased pixels of white reply text can momentarily
    ; match the dark composer gray and a single-pixel PixelSearch hit would latch
    ; onto them; the run check rejects those. It short-circuits as soon as the
    ; band is confirmed tall enough, so the whole scan is ~150 ms vs the ~1.3 s
    ; full-window measure it replaces. A strip hit means a stable bottom-pinned
    ; composer (no animation), so the caller can skip its confirmation re-scan.
    stripTop := yBottom - 220
    if (stripTop < yTop)
        stripTop := yTop
    res := ScanLowestComposerBand(clickX, stripTop, yBottom, composerColors)
    if (res.y > 0) {
        viaStrip := true
        VerboseLog("gemini_scan_strip top=" . res.top . " bot=" . res.bot . " clickY=" . res.y)
        return res.y
    }

    ; FALLBACK — new-chat centered composer (or an unusual layout). Scan the
    ; whole content area; the composer is still the lowest qualifying band.
    res := ScanLowestComposerBand(clickX, yTop, yBottom, composerColors)
    if (res.y = 0) {
        VerboseLog("gemini_scan_no_band yTop=" . yTop . " yBottom=" . yBottom)
        return 0
    }
    VerboseLog("gemini_scan_band top=" . res.top . " bot=" . res.bot)
    return res.y
}

/**
 * Find the lowest tall composer-fill band on the vertical line at clickX within
 * [yFrom, yBottom]. Returns { y: clickY, top, bot } (y=0 if none). Confirms a
 * band is at least ~26 px tall before accepting it (rejects thin lines / text
 * anti-aliasing), but stops measuring height the moment that threshold is met.
 */
ScanLowestComposerBand(clickX, yFrom, yBottom, composerColors) {
    lowestTop := 0
    lowestBot := 0
    searchFrom := yFrom
    Loop 40 {
        hitY := 0
        for _, col in composerColors {
            fx := 0
            fy := 0
            try {
                if (PixelSearch(&fx, &fy, clickX, searchFrom, clickX, yBottom, col, 10)
                    && (hitY = 0 || fy < hitY))
                    hitY := fy
            }
        }
        if (hitY = 0)
            break
        bandTop := hitY
        bandBot := hitY
        y := hitY + 6
        ; Only need to confirm the band is tall enough (a real input box, not a
        ; 1-2 px text artifact); 26 px is well under the composer's ~48 px height.
        while (y <= yBottom && (y - bandTop) < 30) {
            if !IsGeminiComposerFill(clickX, y)
                break
            bandBot := y
            y += 6
        }
        if ((bandBot - bandTop) >= 24) {
            lowestTop := bandTop
            lowestBot := bandBot
        }
        searchFrom := bandBot + 10
        if (searchFrom >= yBottom)
            break
    }
    if (lowestTop = 0)
        return { y: 0, top: 0, bot: 0 }
    ; Click ~18 px below the band top — safely inside the input box.
    clickY := lowestTop + 18
    if (clickY > lowestBot)
        clickY := Round((lowestTop + lowestBot) / 2)
    return { y: clickY, top: lowestTop, bot: lowestBot }
}


/**
 * True if the pixel at (x,y) is the Gemini composer's dark input-fill shade —
 * darker-gray, near-neutral, and distinct from the near-black page background
 * (~0x0F0F0F) and from lighter text/icons.
 */
IsGeminiComposerFill(x, y) {
    px := 0
    try {
        px := PixelGetColor(x, y, "RGB")
    } catch {
        return false
    }
    r := (px >> 16) & 0xFF
    g := (px >> 8) & 0xFF
    b := px & 0xFF
    mx := Max(r, g, b)
    mn := Min(r, g, b)
    return (mx >= 0x18 && mx <= 0x4A && (mx - mn) <= 0x0C)
}

ClipboardSequence() {
    return DllCall("GetClipboardSequenceNumber", "UInt")
}

/**
 * Wait until the OS clipboard changes (extension finished writing). Avoids reading a stale URL
 * while navigator.clipboard.writeText is still pending, or general race with Sleep(300).
 */
WaitForClipboardUpdate(seqBefore, timeoutMs := 4000) {
    deadline := A_TickCount + timeoutMs
    Loop {
        if (ClipboardSequence() != seqBefore)
            return true
        if (A_TickCount >= deadline)
            return false
        Sleep(30)
    }
}

ClipboardTextLooksLikeYouTubeUrl(s) {
    if (s = "")
        return false
    ; Accept any URL form content.js can produce (watch, shorts → watch, youtu.be).
    return InStr(s, "youtube.com/watch?v=")
        || InStr(s, "youtube.com/shorts/")
        || InStr(s, "youtu.be/")
}

FocusGeminiComposer(topHwnd, xFrac, yFrac) {
    render := ChromeLargestRenderHwnd(topHwnd)
    if !render
        return false
    WinGetClientPos(, , &cw, &ch, topHwnd)
    pcx := Round(cw * xFrac)
    pcy := Round(ch * yFrac)
    mapped := ParentClientToRenderClient(topHwnd, render, pcx, pcy)
    if !mapped
        return false
    cx := mapped.x
    cy := mapped.y
    PostMouseMove(render, cx, cy)
    Sleep(30)
    PostLClick(render, cx, cy)
    return true
}

/**
 * Resync hover at multiple jitter points so YouTube's mousemove handler updates
 * hoveredVideoUrl even if the cursor sits exactly on an overlay seam.
 */
SyncChromiumHoverThorough(topHwnd) {
    render := ChromeLargestRenderHwnd(topHwnd)
    if !render
        return false
    pt := Buffer(8, 0)
    if !DllCall("GetCursorPos", "Ptr", pt)
        return false
    if !DllCall("ScreenToClient", "Ptr", render, "Ptr", pt)
        return false
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    ; Several small moves around the cursor; YouTube's pointermove fires on each.
    for delta in [[0,0],[2,0],[0,2],[-2,0],[0,-2],[1,1],[0,0]] {
        PostMouseMove(render, cx + delta[1], cy + delta[2])
        Sleep(15)
    }
    return true
}

/**
 * Like SyncChromiumHoverThorough but at an explicit SCREEN point instead of the
 * live cursor. Used by the slow/activation path so content.js's hoveredVideoUrl
 * is refreshed at the position the cursor was in WHEN Alt+Z WAS PRESSED — not
 * wherever the user has since moved it. PostMessage-only: the real OS cursor is
 * left where the user moved it (we don't fight their hand).
 */
SyncChromiumHoverAtScreenPoint(topHwnd, sx, sy) {
    render := ChromeLargestRenderHwnd(topHwnd)
    if !render
        return false
    pt := Buffer(8, 0)
    NumPut("Int", sx, pt, 0)
    NumPut("Int", sy, pt, 4)
    if !DllCall("ScreenToClient", "Ptr", render, "Ptr", pt)
        return false
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    for delta in [[0,0],[2,0],[0,2],[-2,0],[0,-2],[1,1],[0,0]] {
        PostMouseMove(render, cx + delta[1], cy + delta[2])
        Sleep(15)
    }
    return true
}

/**
 * Active Brave tab title check — only the top-level window's title reflects the
 * active tab. If "YouTube" isn't in it, content.js is on a different page and
 * Alt+X will silently miss.
 */
ActiveTabIsYouTube(hwnd) {
    title := WinGetTitle(hwnd)
    return InStr(title, "YouTube") > 0
}

/**
 * Resolve where to click in the Gemini window. Tries the pixel scan first; if
 * that fails, falls back to a title-based new-vs-active heuristic with a pixel
 * sanity check at the bottom-composer spot. Returns {y, tag}.
 */
ResolveGeminiClickY(gemHwnd, clickX, bottomY, centerY) {
    viaStrip := false
    foundY := FindGeminiComposerScreenY(gemHwnd, clickX, &viaStrip)
    if (foundY > 0)
        return { y: foundY, tag: viaStrip ? "scan-strip" : "scan-full", stable: viaStrip }
    gemTitle := ""
    try gemTitle := WinGetTitle(gemHwnd)
    isNewChat := InStr(gemTitle, "Gemini") && !InStr(gemTitle, " - ")
    try {
        CoordMode("Pixel", "Screen")
        px := PixelGetColor(clickX, bottomY, "RGB")
        r := (px >> 16) & 0xFF
        g := (px >> 8) & 0xFF
        b := px & 0xFF
        maxCh := Max(r, g, b)
        if (maxCh < 0x18)
            isNewChat := true
        VerboseLog("gemini_bottom_pixel=" . Format("0x{:06X}", px) . " maxCh=" . maxCh)
    }
    return { y: isNewChat ? centerY : bottomY, tag: isNewChat ? "new(fallback)" : "active(fallback)", stable: false }
}

/**
 * True if the Gemini window title looks like a fresh/empty chat (no per-chat
 * topic). Active chat: "Gemini - <topic> - Google Gemini" (two " - " separators).
 * New chat: "Gemini - Google Gemini" (one " - ").
 */
GeminiTitleIsNewChat(title) {
    count := 0
    pos := 1
    while (pos := InStr(title, " - ", false, pos)) {
        count++
        pos += 3
    }
    return count <= 1
}

/**
 * Click Gemini's "New chat" pencil (top of the left rail) so each summarize
 * request starts in a clean thread. A thread that already refused a video
 * ("can't access this URL") tends to keep refusing the same URL because the
 * refusal is now part of the conversation context; a fresh chat lets Gemini's
 * video tool fire again. Success is confirmed by the window title dropping its
 * per-chat topic. Returns true once a topic-less (new) title is seen.
 */
StartNewGeminiChat(gemHwnd) {
    global kGeminiNewChatBtnX, kGeminiNewChatBtnY
    before := ""
    try before := WinGetTitle(gemHwnd)
    if (GeminiTitleIsNewChat(before)) {
        DebugLog("Gemini already on a new chat (title=" . before . ") — skipping new-chat click.")
        return true
    }
    WinGetPos(&wx, &wy, &ww, &wh, gemHwnd)
    sx := wx + kGeminiNewChatBtnX
    sy := wy + kGeminiNewChatBtnY
    cur := before
    Loop 2 {
        PostClickAtScreen(gemHwnd, sx, sy)
        ; Poll up to ~1.2 s for the title to drop its topic.
        Loop 12 {
            Sleep(100)
            try cur := WinGetTitle(gemHwnd)
            if (GeminiTitleIsNewChat(cur)) {
                DebugLog("Gemini new chat started (title=" . cur . ").")
                return true
            }
        }
        DebugLog("Gemini new-chat click attempt " . A_Index . " didn't confirm yet (title=" . cur . ").")
    }
    DebugLog("Gemini new-chat click did not confirm a fresh chat; proceeding anyway.")
    return false
}

/**
 * One trigger attempt with its own clipboard-sequence wait. Returns true if the
 * extension wrote a fresh clipboard value within timeoutMs.
 *
 * Uses F24 as the in-tab signal (no global binding, no collision with other apps'
 * Alt+X hooks like CopyAnkitoChatGPT). Beacon-aware: caller passes hwnd so we can
 * capture the title beacon (set by content.js for ~300 ms after every trigger).
 */
TryCopyOnce(timeoutMs, hwnd := 0) {
    seqBefore := ClipboardSequence()
    tStart := A_TickCount
    SendInput("{F24}")
    deadline := tStart + timeoutMs
    beaconSeen := ""
    Loop {
        if (hwnd && beaconSeen = "") {
            b := ReadTitleBeacon(hwnd)
            if (b != "")
                beaconSeen := b
        }
        if (ClipboardSequence() != seqBefore) {
            VerboseLog("clip_changed elapsed=" . (A_TickCount - tStart) . " beacon=" . beaconSeen)
            return { ok: true, beacon: beaconSeen }
        }
        if (A_TickCount >= deadline) {
            if (hwnd && beaconSeen = "") {
                b := ReadTitleBeacon(hwnd)
                if (b != "")
                    beaconSeen := b
            }
            VerboseLog("clip_timeout elapsed=" . (A_TickCount - tStart) . " beacon=" . (beaconSeen = "" ? "none" : beaconSeen))
            return { ok: false, beacon: beaconSeen }
        }
        Sleep(25)
    }
}

$!z:: {
    DebugLog("--- Alt+Z pressed ---")
    ; Capture the cursor position the instant Alt+Z is pressed, before the user
    ; can move it. The slow/activation path syncs the YouTube hover at THIS point
    ; (not the live cursor) so moving the mouse afterward doesn't change which
    ; video gets copied. The fast path doesn't need it (it copies immediately).
    CoordMode("Mouse", "Screen")
    MouseGetPos(&origX, &origY)
    DebugLog("Press-time cursor: " . origX . "," . origY)

    success := false
    pickedHwnd := 0
    pickedExe := ""

    ; ---- FAST PATH ---------------------------------------------------------
    ; If a YouTube tab is already in front, copy the hovered video RIGHT NOW,
    ; before doing anything that takes time (KeyWait / WinActivate / mouse
    ; jitter). This pins the copy to the thumbnail under the cursor at the
    ; moment Alt+Z was pressed, so the user can move the mouse immediately
    ; afterward without changing what gets copied. It also lets the "Copied!"
    ; toast appear on the focused YouTube tab.
    ;
    ; We release Alt first: content.js ignores F24 while Alt is held
    ; (`!e.altKey` guard), and the user is almost always still holding Alt this
    ; early. Sending {Alt up} flips the OS modifier state so the synthetic F24
    ; registers with altKey=false, WITHOUT waiting for the physical release
    ; (waiting would give the cursor time to drift off the thumbnail).
    fgInfo := ForegroundYouTubeWindow()
    if (fgInfo) {
        SendInput("{LAlt up}{RAlt up}")
        DebugLog("Fast-path: foreground YouTube in " . fgInfo.exe . " — copying hovered video immediately.")
        res := TryCopyOnce(kCopyAttemptTimeoutMs, fgInfo.hwnd)
        if (res.ok) {
            success := true
            pickedHwnd := fgInfo.hwnd
            pickedExe := fgInfo.exe
            WriteLastWinner(pickedExe)
            DebugLog("Fast-path copy succeeded (beacon=" . (res.beacon = "" ? "none" : res.beacon) . ").")
            ; (The "Copied!" toast dwell is applied in the common section below,
            ; so both the fast and slow paths get it.)
        } else {
            DebugLog("Fast-path copy failed (beacon=" . (res.beacon = "" ? "none" : res.beacon) . ") — falling back to activation flow.")
        }
    }

    ; ---- SLOW PATH ---------------------------------------------------------
    ; Foreground wasn't a usable YouTube tab, or the fast copy failed. Fall back
    ; to the activate-and-jitter flow across all candidate browsers.
    if (!success) {
        ; Brief wait for the user to release Alt before we activate Brave and send F24.
        ; F24 itself doesn't fight a held Alt, but a still-pressed Alt can interfere
        ; with WinActivate focus. Cap the wait so a stuck-down case still proceeds.
        KeyWait("LAlt", "T0.4")
        KeyWait("RAlt", "T0.4")

        candidates := FindYouTubeCandidates()
        if (candidates.Length = 0) {
            DebugLog("No YouTube-capable browser window found (Brave/Chrome).")
            TrayTip("YouTube window not found in Brave or Chrome.", "CopyURL")
            return
        }
        DebugLog("Candidates: " . candidates.Length)

        for _ci, cand in candidates {
            hwnd := cand.hwnd
            pickedExe := cand.exe
            DebugLog("Trying candidate #" . _ci . " exe=" . pickedExe . " title=" . SubStr(cand.title, 1, 160))
            WinActivate(hwnd)
            if !WinWaitActive(hwnd,, 2) {
                DebugLog("WinWaitActive timed out for hwnd=" . hwnd)
                continue
            }
            if !ActiveTabIsYouTube(hwnd) {
                DebugLog("Active tab is not YouTube. Title=" . WinGetTitle(hwnd))
                continue
            }
            SendInput("{Escape}")
            Sleep(200)

            ; Retry the copy a few times for this candidate.
            candFailedFast := false
            Loop kCopyMaxAttempts {
                attempt := A_Index
                ; Refresh the YouTube hover at the PRESS-TIME cursor position
                ; (origX,origY) — NOT the live cursor. Otherwise, if the user
                ; moved the mouse after Alt+Z, content.js would copy the video
                ; they moved ONTO instead of the one they started on. We do NOT
                ; move the real OS cursor here, so the user's hand isn't fought.
                SyncChromiumHoverAtScreenPoint(hwnd, origX, origY)
                Sleep(40)
                SyncChromiumHoverAtScreenPoint(hwnd, origX, origY)
                Sleep(100)
                DebugLog("Copy attempt " . attempt . " on " . pickedExe)
                res := TryCopyOnce(kCopyAttemptTimeoutMs, hwnd)
                if (res.ok) {
                    success := true
                    DebugLog("Copy attempt " . attempt . " on " . pickedExe . " succeeded.")
                    break
                }
                DebugLog("Copy attempt " . attempt . " on " . pickedExe . " timed out (beacon=" . (res.beacon = "" ? "none" : res.beacon) . ").")
                ; Fast-fail: if extension didn't fire at all (beacon=none),
                ; further retries on the same browser won't help.
                if (kFastFailOnNoBeacon && res.beacon = "") {
                    candFailedFast := true
                    break
                }
                Sleep(120)
            }
            if (success) {
                pickedHwnd := hwnd
                WriteLastWinner(pickedExe)
                break
            }
            DebugLog("Candidate " . pickedExe . " " . (candFailedFast ? "fast-failed (beacon=none)" : "gave up after " . kCopyMaxAttempts . " attempts") . " — falling through to next candidate.")
        }
    }

    if !success {
        TrayTip("YouTube copy timed out across all browsers — hover a thumbnail and try again.", "CopyURL")
        return
    }

    ; Make sure Alt is fully released before we drive Gemini with Ctrl+A/Ctrl+V/
    ; Enter — a still-held Alt would turn those into Alt-chords. The slow path
    ; already KeyWaited above; the fast path skipped it (deliberately), so wait
    ; here. The copy is already done, so a moving mouse no longer matters.
    KeyWait("LAlt", "T0.4")
    KeyWait("RAlt", "T0.4")

    ; Reliable, browser-independent "Copied!" confirmation drawn by AHK itself,
    ; near where the cursor was when Alt+Z was pressed.
    if (kAhkToast)
        ShowCopiedToast("Copied!", origX, origY)

    ; Optional extra: keep the YouTube tab in front so the browser's own
    ; content-script bubble lingers too (defaults to 0 = off; the AHK toast above
    ; is the primary confirmation).
    if (kToastDwellMs > 0)
        Sleep(kToastDwellMs)

    Sleep(60)
    clipUrl := A_Clipboard
    ; If the clipboard doesn't look right yet, give it a brief grace period —
    ; another script's clipboard write can race ours by a few ms.
    if !ClipboardTextLooksLikeYouTubeUrl(clipUrl) {
        Loop 8 {
            Sleep(40)
            clipUrl := A_Clipboard
            if ClipboardTextLooksLikeYouTubeUrl(clipUrl)
                break
        }
    }
    if !ClipboardTextLooksLikeYouTubeUrl(clipUrl) {
        DebugLog("Clipboard not a YouTube URL: " . SubStr(clipUrl, 1, 120))
        TrayTip("Clipboard does not look like a YouTube URL — copy may have failed.", "CopyURL")
        return
    }
    DebugLog("Got URL: " . clipUrl)
    if (kGeminiPasteSuffix != "")
        A_Clipboard := clipUrl . kGeminiPasteSuffix
    VerboseLog("stage:find_gemini")
    gemHwnd := FindGeminiWindow()
    if !gemHwnd {
        DebugLog("Gemini window not found; left URL on clipboard.")
        A_Clipboard := clipUrl
        return
    }
    VerboseLog("stage:activate_gemini hwnd=" . gemHwnd)
    tAct := A_TickCount
    WinActivate(gemHwnd)
    if !WinWaitActive(gemHwnd,, 2) {
        DebugLog("WinWaitActive(Gemini) timed out after " . (A_TickCount - tAct) . " ms.")
        A_Clipboard := clipUrl
        return
    }
    VerboseLog("stage:gemini_active elapsed=" . (A_TickCount - tAct))
    ; Start a fresh chat so a previously-refused thread doesn't keep refusing the
    ; same URL (see kGeminiNewChatEachTime). This also resets the composer to its
    ; centered new-chat layout, which the pixel scan below already handles.
    if (kGeminiNewChatEachTime) {
        VerboseLog("stage:new_chat")
        StartNewGeminiChat(gemHwnd)
        Sleep(120)  ; let the fresh-chat layout begin settling before the scan
    }
    ; Real click on the "Ask Gemini" input field. Composer position depends on
    ; chat state (new = centered, active = pinned to bottom) AND DPI, so the
    ; only reliable approach is to find the composer's medium-gray fill via
    ; pixel scan along the window's vertical center. Falls back to layout
    ; heuristics only if the scan finds nothing.
    ;
    ; Why a second scan-and-click pass: on a freshly-activated PWA the composer
    ; can still be animating into position (new/centered chat), so the first scan
    ; may report a slightly different Y than the final rendered position. A second
    ; pass catches the settled layout. But when pass 1 located the composer via
    ; the bottom strip (r1.stable) it's an already-settled, bottom-pinned input —
    ; the common case — so we skip pass 2's ~230 ms re-scan entirely and go
    ; straight to paste.
    Sleep(140)
    VerboseLog("stage:pre_scan")
    WinGetPos(&wx, &wy, &ww, &wh, gemHwnd)
    clickX := wx + Round(ww * 0.5)
    bottomY := wy + wh - 60
    centerY := wy + Round(wh * kGeminiNewChatYFrac)

    ; Pass 1 — post click directly to render widget; OS cursor never moves.
    tScan := A_TickCount
    r1 := ResolveGeminiClickY(gemHwnd, clickX, bottomY, centerY)
    DebugLog("Gemini pass1 layout=" . r1.tag . " clickY=" . r1.y . " wy=" . wy . " wh=" . wh . " scanMs=" . (A_TickCount - tScan))
    PostClickAtScreen(gemHwnd, clickX, r1.y)

    ; Pass 2 — only when pass 1 was NOT a stable bottom-strip hit (i.e. a new/
    ; centered chat that may still be animating). Re-scan and re-click if the
    ; composer Y moved.
    if (!r1.stable) {
        Sleep(70)
        tScan2 := A_TickCount
        r2 := ResolveGeminiClickY(gemHwnd, clickX, bottomY, centerY)
        if (r2.y != r1.y || r2.tag != r1.tag) {
            DebugLog("Gemini pass2 layout=" . r2.tag . " clickY=" . r2.y . " (changed from pass1) scanMs=" . (A_TickCount - tScan2))
            PostClickAtScreen(gemHwnd, clickX, r2.y)
        }
        Sleep(40)
    } else {
        Sleep(60)
    }
    VerboseLog("stage:pre_paste")
    ; Now the input is focused — select all within it, paste, submit.
    ; Gemini's composer is React-driven: pasted text needs a moment to be
    ; reflected in component state before Enter is treated as "submit".
    ; Too short a gap and Enter just inserts a newline (or is ignored).
    SendInput("^a")
    Sleep(40)
    ; Re-assert clipboard right before paste in case anything raced it.
    if (kGeminiPasteSuffix != "")
        A_Clipboard := clipUrl . kGeminiPasteSuffix
    else
        A_Clipboard := clipUrl
    Sleep(25)
    SendInput("^v")
    Sleep(700)  ; let React commit the paste + enable the send button
    SendEvent("{Enter}")
    Sleep(200)
    ; Belt-and-suspenders: a second Enter via SendInput in case the first
    ; landed before the composer was ready. If the prompt was already sent,
    ; a stray Enter in an empty composer is a no-op.
    SendInput("{Enter}")
    A_Clipboard := clipUrl
    DebugLog("Sent to Gemini.")
}
