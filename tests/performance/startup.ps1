# Starts the real app, with its real window and GPU surface, on a private
# Windows desktop nobody is looking at: nothing appears on screen and focus
# stays where it is. Measures time to first idle, memory and idle CPU, then
# asks the window to close and checks that the app left cleanly.
#
#   zig build -Doptimize=ReleaseFast
#   powershell -File tests/performance/startup.ps1 -Exe zig-out/bin/kest.exe -Data <folder> [-Runs 5] [-IdleSeconds 10]
#
# -Data becomes KEST_DATA: the app reads and writes only there.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Data,
    [int]$Runs = 5,
    [int]$IdleSeconds = 10
)
$ErrorActionPreference = 'Stop'

Add-Type -Language CSharp @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Hidden {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr attrs);
    [DllImport("user32")] static extern bool CloseDesktop(IntPtr desk);
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32")] static extern bool EnumDesktopWindows(IntPtr desk, EnumProc cb, IntPtr param);
    [DllImport("user32")] static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32")] static extern uint WaitForInputIdle(IntPtr process, uint ms);

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
    /// Asks each top-level window of the process to close. How many were asked.
    public static int CloseWindows(IntPtr desk, int pid) {
        List<IntPtr> found = new List<IntPtr>();
        EnumDesktopWindows(desk, delegate(IntPtr h, IntPtr p) {
            int owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid) found.Add(h);
            return true;
        }, IntPtr.Zero);
        foreach (IntPtr h in found) PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
        return found.Count;
    }
}
"@

$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Data | Out-Null
$Data = (Resolve-Path $Data).Path
$env:KEST_DATA = $Data
$name = "kest-measure-$PID"
$desk = [Hidden]::NewDesktop($name)
$cwd = Split-Path $Exe
$startup = @(); $working = @(); $private = @(); $cpu = @(); $handles = @()
try {
    for ($i = 1; $i -le $Runs; $i++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $id = [Hidden]::Start($Exe, $name, $cwd)
        $p = [Diagnostics.Process]::GetProcessById($id)
        [void]$p.Handle   # Keeps the process object valid past the exit, for its code.
        if (-not $p.WaitForInputIdle(30000)) { throw "Not idle after 30 s" }
        $ms = $clock.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 500   # Fonts and first frames settle.
        $p.Refresh()
        $cpu0 = $p.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Seconds $IdleSeconds
        $p.Refresh()
        $idle = ($p.TotalProcessorTime.TotalMilliseconds - $cpu0) / ($IdleSeconds * 1000 * [Environment]::ProcessorCount) * 100
        $startup += $ms; $working += $p.WorkingSet64 / 1MB; $private += $p.PrivateMemorySize64 / 1MB; $cpu += $idle; $handles += $p.HandleCount
        $asked = [Hidden]::CloseWindows($desk, $id)
        if (-not $p.WaitForExit(10000)) { $p.Kill(); throw "Run ${i}: still running 10 s after the window was asked to close" }
        "run {0}: first idle {1,7:N1} ms   working set {2,6:N1} MiB   private {3,6:N1} MiB   idle CPU {4:N3} %   windows closed {5}   exit {6}" -f $i, $ms, ($p.WorkingSet64 / 1MB * 0 + $working[-1]), $private[-1], $idle, $asked, $p.ExitCode
    }
} finally {
    [Hidden]::Close($desk)
}
$sorted = $startup | Sort-Object
"median first idle: {0:N1} ms   median working set: {1:N1} MiB   median idle CPU: {2:N3} %" -f $sorted[[int][Math]::Floor($sorted.Count / 2)], (($working | Sort-Object)[[int][Math]::Floor($working.Count / 2)]), (($cpu | Sort-Object)[[int][Math]::Floor($cpu.Count / 2)])
