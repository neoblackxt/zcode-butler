#!/usr/bin/env powershell
# =====================================================================
# ZCode 会话统计覆盖层 v0.12(码管家·会话统计条;输入框上沿,B+E1 徽章仪表右置)
# 显示:● ⚡ 首 token X.XXs | ▁▃▅ N.N tok/s(双胶囊,呼吸绿点+sky 火花线,页面内假数据)
# v0.12:出现时机 + 位置自适应(CDP 通道):
#   ZCode 以 --remote-debugging-port=9222 启动(zcode-cdp-launch.vbs)时,anchor-probe.mjs
#   读 composer 实时 rect(视口 CSS px)→ ~/.zcode/stats-widget-anchor.json → 本宿主换算
#   屏幕坐标(ClientToScreen+GetDpiForWindow)。行为:右缘/上沿实时跟随;composer 高
#   > showMaxComposerPx(288+24 滞回)隐藏、回落恢复;侧栏/面板宽度自适应。
#   无 CDP(裸启动/探锚死/文件陈旧>2s)自动降级基线常量锚(v0.11 行为,常显)。
#   C# 跟随重构为「窗口相对偏移」:SetFollowParams(z,offX,offY,w,h),基线/CDP 统一喂入。
# v0.11:形态换 B+E1 定稿(见桌面仓库 ZCode UI/zcode-composer-stats-prototypes.html),
#   锚从「输入框下空带居中」改为「输入框上沿右对齐」:
#   垂直 = 可视帧底边 - 35(带,v0.10 实测状态无关)- composerHeight - gap - 窗高
#   水平 = 窗口中心 + centerXOffset + composerHalfWidth - 窗宽(右缘贴 composer 右缘)
#   composerHeight=182 / composerHalfWidth=841 为 2026-09-28 实机实测值(1.75dpr 最大化),
#   ~/.zcode/stats-widget.json 可调(composerHeightPx / composerHalfWidthPx / gapAbovePx)
# v0.10:垂直锚改 DWM 可视帧底边(ExtendedFrameBounds)——窗口矩形含不可见
#   缩放边框(最大化超出可视区 ~12px / 普通态内缩 ~8px),旧锚随缩放状态漂移
#   (全屏 3-4px vs 非全屏 12px)。现为「输入框下空带居中」:带高实测 35px
#   (输入框底 2041 ~ 1px 边框线 2075 = 20css 固定内边距,与窗口状态无关),
#   文字 19px → bottomMargin=8(窗口底缘距可视底边),文字底对齐。
#   水平仍 = 窗口中心 + 63(输入框偏心)。
# v0.9:帧级跟随(WinEvent 回调只 PostMessage,WndProc 移动,守重入契约);
#   v0.8:纯窗口矩形锚定(删全部像素扫描);v0.6:字号定死 12px。
#   反推界面字号(渲染像素即真值,设置改完 ≤2s 生效,不依赖 localStorage
#   落盘);修复页面对宿主字号推送的监听错误(chrome.webview + 对象直用)。
# v0.3:锚点像素伺服——每 2s 扫描底栏定位绿点(GLM 组左缘,稳定可靠);
#   上下文圆环(用户确认紧挨 GLM-5.3 左侧,空闲时隐藏)弹出时自然落在
#   覆盖层与绿点之间,两侧各 ~12px 等距;覆盖层右缘 = 绿点视觉左缘-48。
#   窗口宽度/布局变化自适应。
# v0.2:字号跟随 ZCode「设置-外观-界面字号」(localStorage zcode-ui-font-size-px,
#   12~20,默认14;条带用同档 text-ui-lg = 界面字号+2,2s 轮询);颜色/字重
#   对齐胶囊文字实测值(#D4D4D4 / 400)。
# 壳:继承码管家 butler-widget.ps1 v0.4.4 的合成宿主(NOREDIRECTIONBITMAP +
#   DComp + CoreWebView2CompositionController 逐像素透明),裁剪为纯文本条:
#   整窗 HTTRANSPARENT 点击穿透 / WinEvent 跟随 ZCode / owned 同层 /
#   Ctrl+Alt+S 显隐 / 单实例互斥 / 生死绑定(ZCode 亡则退、脚本删则退)
# 定位:底部上方 70px 扫一行像素找输入框中心(见 v0.7 注记);
#   ~/.zcode/stats-widget.json 可调:
#   centerXOffset    相对输入框中心的水平微调(物理像素)
#   centerYFromBottom 垂直中心线距窗口底缘(默认 36 = 输入框下空白带中心)
# 实测基准:3840x2160 最大化窗口、1.75 dpr;布局变化后在 json 里微调
# 注意:本文件必须 UTF-8 带 BOM 保存(PS5.1 无 BOM 按 ANSI 解析,C# here-string
#   中文注释乱码吞换行 → Add-Type 静默失败)
# =====================================================================
param(
  [switch]$NoShowIfExists
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 单实例互斥 + 换代对账(公共层) ----
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
$ownsMutex = Request-ButlerSingleInstance -MutexName 'Global\ZCode-Stats-Widget' -Kind 'stats' `
  -ScriptDir $PSScriptRoot -ProcessMatch 'stats-widget\.ps1'
if (-not $ownsMutex) { exit }

# ---- 路径与配置 ----
$dotZcode = Join-Path $env:USERPROFILE '.zcode'
$configFile = Join-Path $dotZcode 'stats-widget.json'
$htmlFile = Join-Path $PSScriptRoot 'stats-widget.html'
$dbgLog = Join-Path $env:TEMP 'stats-widget-debug.log'
function WLog($m) { try { Add-Content -Path $dbgLog -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) } catch { } }
function WLogRaw($m) { try { [IO.File]::AppendAllText($dbgLog, [DateTime]::Now.ToString('MM-dd HH:mm:ss') + ' ' + $m + [char]13 + [char]10) } catch { } }

$script:centerXOffset = 63        # 输入框中心相对窗口中心的水平偏移(侧栏所致,实测 63;侧栏折叠后改 0)
# v0.11 右置上沿锚常量(物理像素,1.75dpr 基准;三项均可在 json 覆盖)
$script:bandFromBottom = 35       # 输入框底缘距可视帧底边(v0.10 实测 35px,状态无关)
$script:composerHeightPx = 182    # 2026-09-28 实机实测(上缘1859/下缘2041,1.75dpr 最大化)
$script:composerHalfWidthPx = 841 # 2026-09-28 实机实测(composer 右缘2824 = 中心1920+偏移63+半宽841)
$script:gapAbovePx = 8            # 浮标底缘与输入框上沿间距
$script:showMaxComposerPx = 288   # v0.12 出现阈值:composer 实测高超过(288+24 滞回)即隐藏;json 可调
$script:cfgWinW = 0
$script:cfgWinH = 0
try {
  $c = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($c) {
    if ($c.centerXOffset -ne $null) { $script:centerXOffset = [int]$c.centerXOffset }
    if ($c.bottomMargin -ne $null) { } # v0.10 旧参数,已废弃(保留容错不报错)
    if ($c.composerHeightPx -ne $null) { $script:composerHeightPx = [int]$c.composerHeightPx }
    if ($c.composerHalfWidthPx -ne $null) { $script:composerHalfWidthPx = [int]$c.composerHalfWidthPx }
    if ($c.gapAbovePx -ne $null) { $script:gapAbovePx = [int]$c.gapAbovePx }
    if ($c.showMaxComposerPx -ne $null) { $script:showMaxComposerPx = [int]$c.showMaxComposerPx }
    if ($c.winW) { $script:cfgWinW = [int]$c.winW }
    if ($c.winH) { $script:cfgWinH = [int]$c.winH }
  }
} catch { }

# ---- 尺寸:B+E1 双胶囊(v0.11 定死,不走字号伸缩;物理像素) ----
$script:dpr = 1.75
$script:stripCssPx = 11           # 胶囊字号 11css(记录用,尺寸不再由它推导)
function Update-StripMetrics {
  # 双胶囊 ≈460 物理宽;窗体右对齐内容,富余向左延伸(透明不可见)
  if ($script:cfgWinW -gt 0) { $script:winW = $script:cfgWinW }
  else { $script:winW = 600 }
  if ($script:cfgWinH -gt 0) { $script:winH = $script:cfgWinH }
  else { $script:winH = 52 }      # 胶囊 42 + 上下余量
}
$script:winW = 840; $script:winH = 48
Update-StripMetrics

# ---- 依赖装载与 DPI ----
Add-Type -AssemblyName WindowsBase, System.Drawing
Add-Type -Namespace StatsNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint idObject, uint flags);
public delegate void WinEventProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
[DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hHook);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint exitCode);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int cb);
public static IntPtr SetOwner(IntPtr h, IntPtr owner) {
  if (IntPtr.Size == 8) return SetWindowLongPtr(h, -8, owner);
  return new IntPtr(SetWindowLong(h, -8, owner.ToInt32()));
}
'@
# 跨回调状态:WinEvent delegate 里 $script: 会丢,置脏走 .NET 静态字段
Add-Type -TypeDefinition 'public static class StatsState { public static volatile int FollowDirty; }'
[void][StatsNative.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

# v0.2.0 staging 运行时(公共层):DLL 只从 %LOCALAPPDATA% 加载(与 butler-widget 共用
# 一份 DLL 与逻辑),进程对插件缓存零句柄 → ZCode 卸载/更新不再撞锁(见开发日志)。
# 种子在 scripts/webview2(两悬浮窗共享,v0.2.1 从 widget/ 迁出)。
$wv2Dir = Initialize-ButlerWebview2Staging -SeedDir (Join-Path $PSScriptRoot '..\..\webview2')
$env:PATH = $wv2Dir + ';' + $env:PATH
$asmCore = [System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Core.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $wv2Dir 'Microsoft.Web.WebView2.Wpf.dll'))

# =====================================================================
# 内联 C# 合成宿主(与 butler 同源;整窗穿透,无鼠标转发/形状掩码)
# =====================================================================
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

public static class StatsHost {
  private static IntPtr _hwnd;
  private static WndProcDelegate _proc;
  private static IDCompositionDevice _device;
  private static IDCompositionTarget _target;
  private static IDCompositionVisual _visual;
  private static CoreWebView2CompositionController _controller;
  private static Dispatcher _dispatcher;
  private static bool _destroyed;

  public static Action OnHotKey;
  public static Action<string> OnMessage;
  public static Action<string> Log = delegate { };
  public static string DbgPath = "";
  private static void RawLog(string s) {
    try { System.IO.File.AppendAllText(DbgPath, DateTime.Now.ToString("MM-dd HH:mm:ss") + " " + s + "\r\n"); } catch { }
  }

  private const uint WM_DESTROY = 2, WM_SIZE = 5, WM_ERASEBKGND = 0x14,
    WM_NCHITTEST = 0x84, WM_HOTKEY = 0x312;
  private const int HTTRANSPARENT = -1;

  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  private delegate IntPtr WndProcDelegate(IntPtr h, uint m, IntPtr w, IntPtr l);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern ushort RegisterClassEx(ref WNDCLASSEX c);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool SetWindowText(IntPtr h, string t);
  [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
  [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandleW(string name);
  [DllImport("dcomp.dll")] private static extern int DCompositionCreateDevice(IntPtr dxgi, Guid iid, out IntPtr dev);
  [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG m, IntPtr h, uint a, uint b, uint remove);
  [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG m);

  [StructLayout(LayoutKind.Sequential)]
  private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int ptX, ptY; }

  // pump host messages while a task completes (controller setup SendMessages us)
  private static T PumpWait<T>(Task<T> t) {
    while (!t.IsCompleted) {
      MSG m;
      while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1 /*PM_REMOVE*/)) { TranslateMessage(ref m); DispatchMessage(ref m); }
      System.Threading.Thread.Sleep(15);
    }
    return t.Result;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct WNDCLASSEX {
    public int cbSize; public uint style; public WndProcDelegate lpfnWndProc;
    public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
    public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
  }

  [ComImport, Guid("C37EA93A-E7AA-450D-B16F-9746CB0407F3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionDevice {
    void Commit();
    void WaitForCommitCompletion();
    void GetFrameStatistics(IntPtr stats);
    void CreateTargetForHwnd(IntPtr hwnd, bool topmost, out IDCompositionTarget target);
    void CreateVisual(out IDCompositionVisual visual);
  }
  [ComImport, Guid("eacdd04c-117e-4e17-88f4-d1b12b0e3d89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionTarget { void SetRoot(IDCompositionVisual visual); }
  [ComImport, Guid("4d93059d-097b-4651-9a60-f0f25116e2f3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IDCompositionVisual { }

  public static IntPtr Handle { get { return _hwnd; } }
  public static bool Ready { get { return _controller != null; } }
  public static bool Visible { get { return IsWindowVisible(_hwnd); } }

  public static void PostJson(string json) {
    var c = _controller;
    if (c != null && c.CoreWebView2 != null) { try { c.CoreWebView2.PostWebMessageAsJson(json); } catch { } }
  }

  public static void Init(int x, int y, int w, int h, string udf, string url) {
    Log("init: enter");
    var wc = new WNDCLASSEX();
    wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
    wc.style = 0;
    wc.lpfnWndProc = _proc = WndProcImpl;
    wc.hInstance = GetModuleHandleW(null);
    wc.hCursor = IntPtr.Zero;
    wc.hbrBackground = IntPtr.Zero;
    wc.lpszClassName = "StatsWidgetWnd";
    RegisterClassEx(ref wc);
    Log("init: class registered");
    int WS_POPUP = unchecked((int)0x80000000);
    Log("init: creating window");
    int ex = 0x00200000 /*WS_EX_NOREDIRECTIONBITMAP*/
           | 0x00000080 /*WS_EX_TOOLWINDOW*/
           | 0x08000000; /*WS_EX_NOACTIVATE:z order managed by owner relation*/
    _hwnd = CreateWindowEx(ex, "StatsWidgetWnd", "StatsWidget", WS_POPUP, x, y, w, h, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
    SetWindowText(_hwnd, "StatsWidget");
    Log("hwnd=0x" + _hwnd.ToString("X") + " size=" + w + "x" + h);
    if (_hwnd == IntPtr.Zero) { Fail("window create failed"); return; }

    IntPtr devPtr;
    int hr = DCompositionCreateDevice(IntPtr.Zero, typeof(IDCompositionDevice).GUID, out devPtr);
    if (hr != 0 || devPtr == IntPtr.Zero) { Fail("DCompositionCreateDevice hr=0x" + hr.ToString("X8")); return; }
    _device = (IDCompositionDevice)Marshal.GetObjectForIUnknown(devPtr);
    _device.CreateTargetForHwnd(_hwnd, true, out _target);
    _device.CreateVisual(out _visual);
    _target.SetRoot(_visual);
    _device.Commit();

    try {
      var env = PumpWait(CoreWebView2Environment.CreateAsync(null, udf, null));
      _controller = PumpWait(env.CreateCoreWebView2CompositionControllerAsync(_hwnd));
      _controller.RootVisualTarget = _visual;
      _device.Commit();   // commit again after put_RootVisualTarget
      _controller.Bounds = new Rectangle(0, 0, w, h);
      _controller.IsVisible = true;
      _controller.NotifyParentWindowPositionChanged();
      _controller.DefaultBackgroundColor = Color.Transparent;
      var core = _controller.CoreWebView2;
      core.WebMessageReceived += (s, e) => {
        try {
          var msg = e.TryGetWebMessageAsString();
          Log("wmsg: " + (msg == null ? "null" : (msg.Length > 60 ? msg.Substring(0, 60) : msg)));
          if (OnMessage != null) _dispatcher.InvokeAsync(() => OnMessage(msg));
        } catch { }
      };
      core.Navigate(url);
      core.NavigationCompleted += (s, e) => Log("nav " + (e.IsSuccess ? "ok" : "FAIL " + e.WebErrorStatus));
      _dispatcher = Dispatcher.FromThread(System.Threading.Thread.CurrentThread);
      if (_dispatcher == null) _dispatcher = Dispatcher.CurrentDispatcher;
      Log("composition controller ready");
    } catch (Exception e2) {
      var e1 = e2; while (e1.InnerException != null) e1 = e1.InnerException;
      Fail("setup: " + e1.Message);
    }
  }

  private static void Fail(string why) {
    Log("FATAL " + why);
    try {
      // CodeDom compiles C# as ANSI: non-ASCII literals corrupt -- English only
      System.Diagnostics.Process.Start("mshta",
        "vbscript:MsgBox(\"Stats widget init failed: " + why.Replace('"', ' ').Replace("\r", " ").Replace("\n", " ") +
        " (WebView2 Runtime required: developer.microsoft.com/microsoft-edge/webview2/)\",48,\"ZCode stats\")(window.close)");
    } catch { }
    Environment.Exit(1);
  }

  public static void Show() { ShowWindow(_hwnd, 8 /*SW_SHOWNA*/); }
  public static void Hide() { ShowWindow(_hwnd, 0); }

  // ---- immediate follow: move INSIDE the WinEvent callback (frame-synced with the
  //      ZCode window drag; WINEVENT_OUTOFCONTEXT callbacks run on this thread's
  //      message pump, so SetWindowPos here is safe and adds zero timer latency) ----
  [StructLayout(LayoutKind.Sequential)]
  private struct ZRECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll", EntryPoint = "GetWindowRect")] private static extern bool GetWindowRect2(IntPtr h, out ZRECT r);
  [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")] private static extern uint GetWindowThreadProcessId2(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int DwmGetWindowAttribute2(IntPtr h, int attr, out ZRECT r, int cb);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)]
  private delegate void FollowProc(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
  [DllImport("user32.dll", EntryPoint = "SetWinEventHook")] private static extern IntPtr SetWinEventHook2(uint min, uint max, IntPtr mod, FollowProc proc, uint pid, uint idObject, uint flags);
  [DllImport("user32.dll", EntryPoint = "UnhookWinEvent")] private static extern bool UnhookWinEvent2(IntPtr h);
  private static IntPtr _zHwnd;
  private static int _offX, _offY, _fwW, _fwH;
  private static FollowProc _followProc;
  private static IntPtr _locHook;

  // v0.12:跟随参数统一为「窗口相对偏移」——基线常量与 CDP 实时几何都由 PS1 换算成偏移喂入,
  // 窗口拖动回调按最新偏移贴住,高度感知不因窗口移动而丢失
  public static void SetFollowParams(IntPtr z, int offX, int offY, int w, int h) {
    _zHwnd = z; _offX = offX; _offY = offY; _fwW = w; _fwH = h;
  }
  public static void HookFollowNow() {
    if (_locHook != IntPtr.Zero) { try { UnhookWinEvent2(_locHook); } catch { } _locHook = IntPtr.Zero; }
    if (_zHwnd == IntPtr.Zero || _zHwnd == _hwnd) return;
    uint pid; GetWindowThreadProcessId2(_zHwnd, out pid);
    _followProc = OnLocChange;
    _locHook = SetWinEventHook2(0x800B /*EVENT_OBJECT_LOCATIONCHANGE*/, 0x800B, IntPtr.Zero, _followProc, pid, 0, 0);
  }
  public static void UnhookFollowNow() {
    if (_locHook != IntPtr.Zero) { try { UnhookWinEvent2(_locHook); } catch { } _locHook = IntPtr.Zero; }
    _followProc = null;
  }
  // 可视帧底边(DWM ExtendedFrameBounds):最大化/普通状态一致——窗口矩形含不可见
  // 缩放边框(最大化超出可视区 ~12px,普通状态内缩 ~8px),拿它当锚会随缩放状态漂移
  public static int VisibleBottom() {
    try {
      ZRECT f;
      if (DwmGetWindowAttribute2(_zHwnd, 9 /*DWMWA_EXTENDED_FRAME_BOUNDS*/, out f, System.Runtime.InteropServices.Marshal.SizeOf(typeof(ZRECT))) == 0
          && f.Bottom > f.Top && f.Bottom < 100000) return f.Bottom;
    } catch { }
    ZRECT r; GetWindowRect2(_zHwnd, out r);
    return r.Bottom;
  }
  private static void OnLocChange(IntPtr hHook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
    try {
      if (_zHwnd == IntPtr.Zero || _hwnd == IntPtr.Zero) return;
      if (hwnd != _zHwnd) return;   // v0.12.3:只认主窗口自身;侧栏切换重排会触发其它子 HWND 的
                                    // LOCATIONCHANGE,不滤则按旧烘焙偏移瞬移 = 抖动
      ZRECT r; GetWindowRect2(_zHwnd, out r);
      int x = r.Left + _offX;                          // v0.12 统一偏移(基线/CDP 同源)
      int y = VisibleBottom() - _offY - _fwH;
      // WinEvent 回调里禁止同步消息类 API(重入会破坏内部状态)→ 只投递,
      // 移动在自家 WndProc 里做;投递消息在下一轮泵即处理,仍是帧级
      PostMessageW(_hwnd, WM_APP_FOLLOW, (IntPtr)x, (IntPtr)y);
    } catch { }
  }
  private const uint WM_APP_FOLLOW = 0x8064;
  [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);

  public static void MoveTo(int x, int y) {
    SetWindowPos(_hwnd, IntPtr.Zero, x, y, 0, 0, 0x0015);
    var c = _controller;
    if (c != null) { try { c.NotifyParentWindowPositionChanged(); } catch { } }   // re-rasterize on cross-DPI move
  }
  public static void Resize(int w, int h) {
    SetWindowPos(_hwnd, IntPtr.Zero, 0, 0, w, h, 0x0016);   // NOMOVE|NOZORDER|NOACTIVATE
  }
  public static void Destroy() { if (_hwnd != IntPtr.Zero) { DestroyWindowQuiet(); } }
  public static void Shutdown() { var c = _controller; if (c != null && !_destroyed) { try { c.Close(); } catch { } } }
  private static void DestroyWindowQuiet() { try { SendMessageW(_hwnd, 0x0012 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero); } catch { } }
  [DllImport("user32.dll")] private static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);

  private static IntPtr WndProcImpl(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
    switch (msg) {
      case WM_NCHITTEST: return (IntPtr)HTTRANSPARENT;   // whole-window pass-through: text only, never blocks composer
      case WM_HOTKEY: if (OnHotKey != null) OnHotKey(); return IntPtr.Zero;
      case WM_APP_FOLLOW:
        SetWindowPos(_hwnd, IntPtr.Zero, wp.ToInt32(), lp.ToInt32(), 0, 0, 0x0015);
        return IntPtr.Zero;
      case WM_SIZE:
        if (_controller != null) {
          try { _controller.Bounds = new Rectangle(0, 0, (short)((int)lp & 0xFFFF), (short)(((int)lp >> 16) & 0xFFFF)); } catch { }
        }
        return IntPtr.Zero;
      case WM_ERASEBKGND: return (IntPtr)1;
      case 0x0012: RawLog("wm_close"); break;   // 排查:谁在关窗;break 走默认销毁
      case WM_DESTROY:
        _destroyed = true;
        RawLog("wm_destroy");
        PostQuitMessage(0); return IntPtr.Zero;
    }
    return DefWindowProc(h, msg, wp, lp);
  }
}
'@ -ReferencedAssemblies @('System.dll', ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | Select-Object -First 1).Location, ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'WindowsBase' } | Select-Object -First 1).Location, ($asmCore.Location))
[StatsHost]::Log = { param($s) WLog $s }
[StatsHost]::DbgPath = $dbgLog

# 页面加载:file:// 会被 WebView2 磁盘缓存 → 复制到随机临时路径
$script:pageFile = Join-Path $env:TEMP ('stats-widget-page-{0}.html' -f [Guid]::NewGuid().ToString('N'))
try { Copy-Item -LiteralPath $htmlFile -Destination $script:pageFile -Force } catch { $script:pageFile = $htmlFile }

# ---- 初始兜底位置(主屏右下;吸附成功后被 Position-Follow 覆盖) ----
$screenW = [StatsNative.Win]::GetSystemMetrics(0)
$screenH = [StatsNative.Win]::GetSystemMetrics(1)
$initX = $screenW - $script:winW - 40
$initY = $screenH - $script:winH - 80

WLog ('boot: init ' + $initX + ',' + $initY + ' ' + $script:winW + 'x' + $script:winH + ' cx=' + $script:centerXOffset + ' halfW=' + $script:composerHalfWidthPx + ' compH=' + $script:composerHeightPx + ' showMax=' + $script:showMaxComposerPx + ' v0.12-B+E1')
[StatsHost]::Init($initX, $initY, $script:winW, $script:winH, (Join-Path $dotZcode 'stats-widget-wv2'), ('file:///' + ($script:pageFile -replace '\\', '/')))
# Ctrl+Alt+S:显隐开关(MOD_ALT 0x1 | MOD_CONTROL 0x2,VK_S 0x53)
[void][StatsNative.Win]::RegisterHotKey([StatsHost]::Handle, 0xB002, 0x3, 0x53)

[StatsHost]::OnHotKey = {
  if ([StatsHost]::Visible) { [StatsHost]::Hide() } else { [StatsHost]::Show() }
}

# ---- 页面消息:回执日志(主题应用等) ----
[StatsHost]::OnMessage = {
  param($msg)
  if ($msg -like '*theme*') { WLog ('page-ack: ' + $msg) }
}

# =====================================================================
# 窗口跟随 ZCode(物理像素域 + WinEvent + 33ms 节流;与 butler 同源)
# =====================================================================
$script:zcodePid = 0
$script:zcodeHwnd = [IntPtr]::Zero
$script:followHooks = @()
$script:winEventProc = $null
$script:rescanBusy = $false
# v0.12 CDP 探锚通道(anchor-probe.mjs 原子写;陈旧 >2s 视为不可用,落基线)
$script:anchorFile = Join-Path $dotZcode 'stats-widget-anchor.json'
$script:lastAnchorWrite = [datetime]::MinValue
$script:lastAnchorCheck = (Get-Date).AddSeconds(-1)
$script:cdpShown = $true
$script:anchorWasPresent = $false
$script:cdpActive = $false
$script:lastTheme = ''
$script:tgX = 0; $script:tgY = 0; $script:tgVisible = $true
$script:curX = $null; $script:curY = $null
$script:lastZL = [int]::MinValue; $script:lastZT = [int]::MinValue
$script:hadCdpOnce = $false; $script:lastGoodX = 0; $script:lastGoodY = 0; $script:lastCdpGood = [datetime]::MinValue

function Find-ZcodeWindow([int]$targetPid) {
  $best = [IntPtr]::Zero; $bestArea = 0
  foreach ($candidatePid in @($targetPid) + @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) {
    if ($candidatePid -le 0) { continue }
    $p = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
    $r = New-Object StatsNative.Win+RECT
    [StatsNative.Win]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt $bestArea -and $area -gt 200000) { $best = $p.MainWindowHandle; $bestArea = $area }
  }
  return $best
}
function Get-VisibleBottom {
  # DWM 可视帧底边:最大化/普通状态一致(窗口矩形含不可见缩放边框会随状态漂移)
  $f = New-Object StatsNative.Win+RECT
  try {
    $hr = [StatsNative.Win]::DwmGetWindowAttribute($script:zcodeHwnd, 9, [ref]$f, [System.Runtime.InteropServices.Marshal]::SizeOf($f))
    if ($hr -eq 0 -and $f.Bottom -gt $f.Top -and $f.Bottom -lt 100000) { return $f.Bottom }
  } catch { }
  $r = New-Object StatsNative.Win+RECT
  [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  return $r.Bottom
}
function Get-TargetPosition {
  # v0.12.4 目标位置 + 可见性:锚文件三态——
  #   ① fresh + geometry → 跟随(CDP 分支);② fresh + none → 隐藏(输入框不在:设置/搜索/插件市场页或被覆盖);
  #   ③ 缺失/陈旧 → 通道失联:10s 内保持原位,超时落基线常量(v0.11 公式)
  $useCdp = $false; $none = $false; $ar = 0.0; $at = 0.0; $ah = 0.0
  try {
    if (Test-Path $script:anchorFile) {
      $fi = Get-Item $script:anchorFile -ErrorAction SilentlyContinue
      if ($fi -and ((New-TimeSpan $fi.LastWriteTime (Get-Date)).TotalMilliseconds -lt 2000)) {
        $a = Get-Content $script:anchorFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($a -and $a.mode -eq 'phys') {
          if ($a.none) { $none = $true; $useCdp = $true }
          elseif ($a.right -gt 100 -and $a.height -gt 40) { $ar = [double]$a.right; $at = [double]$a.top; $ah = [double]$a.height; $useCdp = $true }
        }
      }
    }
  } catch { }
  if ($useCdp) {
    if ($none) {
      # ①a 探针 UIA 劣化窗口(载荷带 n:0,composer 其实在)→ 保持原位,不隐藏不滑走
      if ($a.n -eq 0) {
        $script:cdpActive = $true
        if (-not $script:hadCdpOnce) { return @{ visible = $false } }   # 预热期就劣化:尚无几何可保持 → 藏
        return @{ x = $script:lastGoodX; y = $script:lastGoodY; visible = $script:cdpShown }
      }
      # ①b 真 none(设置/搜索/自动化/插件市场等页面,输入框不在或被覆盖)→ 隐藏
      $script:cdpActive = $true
      return @{ visible = $false }
    }
    $x = [int]$ar - $script:winW                                  # 右缘贴 composer 右缘
    $x = [int]$ar - $script:winW                                  # 右缘贴 composer 右缘
    $y = [int]$at - $script:gapAbovePx - $script:winH             # 底缘贴 composer 上沿 - gap
    # 出现时机状态机:超高隐藏(滞回 24px),回落恢复
    if ($script:cdpShown) {
      if ($ah -gt ($script:showMaxComposerPx + 24)) { $script:cdpShown = $false; WLog ('cdp hide: composerH=' + $ah) }
    } elseif ($ah -le $script:showMaxComposerPx) { $script:cdpShown = $true; WLog ('cdp show: composerH=' + $ah) }
    # v0.12.3 主题推送:探针采样编辑区亮度 → 页面切浅/深配色
    if ($a.theme -ne $script:lastTheme -and ($a.theme -eq 'light' -or $a.theme -eq 'dark')) {
      $script:lastTheme = $a.theme
      WLog ('theme push: ' + $a.theme)
      try { [StatsHost]::PostJson('{"type":"theme","v":"' + $a.theme + '"}') } catch { WLog ('theme push THREW ' + $_.Exception.Message) }
    }
    $script:cdpActive = $true
    $script:hadCdpOnce = $true; $script:lastGoodX = $x; $script:lastGoodY = $y; $script:lastCdpGood = Get-Date
    return @{ x = $x; y = $y; visible = $script:cdpShown }
  }
  $script:cdpActive = $false
  # 锚暂断(探针自愈接力/预热,通常 1-2s):10s 内有过 CDP 几何 → 保持原位,输入框没动就不滑走
  if ($script:hadCdpOnce -and ((Get-Date) - $script:lastCdpGood).TotalMilliseconds -lt 10000) {
    return @{ x = $script:lastGoodX; y = $script:lastGoodY; visible = $script:cdpShown }
  }
  $r = New-Object StatsNative.Win+RECT
  [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $x = $r.Left + [int](($r.Right - $r.Left) / 2) + $script:centerXOffset + $script:composerHalfWidthPx - $script:winW
  $y = (Get-VisibleBottom) - $script:bandFromBottom - $script:composerHeightPx - $script:gapAbovePx - $script:winH
  return @{ x = $x; y = $y; visible = $true }
}
function Update-FollowParamsXY([int]$x, [int]$y) {
  # C# 帧级跟随吃「窗口相对偏移」:滑翔时同步烘焙"当前位",OnLocChange 抢拍也落在滑翔路径上
  $r = New-Object StatsNative.Win+RECT
  [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$r) | Out-Null
  $offY = (Get-VisibleBottom) - $y - $script:winH
  try { [StatsHost]::SetFollowParams($script:zcodeHwnd, ($x - $r.Left), $offY, $script:winW, $script:winH) } catch { }
}
function Position-Follow {
  if (([int64]$script:zcodeHwnd) -eq 0) { return }
  if (-not [StatsNative.Win]::IsWindow($script:zcodeHwnd)) { return }
  $t = Get-TargetPosition
  $script:tgX = $t.x; $script:tgY = $t.y; $script:tgVisible = $t.visible
  if (-not $t.visible) { if ([StatsHost]::Visible) { [StatsHost]::Hide() }; return }
  if (-not [StatsHost]::Visible) {
    [StatsHost]::Show()
    # 从隐藏恢复:直接吸附目标位,不做滑翔;烘焙目标偏移供 C# 帧级跟随
    $script:curX = $t.x; $script:curY = $t.y
    Update-FollowParamsXY $t.x $t.y
    return
  }
  # 常规态:只烘焙滑翔当前位置(终值偏移由滑翔收敛后烘焙),否则 OnLocChange 会按
  # 终值瞬移、滑翔又拉回 —— 侧栏切换时的抖动根源
  if ($script:curX -eq $null) {
    # 首个目标:必须落位(滑翔块看到 cur==tg 会以为已到位而永不移动)
    $script:curX = $t.x; $script:curY = $t.y
    [StatsHost]::MoveTo($t.x, $t.y)
  }
  Update-FollowParamsXY $script:curX $script:curY
}
function Hook-FollowEvents {
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  if ($script:zcodePid -eq 0 -or ([int64]$script:zcodeHwnd) -eq 0) { return }
  $proc = [StatsNative.Win+WinEventProc]{ param($hHook, $evt, $hwnd, $idObject, $idChild, $thread, $time) [StatsState]::FollowDirty = 1 }
  $script:winEventProc = $proc
  # LOCATIONCHANGE 已由 C# 侧帧级回调处理;PS 钩子只管 显隐/最小化 同步
  $script:followHooks += [StatsNative.Win]::SetWinEventHook($EVENT_MINIMIZESTART, $EVENT_MINIMIZEEND, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  $script:followHooks += [StatsNative.Win]::SetWinEventHook($EVENT_OBJECT_SHOW, $EVENT_OBJECT_HIDE, [IntPtr]::Zero, $proc, [uint32]$script:zcodePid, $OBJID_WINDOW, $WINEVENT_OUTOFCONTEXT)
  [StatsState]::FollowDirty = 1
}
function Attach-Zcode {
  $p = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return $false }
  $script:zcodePid = $p.Id
  $hwnd = Find-ZcodeWindow $script:zcodePid
  if (([int64]$hwnd) -eq 0) { return $false }
  $script:zcodeHwnd = $hwnd
  Hook-FollowEvents
  Position-Follow
  try { [void][StatsNative.Win]::SetOwner(([StatsHost]::Handle), $hwnd) } catch { }
  # 帧级跟随:LOCATIONCHANGE 回调里直接 SetWindowPos(C# 侧,零定时器延迟);
  # 偏移量由 Position-Follow → Update-FollowParams 统一喂入(基线/CDP 同源)
  try { [StatsHost]::HookFollowNow() } catch { WLog ('hook-follow THREW: ' + $_.Exception.Message) }
  return $true
}
function Detach-Zcode {
  try { [StatsHost]::UnhookFollowNow() } catch { }
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  $script:followHooks = @()
  try { [void][StatsNative.Win]::SetOwner(([StatsHost]::Handle), [IntPtr]::Zero) } catch { }
  $script:zcodeHwnd = [IntPtr]::Zero
  $script:zcodePid = 0
}
function Test-ZcodeAlive {
  if (@(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  if ($script:zcodePid -gt 0) { return [bool](Get-Process -Id $script:zcodePid -ErrorAction SilentlyContinue) }
  return $false
}

function Stop-Widget([string]$reason) {
  WLog ('exit: ' + $reason)
  try {
    if ([StatsNative.Win]::IsWindow(([StatsHost]::Handle))) {
      [StatsHost]::Shutdown()
      WLog 'exit: shutdown done'
    } else { WLog 'exit: window dead, skip shutdown' }
  } catch { WLog ('exit: shutdown THREW ' + $_.Exception.Message) }
  try { [StatsHost]::Destroy() } catch { }
  try { [void][StatsNative.Win]::UnregisterHotKey([StatsHost]::Handle, 0xB002) } catch { }
  foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
  if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
  try { $mutex.ReleaseMutex() | Out-Null } catch { }
  WLog 'exit: cleanup done, terminate'
  [void][StatsNative.Win]::TerminateProcess([StatsNative.Win]::GetCurrentProcess(), 0)
  [Environment]::Exit(0)
}

$EVENT_MINIMIZESTART = 0x0016; $EVENT_MINIMIZEEND = 0x0017; $EVENT_LOCATIONCHANGE = 0x800B
$EVENT_OBJECT_SHOW = 0x8002; $EVENT_OBJECT_HIDE = 0x8003
$WINEVENT_OUTOFCONTEXT = 0x0000; $OBJID_WINDOW = 0

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$followTimer.Add_Tick({
  try {
    # v0.12:锚文件监听(100ms 一次 stat)。三类变化都要置脏:
    #   ① mtime 变了(新 rect);② 文件消失(探锚死/清场 → 回落基线);③ CDP 激活中但 >2s 无心跳(陈旧 → 回落基线)
    if (((Get-Date) - $script:lastAnchorCheck).TotalMilliseconds -ge 100) {
      $script:lastAnchorCheck = Get-Date
      try {
        $present = Test-Path $script:anchorFile
        if ($present) {
          $lw = (Get-Item $script:anchorFile -ErrorAction SilentlyContinue).LastWriteTimeUtc
          if ($lw -and $lw -ne $script:lastAnchorWrite) { $script:lastAnchorWrite = $lw; [StatsState]::FollowDirty = 1 }
          elseif ($script:cdpActive -and $lw -and ((New-TimeSpan $lw (Get-Date).ToUniversalTime()).TotalMilliseconds -gt 2000)) { [StatsState]::FollowDirty = 1 }
        } elseif ($script:anchorWasPresent) {
          $script:lastAnchorWrite = [datetime]::MinValue
          [StatsState]::FollowDirty = 1
        }
        $script:anchorWasPresent = $present
      } catch { }
    }
    if ([StatsState]::FollowDirty -eq 1) {
      [StatsState]::FollowDirty = 0
      if (([int64]$script:zcodeHwnd) -ne 0 -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)) {
        if ([StatsNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [StatsNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
          if ([StatsHost]::Visible) { [StatsHost]::Hide() }
        }
        else {
          Position-Follow   # 更新目标/可见性并喂 C# 偏移;移动由下方滑翔块执行(v0.12.3)
        }
      }
    }
    # v0.12.3 滑翔:每个 tick 向目标走 45%,2px 内吸附——布局切换从"闪现"变 ~200ms 滑翔。
    # 窗口被拖动/缩放时跳过(C# 帧级偏移已贴住,且本 tick 目标可能尚未刷新),并同步吸附。
    if (([int64]$script:zcodeHwnd) -ne 0 -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)) {
      $zr = New-Object StatsNative.Win+RECT
      [StatsNative.Win]::GetWindowRect($script:zcodeHwnd, [ref]$zr) | Out-Null
      $windowMoved = ($zr.Left -ne $script:lastZL -or $zr.Top -ne $script:lastZT)
      $script:lastZL = $zr.Left; $script:lastZT = $zr.Top
      if ($windowMoved) {
        # 同步 cur 到浮标实际矩形(而非目标):窗口被拖动时 C# 已贴住,cur 若同步到
        # 未刷新的目标会让滑翔误判"已到位"而卡死
        $wr = New-Object StatsNative.Win+RECT
        [StatsNative.Win]::GetWindowRect([StatsHost]::Handle, [ref]$wr) | Out-Null
        $script:curX = $wr.Left; $script:curY = $wr.Top
      }
      if ($script:tgVisible -and [StatsHost]::Visible -and -not $windowMoved) {
        if ($script:curX -eq $null) { $script:curX = $script:tgX; $script:curY = $script:tgY }
        $dx = $script:tgX - $script:curX; $dy = $script:tgY - $script:curY
        if ([Math]::Abs($dx) -lt 2 -and [Math]::Abs($dy) -lt 2) {
          if ($dx -ne 0 -or $dy -ne 0) {
            $script:curX = $script:tgX; $script:curY = $script:tgY
            [StatsHost]::MoveTo($script:curX, $script:curY)
            Update-FollowParamsXY $script:curX $script:curY
          }
        } else {
          $script:curX += [int][Math]::Round($dx * 0.45); $script:curY += [int][Math]::Round($dy * 0.45)
          [StatsHost]::MoveTo($script:curX, $script:curY)
          Update-FollowParamsXY $script:curX $script:curY   # 抢拍落在滑翔路径上,不瞬移
        }
      }
    }
  } catch { }
})
$followTimer.Start()

# 生死绑定:ZCode 亡则退、脚本删则退、句柄丢先重吸附
$rescanTimer = New-Object System.Windows.Threading.DispatcherTimer
$rescanTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$rescanTimer.Add_Tick({
  if ($script:rescanBusy) { return }
  $script:rescanBusy = $true
  try {
    if ($PSCommandPath -and -not (Test-Path $PSCommandPath)) { Stop-Widget 'script-deleted' }
    if (-not (Test-ZcodeAlive)) { Stop-Widget 'zcode-dead' }
    if (-not [StatsNative.Win]::IsWindow(([StatsHost]::Handle))) { Stop-Widget 'widget-hwnd-dead' }
    $alive = (([int64]$script:zcodeHwnd) -ne 0) -and [StatsNative.Win]::IsWindow($script:zcodeHwnd)
    if (-not $alive) {
      Detach-Zcode
      if (Attach-Zcode) { if (-not [StatsHost]::Visible) { [StatsHost]::Show() } }
      elseif ([StatsHost]::Visible) { [StatsHost]::Hide() }
    }
    elseif ([StatsNative.Win]::IsIconic($script:zcodeHwnd) -or (-not [StatsNative.Win]::IsWindowVisible($script:zcodeHwnd))) {
      if ([StatsHost]::Visible) { [StatsHost]::Hide() }
    }
  } finally { $script:rescanBusy = $false }
})
$rescanTimer.Start()

# v0.12:CDP 探锚(独立 node 进程,经 vbs 逃 Job;端口够不到 60s 自退,宿主下次启动再拉)
$probeVbs = Join-Path $PSScriptRoot 'anchor-probe-launch.vbs'
if (Test-Path $probeVbs) { try { Start-Process wscript.exe -ArgumentList ('"' + $probeVbs + '"') -WindowStyle Hidden } catch { WLog ('probe-launch THREW ' + $_.Exception.Message) } }

# 进程退出兜底(正路 = Stop-Widget 显式清场)
[AppDomain]::CurrentDomain.add_ProcessExit({
  try {
    WLogRaw 'processexit: begin(fallback)'
    [StatsHost]::Shutdown()
    try { [void][StatsNative.Win]::UnregisterHotKey([StatsHost]::Handle, 0xB002) } catch { }
    foreach ($h in $script:followHooks) { try { [StatsNative.Win]::UnhookWinEvent($h) | Out-Null } catch { } }
    if ($script:pageFile -and (Test-Path $script:pageFile)) { try { Remove-Item -LiteralPath $script:pageFile -ErrorAction SilentlyContinue } catch { } }
    $mutex.ReleaseMutex() | Out-Null
  } catch { }
})

if (-not $NoShowIfExists) { [StatsHost]::Show() }
[void](Attach-Zcode)
[System.Windows.Threading.Dispatcher]::Run()
Stop-Widget 'dispatcher-end'
