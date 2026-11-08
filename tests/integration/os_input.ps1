# Drives the real app through its real Win32 window procedure, on a private
# desktop (nothing appears on screen; the user's mouse and focus are not
# touched). Mouse, keyboard and committed IME text arrive as the window
# messages Windows itself delivers. The results are read back from the files
# the app saves, not from the app's own state.
#
#   zig build -Doptimize=ReleaseFast
#   powershell -File tests/integration/os_input.ps1 -Exe zig-out/bin/kest.exe -Data <empty folder> [-Shots <folder>]
#
# Checks: a click that wobbles 2px moves nothing; dragging reorders before a
# row and drops into a folder; Escape cancels a drag; typed ASCII, accented,
# CJK and a surrogate-pair emoji reach the URL and are saved; the IME
# composition window follows the URL caret; with -Dpi, all of it after a
# simulated move to a monitor at that DPI. A UI Automation client attached
# throughout checks what screen readers see: names, roles, focus, field text.
# Ctrl C / Ctrl V go through the real Windows clipboard (its previous
# contents, every format, are saved and put back). A second launch with no
# appearance chosen checks the window follows Windows switching light/dark.
# Set KEST_UIA_LIST=1 to print every published element with its rectangle.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Data,
    [string]$Shots = '',
    [double]$Pace = 1,
    # Simulate moving the window to a monitor at this DPI (e.g. 144 = 150%)
    # before any input: the real WM_DPICHANGED path, then every check at that scale.
    [int]$Dpi = 0
)
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing -Language CSharp @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class Os {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr attrs);
    [DllImport("user32")] static extern bool CloseDesktop(IntPtr desk);
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32")] static extern bool EnumDesktopWindows(IntPtr desk, EnumProc cb, IntPtr param);
    [DllImport("user32")] static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32", EntryPoint = "PostMessageW")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32", EntryPoint = "SendMessageW")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [DllImport("user32")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);

    public static IntPtr NewDesktop(string name) {
        IntPtr d = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000u, IntPtr.Zero);
        if (d == IntPtr.Zero) throw new Exception("CreateDesktop: " + Marshal.GetLastWin32Error());
        return d;
    }
    public static void Close(IntPtr desk) { CloseDesktop(desk); }
    public static int Start(string exe, string desktop, string cwd) {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.lpDesktop = desktop;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(exe, null, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, cwd, ref si, out pi))
            throw new Exception("CreateProcess: " + Marshal.GetLastWin32Error());
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return pi.dwProcessId;
    }
    public static IntPtr MainWindow(IntPtr desk, int pid) {
        IntPtr found = IntPtr.Zero;
        EnumDesktopWindows(desk, delegate(IntPtr h, IntPtr p) {
            int owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr Lp(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
    /// Saves what the window draws; false when the surface can't be read back.
    public static bool Shot(IntPtr hwnd, string path) {
        RECT r; GetClientRect(hwnd, out r);
        using (Bitmap b = new Bitmap(Math.Max(1, r.Right), Math.Max(1, r.Bottom))) {
            using (Graphics g = Graphics.FromImage(b)) {
                IntPtr dc = g.GetHdc();
                bool ok = PrintWindow(hwnd, dc, 3); // client only, full content
                g.ReleaseHdc(dc);
                if (!ok) return false;
            }
            b.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
"@

$WM_MOUSEMOVE = 0x200; $WM_LBUTTONDOWN = 0x201; $WM_LBUTTONUP = 0x202
$WM_KEYDOWN = 0x100; $WM_KEYUP = 0x101; $WM_CHAR = 0x102; $WM_CLOSE = 0x10
$VK_ESCAPE = 0x1B; $VK_END = 0x23; $VK_CONTROL = 0x11

# A collection with a folder and three requests, written as the app writes it.
New-Item -ItemType Directory -Force $Data | Out-Null
$Data = (Resolve-Path $Data).Path
if (Get-ChildItem $Data -Force) { throw "-Data must be an empty folder: $Data" }
$cid = '0a5e0000c0110001'
$ids = @{ Folder = 'f01de0000000000a'; Alpha = 'a1000000000000a1'; Beta = 'b2000000000000b2'; Gamma = 'c3000000000000c3' }
$dir = Join-Path $Data "collections\$cid\requests"
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Data "collections\$cid\collection.json"), @"
{
  "format": "kest.collection/1",
  "id": "$cid",
  "name": "OS input",
  "expanded": true,
  "items": [
    { "type": "folder", "id": "$($ids.Folder)", "name": "Folder A", "expanded": false, "items": [] },
    { "type": "request", "id": "$($ids.Alpha)", "name": "Alpha", "method": "GET" },
    { "type": "request", "id": "$($ids.Beta)", "name": "Beta", "method": "GET" },
    { "type": "request", "id": "$($ids.Gamma)", "name": "Gamma", "method": "GET" }
  ]
}
"@, $utf8)
foreach ($n in 'Alpha', 'Beta', 'Gamma') {
    [IO.File]::WriteAllText((Join-Path $dir "$($ids[$n]).json"), @"
{ "format": "kest.request/1", "name": "$n", "method": "GET", "url": "https://example.invalid/$($n.ToLower())", "params": [], "headers": [], "body": { "kind": "none", "text": "" } }
"@, $utf8)
}
[IO.File]::WriteAllText((Join-Path $Data 'workspace.json'), @"
{ "format": "kest.workspace/1", "dark": true, "sidebarOpen": true, "sidebarWidth": 300, "autosave": true, "windowWidth": 1280, "windowHeight": 800, "openTabs": [] }
"@, $utf8)

$env:KEST_DATA = $Data
$env:KEST_SYNTHETIC_POINTER = '1'
$Exe = (Resolve-Path $Exe).Path
$name = "kest-input-$PID"
$desk = [Os]::NewDesktop($name)
$failures = @()
function Check($ok, $what) {
    if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:failures += $what }
}
try {
    $id = [Os]::Start($Exe, $name, (Split-Path $Exe))
    $p = [Diagnostics.Process]::GetProcessById($id)
    [void]$p.Handle
    if (-not $p.WaitForInputIdle(30000)) { throw 'Not idle after 30 s' }
    Start-Sleep -Milliseconds ([int](700 * $Pace))
    $hwnd = [Os]::MainWindow($desk, $id)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'No window' }
    $scale = [Os]::GetDpiForWindow($hwnd) / 96.0
    if ($Dpi -gt 0) {
        $from = [int]([Os]::GetDpiForWindow($hwnd))
        [void][Os]::SendMessage($hwnd, 0x8000 + 75, [IntPtr]$Dpi, [IntPtr]$from)
        Start-Sleep -Milliseconds ([int](900 * $Pace))
        $scale = $Dpi / 96.0
    }
    # The default window size follows the screen; every point below assumes
    # a 1280x800 (logical) client area, so set it.
    $rc = New-Object Os+RECT; [void][Os]::GetClientRect($hwnd, [ref]$rc)
    $wr = New-Object Os+RECT; [void][Os]::GetWindowRect($hwnd, [ref]$wr)
    $frameW = ($wr.Right - $wr.Left) - $rc.Right; $frameH = ($wr.Bottom - $wr.Top) - $rc.Bottom
    [void][Os]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, [int][Math]::Round(1280 * $scale) + $frameW, [int][Math]::Round(800 * $scale) + $frameH, 0x16)
    Start-Sleep -Milliseconds ([int](500 * $Pace))
    [void][Os]::GetClientRect($hwnd, [ref]$rc)
    "window: client {0}x{1} px, scale {2}" -f $rc.Right, $rc.Bottom, $scale

    # Layout points are logical; the window speaks physical pixels.
    function Px($v) { [int][Math]::Round([double]$v * $scale) }
    function SendMove($x, $y, $held) { [void][Os]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]$(if ($held) { 1 } else { 0 }), [Os]::Lp((Px $x), (Px $y))); Start-Sleep -Milliseconds ([int](60 * $Pace)) }
    function SendDown($x, $y) { [void][Os]::PostMessage($hwnd, $WM_LBUTTONDOWN, [IntPtr]1, [Os]::Lp((Px $x), (Px $y))); Start-Sleep -Milliseconds ([int](80 * $Pace)) }
    function SendUp($x, $y) { [void][Os]::PostMessage($hwnd, $WM_LBUTTONUP, [IntPtr]0, [Os]::Lp((Px $x), (Px $y))); Start-Sleep -Milliseconds ([int](150 * $Pace)) }
    function SendKey($vk) { [void][Os]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$vk, [IntPtr]1); Start-Sleep -Milliseconds ([int](40 * $Pace)); [void][Os]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$vk, [IntPtr]0xC0000001); Start-Sleep -Milliseconds ([int](60 * $Pace)) }
    function SendType($text) { foreach ($ch in $text.ToCharArray()) { [void][Os]::PostMessage($hwnd, $WM_CHAR, [IntPtr][int]$ch, [IntPtr]1); Start-Sleep -Milliseconds ([int](15 * $Pace)) }; Start-Sleep -Milliseconds ([int](150 * $Pace)) }
    function SendDrag($fromY, $toY, $shot) {
        SendMove 120 $fromY $false; SendDown 120 $fromY
        $steps = 6
        for ($i = 1; $i -le $steps; $i++) { SendMove 120 ($fromY + ($toY - $fromY) * $i / $steps) $true }
        Start-Sleep -Milliseconds ([int](120 * $Pace))
        if ($shot -and $Shots) { [void][Os]::Shot($hwnd, (Join-Path $Shots $shot)) }
        SendUp 120 $toY
        SendMove 900 600 $false
    }
    # Tree rows: 30px tall; the first (the collection) is centred at y=138.
    function Row($i) { 138 + 30 * $i }
    if ($Shots) { New-Item -ItemType Directory -Force $Shots | Out-Null; [void][Os]::Shot($hwnd, (Join-Path $Shots 'os-start.png')) }

    # Screen readers: a UI Automation client attaches first, so the provider
    # runs during all of the input below (the first request turns it on).
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [Windows.Automation.AutomationElement]
    $el = $A::FromHandle($hwnd)
    Start-Sleep -Milliseconds ([int](800 * $Pace))
    function UiaFocus {
        $f = $el.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($A::HasKeyboardFocusProperty, $true)))
        if ($f) { [pscustomobject]@{ Name = $f.Current.Name; Type = $f.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '' } } else { $null }
    }

    # Rows: 0 OS input, 1 Folder A, 2 Alpha, 3 Beta, 4 Gamma.
    # A click that wobbles 2px is a click: nothing moves.
    SendMove 120 (Row 3) $false; SendDown 120 (Row 3); SendMove 122 ((Row 3) - 2) $true; SendUp 122 ((Row 3) - 2)
    # Gamma onto the top quarter of Alpha: before Alpha.
    SendDrag (Row 4) ((Row 2) - 10) 'os-drag-reorder.png'
    # Rows: 0, 1 Folder A, 2 Gamma, 3 Alpha, 4 Beta. Beta onto the middle of Folder A.
    SendDrag (Row 4) (Row 1) 'os-drag-into.png'
    # Rows: 0, 1 Folder A (opened), 2 Beta, 3 Gamma, 4 Alpha. Escape cancels a drag.
    SendMove 120 (Row 3) $false; SendDown 120 (Row 3)
    foreach ($y in @(((Row 3) - 15), (Row 2), (Row 1))) { SendMove 120 $y $true }
    SendKey $VK_ESCAPE
    SendUp 120 (Row 1)
    SendMove 900 600 $false

    # Open Alpha with a click, then type at the end of its URL: ASCII, an
    # accented letter, CJK (as an IME commits it) and an emoji (a UTF-16
    # surrogate pair, two WM_CHAR messages).
    SendMove 120 (Row 4) $false; SendDown 120 (Row 4); SendUp 120 (Row 4)
    Start-Sleep -Milliseconds ([int](300 * $Pace))
    $treeFocus = UiaFocus
    "uia focus in the tree: {0}" -f $(if ($treeFocus) { "$($treeFocus.Type) '$($treeFocus.Name)'" } else { 'none' })
    SendMove 800 132 $false; SendDown 800 132; SendUp 800 132
    SendKey $VK_END
    # The IME composition window follows the caret (read back from the
    # window's own input context, client pixels).
    function ImePoint { $r = [Os]::SendMessage($hwnd, 0x8000 + 74, [IntPtr]0, [IntPtr]0).ToInt64(); if ($r -lt 0) { $null } else { @{ x = $r -band 0xFFFF; y = ($r -shr 16) -band 0xFFFF } } }
    $imeBefore = ImePoint
    $typed = "/typed-$([char]0xE9)$([char]0x65E5)$([char]0x672C)$([char]0xD83D)$([char]0xDE00)"
    SendType $typed
    Start-Sleep -Milliseconds ([int](400 * $Pace))
    $imeAfter = ImePoint
    "ime composition point: before typing {0}, after typing {1}" -f $(if ($imeBefore) { "$($imeBefore.x),$($imeBefore.y)" } else { 'none' }), $(if ($imeAfter) { "$($imeAfter.x),$($imeAfter.y)" } else { 'none' })
    if ($Shots) { [void][Os]::Shot($hwnd, (Join-Path $Shots 'os-typed.png')) }

    # The UI Automation tree the window publishes now.
    $all = @($el.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
    $script:uia = @($all | ForEach-Object { $c = $_.Current; [pscustomobject]@{ Name = $c.Name; Type = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''; Focus = $c.HasKeyboardFocus; Rect = $c.BoundingRectangle; El = $_ } })
    "uia: window '{0}' exposes {1} element(s)" -f $el.Current.Name, $uia.Count
    $win = $el.Current.BoundingRectangle
    $focused = $uia | Where-Object { $_.Focus } | Select-Object -First 1
    $script:uiaFocus = if ($focused) { $v = $null; $vp = $null; if ($focused.El.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $v = $vp.Current.Value }; [pscustomobject]@{ Name = $focused.Name; Type = $focused.Type; Value = $v } } else { $null }
    "uia focus: {0}" -f $(if ($uiaFocus) { "$($uiaFocus.Type) '$($uiaFocus.Name)' value '$($uiaFocus.Value)'" } else { 'none' })
    $script:uiaInside = @($uia | Where-Object { $_.Rect.Width -gt 0 -and ($_.Rect.Left -lt $win.Left - 1 -or $_.Rect.Top -lt $win.Top - 1 -or $_.Rect.Right -gt $win.Right + 1 -or $_.Rect.Bottom -gt $win.Bottom + 1) }).Count -eq 0
    $script:uiaUnnamed = @($uia | Where-Object { -not $_.Name -and $_.Type -ne 'Edit' } | ForEach-Object { $_.Type })
    "uia unnamed (not fields): {0}" -f $uiaUnnamed.Count
    if ($env:KEST_UIA_LIST) { $uia | ForEach-Object { "  uia {0,-14} {1} {2}" -f $_.Type, $_.Name, $_.Rect } }

    # The real clipboard: Ctrl A, Ctrl C in the URL field, then End and
    # Ctrl V. Whatever the clipboard held (every format) is saved first and
    # put back afterwards; if any format can't be read, this is skipped.
    # Ctrl travels as its own key messages; the app (under the harness flag)
    # turns them into thread key state, which is what GetKeyState reads.
    function SendCtrl($vk) {
        [void][Os]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$VK_CONTROL, [IntPtr]1); Start-Sleep -Milliseconds ([int](30 * $Pace))
        SendKey $vk
        [void][Os]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$VK_CONTROL, [IntPtr]0xC0000001); Start-Sleep -Milliseconds ([int](60 * $Pace))
    }
    Add-Type -AssemblyName System.Windows.Forms
    $CB = [Windows.Forms.Clipboard]
    $script:clipboard = 'skipped'
    $before = $CB::GetDataObject()
    $keep = New-Object Windows.Forms.DataObject
    $readable = $true
    foreach ($f in @($before.GetFormats($false))) {
        try { $d = $before.GetData($f, $false); if ($null -eq $d) { $readable = $false } else { $keep.SetData($f, $false, $d) } } catch { $readable = $false }
    }
    $beforeText = if ($CB::ContainsText()) { $CB::GetText() } else { $null }
    if ($readable) {
        try {
            $CB::Clear()
            SendCtrl 0x41; SendCtrl 0x43
            Start-Sleep -Milliseconds ([int](300 * $Pace))
            $script:copied = if ($CB::ContainsText()) { $CB::GetText() } else { '' }
            $CB::SetText('/pasted')
            SendKey $VK_END
            SendCtrl 0x56
            Start-Sleep -Milliseconds ([int](300 * $Pace))
            $script:clipboard = 'ran'
        } finally {
            if (@($before.GetFormats($false)).Count) { $CB::SetDataObject($keep, $true) } else { $CB::Clear() }
        }
        $afterText = if ($CB::ContainsText()) { $CB::GetText() } else { $null }
        $script:clipboardRestored = $afterText -eq $beforeText
        "clipboard: copied '{0}'; previous contents restored: {1}" -f $copied, $clipboardRestored
    } else { "clipboard: skipped (a format could not be saved)" }

    [void][Os]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]0, [IntPtr]0)
    if (-not $p.WaitForExit(15000)) { $p.Kill(); throw 'Still running 15 s after WM_CLOSE' }
    "exit code: $($p.ExitCode)"
} finally {
    if ($p -and -not $p.HasExited) { $p.Kill() }
    [Os]::Close($desk)
}

# Following Windows' app theme live: a workspace with no appearance chosen,
# then the switch Windows makes (simulated light, then dark, followed by the
# real WM_SETTINGCHANGE path). The title bar colour the app gives DWM shows
# which theme it is drawing.
$themeData = Join-Path $Data 'theme'
New-Item -ItemType Directory -Force $themeData | Out-Null
[IO.File]::WriteAllText((Join-Path $themeData 'workspace.json'), '{ "format": "kest.workspace/1", "windowWidth": 1280, "windowHeight": 800, "openTabs": [] }', $utf8)
$env:KEST_DATA = $themeData
$desk2 = [Os]::NewDesktop("$name-theme")
try {
    $id2 = [Os]::Start($Exe, "$name-theme", (Split-Path $Exe))
    $p2 = [Diagnostics.Process]::GetProcessById($id2)
    [void]$p2.Handle
    if (-not $p2.WaitForInputIdle(30000)) { throw 'Not idle after 30 s' }
    Start-Sleep -Milliseconds ([int](700 * $Pace))
    $h2 = [Os]::MainWindow($desk2, $id2)
    function Luma($v) { if ($v -lt 0) { -1 } else { 0.2126 * ($v -band 0xFF) + 0.7152 * (($v -shr 8) -band 0xFF) + 0.0722 * (($v -shr 16) -band 0xFF) } }
    # The title bar colour the app last gave DWM (DWM does not report it back).
    function Caption { [Os]::SendMessage($h2, 0x8000 + 78, [IntPtr]0, [IntPtr]0).ToInt64() }
    $themeStart = Luma (Caption)
    [void][Os]::SendMessage($h2, 0x8000 + 77, [IntPtr]0, [IntPtr]0)
    Start-Sleep -Milliseconds ([int](900 * $Pace))
    $themeLight = Luma (Caption)
    [void][Os]::SendMessage($h2, 0x8000 + 77, [IntPtr]1, [IntPtr]0)
    Start-Sleep -Milliseconds ([int](900 * $Pace))
    $themeDark = Luma (Caption)
    "title bar luminance: start {0:N0}, Windows light {1:N0}, Windows dark {2:N0}" -f $themeStart, $themeLight, $themeDark
    [void][Os]::PostMessage($h2, $WM_CLOSE, [IntPtr]0, [IntPtr]0)
    if (-not $p2.WaitForExit(15000)) { $p2.Kill(); throw 'Theme run still running 15 s after WM_CLOSE' }
} finally {
    if ($p2 -and -not $p2.HasExited) { $p2.Kill() }
    [Os]::Close($desk2)
}
$themeSaved = Get-Content -Raw (Join-Path $themeData 'workspace.json')

# Read back what the app saved.
$tree = Get-Content -Raw -Encoding UTF8 (Join-Path $Data "collections\$cid\collection.json") | ConvertFrom-Json
$top = @($tree.items | ForEach-Object { $_.name })
$folder = $tree.items | Where-Object { $_.name -eq 'Folder A' }
$inside = @($folder.items | ForEach-Object { $_.name })
"saved order: [{0}]; Folder A: [{1}]" -f ($top -join ', '), ($inside -join ', ')
Check (($top -join ',') -eq 'Folder A,Gamma,Alpha') 'click stayed a click; Gamma dropped before Alpha; Escape left Gamma in place'
Check (($inside -join ',') -eq 'Beta') 'Beta dropped into Folder A'
$alpha = Get-Content -Raw -Encoding UTF8 (Join-Path $dir "$($ids.Alpha).json") | ConvertFrom-Json
"saved Alpha url: $($alpha.url)"
$pasted = if ($clipboard -eq 'ran') { '/pasted' } else { '' }
Check ($alpha.url -eq "https://example.invalid/alpha$typed$pasted") 'typed ASCII, accented, CJK and emoji text saved in the URL'
if ($clipboard -eq 'ran') {
    Check ($copied -eq "https://example.invalid/alpha$typed") 'Ctrl C puts the URL (with CJK and emoji) on the Windows clipboard'
    Check ($alpha.url.EndsWith('/pasted')) 'Ctrl V pastes clipboard text at the caret'
    Check $clipboardRestored 'the clipboard is restored afterwards'
}
Check ($themeLight -ge 0 -and $themeDark -ge 0 -and $themeLight -gt $themeDark + 60) 'with no appearance chosen, the window follows Windows switching to light and back to dark, live'
Check ($themeSaved -notmatch '"dark"') 'following Windows is kept: no appearance is written'
function Has($name, $type) { @($uia | Where-Object { $_.Name -eq $name -and $_.Type -eq $type }).Count -gt 0 }
Check ($uia.Count -ge 20) 'UI Automation publishes the window''s controls'
Check ($rc.Right -eq [int][Math]::Round(1280 * $scale) -and $rc.Bottom -eq [int][Math]::Round(800 * $scale)) 'client area is 1280x800 (logical)'
Check ((Has 'Send' 'Button') -and ((Has 'Save' 'Button') -or (Has 'Saved' 'Button'))) 'buttons are named by their text (Send, Save)'
Check ((Has 'Create' 'SplitButton') -and (Has 'Collection actions' 'SplitButton') -and (Has 'Request actions' 'SplitButton')) 'icon-only menu buttons are named (Create, Collection actions, Request actions)'
Check ((Has 'Search requests' 'Edit') -and (Has 'Params' 'TabItem') -and (Has 'Settings' 'TabItem')) 'search field and request section tabs have names and roles'
Check ((Has 'GET Alpha' 'TreeItem') -and (Has 'Folder Folder A' 'TreeItem') -and (Has 'GET Beta' 'TreeItem')) 'collection rows are tree items with method and name'
Check ($uiaFocus -and $uiaFocus.Type -eq 'Edit' -and $uiaFocus.Value -eq "https://example.invalid/alpha$typed") 'the focused URL field reports keyboard focus and its current text'
Check $uiaInside 'every published rectangle lies inside the window'
Check ($uiaUnnamed.Count -eq 0) 'no unnamed controls apart from fields'
Check ($treeFocus -and $treeFocus.Type -eq 'TreeItem' -and $treeFocus.Name -eq 'GET Alpha') 'with the tree focused, its selected row reports keyboard focus'
Check ((Has 'GET Alpha' 'TabItem') -and (Has 'Close Alpha' 'Button') -and (Has 'Collections' 'Tree')) 'open requests are tabs with close buttons; the collection tree is a tree'
$glyphs = '[{0}-{1}]' -f [char]0xE000, [char]0xF8FF
Check (@($uia | Where-Object { $_.Name -match $glyphs }).Count -eq 0) 'no icon glyphs in names'
# The URL field spans about x 427..1060, y 113..151 (logical) at this size.
Check ($imeBefore -and $imeAfter -and $imeAfter.x -gt $imeBefore.x -and $imeAfter.x -ge (Px 427) -and $imeAfter.x -le (Px 1060) -and $imeAfter.y -ge (Px 105) -and $imeAfter.y -le (Px 155)) 'IME composition window sits at the URL caret and follows typing'
if ($failures.Count) { "FAILED: $($failures.Count)"; exit 1 }
'all OS input checks passed'
