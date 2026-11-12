<#
.SYNOPSIS
    Gemini Hakimi Widget (反重力哈基米记账桌宠 v2.1)
    - Fixed 100% of DPI / WPF-vs-Win32 coordinate jumping ("点一下乱飞" 彻底根除: 全程纯物理像素 GetWindowRect + SetWindowPos + Opacity 无重排)
    - Beautified soft-glass comic bubble (珍珠粉紫渐变 + 胶囊模型徽标 + 柔光阴影)
    - Distinct click gestures:
      * 单击桌宠: 摸摸头 (大肥鱼原版 press.wav + release.wav + 脸红Q弹)
      * 单击两次桌宠 (270ms~950ms) 或点气泡 × / 💬: 开关基础气泡
      * 快速双击桌宠 (<=270ms) 或点 📊 / 气泡底部详情条: 展开/收起自适应位置详细信息窗口
    - Added Claude (克劳德: Opus 4.6 / Sonnet 4.6 / Sonnet 4.5 / Haiku 4.5) & Gemini 5h/weekly quotas, removed non-existent gemini-3.8-pro
#>
param(
    [switch]$CheckOnly,
    [switch]$OpenDetails
)

$ErrorActionPreference = "Stop"

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA -and !$CheckOnly) {
    $psArgs = @("-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$PSCommandPath`"")
    if ($OpenDetails) { $psArgs += "-OpenDetails" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Native C# Win32 Host Follower (100% Physical Pixels, 0ms SetWinEventHook 0x800B) + Memory Audio Player
$nativeCSharp = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class HakimiWin32 {
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);

    public static void HideFromAltTab(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return;
        int style = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, style | WS_EX_TOOLWINDOW);
    }

    public static void SetClickThrough(IntPtr hwnd, bool enable) {
        if (hwnd == IntPtr.Zero) return;
        int style = GetWindowLong(hwnd, GWL_EXSTYLE);
        if (enable) {
            SetWindowLong(hwnd, GWL_EXSTYLE, style | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW);
        } else {
            SetWindowLong(hwnd, GWL_EXSTYLE, (style & ~WS_EX_TRANSPARENT) | WS_EX_TOOLWINDOW);
        }
    }
}

public static class HakimiAudioPlayer {
    private const uint SND_ASYNC = 0x0001;
    private const uint SND_NODEFAULT = 0x0002;
    private const uint SND_MEMORY = 0x0004;

    [DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool PlaySoundW(IntPtr pszSound, IntPtr hmod, uint fdwSound);

    private static byte[] _pressBytes;
    private static byte[] _releaseBytes;
    private static GCHandle _pressHandle;
    private static GCHandle _releaseHandle;
    public static bool SoundEnabled = true;

    public static void Initialize(byte[] pressWav, byte[] releaseWav) {
        try {
            if (_pressHandle.IsAllocated) _pressHandle.Free();
            if (_releaseHandle.IsAllocated) _releaseHandle.Free();
            if (pressWav != null && pressWav.Length > 0) {
                _pressBytes = pressWav;
                _pressHandle = GCHandle.Alloc(_pressBytes, GCHandleType.Pinned);
            }
            if (releaseWav != null && releaseWav.Length > 0) {
                _releaseBytes = releaseWav;
                _releaseHandle = GCHandle.Alloc(_releaseBytes, GCHandleType.Pinned);
            }
        } catch {}
    }

    public static void PlayPress() {
        if (!SoundEnabled || !_pressHandle.IsAllocated) return;
        try {
            PlaySoundW(_pressHandle.AddrOfPinnedObject(), IntPtr.Zero, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
        } catch {}
    }

    public static void PlayRelease() {
        if (!SoundEnabled || !_releaseHandle.IsAllocated) return;
        try {
            PlaySoundW(_releaseHandle.AddrOfPinnedObject(), IntPtr.Zero, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
        } catch {}
    }
}

public static class HakimiHostFollower {
    private delegate void WinEventDelegate(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    private static IntPtr _hook = IntPtr.Zero;
    private static WinEventDelegate _proc;
    private static IntPtr _targetHwnd = IntPtr.Zero;
    private static uint _targetPid = 0;
    private static IntPtr _widgetHwnd = IntPtr.Zero;
    private static IntPtr _detailHwnd = IntPtr.Zero;

    public static bool IsPaused = false;
    // AnchorCorner: 0 = BottomRight, 1 = BottomLeft, 2 = TopRight, 3 = TopLeft
    public static int AnchorCorner = 0;
    // Physical pixel offset from chosen host corner to widget top-left
    public static int CornerOffsetX = -350;
    public static int CornerOffsetY = -350;
    // Detail window physical pixel offset from widget top-left
    public static int DetailOffsetX = -220;
    public static int DetailOffsetY = -260;
    public static bool DetailVisible = false;

    public static int LastWidgetX = 0;
    public static int LastWidgetY = 0;
    public static bool HasValidPosition = false;
    public static bool MovedByHook = false;

    public static double GetDpiScale(IntPtr hwnd) {
        if (hwnd != IntPtr.Zero) {
            try {
                uint dpi = GetDpiForWindow(hwnd);
                if (dpi >= 72 && dpi <= 480) return dpi / 96.0;
            } catch {}
        }
        return 1.0;
    }

    public static bool TryGetBounds(IntPtr hwnd, out RECT rect) {
        rect = new RECT();
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd) || IsIconic(hwnd)) return false;
        try {
            int hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out rect, Marshal.SizeOf(typeof(RECT)));
            if (hr == 0 && (rect.Right > rect.Left) && (rect.Bottom > rect.Top) && rect.Left > -10000 && rect.Top > -10000) {
                return true;
            }
        } catch {}
        if (!GetWindowRect(hwnd, out rect)) return false;
        return (rect.Right > rect.Left) && (rect.Bottom > rect.Top) && rect.Left > -10000 && rect.Top > -10000;
    }

    public static bool GetWidgetPhysicalRect(out RECT rect) {
        rect = new RECT();
        if (_widgetHwnd == IntPtr.Zero || !IsWindow(_widgetHwnd)) return false;
        return GetWindowRect(_widgetHwnd, out rect);
    }

    public static bool GetDetailPhysicalRect(out RECT rect) {
        rect = new RECT();
        if (_detailHwnd == IntPtr.Zero || !IsWindow(_detailHwnd)) return false;
        return GetWindowRect(_detailHwnd, out rect);
    }

    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public static void RestoreTopmost() {
        if (_widgetHwnd != IntPtr.Zero && IsWindow(_widgetHwnd)) {
            SetWindowPos(_widgetHwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        if (DetailVisible && _detailHwnd != IntPtr.Zero && IsWindow(_detailHwnd)) {
            SetWindowPos(_detailHwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
    }

    public static void MoveWidgetPhysical(int physX, int physY) {
        if (_widgetHwnd == IntPtr.Zero) return;
        LastWidgetX = physX;
        LastWidgetY = physY;
        HasValidPosition = true;
        SetWindowPos(_widgetHwnd, HWND_TOPMOST, physX, physY, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        if (DetailVisible && _detailHwnd != IntPtr.Zero && IsWindow(_detailHwnd)) {
            SetWindowPos(_detailHwnd, HWND_TOPMOST, physX + DetailOffsetX, physY + DetailOffsetY, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    public static void MoveDetailPhysical(int physX, int physY) {
        if (_detailHwnd == IntPtr.Zero || !IsWindow(_detailHwnd)) return;
        SetWindowPos(_detailHwnd, IntPtr.Zero, physX, physY, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static IntPtr FindAntigravityWindow(uint selfPid) {
        IntPtr found = IntPtr.Zero;
        int bestArea = 0;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindow(hWnd)) return true;
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == selfPid || pid == 0) return true;

            // 1. Process Name Check: MUST be Antigravity process!
            string procName = "";
            try {
                Process p = Process.GetProcessById((int)pid);
                procName = p.ProcessName.ToLowerInvariant();
            } catch {
                return true;
            }
            if (procName.IndexOf("antigravity") < 0 || procName.IndexOf("powershell") >= 0) {
                return true;
            }

            // 2. Class Name Check: Electron top-level window MUST be Chrome_WidgetWin_1
            StringBuilder clsSb = new StringBuilder(128);
            GetClassName(hWnd, clsSb, 128);
            string cls = clsSb.ToString();
            if (cls != "Chrome_WidgetWin_1") {
                return true;
            }

            // 3. Title Check: exclude Hakimi itself and must not be empty
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            string title = sb.ToString();
            if (string.IsNullOrEmpty(title) || title.Contains("Gemini Hakimi")) return true;

            // 4. Bounds Check
            RECT r;
            if (GetWindowRect(hWnd, out r)) {
                int w = r.Right - r.Left;
                int h = r.Bottom - r.Top;
                if (w >= 400 && h >= 300 && (w * h) > bestArea) {
                    bestArea = w * h;
                    found = hWnd;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool EnsureHooked(IntPtr widgetHwnd, IntPtr detailHwnd, uint selfPid) {
        _widgetHwnd = widgetHwnd;
        _detailHwnd = detailHwnd;

        if (_targetHwnd != IntPtr.Zero && IsWindow(_targetHwnd)) {
            return true;
        }

        IntPtr candidate = FindAntigravityWindow(selfPid);
        if (candidate == IntPtr.Zero) return false;

        uint pid = 0;
        GetWindowThreadProcessId(candidate, out pid);
        if (pid == 0) return false;

        if (_hook != IntPtr.Zero && _targetPid != pid) {
            UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }

        _targetHwnd = candidate;
        _targetPid = pid;

        if (_hook == IntPtr.Zero) {
            _proc = new WinEventDelegate(OnWinEvent);
            _hook = SetWinEventHook(
                EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
                IntPtr.Zero, _proc, _targetPid, 0, WINEVENT_OUTOFCONTEXT);
        }

        return true;
    }

    public static void Stop() {
        if (_hook != IntPtr.Zero) {
            UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }
        _targetHwnd = IntPtr.Zero;
        _targetPid = 0;
    }

    public static IntPtr GetTargetHwnd() {
        return _targetHwnd;
    }

    public static uint GetTargetPid() {
        return _targetPid;
    }

    public static bool IsHostWindowAlive() {
        if (_targetHwnd == IntPtr.Zero || !IsWindow(_targetHwnd)) return false;
        if (!IsHostProcessAlive()) return false;
        if (IsHostMinimized()) return true;
        return IsWindowVisible(_targetHwnd);
    }

    public static bool IsHostMinimized() {
        if (_targetHwnd == IntPtr.Zero || !IsWindow(_targetHwnd)) return false;
        if (IsIconic(_targetHwnd)) return true;
        RECT r;
        if (GetWindowRect(_targetHwnd, out r)) {
            if (r.Left <= -10000 || r.Top <= -10000) return true;
        }
        return false;
    }

    public static bool IsHostProcessAlive() {
        if (_targetPid == 0) return false;
        try {
            Process p = Process.GetProcessById((int)_targetPid);
            return !p.HasExited;
        } catch {
            return false;
        }
    }

    public static void RecordAnchorFromCurrentPhysicalRect() {
        RECT r, wRect;
        if (!TryGetBounds(_targetHwnd, out r)) return;
        if (!GetWidgetPhysicalRect(out wRect)) return;

        int widgetW = Math.Max(100, wRect.Right - wRect.Left);
        int widgetH = Math.Max(100, wRect.Bottom - wRect.Top);
        int hostCenterX = (r.Left + r.Right) / 2;
        int hostCenterY = (r.Top + r.Bottom) / 2;
        int widgetCenterX = wRect.Left + (widgetW / 2);
        int widgetCenterY = wRect.Top + (widgetH / 2);

        bool isRight = widgetCenterX >= hostCenterX;
        bool isBottom = widgetCenterY >= hostCenterY;

        if (isBottom && isRight) {
            AnchorCorner = 0; // BottomRight
            CornerOffsetX = wRect.Left - r.Right;
            CornerOffsetY = wRect.Top - r.Bottom;
        } else if (isBottom && !isRight) {
            AnchorCorner = 1; // BottomLeft
            CornerOffsetX = wRect.Left - r.Left;
            CornerOffsetY = wRect.Top - r.Bottom;
        } else if (!isBottom && isRight) {
            AnchorCorner = 2; // TopRight
            CornerOffsetX = wRect.Left - r.Right;
            CornerOffsetY = wRect.Top - r.Top;
        } else {
            AnchorCorner = 3; // TopLeft
            CornerOffsetX = wRect.Left - r.Left;
            CornerOffsetY = wRect.Top - r.Top;
        }
        CornerOffsetX = Math.Max(-1200, Math.Min(600, CornerOffsetX));
        CornerOffsetY = Math.Max(-1200, Math.Min(600, CornerOffsetY));
        LastWidgetX = wRect.Left;
        LastWidgetY = wRect.Top;
        HasValidPosition = true;
    }

    public static void SyncNow() {
        if (IsPaused || _widgetHwnd == IntPtr.Zero || _targetHwnd == IntPtr.Zero) return;
        if (!IsWindow(_targetHwnd) || !IsWindowVisible(_targetHwnd) || IsIconic(_targetHwnd)) return;

        RECT r;
        if (!TryGetBounds(_targetHwnd, out r)) return;

        int anchorX = (AnchorCorner == 0 || AnchorCorner == 2) ? r.Right : r.Left;
        int anchorY = (AnchorCorner == 0 || AnchorCorner == 1) ? r.Bottom : r.Top;

        int targetX = anchorX + CornerOffsetX;
        int targetY = anchorY + CornerOffsetY;

        MoveWidgetPhysical(targetX, targetY);
    }

    private static void OnWinEvent(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime) {
        if (IsPaused || idObject != 0 || hwnd == IntPtr.Zero) return;
        if (hwnd != _targetHwnd) return;
        MovedByHook = true;
        SyncNow();
    }
}
"@

Add-Type -TypeDefinition $nativeCSharp -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$AssetsDir = Join-Path $RootDir "assets"
$ConfigDir = Join-Path $RootDir "config"
$ConfigPath = Join-Path $ConfigDir "config.json"
$PidPath = Join-Path $ConfigDir "pet.pid"
$PricingPath = Join-Path $ScriptDir "Pricing.json"
$QuotesPath = Join-Path $AssetsDir "quotes.json"
$XamlPath = Join-Path $ScriptDir "WidgetWindow.xaml"

. (Join-Path $ScriptDir "AntigravityMonitor.ps1")

if (!(Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}

$DefaultConfig = @{
    position_x = $null
    position_y = $null
    anchor_corner = 0
    corner_offset_x = $null
    corner_offset_y = $null
    scale = 1.0
    opacity = 1.0
    sound_enabled = $true
    sound_volume = 0.8
    cache_sound_enabled = $false
    speech_bubble_enabled = $true
    topmost = $true
    click_through = $false
    follow_antigravity = $true
    hide_with_antigravity = $true
    active_model = "gemini-4-hydrogen"
    active_plan = "free"
    antigravity_brain_path = Join-Path $env:USERPROFILE ".gemini\antigravity\brain"
}

$Config = $DefaultConfig.Clone()
if (Test-Path $ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            $Config[$p.Name] = $p.Value
        }
    } catch {}
}

if ($null -eq $Config.anchor_corner) {
    $Config.anchor_corner = 0
    $Config.follow_antigravity = $true
}
if ($null -ne $Config.corner_offset_x -and ([int]$Config.corner_offset_x -lt -1200 -or [int]$Config.corner_offset_x -gt 600)) {
    $Config.corner_offset_x = $null
    $Config.corner_offset_y = $null
}
if ($null -ne $Config.corner_offset_y -and ([int]$Config.corner_offset_y -lt -1200 -or [int]$Config.corner_offset_y -gt 600)) {
    $Config.corner_offset_x = $null
    $Config.corner_offset_y = $null
}
if ($null -ne $Config.position_x -and ([int]$Config.position_x -lt -4000 -or [int]$Config.position_x -gt 12000)) {
    $Config.position_x = $null
    $Config.position_y = $null
}

function Save-Config {
    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    } catch {}
}

# Load Quotes
$Quotes = @{
    greetings = @("哈基米南北绿豆～反重力记账挂件已就位喵！", "叮咚！你的专属 Gemini & Claude 哈基米来盯账单啦～")
    headpat = @("呼噜噜……摸头杀犯规啦，再摸算力要溢出来啦喵～", "喵呜～手感不错吧？这可是百万上下文容量的聪明脑袋瓜哦！", "嘿嘿，被摸头充能完毕！下一次推理一定更快更准喵～")
    idle = @("哈基米南北绿豆，阿西嘎阿西～今天写了多少行神仙代码呀？", "超长上下文待命中！就算把整个仓库喂给人家也完全吃得下哦～")
    cache_praise = @("哇哦！刚刚这一轮 Prompt 缓存命中率超高，帮你省下超多 Token 喵！", "不愧是 Context Caching 魔法，重复上下文全都打骨折价啦～")
}
if (Test-Path $QuotesPath) {
    try {
        $qJson = Get-Content -LiteralPath $QuotesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $qJson.PSObject.Properties) {
            $Quotes[$p.Name] = @($p.Value)
        }
    } catch {}
}

# Initialize Monitor
$Monitor = [AntigravityMonitor]::new(
    [string]$Config.antigravity_brain_path,
    $PricingPath,
    [string]$Config.active_model,
    [string]$Config.active_plan
)
if ($Monitor.Pricing -and !$Monitor.Pricing.models.ContainsKey($Config.active_model)) {
    $Config.active_model = $Monitor.ActiveModel
}

# Initialize Memory-Pinned Audio Player with DeepSeek Whale Default Pet Sounds (press.wav / D1.mp3 + release.wav / D2.mp3)
$pressWavPath = Join-Path $AssetsDir "sounds\press.wav"
$releaseWavPath = Join-Path $AssetsDir "sounds\release.wav"
$pressBytes = if (Test-Path $pressWavPath) { [System.IO.File]::ReadAllBytes($pressWavPath) } else { $null }
$releaseBytes = if (Test-Path $releaseWavPath) { [System.IO.File]::ReadAllBytes($releaseWavPath) } else { $null }
[HakimiAudioPlayer]::Initialize($pressBytes, $releaseBytes)
[HakimiAudioPlayer]::SoundEnabled = [bool]$Config.sound_enabled

$FallbackMediaPlayer = [System.Windows.Media.MediaPlayer]::new()
function Play-HakimiSound([string]$type) {
    if (!$Config.sound_enabled) { return }
    if ($type -eq "press") {
        [HakimiAudioPlayer]::PlayPress()
        return
    }
    if ($type -eq "release") {
        [HakimiAudioPlayer]::PlayRelease()
        return
    }
    # 轮次完成、缓存命中与结算扣费音效严格受 cache_sound_enabled 开关控制
    if ($type -in @("cost", "task", "chime", "coin") -and !$Config.cache_sound_enabled) {
        return
    }
    $soundMap = @{
        "pet"   = "press.wav"
        "cost"  = "cost-default.wav"
        "task"  = "task-end-a.wav"
        "chime" = "chime.wav"
        "warn"  = "Ya1.mp3"
    }
    $file = $soundMap[$type]
    if (!$file) { $file = "press.wav" }
    $fullPath = Join-Path (Join-Path $AssetsDir "sounds") $file
    if (Test-Path $fullPath) {
        try {
            $FallbackMediaPlayer.Open([Uri]::new($fullPath))
            $FallbackMediaPlayer.Volume = [double]$Config.sound_volume
            $FallbackMediaPlayer.Play()
        } catch {}
    }
}

# Unlocked Bitmap Loader
function Read-UnlockedBitmap([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = [System.IO.MemoryStream]::new($bytes)
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = $ms
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } finally {
        $ms.Dispose()
    }
}

# Load Main Widget Window XAML
[xml]$xamlContent = Get-Content -LiteralPath $XamlPath -Raw -Encoding UTF8
$reader = [System.Xml.XmlNodeReader]::new($xamlContent)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Find Main Window Controls
$Root = $window.FindName("Root")
$WidgetScale = $window.FindName("WidgetScale")
$FacingScale = $window.FindName("FacingScale")
$MascotContainer = $window.FindName("MascotContainer")
$SquishScale = $window.FindName("SquishScale")
$BreathTranslate = $window.FindName("BreathTranslate")
$CharacterImg = $window.FindName("CharacterImg")
$HeartBadge = $window.FindName("HeartBadge")
$HeartText = $window.FindName("HeartText")
$HeartTranslate = $window.FindName("HeartTranslate")
$HeartScale = $window.FindName("HeartScale")

$Bubble = $window.FindName("Bubble")
$BubbleCard = $window.FindName("BubbleCard")
$BubbleCloseBtn = $window.FindName("BubbleCloseBtn")
$FooterDetailPill = $window.FindName("FooterDetailPill")
$Tail = $window.FindName("Tail")
$TailNear = $window.FindName("TailNear")
$TextOverlay = $window.FindName("TextOverlay")
$TextFacingScale = $window.FindName("TextFacingScale")

$QuotaViewGrid = $window.FindName("QuotaViewGrid")
$HeaderTitle = $window.FindName("HeaderTitle")
$ActiveModelBadge = $window.FindName("ActiveModelBadge")
$FiveHourLabel = $window.FindName("FiveHourLabel")
$FiveHourValue = $window.FindName("FiveHourValue")
$FiveHourBarTrack = $window.FindName("FiveHourBarTrack")
$FiveHourBarFill = $window.FindName("FiveHourBarFill")
$FiveHourResetText = $window.FindName("FiveHourResetText")
$WeeklyLabel = $window.FindName("WeeklyLabel")
$WeeklyValue = $window.FindName("WeeklyValue")
$WeeklyBarTrack = $window.FindName("WeeklyBarTrack")
$WeeklyBarFill = $window.FindName("WeeklyBarFill")
$WeeklyResetText = $window.FindName("WeeklyResetText")
$UpdatedText = $window.FindName("UpdatedText")

$QuoteViewGrid = $window.FindName("QuoteViewGrid")
$BubbleText = $window.FindName("BubbleText")
$BubbleSubText = $window.FindName("BubbleSubText")

$BubbleToggleBtn = $window.FindName("BubbleToggleBtn")
$BubbleBtnFacingScale = $window.FindName("BubbleBtnFacingScale")
$DetailButton = $window.FindName("DetailButton")
$DetailFacingScale = $window.FindName("DetailFacingScale")
$MenuButton = $window.FindName("MenuButton")
$MenuFacingScale = $window.FindName("MenuFacingScale")

# Build Adaptive Detailed Info Window ($detailWindow)
[xml]$detailXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gemini Hakimi Details"
        Width="352" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
    <Border Margin="8" CornerRadius="16" Background="#F5131926" BorderBrush="#4D818CF8" BorderThickness="1.5">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="4" Opacity="0.42"/>
        </Border.Effect>
        <StackPanel Margin="14,12,14,12">
            <!-- Header -->
            <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="✨ Gemini &amp; Claude 限额详情" Foreground="#F8FAFC" FontSize="12.5" FontWeight="Bold"/>
                </StackPanel>
                <Border Grid.Column="1" Background="#264F46E5" BorderBrush="#66818CF8" BorderThickness="1" CornerRadius="6" Padding="6,2" Margin="0,0,6,0" VerticalAlignment="Center">
                    <TextBlock x:Name="QuadrantBadge" Text="↖ 左上自适应" Foreground="#A5B4FC" FontSize="9.5" FontWeight="Bold"/>
                </Border>
                <Border x:Name="CloseDetailBtn" Grid.Column="2" Width="20" Height="20" CornerRadius="10" Background="#26FFFFFF" Cursor="Hand">
                    <TextBlock Text="✕" Foreground="#CBD5E1" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
            </Grid>

            <!-- Section 1: Per-Model 5-Hour & Weekly Quotas (Gemini + Claude) -->
            <Border Background="#1AFFFFFF" CornerRadius="10" Padding="9,7" Margin="0,0,0,8">
                <StackPanel>
                    <Grid Margin="0,0,0,5">
                        <TextBlock Text="🐉 Gemini / Claude 5h与每周剩余限额 (点击切换)" Foreground="#94A3B8" FontSize="10" FontWeight="SemiBold"/>
                        <TextBlock x:Name="DetailPlanBadge" Text="Free 层" Foreground="#38BDF8" FontSize="10" FontWeight="Bold" HorizontalAlignment="Right"/>
                    </Grid>
                    <StackPanel x:Name="ModelQuotaStack"/>
                </StackPanel>
            </Border>

            <!-- Section 2: Real-Time RPM / TPM / TPS / Context Window -->
            <Border Background="#14FFFFFF" CornerRadius="10" Padding="8,6" Margin="0,0,0,8">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,2,0">
                        <TextBlock Text="RPM (每分请求)" Foreground="#94A3B8" FontSize="9"/>
                        <TextBlock x:Name="DetailRpmText" Text="0 / 15" Foreground="#E2E8F0" FontSize="10.5" FontWeight="Bold" Margin="0,1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="2,0,2,0">
                        <TextBlock Text="TPM (每分Token)" Foreground="#94A3B8" FontSize="9"/>
                        <TextBlock x:Name="DetailTpmText" Text="0 / 1.0M" Foreground="#E2E8F0" FontSize="10.5" FontWeight="Bold" Margin="0,1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Margin="2,0,2,0">
                        <TextBlock Text="TPS (每秒Token)" Foreground="#94A3B8" FontSize="9"/>
                        <TextBlock x:Name="DetailTpsText" Text="0 / 16.7k" Foreground="#F472B6" FontSize="10.5" FontWeight="Bold" Margin="0,1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="3" Margin="2,0,0,0">
                        <TextBlock Text="上下文占比" Foreground="#94A3B8" FontSize="9"/>
                        <TextBlock x:Name="DetailCtxText" Text="0.0% (1.0M)" Foreground="#E2E8F0" FontSize="10.5" FontWeight="Bold" Margin="0,1,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Section 3: Turn & Today Token Cost + Prompt Cache Savings -->
            <Border Background="#1E1E2E" BorderBrush="#3310B981" BorderThickness="1" CornerRadius="10" Padding="9,7">
                <StackPanel>
                    <Grid Margin="0,0,0,3">
                        <TextBlock x:Name="DetailTurnText" Text="本轮: In 0 · Cache 0 · Out 0" Foreground="#CBD5E1" FontSize="10.5"/>
                        <TextBlock x:Name="DetailHitText" Text="命中 0%" Foreground="#34D399" FontSize="10.5" FontWeight="Bold" HorizontalAlignment="Right"/>
                    </Grid>
                    <Grid>
                        <TextBlock x:Name="DetailTodayText" Text="今日累计 (0 轮): ¥0.00" Foreground="#F8FAFC" FontSize="11" FontWeight="Bold"/>
                        <TextBlock x:Name="DetailSaveText" Text="⚡ 缓存已省 ¥0.00" Foreground="#10B981" FontSize="11" FontWeight="Bold" HorizontalAlignment="Right"/>
                    </Grid>
                </StackPanel>
            </Border>
                    <!-- Section 4: Quick Toggles (Sound & Cache Chimes) -->
            <Grid Margin="0,7,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="TogglePetSoundBtn" Grid.Column="0" Background="#14FFFFFF" CornerRadius="6" Padding="6,4" Margin="0,0,4,0" Cursor="Hand">
                    <TextBlock x:Name="TogglePetSoundText" Text="🔊 摸头音效: 开" Foreground="#94A3B8" FontSize="9.5" HorizontalAlignment="Center"/>
                </Border>
                <Border x:Name="ToggleCacheSoundBtn" Grid.Column="1" Background="#14FFFFFF" CornerRadius="6" Padding="6,4" Margin="4,0,0,0" Cursor="Hand">
                    <TextBlock x:Name="ToggleCacheSoundText" Text="🔕 缓存提示音: 关" Foreground="#94A3B8" FontSize="9.5" HorizontalAlignment="Center"/>
                </Border>
            </Grid>
        </StackPanel>
    </Border>
</Window>
"@
$detailReader = [System.Xml.XmlNodeReader]::new($detailXaml)
$detailWindow = [System.Windows.Markup.XamlReader]::Load($detailReader)

$QuadrantBadge = $detailWindow.FindName("QuadrantBadge")
$CloseDetailBtn = $detailWindow.FindName("CloseDetailBtn")
$DetailPlanBadge = $detailWindow.FindName("DetailPlanBadge")
$ModelQuotaStack = $detailWindow.FindName("ModelQuotaStack")
$DetailRpmText = $detailWindow.FindName("DetailRpmText")
$DetailTpmText = $detailWindow.FindName("DetailTpmText")
$DetailTpsText = $detailWindow.FindName("DetailTpsText")
$DetailCtxText = $detailWindow.FindName("DetailCtxText")
$DetailTurnText = $detailWindow.FindName("DetailTurnText")
$DetailHitText = $detailWindow.FindName("DetailHitText")
$DetailTodayText = $detailWindow.FindName("DetailTodayText")
$DetailSaveText = $detailWindow.FindName("DetailSaveText")

# Load Unlocked Character Images
$normalImgPath = Join-Path $AssetsDir "gemini_normal.png"
$blushImgPath = Join-Path $AssetsDir "gemini_blush.png"
$normalBitmap = Read-UnlockedBitmap $normalImgPath
$blushBitmap = Read-UnlockedBitmap $blushImgPath
if ($normalBitmap) {
    $CharacterImg.Source = $normalBitmap
}

# Apply Initial Config (Use Opacity for Bubble visibility to prevent WPF layout jumps!)
$s = [double]$Config.scale
if ($s -le 0.4) { $s = 1.0 }
$WidgetScale.ScaleX = $s
$WidgetScale.ScaleY = $s
$window.Opacity = [double]$Config.opacity
$window.Topmost = [bool]$Config.topmost
$detailWindow.Topmost = [bool]$Config.topmost

function Set-BubbleVisible([bool]$visible) {
    $Config.speech_bubble_enabled = $visible
    Save-Config
    if ($visible) {
        $Bubble.Opacity = 1.0
        $Bubble.IsHitTestVisible = $true
        $BubbleToggleBtn.Opacity = 1.0
    } else {
        $Bubble.Opacity = 0.0
        $Bubble.IsHitTestVisible = $false
        $BubbleToggleBtn.Opacity = 0.65
    }
}
Set-BubbleVisible ([bool]$Config.speech_bubble_enabled)

function Format-Tok([double]$n) {
    if ($n -ge 1000000) { return [string]::Format("{0:F2}M", $n / 1000000.0) }
    if ($n -ge 1000) { return [string]::Format("{0:F1}k", $n / 1000.0) }
    if ($n % 1 -ne 0) { return [string]::Format("{0:F1}", $n) }
    return [string]::Format("{0:F0}", $n)
}

function Get-QuotaColorBrush([int]$remainingPct, [bool]$isWeekly) {
    if ($remainingPct -le 15) {
        return [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#EF4444"))
    }
    if ($remainingPct -le 35) {
        return [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#F59E0B"))
    }
    if ($isWeekly) {
        return [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#3B82F6"))
    }
    return [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#10B981"))
}

$state = @{
    PetCount = 0
    BreathPhase = 0.0
    IsDragging = $false
    WasDragged = $false
    DragStartCursorX = 0
    DragStartCursorY = 0
    WinStartPhysX = 0
    WinStartPhysY = 0
    LastMascotClickTick = 0L
    LastBubbleClickTick = 0L
    QuoteRevertTime = [datetime]::MinValue
    CurrentQuadrant = "BottomRight"
    DetailOpen = [bool]$OpenDetails
    SelfPid = [uint32]$PID
    WindowHwnd = [IntPtr]::Zero
    DetailHwnd = [IntPtr]::Zero
    HostHiddenState = $false
    EverHookedHost = $false
    HostMissingTicks = 0
    DetailWasOpen = $false
}

function Show-BubbleQuote([string]$text, [string]$sub = "", [int]$durationSec = 4) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $BubbleText.Text = $text
    if ($sub) {
        $BubbleSubText.Text = $sub
    } else {
        $BubbleSubText.Text = "单击切回额度 · 单击两次关气泡 · 双击看详情"
    }
    $Bubble.Opacity = 1.0
    $Bubble.IsHitTestVisible = $true
    $QuotaViewGrid.Opacity = 0.0
    $QuotaViewGrid.IsHitTestVisible = $false
    $QuoteViewGrid.Opacity = 1.0
    $QuoteViewGrid.IsHitTestVisible = $true
    $state.QuoteRevertTime = [datetime]::UtcNow.AddSeconds($durationSec)
}

function Show-BubbleQuotaView {
    $QuoteViewGrid.Opacity = 0.0
    $QuoteViewGrid.IsHitTestVisible = $false
    $QuotaViewGrid.Opacity = 1.0
    $QuotaViewGrid.IsHitTestVisible = $true
    $state.QuoteRevertTime = [datetime]::MinValue
    if (!$Config.speech_bubble_enabled) {
        $Bubble.Opacity = 0.0
        $Bubble.IsHitTestVisible = $false
    }
}

# Adaptive Quadrant Layout Engine (100% Physical Pixels — Never touches $window.Left / $window.Top!)
function Update-QuadrantLayout {
    $wRect = New-Object HakimiHostFollower+RECT
    if (![HakimiHostFollower]::GetWidgetPhysicalRect([ref]$wRect)) { return }

    $winPhysW = [Math]::Max(200, ($wRect.Right - $wRect.Left))
    $winPhysH = [Math]::Max(200, ($wRect.Bottom - $wRect.Top))
    $winCenterX = $wRect.Left + ($winPhysW * 0.5)
    $winCenterY = $wRect.Top + ($winPhysH * 0.5)

    $refCenterX = 0.0
    $refCenterY = 0.0
    $targetHwnd = [HakimiHostFollower]::GetTargetHwnd()
    $hRect = New-Object HakimiHostFollower+RECT
    if ($Config.follow_antigravity -and $targetHwnd -ne [IntPtr]::Zero -and [HakimiHostFollower]::TryGetBounds($targetHwnd, [ref]$hRect)) {
        $refCenterX = ($hRect.Left + $hRect.Right) * 0.5
        $refCenterY = ($hRect.Top + $hRect.Bottom) * 0.5
    } else {
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new([int]$winCenterX, [int]$winCenterY))
        $wa = $screen.WorkingArea
        $refCenterX = $wa.Left + ($wa.Width * 0.5)
        $refCenterY = $wa.Top + ($wa.Height * 0.5)
    }

    $isRight = ($winCenterX -ge $refCenterX)
    $isBottom = ($winCenterY -ge $refCenterY)

    # 1. Flip Horizontal Facing
    if ($isRight) {
        $FacingScale.ScaleX = 1.0
        $TextFacingScale.ScaleX = 1.0
        $MenuFacingScale.ScaleX = 1.0
        $DetailFacingScale.ScaleX = 1.0
        $BubbleBtnFacingScale.ScaleX = 1.0
    } else {
        $FacingScale.ScaleX = -1.0
        $TextFacingScale.ScaleX = -1.0
        $MenuFacingScale.ScaleX = -1.0
        $DetailFacingScale.ScaleX = -1.0
        $BubbleBtnFacingScale.ScaleX = -1.0
    }

    # 2. Flip Vertical Placement inside Canvas
    if ($isBottom) {
        [System.Windows.Controls.Canvas]::SetTop($MascotContainer, 142)
        [System.Windows.Controls.Canvas]::SetTop($Bubble, 8)
        [System.Windows.Controls.Canvas]::SetTop($Tail, 149)
        [System.Windows.Controls.Canvas]::SetTop($TailNear, 163)
        [System.Windows.Controls.Canvas]::SetTop($BubbleToggleBtn, 158)
        [System.Windows.Controls.Canvas]::SetTop($DetailButton, 158)
        [System.Windows.Controls.Canvas]::SetTop($MenuButton, 158)
    } else {
        [System.Windows.Controls.Canvas]::SetTop($MascotContainer, 0)
        [System.Windows.Controls.Canvas]::SetTop($Bubble, 162)
        [System.Windows.Controls.Canvas]::SetTop($Tail, 8)
        [System.Windows.Controls.Canvas]::SetTop($TailNear, -4)
        [System.Windows.Controls.Canvas]::SetTop($BubbleToggleBtn, 158)
        [System.Windows.Controls.Canvas]::SetTop($DetailButton, 158)
        [System.Windows.Controls.Canvas]::SetTop($MenuButton, 158)
    }

    # 3. Position Adaptive Detail Window in Physical Pixels
    $dpiScale = [HakimiHostFollower]::GetDpiScale($state.WindowHwnd)
    $dRect = New-Object HakimiHostFollower+RECT
    $dwPhys = [int][Math]::Round(352 * $dpiScale)
    $dhPhys = [int][Math]::Round(410 * $dpiScale)
    if ([HakimiHostFollower]::GetDetailPhysicalRect([ref]$dRect)) {
        if (($dRect.Right - $dRect.Left) -gt 100) { $dwPhys = $dRect.Right - $dRect.Left }
        if (($dRect.Bottom - $dRect.Top) -gt 100) { $dhPhys = $dRect.Bottom - $dRect.Top }
    }

    $insetX = [int][Math]::Round(145 * $dpiScale)
    $insetY = [int][Math]::Round(145 * $dpiScale)
    $detailPhysX = 0
    $detailPhysY = 0

    if ($isBottom -and $isRight) {
        $state.CurrentQuadrant = "BottomRight"
        $QuadrantBadge.Text = "↖ 左上自适应 (桌宠右下)"
        $detailPhysX = $wRect.Left - $dwPhys + $insetX
        $detailPhysY = $wRect.Top - $dhPhys + $insetY
    } elseif ($isBottom -and !$isRight) {
        $state.CurrentQuadrant = "BottomLeft"
        $QuadrantBadge.Text = "↗ 右上自适应 (桌宠左下)"
        $detailPhysX = $wRect.Right - $insetX
        $detailPhysY = $wRect.Top - $dhPhys + $insetY
    } elseif (!$isBottom -and $isRight) {
        $state.CurrentQuadrant = "TopRight"
        $QuadrantBadge.Text = "↙ 左下自适应 (桌宠右上)"
        $detailPhysX = $wRect.Left - $dwPhys + $insetX
        $detailPhysY = $wRect.Bottom - $insetY
    } else {
        $state.CurrentQuadrant = "TopLeft"
        $QuadrantBadge.Text = "↘ 右下自适应 (桌宠左上)"
        $detailPhysX = $wRect.Right - $insetX
        $detailPhysY = $wRect.Bottom - $insetY
    }

    # Clamp Detail Window within current monitor working area (Physical Pixels)
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new([int]$winCenterX, [int]$winCenterY))
    $wa = $screen.WorkingArea
    if ($detailPhysX -lt ($wa.Left + 8)) { $detailPhysX = $wa.Left + 8 }
    if (($detailPhysX + $dwPhys) -gt ($wa.Right - 8)) { $detailPhysX = $wa.Right - $dwPhys - 8 }
    if ($detailPhysY -lt ($wa.Top + 8)) { $detailPhysY = $wa.Top + 8 }
    if (($detailPhysY + $dhPhys) -gt ($wa.Bottom - 8)) { $detailPhysY = $wa.Bottom - $dhPhys - 8 }

    [HakimiHostFollower]::DetailOffsetX = $detailPhysX - $wRect.Left
    [HakimiHostFollower]::DetailOffsetY = $detailPhysY - $wRect.Top
    [HakimiHostFollower]::DetailVisible = [bool]$state.DetailOpen

    if ($state.DetailOpen) {
        [HakimiHostFollower]::MoveDetailPhysical($detailPhysX, $detailPhysY)
    }
}

function Toggle-DetailWindow {
    $state.DetailOpen = !$state.DetailOpen
    if ($state.DetailOpen) {
        Update-UI
        $detailWindow.Show()
        $detailWindow.UpdateLayout()
        Update-QuadrantLayout
    } else {
        $detailWindow.Hide()
        [HakimiHostFollower]::DetailVisible = $false
    }
}

# Update UI from Monitor
function Update-UI {
    $mInfo = $Monitor.Pricing.models[$Monitor.ActiveModel]
    $shortName = if ($mInfo -and $mInfo.short_name) { $mInfo.short_name } else { "4 Hydrogen" }
    $vendorName = if ($mInfo -and $mInfo.vendor) { $mInfo.vendor } else { "Gemini" }
    $HeaderTitle.Text = "$vendorName 额度池"
    $ActiveModelBadge.Text = $shortName

    # 1. Update Base Bubble: Row 1 = Active Model Pool, Row 2 = Companion Independent Pool
    $isActDis = [bool]$Monitor.FiveHour.Disabled
    if ($null -ne $FiveHourLabel) {
        $FiveHourLabel.Text = if ($Monitor.FiveHour.RowLabel) { [string]$Monitor.FiveHour.RowLabel } else { "5h 池" }
    }
    $rem5h = [int]$Monitor.FiveHour.RemainingPct
    if ($isActDis) {
        $FiveHourValue.Text = "--"
        $FiveHourValue.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        $FiveHourBarFill.Width = 0
        $FiveHourResetText.Text = "🔒 $($Monitor.FiveHour.ResetDisplay)"
    } else {
        $FiveHourValue.Text = "$rem5h%"
        $FiveHourValue.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#0F172A"))
        $FiveHourBarFill.Width = [Math]::Round(118.0 * ($rem5h / 100.0))
        $FiveHourBarFill.Background = Get-QuotaColorBrush $rem5h ([bool]$Monitor.FiveHour.IsWeekly)
        $FiveHourResetText.Text = "⏳ $($Monitor.FiveHour.ResetDisplay)"
    }

    if ($null -ne $WeeklyLabel) {
        $WeeklyLabel.Text = if ($Monitor.Weekly.ShortLabel) { [string]$Monitor.Weekly.ShortLabel } else { "Argon" }
    }
    $rem7d = [int]$Monitor.Weekly.RemainingPct
    $WeeklyValue.Text = "$rem7d%"
    $WeeklyBarFill.Width = [Math]::Round(118.0 * ($rem7d / 100.0))
    $WeeklyBarFill.Background = Get-QuotaColorBrush $rem7d $true
    $WeeklyResetText.Text = "📅 $($Monitor.Weekly.ResetDisplay)"

    $UpdatedText.Text = [string]::Format(
        "今日 ¥{0:F2} · ⚡省 ¥{1:F2} · 详情 ↗",
        $Monitor.Today.CostCNY,
        $Monitor.Today.SavingsCNY
    )

    # 2. Update Adaptive Detail Window (Independent Pool-Aware Per-Model Quotas)
    if ($null -ne $TogglePetSoundText) {
        $TogglePetSoundText.Text = if ($Config.sound_enabled) { "🔊 摸头音效: 开" } else { "🔇 摸头音效: 关" }
        $TogglePetSoundText.Foreground = if ($Config.sound_enabled) { [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A5B4FC") } else { [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B") }
    }
    if ($null -ne $ToggleCacheSoundText) {
        $ToggleCacheSoundText.Text = if ($Config.cache_sound_enabled) { "🔔 缓存提示音: 开" } else { "🔕 缓存提示音: 关" }
        $ToggleCacheSoundText.Foreground = if ($Config.cache_sound_enabled) { [System.Windows.Media.BrushConverter]::new().ConvertFromString("#34D399") } else { [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B") }
    }

    $DetailPlanBadge.Text = if (![string]::IsNullOrEmpty($Monitor.LivePlanName)) {
        "$($Monitor.LivePlanName) 实时池"
    } elseif ($Monitor.ActivePlan -eq "tier1") {
        "Tier 1 付费层 (5x限额)"
    } else {
        "Free 免费层"
    }
    $DetailRpmText.Text = "$($Monitor.RateLimits.CurrentRPM) / $($Monitor.RateLimits.MaxRPM)"
    $DetailTpmText.Text = "$(Format-Tok $Monitor.RateLimits.CurrentTPM) / $(Format-Tok $Monitor.RateLimits.MaxTPM)"
    $DetailTpsText.Text = "$(Format-Tok $Monitor.RateLimits.CurrentTPS) / $(Format-Tok $Monitor.RateLimits.MaxTPS)"
    $DetailCtxText.Text = "$($Monitor.Session.ContextPct)% ($(Format-Tok $Monitor.Session.CurrentContext))"

    $DetailTurnText.Text = "本轮: In $(Format-Tok $Monitor.LastTurn.InputTokens) · Cache $(Format-Tok $Monitor.LastTurn.CacheReadTokens) · Out $(Format-Tok $Monitor.LastTurn.OutputTokens)"
    $DetailHitText.Text = "命中 $($Monitor.LastTurn.CacheHitRate)%"
    $DetailTodayText.Text = [string]::Format("今日累计 ({0} 轮): ¥{1:F2}", $Monitor.Today.Turns, $Monitor.Today.CostCNY)
    $DetailSaveText.Text = [string]::Format("⚡ 缓存已省 ¥{0:F2}", $Monitor.Today.SavingsCNY)

    $poolBadgePalette = @{
        "flash_hydrogen" = @{ Bg = "#2210B981"; Border = "#5510B981"; Text = "#34D399" }
        "argon"          = @{ Bg = "#264F46E5"; Border = "#66818CF8"; Text = "#A5B4FC" }
        "claude"         = @{ Bg = "#22F59E0B"; Border = "#55F59E0B"; Text = "#FCD34D" }
        "carbon"         = @{ Bg = "#22A855F7"; Border = "#55C084FC"; Text = "#D8B4FE" }
    }

    $ModelQuotaStack.Children.Clear()
    foreach ($mq in $Monitor.ModelQuotas) {
        $isAct = [bool]$mq.IsActive
        $isDis = [bool]$mq.Disabled
        $isClaude = ([string]$mq.Vendor -eq "Claude")
        $qPool = if ($mq.QuotaPool) { [string]$mq.QuotaPool } else { "argon" }
        $pctVal = if ($null -ne $mq.RemainingPct) { [int]$mq.RemainingPct } else { [int]$mq.FiveHourRemainingPct }
        $resText = if ($mq.ResetDisplay) { [string]$mq.ResetDisplay } else { [string]$mq.FiveHourReset }
        $winText = if ($mq.WindowLabel) { [string]$mq.WindowLabel } else { "5h 周期池" }
        $poolTxt = if ($isDis) { "暂不可用·Ultra" } elseif ($mq.PoolLabel) { [string]$mq.PoolLabel } else { "独立池" }

        $rowBorder = [System.Windows.Controls.Border]::new()
        $rowBorder.CornerRadius = [System.Windows.CornerRadius]::new(7)
        $rowBorder.Padding = [System.Windows.Thickness]::new(7, 4.5, 7, 4.5)
        $rowBorder.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3.5)
        $rowBorder.Cursor = [System.Windows.Input.Cursors]::Hand
        $rowBorder.Tag = [string]$mq.Key
        $rowBorder.Opacity = if ($isDis -and !$isAct) { 0.72 } else { 1.0 }
        if ($isAct) {
            $rowBorder.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#334F46E5"))
            $rowBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#818CF8"))
            $rowBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        } elseif ($isDis) {
            $rowBorder.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#1264748B"))
            $rowBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#2864748B"))
            $rowBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        } else {
            $rowBorder.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($isClaude) { "#17F59E0B" } else { "#12FFFFFF" })))
            $rowBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($isClaude) { "#2EF59E0B" } else { "#1FFFFFFF" })))
            $rowBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        }

        $sp = [System.Windows.Controls.StackPanel]::new()

        $topGrid = [System.Windows.Controls.Grid]::new()
        $tc0 = [System.Windows.Controls.ColumnDefinition]::new()
        $tc0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $tc1 = [System.Windows.Controls.ColumnDefinition]::new()
        $tc1.Width = [System.Windows.GridLength]::Auto
        $topGrid.ColumnDefinitions.Add($tc0)
        $topGrid.ColumnDefinitions.Add($tc1)

        $leftStack = [System.Windows.Controls.StackPanel]::new()
        $leftStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $leftStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $nameTxt = [System.Windows.Controls.TextBlock]::new()
        $nameTxt.Text = $(if ($isAct) { "● $($mq.DisplayName)" } else { "  $($mq.DisplayName)" })
        $nameColor = if ($isAct) { "#A5B4FC" } elseif ($isDis) { "#94A3B8" } elseif ($isClaude) { "#FCD34D" } else { "#F1F5F9" }
        $nameTxt.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($nameColor))
        $nameTxt.FontSize = 10.2
        $nameTxt.FontWeight = [System.Windows.FontWeights]::Bold
        $nameTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $leftStack.Children.Add($nameTxt) | Out-Null

        $pal = if ($isDis) {
            @{ Bg = "#2264748B"; Border = "#4494A3B8"; Text = "#94A3B8" }
        } elseif ($poolBadgePalette.ContainsKey($qPool)) {
            $poolBadgePalette[$qPool]
        } else {
            $poolBadgePalette["argon"]
        }
        $pBadge = [System.Windows.Controls.Border]::new()
        $pBadge.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $pBadge.Padding = [System.Windows.Thickness]::new(4, 0.5, 4, 0.5)
        $pBadge.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
        $pBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $pBadge.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($pal.Bg))
        $pBadge.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($pal.Border))
        $pBadge.BorderThickness = [System.Windows.Thickness]::new(0.8)
        $pBadgeTxt = [System.Windows.Controls.TextBlock]::new()
        $pBadgeTxt.Text = $poolTxt
        $pBadgeTxt.FontSize = 8.2
        $pBadgeTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
        $pBadgeTxt.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($pal.Text))
        $pBadge.Child = $pBadgeTxt
        $leftStack.Children.Add($pBadge) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($leftStack, 0)

        $rightTxt = [System.Windows.Controls.TextBlock]::new()
        $rightTxt.Text = $resText
        $rightTxt.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($isDis) { "#64748B" } else { "#94A3B8" })))
        $rightTxt.FontSize = 8.4
        $rightTxt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $rightTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($rightTxt, 1)

        $topGrid.Children.Add($leftStack) | Out-Null
        $topGrid.Children.Add($rightTxt) | Out-Null
        $sp.Children.Add($topGrid) | Out-Null

        # Single Honest Pool Progress Bar Row
        $barRow = [System.Windows.Controls.Grid]::new()
        $barRow.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        $bc0 = [System.Windows.Controls.ColumnDefinition]::new()
        $bc0.Width = [System.Windows.GridLength]::new(64)
        $bc1 = [System.Windows.Controls.ColumnDefinition]::new()
        $bc1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $bc2 = [System.Windows.Controls.ColumnDefinition]::new()
        $bc2.Width = [System.Windows.GridLength]::new(42)
        $barRow.ColumnDefinitions.Add($bc0)
        $barRow.ColumnDefinitions.Add($bc1)
        $barRow.ColumnDefinitions.Add($bc2)

        $lblWin = [System.Windows.Controls.TextBlock]::new()
        $lblWin.Text = $winText
        $lblWin.FontSize = 8.8
        $lblWin.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        $lblWin.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($lblWin, 0)

        $trk = [System.Windows.Controls.Border]::new()
        $trk.Width = 172; $trk.Height = 5.5
        $trk.CornerRadius = [System.Windows.CornerRadius]::new(3)
        $trk.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#334155"))
        $trk.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $trk.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $fil = [System.Windows.Controls.Border]::new()
        $fil.Height = 5.5
        $fil.CornerRadius = [System.Windows.CornerRadius]::new(3)
        $fil.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        if ($isDis) {
            $fil.Width = 0
            $fil.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#475569"))
        } else {
            $fil.Width = [Math]::Round(172.0 * ($pctVal / 100.0))
            $fil.Background = Get-QuotaColorBrush $pctVal ([bool]$mq.IsWeekly)
        }
        $trk.Child = $fil
        [System.Windows.Controls.Grid]::SetColumn($trk, 1)

        $valTxt = [System.Windows.Controls.TextBlock]::new()
        $valTxt.Text = if ($isDis) { "未解锁" } else { "$pctVal%" }
        $valTxt.FontSize = 9.5
        $valTxt.FontWeight = [System.Windows.FontWeights]::Bold
        $valTxt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $valTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $valTxt.Foreground = if ($isDis) {
            [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString("#94A3B8"))
        } else {
            Get-QuotaColorBrush $pctVal ([bool]$mq.IsWeekly)
        }
        [System.Windows.Controls.Grid]::SetColumn($valTxt, 2)

        $barRow.Children.Add($lblWin) | Out-Null
        $barRow.Children.Add($trk) | Out-Null
        $barRow.Children.Add($valTxt) | Out-Null
        $sp.Children.Add($barRow) | Out-Null

        $rowBorder.Child = $sp

        $rowBorder.Add_MouseLeftButtonUp({
            param($sender, $e)
            $mk = [string]$sender.Tag
            if ($mk) {
                $Config.active_model = $mk
                Save-Config
                $Monitor.SetModel($mk, $Config.active_plan)
                if (!$Monitor.SyncFromSidecar()) { $Monitor.ScanAllWindows() }
                Play-HakimiSound "press"
                Update-UI
            }
            $e.Handled = $true
        })

        $ModelQuotaStack.Children.Add($rowBorder) | Out-Null
    }
}

Update-UI

if ($CheckOnly) {
    Write-Output "CHECK_OK: Gemini Hakimi v2.1 initialized. ActiveModel=$($Monitor.ActiveModel), 5h=$($Monitor.FiveHour.RemainingPct)%, Weekly=$($Monitor.Weekly.RemainingPct)%, Models=$($Monitor.ModelQuotas.Count)"
    exit 0
}

$Monitor.OnTurnFinished = {
    param($turn)
    try {
        Update-UI
        if ($turn.CacheHitRate -ge 80.0 -and $turn.SavingsCNY -ge 0.05) {
            if ($Config.cache_sound_enabled) {
                Play-HakimiSound "task"
            }
            $praiseList = $Quotes.cache_hit
            if (!$praiseList -or $praiseList.Count -eq 0) {
                $praiseList = $Quotes.turn_finished
            }
            $quoteStr = "哇哦！这次 Prompt 缓存命中率超高，又帮主人省下巨额 Token 啦～喵！"
            if ($praiseList -and $praiseList.Count -gt 0) {
                $quoteStr = $praiseList[(Get-Random -Maximum $praiseList.Count)]
            }
            Show-BubbleQuote $quoteStr ("本轮命中率 $($turn.CacheHitRate)% · 省 ¥$([Math]::Round($turn.SavingsCNY, 3))") 6
        } else {
            if ($Config.cache_sound_enabled) {
                Play-HakimiSound "cost"
            }
        }
    } catch {}
}

# Snap Helper (100% Physical Pixels — Never touches $window.Left/$window.Top!)
function Snap-MascotToNearestCorner([bool]$forceCornerDock = $false) {
    $wRect = New-Object HakimiHostFollower+RECT
    if (![HakimiHostFollower]::GetWidgetPhysicalRect([ref]$wRect)) { return }
    $physW = [Math]::Max(200, ($wRect.Right - $wRect.Left))
    $physH = [Math]::Max(200, ($wRect.Bottom - $wRect.Top))
    $curX = $wRect.Left
    $curY = $wRect.Top

    $targetHwnd = [HakimiHostFollower]::GetTargetHwnd()
    $hRect = New-Object HakimiHostFollower+RECT

    if ($Config.follow_antigravity -and $targetHwnd -ne [IntPtr]::Zero -and [HakimiHostFollower]::TryGetBounds($targetHwnd, [ref]$hRect)) {
        if ($forceCornerDock) {
            $corner = [int]$Config.anchor_corner
            if ($corner -eq 0) {
                $curX = $hRect.Right - $physW
                $curY = $hRect.Bottom - $physH
            } elseif ($corner -eq 1) {
                $curX = $hRect.Left
                $curY = $hRect.Bottom - $physH
            } elseif ($corner -eq 2) {
                $curX = $hRect.Right - $physW
                $curY = $hRect.Top
            } else {
                $curX = $hRect.Left
                $curY = $hRect.Top
            }
        } else {
            $snapDist = 65
            if ([Math]::Abs(($curX + $physW) - $hRect.Right) -le $snapDist) {
                $curX = $hRect.Right - $physW
            } elseif ([Math]::Abs($curX - $hRect.Left) -le $snapDist) {
                $curX = $hRect.Left
            }
            if ([Math]::Abs(($curY + $physH) - $hRect.Bottom) -le $snapDist) {
                $curY = $hRect.Bottom - $physH
            } elseif ([Math]::Abs($curY - $hRect.Top) -le $snapDist) {
                $curY = $hRect.Top
            }
        }
        [HakimiHostFollower]::MoveWidgetPhysical($curX, $curY)
        [HakimiHostFollower]::RecordAnchorFromCurrentPhysicalRect()
        $Config.anchor_corner = [HakimiHostFollower]::AnchorCorner
        $Config.corner_offset_x = [HakimiHostFollower]::CornerOffsetX
        $Config.corner_offset_y = [HakimiHostFollower]::CornerOffsetY
    } else {
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new([int]($curX + ($physW / 2)), [int]($curY + ($physH / 2))))
        $wa = $screen.WorkingArea
        $snapDist = 55
        if ([Math]::Abs(($curX + $physW) - $wa.Right) -le $snapDist) {
            $curX = $wa.Right - $physW
        } elseif ([Math]::Abs($curX - $wa.Left) -le $snapDist) {
            $curX = $wa.Left
        }
        if ([Math]::Abs(($curY + $physH) - $wa.Bottom) -le $snapDist) {
            $curY = $wa.Bottom - $physH
        } elseif ([Math]::Abs($curY - $wa.Top) -le $snapDist) {
            $curY = $wa.Top
        }
        [HakimiHostFollower]::MoveWidgetPhysical($curX, $curY)
    }

    $Config.position_x = $curX
    $Config.position_y = $curY
    Save-Config
    Update-QuadrantLayout
}

# Butter-Smooth 60FPS Hardware-Accelerated Q-Elastic Headpat Engine
$quadEaseOut = New-Object System.Windows.Media.Animation.QuadraticEase
$quadEaseOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

$cubicEaseOut = New-Object System.Windows.Media.Animation.CubicEase
$cubicEaseOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

$sineEaseInOut = New-Object System.Windows.Media.Animation.SineEase
$sineEaseInOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

$blushResetTimer = [System.Windows.Threading.DispatcherTimer]::new()
$blushResetTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$blushResetTimer.Add_Tick({
    param($s, $ev)
    if ($normalBitmap) { $CharacterImg.Source = $normalBitmap }
    $s.Stop()
})

$springEndTimer = [System.Windows.Threading.DispatcherTimer]::new()
$springEndTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$springEndTimer.Add_Tick({
    param($s, $ev)
    $state.IsSpringRebounding = $false
    $s.Stop()
})

function Start-MascotPressSquashAnimation {
    $state.IsSpringRebounding = $true
    $springEndTimer.Stop()

    # 1. 95ms Responsive Press Squash: ScaleX -> 1.14, ScaleY -> 0.84 (Fast cubic ease)
    $animX = New-Object System.Windows.Media.Animation.DoubleAnimation(1.14, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(95)))
    $animX.EasingFunction = $quadEaseOut
    $animY = New-Object System.Windows.Media.Animation.DoubleAnimation(0.84, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(95)))
    $animY.EasingFunction = $quadEaseOut

    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $animX)
    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animY)

    # 2. Heart Badge Pop & Float
    if ($HeartTranslate -and $HeartScale) {
        $HeartTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
        $HeartScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $HeartScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $HeartBadge.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)

        $HeartTranslate.Y = 2
        $HeartScale.ScaleX = 0.85
        $HeartScale.ScaleY = 0.85

        $htAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(-14.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $htAnim.EasingFunction = $cubicEaseOut
        $HeartTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $htAnim)

        $hsAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
        $hsAnim.EasingFunction = $cubicEaseOut
        $HeartScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $hsAnim)
        $HeartScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $hsAnim)

        $hoAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120)))
        $HeartBadge.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $hoAnim)
    } else {
        $HeartBadge.Opacity = 1.0
    }
}

function Start-MascotReleaseSpringAnimation {
    $state.IsSpringRebounding = $true
    $springEndTimer.Stop()
    $springEndTimer.Start()

    # Butter-smooth 480ms Q-elastic jelly rebound (4 keyframes with cubic/sine splines)
    # (1.14, 0.84) -> Stretch Overshoot (0.91, 1.13) -> Squash Rebound (1.06, 0.95) -> Settle (0.985, 1.015) -> Rest (1.0, 1.0)
    $kfX = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $kfY = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames

    # Frame 1 (120ms): Overshoot Stretch Upward
    $f1X = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(0.91, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(120)))
    $f1X.EasingFunction = $cubicEaseOut
    $f1Y = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.13, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(120)))
    $f1Y.EasingFunction = $cubicEaseOut

    # Frame 2 (240ms): Secondary Squash Bounce
    $f2X = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.055, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(240)))
    $f2X.EasingFunction = $sineEaseInOut
    $f2Y = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(0.955, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(240)))
    $f2Y.EasingFunction = $sineEaseInOut

    # Frame 3 (360ms): Micro-settle
    $f3X = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(0.986, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(360)))
    $f3X.EasingFunction = $sineEaseInOut
    $f3Y = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.014, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(360)))
    $f3Y.EasingFunction = $sineEaseInOut

    # Frame 4 (480ms): Complete Rest
    $f4X = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(480)))
    $f4X.EasingFunction = $quadEaseOut
    $f4Y = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(480)))
    $f4Y.EasingFunction = $quadEaseOut

    [void]$kfX.KeyFrames.Add($f1X)
    [void]$kfX.KeyFrames.Add($f2X)
    [void]$kfX.KeyFrames.Add($f3X)
    [void]$kfX.KeyFrames.Add($f4X)

    [void]$kfY.KeyFrames.Add($f1Y)
    [void]$kfY.KeyFrames.Add($f2Y)
    [void]$kfY.KeyFrames.Add($f3Y)
    [void]$kfY.KeyFrames.Add($f4Y)

    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $kfX)
    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $kfY)

    # Fade Heart badge smoothly after 750ms
    if ($HeartBadge) {
        $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(400)))
        $fadeAnim.BeginTime = [TimeSpan]::FromMilliseconds(750)
        $fadeAnim.EasingFunction = $quadEaseOut
        $HeartBadge.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
    }

    # Reset blush image gently after petting session
    $blushResetTimer.Stop()
    $blushResetTimer.Start()
}

function Start-MascotDragSettleAnimation {
    $state.IsSpringRebounding = $false
    $animX = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
    $animX.EasingFunction = $cubicEaseOut
    $animY = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
    $animY.EasingFunction = $cubicEaseOut

    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $animX)
    $SquishScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animY)

    if ($HeartBadge) {
        $HeartBadge.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $HeartBadge.Opacity = 0.0
    }
    if ($normalBitmap) { $CharacterImg.Source = $normalBitmap }
}

$MascotContainer.Add_MouseLeftButtonDown({
    param($sender, $e)
    Play-HakimiSound "press"
    if ($blushBitmap) { $CharacterImg.Source = $blushBitmap }
    Start-MascotPressSquashAnimation

    $state.IsDragging = $true
    $state.WasDragged = $false
    [HakimiHostFollower]::IsPaused = $true

    $pt = [System.Windows.Forms.Cursor]::Position
    $state.DragStartCursorX = $pt.X
    $state.DragStartCursorY = $pt.Y

    $wRect = New-Object HakimiHostFollower+RECT
    if ([HakimiHostFollower]::GetWidgetPhysicalRect([ref]$wRect)) {
        $state.WinStartPhysX = $wRect.Left
        $state.WinStartPhysY = $wRect.Top
    }

    $MascotContainer.CaptureMouse() | Out-Null
    $e.Handled = $true
})

$MascotContainer.Add_MouseMove({
    param($sender, $e)
    if ($state.IsDragging) {
        $pt = [System.Windows.Forms.Cursor]::Position
        $dx = $pt.X - $state.DragStartCursorX
        $dy = $pt.Y - $state.DragStartCursorY
        if ([Math]::Abs($dx) -gt 5 -or [Math]::Abs($dy) -gt 5) {
            $state.WasDragged = $true
            $newPhysX = $state.WinStartPhysX + $dx
            $newPhysY = $state.WinStartPhysY + $dy
            [HakimiHostFollower]::MoveWidgetPhysical($newPhysX, $newPhysY)
            Update-QuadrantLayout
        }
    }
})

$MascotContainer.Add_MouseLeftButtonUp({
    param($sender, $e)
    if ($state.IsDragging) {
        $state.IsDragging = $false
        $MascotContainer.ReleaseMouseCapture()

        Play-HakimiSound "release"
        [HakimiHostFollower]::IsPaused = $false

        if ($state.WasDragged) {
            Start-MascotDragSettleAnimation
            Snap-MascotToNearestCorner $false
        } else {
            Start-MascotReleaseSpringAnimation

            # Stationary Click! Distinguish:
            # 1) Fast Double-Click (<= 270ms) -> Toggle Detail Window
            # 2) Two Single Clicks (270ms < dt <= 950ms) -> Toggle Base Bubble
            # 3) Single Click -> Headpat Quote
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $dt = $nowMs - $state.LastMascotClickTick

            if ($dt -le 270) {
                $state.LastMascotClickTick = 0L
                Toggle-DetailWindow
            } elseif ($dt -le 950) {
                $state.LastMascotClickTick = 0L
                Set-BubbleVisible (!$Config.speech_bubble_enabled)
                $HeartText.Text = $(if ($Config.speech_bubble_enabled) { "💬 气泡已开启" } else { "💤 气泡已隐藏" })
            } else {
                $state.LastMascotClickTick = $nowMs
                $state.PetCount += 1
                $HeartText.Text = "♥ 摸头 +$($state.PetCount)"
                $qPool = @()
                if ($Quotes.pet) { $qPool += $Quotes.pet }
                if ($Quotes.idle) { $qPool += $Quotes.idle }
                if ($qPool.Count -gt 0) {
                    $q = $qPool[(Get-Random -Maximum $qPool.Count)]
                    Show-BubbleQuote $q ("摸摸头 x$($state.PetCount) · 单击两次关气泡 · 双击看详情") 4
                }
            }
        }
    }
    $e.Handled = $true
})

# Bubble Close Button (×) -> Immediately close base bubble
$BubbleCloseBtn.Add_MouseLeftButtonUp({
    param($sender, $e)
    Play-HakimiSound "press"
    Set-BubbleVisible $false
    $e.Handled = $true
})

# Footer Detail Pill inside Bubble -> Toggle Detail Window
$FooterDetailPill.Add_MouseLeftButtonUp({
    param($sender, $e)
    Play-HakimiSound "press"
    Toggle-DetailWindow
    $e.Handled = $true
})

# Bubble Card Click:
# - If in Quote View -> 1st click switches back to Quota View; clicking twice closes the bubble!
# - If in Quota View -> Clicking twice (within 950ms) closes the base bubble!
$BubbleCard.Add_MouseLeftButtonUp({
    param($sender, $e)
    Play-HakimiSound "press"
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $dt = $nowMs - $state.LastBubbleClickTick
    if ($dt -le 900) {
        $state.LastBubbleClickTick = 0L
        Set-BubbleVisible $false
    } else {
        $state.LastBubbleClickTick = $nowMs
        if ($QuoteViewGrid.Opacity -gt 0.5) {
            Show-BubbleQuotaView
        }
    }
    $e.Handled = $true
})

# Bubble Toggle Button (💬)
$BubbleToggleBtn.Add_MouseLeftButtonUp({
    param($sender, $e)
    Play-HakimiSound "press"
    Set-BubbleVisible (!$Config.speech_bubble_enabled)
    $e.Handled = $true
})

# Detail Button (📊) Click
$DetailButton.Add_MouseLeftButtonUp({
    param($sender, $e)
    Play-HakimiSound "press"
    Toggle-DetailWindow
    $e.Handled = $true
})

# Close Detail Button (✕)

$TogglePetSoundBtn = $detailWindow.FindName("TogglePetSoundBtn")
$TogglePetSoundText = $detailWindow.FindName("TogglePetSoundText")
$ToggleCacheSoundBtn = $detailWindow.FindName("ToggleCacheSoundBtn")
$ToggleCacheSoundText = $detailWindow.FindName("ToggleCacheSoundText")

if ($null -ne $TogglePetSoundBtn) {
    $TogglePetSoundBtn.Add_MouseLeftButtonUp({
        $Config.sound_enabled = !$Config.sound_enabled
        [HakimiAudioPlayer]::SoundEnabled = [bool]$Config.sound_enabled
        Save-Config
        Update-UI
    })
}

if ($null -ne $ToggleCacheSoundBtn) {
    $ToggleCacheSoundBtn.Add_MouseLeftButtonUp({
        $Config.cache_sound_enabled = !$Config.cache_sound_enabled
        Save-Config
        Update-UI
        if ($Config.cache_sound_enabled) {
            Play-HakimiSound "task"
        }
    })
}

$CloseDetailBtn.Add_MouseLeftButtonUp({
    param($sender, $e)
    $state.DetailOpen = $false
    $detailWindow.Hide()
    [HakimiHostFollower]::DetailVisible = $false
    $e.Handled = $true
})

# Context Menu Builder
$contextMenu = [System.Windows.Controls.ContextMenu]::new()

function Rebuild-ContextMenu {
    $contextMenu.Items.Clear()

    $miDetail = [System.Windows.Controls.MenuItem]::new()
    $miDetail.Header = "📊 展开/收起 Gemini & Claude 限额详情窗 (快速双击)"
    $miDetail.IsChecked = [bool]$state.DetailOpen
    $miDetail.Add_Click({ Toggle-DetailWindow })
    $contextMenu.Items.Add($miDetail) | Out-Null

    $miBubble = [System.Windows.Controls.MenuItem]::new()
    $miBubble.Header = "💬 显示/隐藏 头顶基础额度气泡 (单击两次)"
    $miBubble.IsChecked = [bool]$Config.speech_bubble_enabled
    $miBubble.Add_Click({ Set-BubbleVisible (!$Config.speech_bubble_enabled) })
    $contextMenu.Items.Add($miBubble) | Out-Null

    $miPet = [System.Windows.Controls.MenuItem]::new()
    $miPet.Header = "🐾 摸摸哈基米 (大肥鱼默认摸头音)"
    $miPet.Add_Click({
        Play-HakimiSound "press"
        $state.PetCount += 1
        Set-BubbleVisible $true
        $q = $Quotes.headpat[(Get-Random -Maximum $Quotes.headpat.Count)]
        Show-BubbleQuote $q ("摸摸头 x$($state.PetCount)") 4
    })
    $contextMenu.Items.Add($miPet) | Out-Null

    $contextMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null

    # Corner Quick-Dock Submenu
    $miCorner = [System.Windows.Controls.MenuItem]::new()
    $miCorner.Header = "📐 一键吸附窗口角落 (四象限自适应)"
    $corners = @(
        @{ Id = 0; Name = "↘ 右下角 (详情窗在左上)" },
        @{ Id = 1; Name = "↙ 左下角 (详情窗在右上)" },
        @{ Id = 2; Name = "↗ 右上角 (详情窗在左下)" },
        @{ Id = 3; Name = "↖ 左上角 (详情窗在右下)" }
    )
    foreach ($c in $corners) {
        $sub = [System.Windows.Controls.MenuItem]::new()
        $sub.Header = $c.Name
        $sub.Tag = $c.Id
        $sub.IsChecked = ([int]$Config.anchor_corner -eq [int]$c.Id)
        $sub.Add_Click({
            param($s, $e)
            $Config.anchor_corner = [int]$s.Tag
            $Config.follow_antigravity = $true
            [HakimiHostFollower]::AnchorCorner = [int]$s.Tag
            Snap-MascotToNearestCorner $true
        })
        $miCorner.Items.Add($sub) | Out-Null
    }
    $contextMenu.Items.Add($miCorner) | Out-Null

    # Model Selector Submenu
    $miModels = [System.Windows.Controls.MenuItem]::new()
    $miModels.Header = "🤖 切换当前 Gemini / Claude 计费模型"
    foreach ($mk in $Monitor.Pricing.models.Keys | Sort-Object) {
        $mSub = [System.Windows.Controls.MenuItem]::new()
        $mSub.Header = "$($Monitor.Pricing.models[$mk].display_name) ($mk)"
        $mSub.Tag = $mk
        $mSub.IsChecked = ($mk -eq $Monitor.ActiveModel)
        $mSub.Add_Click({
            param($s, $e)
            $selectedModel = [string]$s.Tag
            $Config.active_model = $selectedModel
            Save-Config
            $Monitor.SetModel($selectedModel, $Config.active_plan)
            if (!$Monitor.SyncFromSidecar()) { $Monitor.ScanAllWindows() }
            Update-UI
        })
        $miModels.Items.Add($mSub) | Out-Null
    }
    $contextMenu.Items.Add($miModels) | Out-Null

    # Plan Tier Submenu
    $miPlan = [System.Windows.Controls.MenuItem]::new()
    $miPlan.Header = "⚡ 切换限额层级 (Free / Tier 1)"
    foreach ($pl in @(@{k="free";n="Free 免费层 (1x限额 · 15 RPM)"}, @{k="tier1";n="Tier 1 付费层 (5x限额 · 1000 RPM)"})) {
        $pSub = [System.Windows.Controls.MenuItem]::new()
        $pSub.Header = $pl.n
        $pSub.Tag = $pl.k
        $pSub.IsChecked = ($Config.active_plan -eq $pl.k)
        $pSub.Add_Click({
            param($s, $e)
            $Config.active_plan = [string]$s.Tag
            Save-Config
            $Monitor.SetModel($Monitor.ActiveModel, $Config.active_plan)
            Update-UI
        })
        $miPlan.Items.Add($pSub) | Out-Null
    }
    $contextMenu.Items.Add($miPlan) | Out-Null

    $contextMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null

    $miFollow = [System.Windows.Controls.MenuItem]::new()
    $miFollow.Header = "🧲 零延迟死死粘住 Antigravity 窗口 (0ms WinEventHook)"
    $miFollow.IsChecked = [bool]$Config.follow_antigravity
    $miFollow.Add_Click({
        $Config.follow_antigravity = !$Config.follow_antigravity
        Save-Config
        if ($Config.follow_antigravity) {
            [HakimiHostFollower]::EnsureHooked($state.WindowHwnd, $state.DetailHwnd, $state.SelfPid) | Out-Null
            Snap-MascotToNearestCorner $true
        } else {
            [HakimiHostFollower]::Stop()
            if ($state.HostHiddenState) {
                $state.HostHiddenState = $false
                $window.Visibility = [System.Windows.Visibility]::Visible
                if ($state.DetailWasOpen -and $detailWindow) {
                    $detailWindow.Visibility = [System.Windows.Visibility]::Visible
                }
            }
        }
    })
    $contextMenu.Items.Add($miFollow) | Out-Null

    $miHideWithHost = [System.Windows.Controls.MenuItem]::new()
    $miHideWithHost.Header = "🙈 伴随 Antigravity 最小化隐藏与关闭联动"
    $miHideWithHost.IsChecked = [bool]$Config.hide_with_antigravity
    $miHideWithHost.IsEnabled = [bool]$Config.follow_antigravity
    $miHideWithHost.Add_Click({
        $Config.hide_with_antigravity = !$Config.hide_with_antigravity
        Save-Config
        if (!$Config.hide_with_antigravity -and $state.HostHiddenState) {
            $state.HostHiddenState = $false
            $window.Visibility = [System.Windows.Visibility]::Visible
            if ($state.DetailWasOpen -and $detailWindow) {
                $detailWindow.Visibility = [System.Windows.Visibility]::Visible
            }
        }
    })
    $contextMenu.Items.Add($miHideWithHost) | Out-Null

    $miSound = [System.Windows.Controls.MenuItem]::new()
    $miSound.Header = "🔊 开启大肥鱼摸头音效"
    $miSound.IsChecked = [bool]$Config.sound_enabled
    $miSound.Add_Click({
        $Config.sound_enabled = !$Config.sound_enabled
        [HakimiAudioPlayer]::SoundEnabled = [bool]$Config.sound_enabled
        Save-Config
        Update-UI
    })
    $contextMenu.Items.Add($miSound) | Out-Null

    $miCacheSound = [System.Windows.Controls.MenuItem]::new()
    $miCacheSound.Header = if ($Config.cache_sound_enabled) { "🔔 缓存命中提示音: 已开启" } else { "🔕 缓存命中提示音: 已静音 (免打扰)" }
    $miCacheSound.IsChecked = [bool]$Config.cache_sound_enabled
    $miCacheSound.Add_Click({
        $Config.cache_sound_enabled = !$Config.cache_sound_enabled
        Save-Config
        Update-UI
        if ($Config.cache_sound_enabled) {
            Play-HakimiSound "task"
        }
    })
    $contextMenu.Items.Add($miCacheSound) | Out-Null

    $contextMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null

    $miExit = [System.Windows.Controls.MenuItem]::new()
    $miExit.Header = "❌ 退出哈基米桌宠"
    $miExit.Add_Click({
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:54716/api/desktop-pet" -Method Post -Body '{"action":"manual_exit"}' -ContentType "application/json" -TimeoutSec 1 | Out-Null
        } catch {}
        $window.Close()
    })
    $contextMenu.Items.Add($miExit) | Out-Null
}

$window.ContextMenu = $contextMenu
$window.Add_ContextMenuOpening({ Rebuild-ContextMenu })

$MenuButton.Add_MouseLeftButtonUp({
    param($sender, $e)
    Rebuild-ContextMenu
    $contextMenu.PlacementTarget = $MenuButton
    $contextMenu.IsOpen = $true
    $e.Handled = $true
})

# System Tray Icon
$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Text = "反重力哈基米记账 (Gemini & Claude v2.1)"
$icoPath = Join-Path $AssetsDir "gemini_icon.ico"
if (Test-Path $icoPath) {
    $notifyIcon.Icon = [System.Drawing.Icon]::new($icoPath)
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$notifyIcon.Visible = $true
$notifyIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.Visibility -eq [System.Windows.Visibility]::Visible) {
            Toggle-DetailWindow
        } else {
            $state.HostHiddenState = $false
            $window.Visibility = [System.Windows.Visibility]::Visible
            $window.Activate() | Out-Null
        }
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        Rebuild-ContextMenu
        $contextMenu.IsOpen = $true
    }
})

# Window SourceInitialized: Setup Win32 Handle, Alt-Tab Hiding, and 100% Physical Pixel Placement
$window.Add_SourceInitialized({
    try {
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($window)
    $state.WindowHwnd = $helper.Handle
    [HakimiWin32]::HideFromAltTab($state.WindowHwnd)

    $detailHelper = [System.Windows.Interop.WindowInteropHelper]::new($detailWindow)
    $state.DetailHwnd = $detailHelper.EnsureHandle()
    [HakimiWin32]::HideFromAltTab($state.DetailHwnd)

    $placed = $false
    if ($Config.follow_antigravity) {
        $hooked = [HakimiHostFollower]::EnsureHooked($state.WindowHwnd, $state.DetailHwnd, $state.SelfPid)
        if ($hooked) {
            [HakimiHostFollower]::AnchorCorner = [int]$Config.anchor_corner
            if ($null -ne $Config.corner_offset_x -and $null -ne $Config.corner_offset_y) {
                [HakimiHostFollower]::CornerOffsetX = [int]$Config.corner_offset_x
                [HakimiHostFollower]::CornerOffsetY = [int]$Config.corner_offset_y
                [HakimiHostFollower]::SyncNow()
                $placed = $true
            } else {
                Snap-MascotToNearestCorner $true
                $placed = $true
            }
        }
    }

    if (!$placed) {
        $wRect = New-Object HakimiHostFollower+RECT
        [HakimiHostFollower]::GetWidgetPhysicalRect([ref]$wRect) | Out-Null
        $physW = [Math]::Max(200, ($wRect.Right - $wRect.Left))
        $physH = [Math]::Max(200, ($wRect.Bottom - $wRect.Top))
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $px = if ($null -ne $Config.position_x) { [int]$Config.position_x } else { $wa.Right - $physW }
        $py = if ($null -ne $Config.position_y) { [int]$Config.position_y } else { $wa.Bottom - $physH }
        [HakimiHostFollower]::MoveWidgetPhysical($px, $py)
    }

    Update-QuadrantLayout
    if ($state.DetailOpen) {
        $detailWindow.Show()
        $detailWindow.UpdateLayout()
        Update-QuadrantLayout
    }
    } catch {}
})

# Breathing & Host Hook Check Timer (50ms) — NEVER writes $window.Left/$window.Top!
$animTimer = [System.Windows.Threading.DispatcherTimer]::new()
$animTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$animTimer.Add_Tick({
    try {
    if (!$state.IsSpringRebounding) {
        $state.BreathPhase += 0.14
        $BreathTranslate.Y = [Math]::Sin($state.BreathPhase) * 2.0
    } else {
        $BreathTranslate.Y = $BreathTranslate.Y * 0.7
    }

    if ($state.QuoteRevertTime -ne [datetime]::MinValue -and [datetime]::UtcNow -ge $state.QuoteRevertTime) {
        Show-BubbleQuotaView
    }

    if ($Config.follow_antigravity -and !$state.IsDragging) {
        $hooked = [HakimiHostFollower]::EnsureHooked($state.WindowHwnd, $state.DetailHwnd, $state.SelfPid)
        if ($hooked) {
            $state.EverHookedHost = $true
            $state.HostMissingTicks = 0
        }

        if ($Config.hide_with_antigravity -and $state.EverHookedHost) {
            $tHwnd = [HakimiHostFollower]::GetTargetHwnd()
            if ($tHwnd -ne [IntPtr]::Zero) {
                if (![HakimiHostFollower]::IsHostWindowAlive()) {
                    $isProcAlive = [HakimiHostFollower]::IsHostProcessAlive()
                    $newHwnd = [HakimiHostFollower]::FindAntigravityWindow($state.SelfPid)
                    if ($newHwnd -eq [IntPtr]::Zero) {
                        $state.HostMissingTicks++
                        $threshold = if (!$isProcAlive) { 5 } else { 12 }
                        if ($state.HostMissingTicks -ge $threshold) {
                            $window.Close()
                            return
                        }
                    } else {
                        $state.HostMissingTicks = 0
                    }
                } else {
                    $state.HostMissingTicks = 0
                    $isMin = [HakimiHostFollower]::IsHostMinimized()
                    if ($isMin) {
                        if (!$state.HostHiddenState) {
                            $state.HostHiddenState = $true
                            $state.DetailWasOpen = [bool]$state.DetailOpen
                            $window.Visibility = [System.Windows.Visibility]::Collapsed
                            if ($state.DetailOpen -and $detailWindow) {
                                $detailWindow.Visibility = [System.Windows.Visibility]::Collapsed
                            }
                        }
                    } else {
                        if ($state.HostHiddenState) {
                            $state.HostHiddenState = $false
                            $window.Visibility = [System.Windows.Visibility]::Visible
                            if ($state.DetailWasOpen -and $detailWindow) {
                                $detailWindow.Visibility = [System.Windows.Visibility]::Visible
                            }
                            [HakimiHostFollower]::RestoreTopmost()
                            [HakimiHostFollower]::SyncNow()
                            Update-QuadrantLayout
                        }
                    }
                }
            }
        } elseif ($state.HostHiddenState) {
            $state.HostHiddenState = $false
            $window.Visibility = [System.Windows.Visibility]::Visible
            if ($state.DetailWasOpen -and $detailWindow) {
                $detailWindow.Visibility = [System.Windows.Visibility]::Visible
            }
        }

        if ([HakimiHostFollower]::MovedByHook) {
            [HakimiHostFollower]::MovedByHook = $false
            if (!$state.HostHiddenState) {
                Update-QuadrantLayout
            }
        }
    }
    } catch {}
})
$animTimer.Start()

# Transcript Poll Timer (1.5s)
$pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$pollTimer.Add_Tick({
    try {
        $Monitor.PollUpdates()
        Update-UI
    } catch {}
})
$pollTimer.Start()

$app = [System.Windows.Application]::Current
if ($null -eq $app) {
    $app = New-Object System.Windows.Application
}
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# Cleanup on Exit
$window.Add_Closed({
    [HakimiHostFollower]::Stop()
    $animTimer.Stop()
    $pollTimer.Stop()
    try { $detailWindow.Close() } catch {}
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if (Test-Path $PidPath) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
    try { $app.Shutdown() } catch {}
})

try {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding Ascii -Force
} catch {}

$window.Show()
[void]$app.Run()
