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
# CJK and a surrogate-pair emoji reach the URL and are saved; the UI
# Automation tree the window exposes is reported.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Data,
    [string]$Shots = '',
    [double]$Pace = 1
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
    [DllImport("user32")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
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
$VK_ESCAPE = 0x1B; $VK_END = 0x23

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
    $rc = New-Object Os+RECT; [void][Os]::GetClientRect($hwnd, [ref]$rc)
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
    SendMove 800 132 $false; SendDown 800 132; SendUp 800 132
    SendKey $VK_END
    $typed = "/typed-$([char]0xE9)$([char]0x65E5)$([char]0x672C)$([char]0xD83D)$([char]0xDE00)"
    SendType $typed
    Start-Sleep -Milliseconds ([int](400 * $Pace))
    if ($Shots) { [void][Os]::Shot($hwnd, (Join-Path $Shots 'os-typed.png')) }

    # Screen readers: what UI Automation can see of the window.
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $el = [Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $kids = $el.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        "uia: window '{0}' exposes {1} descendant element(s)" -f $el.Current.Name, $kids.Count
    } catch { "uia: not reachable from this desktop ($($_.Exception.Message))" }

    [void][Os]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]0, [IntPtr]0)
    if (-not $p.WaitForExit(15000)) { $p.Kill(); throw 'Still running 15 s after WM_CLOSE' }
    "exit code: $($p.ExitCode)"
} finally {
    if ($p -and -not $p.HasExited) { $p.Kill() }
    [Os]::Close($desk)
}

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
Check ($alpha.url -eq "https://example.invalid/alpha$typed") 'typed ASCII, accented, CJK and emoji text saved in the URL'
if ($failures.Count) { "FAILED: $($failures.Count)"; exit 1 }
'all OS input checks passed'
