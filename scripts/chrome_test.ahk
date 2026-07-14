#Requires AutoHotkey v2.0
;
; chrome_test.ahk — automated end-to-end test for the Chrome path.
;
; What it does, all unattended:
;   1. Locates Chrome's main YouTube window (or asks the user to open one).
;   2. Activates it, finds a real thumbnail anchor, moves the system cursor over it
;      so the page registers a hover (extension needs a real hovered video).
;   3. Clears the clipboard, presses Alt+Z (the user-facing hotkey handled by
;      copy.ahk), and waits for the clipboard sequence number to change.
;   4. Reports PASS / FAIL with the URL or timeout reason.
;
; Run it manually after you have YouTube open in Chrome with thumbnails visible.
; (Brave is left untouched — this script never activates Brave.)
;
; Output: prints to a MsgBox AND appends to scripts\chrome_test_log.txt.

; SendLevel 1 so copy.ahk's $!z:: hook (which by default has #InputLevel 0)
; will accept our synthetic Alt+Z. Without this, AHK silently filters our
; keys from other AHK scripts' hooks.
SendLevel 1
SendMode "Event"

kAttemptCount := 5
kPerAttemptMs := 4000
kLogFile := A_ScriptDir "\chrome_test_log.txt"

Log(line) {
    global kLogFile
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " | " . line . "`n", kLogFile)
}

FindChromeYouTubeWindow() {
    for _i, hwnd in WinGetList("ahk_exe chrome.exe") {
        title := WinGetTitle(hwnd)
        cls := WinGetClass(hwnd)
        visible := DllCall("IsWindowVisible", "Ptr", hwnd)
        if (visible && cls = "Chrome_WidgetWin_1" && title != "" && InStr(title, "YouTube") && !InStr(title, "Gemini"))
            return hwnd
    }
    return 0
}

; Returns true if clipboard sequence number changed within timeoutMs.
WaitForClipboardChange(seqBefore, timeoutMs) {
    deadline := A_TickCount + timeoutMs
    Loop {
        if (DllCall("user32.dll\GetClipboardSequenceNumber", "UInt") != seqBefore)
            return true
        if (A_TickCount >= deadline)
            return false
        Sleep(40)
    }
}

ClipboardSeq() {
    return DllCall("user32.dll\GetClipboardSequenceNumber", "UInt")
}

; --- main ---
results := []
hwnd := FindChromeYouTubeWindow()
if !hwnd {
    MsgBox("Open YouTube in Chrome first (any page with visible thumbnails), then run this test again.", "chrome_test", "Iconx")
    ExitApp
}
Log("=== Chrome test start | hwnd=" . hwnd . " | title=" . SubStr(WinGetTitle(hwnd), 1, 120))

WinActivate(hwnd)
WinWaitActive(hwnd,, 2)
Sleep(400)

; Get window client rect in screen coords.
WinGetPos(&wx, &wy, &ww, &wh, hwnd)
Log("Window rect: x=" . wx . " y=" . wy . " w=" . ww . " h=" . wh)

; We don't know exact thumbnail positions, so probe a grid of points in the
; central content area. For each probe point we move the OS cursor there
; (thumbnails react to hover), wait briefly, clear clipboard, send Alt+Z, and
; see if the extension copies a youtube URL.
CoordMode("Mouse", "Screen")
MouseGetPos(&origX, &origY)

; Grid: roughly the area where thumbnails appear on home/search/watch pages.
xs := []
ys := []
for frac in [0.30, 0.45, 0.60, 0.75]
    xs.Push(wx + Round(ww * frac))
for frac in [0.30, 0.45, 0.60, 0.75]
    ys.Push(wy + Round(wh * frac))

passCount := 0
failCount := 0
attemptsDone := 0
for _i, px in xs {
    for _j, py in ys {
        if (attemptsDone >= kAttemptCount)
            break
        attemptsDone += 1

        MouseMove(px, py, 0)
        Sleep(450)  ; let YouTube register the hover

        ; Re-assert Chrome focus before each attempt — copy.ahk relies on the
        ; foreground window for browser auto-detect.
        if (WinExist("A") != hwnd) {
            WinActivate(hwnd)
            WinWaitActive(hwnd,, 1)
            Sleep(200)
        }

        seqBefore := ClipboardSeq()
        ; SendEvent (not SendInput): SendInput temporarily disables other AHK
        ; scripts' keyboard hooks, so copy.ahk would never see the Alt+Z.
        ; SendEvent goes through the normal input queue and IS visible to hooks.
        SendEvent("{Alt down}z{Alt up}")
        ok := WaitForClipboardChange(seqBefore, kPerAttemptMs)
        if (ok) {
            Sleep(120)
            clip := A_Clipboard
            looksOk := InStr(clip, "youtube.com/watch") || InStr(clip, "youtu.be/")
            if (looksOk) {
                passCount += 1
                Log("Attempt " . attemptsDone . " at (" . px . "," . py . "): PASS url=" . SubStr(clip, 1, 80))
                results.Push("PASS @ (" . px . "," . py . ") — " . SubStr(clip, 1, 60))
            } else {
                failCount += 1
                Log("Attempt " . attemptsDone . " at (" . px . "," . py . "): clipboard changed but not a YouTube URL: " . SubStr(clip, 1, 80))
                results.Push("CLIP-NON-YT @ (" . px . "," . py . ")")
            }
        } else {
            failCount += 1
            Log("Attempt " . attemptsDone . " at (" . px . "," . py . "): TIMEOUT (no clipboard change in " . kPerAttemptMs . "ms)")
            results.Push("TIMEOUT @ (" . px . "," . py . ")")
        }
        Sleep(400)
    }
    if (attemptsDone >= kAttemptCount)
        break
}

MouseMove(origX, origY, 0)

summary := "Chrome test: " . passCount . " PASS / " . failCount . " FAIL out of " . attemptsDone . " attempts.`n`n"
for _i, r in results
    summary .= "  - " . r . "`n"
summary .= "`nFull log: " . kLogFile
Log("=== Chrome test end | pass=" . passCount . " fail=" . failCount)
MsgBox(summary, "chrome_test", (passCount > 0 ? "Iconi" : "Iconx"))
