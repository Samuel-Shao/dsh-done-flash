<#
  dsh-done-flash - Windows tray flasher helper.

  Runs as a short-lived child of the DeepSeek Harness host process. It
  locates the Electron tray icon (the little whale), grabs the icon frames
  that ship with the desktop app, builds a highlighted twin, and blinks the
  live tray icon between the two.

  Everything here is ASCII on purpose: Windows PowerShell 5.1 reads -File
  scripts with the OEM/ANSI code page unless a BOM says otherwise.
#>
param(
  [int]$MainPid = 0,
  [string]$IconPath = '',
  [int]$DurationMs = 4000,
  [int]$IntervalMs = 260,
  [string]$Style = 'blink',
  [string]$Accent = 'FF4D4F',
  [switch]$RequireBackground,
  [int]$Uid = -1,
  [switch]$RestoreOnly,
  [switch]$UntilForeground,
  [string]$AppTitle = 'DeepSeek Harness',
  [int]$MaxDurationMs = 0
)

$ErrorActionPreference = 'Stop'

function Write-Result($obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 4
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}

try {
  Add-Type -AssemblyName System.Drawing
  Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DoneFlashTray {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct NID {
    public uint cbSize;
    public IntPtr hWnd;
    public uint uID;
    public uint uFlags;
    public uint uCallbackMessage;
    public IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string szTip;
    public uint dwState;
    public uint dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szInfo;
    public uint uTimeoutOrVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string szInfoTitle;
    public uint dwInfoFlags;
    public Guid guidItem;
    public IntPtr hBalloonIcon;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct NII {
    public uint cbSize;
    public IntPtr hWnd;
    public uint uID;
    public Guid guidItem;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool Shell_NotifyIcon(uint msg, ref NID data);

  [DllImport("shell32.dll", SetLastError=true)]
  public static extern int Shell_NotifyIconGetRect(ref NII identifier, out RECT iconLocation);

  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr LoadImage(IntPtr hinst, string name, uint type, int cx, int cy, uint flags);

  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr FindWindow(string cls, string title);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool DestroyIcon(IntPtr h);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll", SetLastError=true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern uint GetDpiForWindow(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr CreateMutex(IntPtr attributes, bool initialOwner, string name);

  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool ReleaseMutex(IntPtr handle);

  private static IntPtr flashMutex = IntPtr.Zero;

  // Only one helper may drive the tray icon at a time: two blinks running with
  // opposite phases would look like a solid icon (or fight over the icon).
  public static bool AcquireFlashSlot() {
    flashMutex = CreateMutex(IntPtr.Zero, true, "Global\\dsh-done-flash-tray");
    if (flashMutex == IntPtr.Zero) return false;
    return Marshal.GetLastWin32Error() != 183; // ERROR_ALREADY_EXISTS
  }

  public static void ReleaseFlashSlot() {
    if (flashMutex == IntPtr.Zero) return;
    try { ReleaseMutex(flashMutex); } catch { }
    flashMutex = IntPtr.Zero;
  }

  private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

  public static IntPtr FindTrayHostByPid(int pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      uint owner;
      GetWindowThreadProcessId(hWnd, out owner);
      if (owner != (uint)pid) return true;
      StringBuilder sb = new StringBuilder(256);
      GetClassName(hWnd, sb, sb.Capacity);
      if (sb.ToString() == "Electron_NotifyIconHostWindow") { found = hWnd; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr FindTrayHostAny() {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      StringBuilder sb = new StringBuilder(256);
      GetClassName(hWnd, sb, sb.Capacity);
      if (sb.ToString() == "Electron_NotifyIconHostWindow") { found = hWnd; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static int[] ProbeUids(IntPtr hwnd, int max) {
    List<int> hits = new List<int>();
    for (int uid = 0; uid <= max; uid++) {
      NII id = new NII();
      id.cbSize = (uint)Marshal.SizeOf(typeof(NII));
      id.hWnd = hwnd;
      id.uID = (uint)uid;
      RECT r;
      if (Shell_NotifyIconGetRect(ref id, out r) == 0) hits.Add(uid);
    }
    return hits.ToArray();
  }

  public static bool SetIcon(IntPtr hwnd, uint uid, IntPtr hicon) {
    NID n = new NID();
    n.cbSize = (uint)Marshal.SizeOf(typeof(NID));
    n.hWnd = hwnd;
    n.uID = uid;
    n.uFlags = 0x2; // NIF_ICON
    n.hIcon = hicon;
    return Shell_NotifyIcon(1, ref n); // NIM_MODIFY
  }

  // The tray slot grows with the display scale factor (48 px tall at 100 %,
  // 96 px at 200 %). Measuring it tells us the bitmap size Explorer will
  // actually draw, which a message-only tray window cannot report itself.
  public static int IconSlot(IntPtr hwnd, uint uid, out int width, out int height) {
    NII nii = new NII();
    nii.cbSize = (uint)Marshal.SizeOf(typeof(NII));
    nii.hWnd = hwnd;
    nii.uID = uid;
    RECT r;
    int hr = Shell_NotifyIconGetRect(ref nii, out r);
    width = r.Right - r.Left;
    height = r.Bottom - r.Top;
    return hr;
  }

  public static uint ForegroundPid() {
    IntPtr fg = GetForegroundWindow();
    if (fg == IntPtr.Zero) return 0;
    uint pid;
    GetWindowThreadProcessId(fg, out pid);
    return pid;
  }

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  private static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);

  // True when the window in front belongs to the app's process, or (for the
  // browser-hosted Web UI) shows a title that carries the product name.
  public static bool IsAppForeground(uint ownerPid, string titleNeedle) {
    IntPtr fg = GetForegroundWindow();
    if (fg == IntPtr.Zero) return false;
    uint pid;
    GetWindowThreadProcessId(fg, out pid);
    if (ownerPid != 0 && pid == ownerPid) return true;
    if (String.IsNullOrEmpty(titleNeedle)) return false;
    int len = GetWindowTextLength(fg);
    if (len <= 0) return false;
    StringBuilder sb = new StringBuilder(len + 2);
    GetWindowText(fg, sb, sb.Capacity);
    return sb.ToString().IndexOf(titleNeedle, StringComparison.OrdinalIgnoreCase) >= 0;
  }
}
"@

  # ---- 1. tray host window -------------------------------------------------
  $hwnd = [DoneFlashTray]::FindTrayHostAny()
  if ($hwnd -eq [IntPtr]::Zero) {
    Write-Result @{ ok = $false; error = 'tray-host-not-found' }
    exit 3
  }

  # The pid that owns the tray window is the Electron main process, which is
  # exactly the process whose windows count as "the app is in front".
  $ownerPid = [uint32]0
  [void][DoneFlashTray]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid)

  if ($RequireBackground) {
    $fgPid = [DoneFlashTray]::ForegroundPid()
    $sameApp = [DoneFlashTray]::IsAppForeground($ownerPid, $AppTitle) -or ($MainPid -gt 0 -and $fgPid -eq [uint32]$MainPid)
    if ($sameApp) {
      Write-Result @{ ok = $false; skipped = 'foreground'; foregroundPid = $fgPid; ownerPid = $ownerPid }
      exit 2
    }
  }

  # ---- 2. locate the icon id inside the host window ------------------------
  $uids = [DoneFlashTray]::ProbeUids($hwnd, 64)
  if ($uids.Count -eq 0) {
    Write-Result @{ ok = $false; error = 'tray-icon-not-found'; ownerPid = $ownerPid }
    exit 3
  }
  $target = $uids[0]
  if ($Uid -ge 0) { $target = $Uid }

  # The untouched frame, loaded straight out of the app's own .ico so that
  # restoring is pixel-identical to what the app itself set.
  $hBase = [DoneFlashTray]::LoadImage([IntPtr]::Zero, $IconPath, 1, 0, 0, 0x10)
  if ($hBase -eq [IntPtr]::Zero) {
    Write-Result @{ ok = $false; error = 'icon-load-failed' }
    exit 4
  }

  if ($RestoreOnly) {
    $okr = [DoneFlashTray]::SetIcon($hwnd, [uint32]$target, $hBase)
    [void][DoneFlashTray]::DestroyIcon($hBase)
    Write-Result @{ ok = $okr; restored = $true; uid = $target; ownerPid = $ownerPid }
    exit 0
  }

  # ---- 2b. one blinker at a time -------------------------------------------
  if (-not [DoneFlashTray]::AcquireFlashSlot()) {
    [void][DoneFlashTray]::DestroyIcon($hBase)
    Write-Result @{ ok = $false; skipped = 'already-running'; ownerPid = $ownerPid }
    exit 5
  }

  # ---- 3. pick the icon frame that matches the current DPI ----------------
  # Scale from the measured tray slot: 48 px tall at 100 %, 96 px at 200 %.
  $slotW = 0; $slotH = 0
  $rectHr = [DoneFlashTray]::IconSlot($hwnd, [uint32]$target, [ref]$slotW, [ref]$slotH)
  $dpi = 0
  if ($rectHr -eq 0 -and $slotH -gt 0) { $dpi = [int][math]::Round(96 * $slotH / 48) }
  if ($dpi -le 0) { $dpi = [DoneFlashTray]::GetDpiForWindow($hwnd) }
  if ($dpi -lt 96) { $dpi = 96 }
  $size = [int][math]::Round(16 * $dpi / 96)
  if ($size -lt 16) { $size = 16 }

  $bytes = [System.IO.File]::ReadAllBytes($IconPath)
  $count = [BitConverter]::ToUInt16($bytes, 4)
  $bestOff = -1; $bestLen = 0; $bestW = 0; $bestDelta = [int]::MaxValue
  for ($i = 0; $i -lt $count; $i++) {
    $o = 6 + $i * 16
    $w = [int]$bytes[$o]
    if ($w -eq 0) { $w = 256 }
    $len = [BitConverter]::ToUInt32($bytes, $o + 8)
    $off = [BitConverter]::ToUInt32($bytes, $o + 12)
    $delta = [math]::Abs($w - $size)
    if ($delta -lt $bestDelta) { $bestDelta = $delta; $bestOff = $off; $bestLen = $len; $bestW = $w }
  }
  if ($bestOff -lt 0) {
    Write-Result @{ ok = $false; error = 'icon-frames-unreadable' }
    exit 4
  }

  $stream = New-Object System.IO.MemoryStream(, $bytes[$bestOff..($bestOff + $bestLen - 1)])
  $src = [System.Drawing.Image]::FromStream($stream)

  $work = $size
  $base = New-Object System.Drawing.Bitmap($work, $work, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($base)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, $work, $work)
  $g.Dispose(); $src.Dispose(); $stream.Dispose()

  # ---- 4. build the highlighted twin --------------------------------------
  $badge = New-Object System.Drawing.Bitmap($work, $work, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $gb = [System.Drawing.Graphics]::FromImage($badge)
  $gb.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $gb.DrawImage($base, 0, 0, $work, $work)
  $accentColor = [System.Drawing.ColorTranslator]::FromHtml("#$Accent")

  if ($Style -eq 'blink') {
    $gb.Clear([System.Drawing.Color]::Transparent)
  } elseif ($Style -eq 'ring') {
    $inset = [int][math]::Round($work * 0.14)
    if ($inset -lt 1) { $inset = 1 }
    $gb.Clear($accentColor)
    $gb.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gb.DrawImage($base, $inset, $inset, ($work - 2 * $inset), ($work - 2 * $inset))
  } elseif ($Style -eq 'invert') {
    for ($y = 0; $y -lt $work; $y++) {
      for ($x = 0; $x -lt $work; $x++) {
        $p = $base.GetPixel($x, $y)
        if ($p.A -lt 16) { continue }
        $lum = (0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B)
        if ($lum -lt 140) { $badge.SetPixel($x, $y, $accentColor) } else { $badge.SetPixel($x, $y, [System.Drawing.Color]::White) }
      }
    }
  } else {
    $d = [int][math]::Round($work * 0.56)
    if ($d -lt 8) { $d = 8 }
    $pad = [int][math]::Round($work * 0.02)
    $x0 = $work - $d - $pad
    $y0 = $work - $d - $pad
    $rim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $fill = New-Object System.Drawing.SolidBrush($accentColor)
    $gb.FillEllipse($rim, ($x0 - 1), ($y0 - 1), ($d + 2), ($d + 2))
    $gb.FillEllipse($fill, $x0, $y0, $d, $d)
    $rim.Dispose(); $fill.Dispose()
  }
  $gb.Dispose()

  $hBadge = $badge.GetHicon()

  # ---- 5. blink ------------------------------------------------------------
  # Timed mode stops after DurationMs. UntilForeground mode keeps blinking
  # until the app itself comes to the front (its own window, or a browser
  # tab whose title carries the product name), optionally capped by
  # MaxDurationMs as a safety net.
  $started = Get-Date
  $softDeadline = $started.AddMilliseconds($DurationMs)
  $mode = if ($UntilForeground) { 'until-foreground' } else { 'timed' }
  $reason = 'duration'
  $toggles = 0
  $failed = 0
  $consecutiveFailures = 0
  $on = $true
  while ($true) {
    if ($UntilForeground -and [DoneFlashTray]::IsAppForeground($ownerPid, $AppTitle)) { $reason = 'foreground'; break }
    if (-not $UntilForeground -and (Get-Date) -ge $softDeadline) { $reason = 'duration'; break }
    if ($MaxDurationMs -gt 0 -and ((Get-Date) - $started).TotalMilliseconds -ge $MaxDurationMs) { $reason = 'cap'; break }
    $ok = [DoneFlashTray]::SetIcon($hwnd, [uint32]$target, $(if ($on) { $hBadge } else { $hBase }))
    if ($ok) { $consecutiveFailures = 0 } else { $failed++; $consecutiveFailures++ }
    if ($consecutiveFailures -ge 5) { $reason = 'host-gone'; break }
    $toggles++
    $on = -not $on
    Start-Sleep -Milliseconds $IntervalMs
  }
  [void][DoneFlashTray]::SetIcon($hwnd, [uint32]$target, $hBase)

  [void][DoneFlashTray]::DestroyIcon($hBadge)
  [void][DoneFlashTray]::DestroyIcon($hBase)
  $base.Dispose(); $badge.Dispose()

  Write-Result @{
    ok = ($failed -eq 0)
    uid = $target
    size = $work
    dpi = $dpi
    style = $Style
    mode = $mode
    reason = $reason
    elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    toggles = $toggles
    failed = $failed
    uids = $uids
    ownerPid = $ownerPid
    foregroundPid = [DoneFlashTray]::ForegroundPid()
  }
  exit 0
} catch {
  try { Write-Result @{ ok = $false; error = "$($_.Exception.Message)" } } catch { }
  exit 1
}
