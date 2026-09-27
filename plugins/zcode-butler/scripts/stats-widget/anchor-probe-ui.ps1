# anchor-probe-ui.ps1 (v0.12.2): UIA-based composer geometry probe.
# Why UIA: Electron (ZCode packaged) silently drops --remote-debugging-port even with
# explicit --user-data-dir (verified 2026-09-28: main pid has switches, zero listeners).
# Chromium auto-enables web accessibility on UIA queries (WM_GETOBJECT), so the composer
# contenteditable is exposed as an Edit element with its exact Tailwind ClassName.
# Output contract: ~/.zcode/stats-widget-anchor.json
#   {"t":ms,"mode":"phys","right":R,"top":T,"height":H,"theme":"dark"|"light"}
#   R/T/H = composer FORM approx in PHYSICAL screen px:
#   right = editor.right + 21 (12css padding), top = editor.top - 21,
#   height = editor.height + 111 (182 one-line form - 71 one-line editor, calibrated @1.75dpr).
#   theme = sampled editor background luminance; host pushes it to the page via PostJson.
# Loop 120ms; exits when ZCode process is gone. ASCII-only (PS5.1 no-BOM safe).
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class ProbeNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
[ProbeNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$dot = Join-Path $env:USERPROFILE '.zcode'
$out = Join-Path $dot 'stats-widget-anchor.json'
$lock = Join-Path $dot 'stats-widget-anchor-ui.lock'
$editorClass = 'min-h-10 max-h-40 overflow-y-auto text-ui-base leading-5 text-foreground outline-none'
$EDITOR_TO_FORM = 111   # one-line form height 182 - one-line editor height 71

# ---- single instance: exclusive held handle (OS releases it if this process dies) ----
$lock = Join-Path $dot 'stats-widget-anchor-ui.lock'
$script:lockStream = $null
try {
  # FileShare.None:第二个实例 Open 会直接失败 → 退出。进程死亡 → 句柄自动关闭 → 锁自释放。
  $script:lockStream = [System.IO.File]::Open($lock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
  exit 0   # 已有实例在跑
}
try { $script:lockStream.SetLength(0) } catch { }
try { [System.IO.File]::WriteAllText($lock, "pid=$PID", [System.Text.Encoding]::ASCII) } catch { }

# ZCode 消失超过 10s → 释放锁退场(下次宿主启动会重新拉起);
# 否则常驻等新 ZCode(自愈接力/重启场景下,老探针可直接服务新实例)
$script:lastZcodeSeen = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

function Get-ZCodeHwnd {
  $p = Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { return $p.MainWindowHandle }
  return [IntPtr]::Zero
}

function Emit([double]$right, [double]$top, [double]$height, [string]$theme) {
  # single writer (lock above): direct write, no tmp/rename race; widget tolerates a torn read
  $j = '{{"t":{0},"mode":"phys","right":{1},"top":{2},"height":{3},"theme":"{4}"}}' -f `
    [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), [math]::Round($right, 0), [math]::Round($top, 0), [math]::Round($height, 0), $theme
  Set-Content -Path $out -Value $j -Encoding Ascii
}
function EmitNone {
  $j = '{{"t":{0},"mode":"phys","none":true}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  Set-Content -Path $out -Value $j -Encoding Ascii
}

# theme sample: median luminance of 3 px in the editor's bottom/right padding zones.
# Points deliberately avoid the first text line (bright glyphs on dark bg would read as "light").
$script:sampleBmp = New-Object System.Drawing.Bitmap(1, 1)
$script:sampleGfx = [System.Drawing.Graphics]::FromImage($script:sampleBmp)
function Get-ThemeAt([double]$px, [double]$py) {
  try {
    $script:sampleGfx.CopyFromScreen([int]$px, [int]$py, 0, 0, (New-Object System.Drawing.Size(1, 1)))
    $c = $script:sampleBmp.GetPixel(0, 0)
    return ($c.R * 3 + $c.G * 6 + $c.B) / 10
  } catch { return -1 }
}
function Get-Theme($r) {
  # untyped param: $r is System.Windows.Automation.Rect; a Drawing.RectangleF constraint
  # would throw on binding (SilentlyContinue swallows it) and the probe would never emit.
  $lums = @(
    (Get-ThemeAt ($r.X + 25) ($r.Y + $r.Height - 8)),
    (Get-ThemeAt ($r.X + $r.Width - 25) ($r.Y + $r.Height - 8)),
    (Get-ThemeAt ($r.X + $r.Width - 25) ($r.Y + $r.Height / 2))
  )
  $valid = $lums | Where-Object { $_ -ge 0 } | Sort-Object
  if (-not $valid -or $valid.Count -eq 0) { return $script:committedTheme }
  $med = $valid[[int][math]::Floor($valid.Count / 2)]
  return $(if ($med -gt 140) { 'light' } else { 'dark' })
}
# debounce: only switch the committed theme after 3 consecutive identical classifications
$script:committedTheme = 'dark'
$script:pendingTheme = ''
$script:pendingCount = 0
function Commit-Theme([string]$sampled) {
  if ($sampled -eq $script:committedTheme) { $script:pendingTheme = ''; $script:pendingCount = 0; return $script:committedTheme }
  if ($sampled -eq $script:pendingTheme) { $script:pendingCount++ } else { $script:pendingTheme = $sampled; $script:pendingCount = 1 }
  if ($script:pendingCount -ge 3) {
    $script:committedTheme = $sampled
    $script:pendingTheme = ''; $script:pendingCount = 0
  }
  return $script:committedTheme
}

$classCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ClassNameProperty, $editorClass)
$btnCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$script:misses = 0

function Get-ZCodeRect {
  $zr = New-Object System.Drawing.Rectangle 0, 0, 0, 0
  try {
    $p = Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
      Add-Type @'
using System;using System.Runtime.InteropServices;
public class ProbeRect { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } }
'@ -ErrorAction SilentlyContinue
      $rr = New-Object ProbeRect+RECT
      [ProbeRect]::GetWindowRect($p.MainWindowHandle, [ref]$rr) | Out-Null
      $zr = New-Object System.Drawing.Rectangle($rr.Left, $rr.Top, ($rr.Right - $rr.Left), ($rr.Bottom - $rr.Top))
    }
  } catch { }
  return $zr
}

while ($true) {
  try {
    $hwnd = Get-ZCodeHwnd
    if ($hwnd -eq [IntPtr]::Zero) {
      # ZCode 不在:超过 10s 释放锁退场;10s 内回来则继续服务(免重启抖动)
      if ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $script:lastZcodeSeen -gt 10000) {
        try { $script:lockStream.Close() } catch { }
        exit 0
      }
      Start-Sleep -Milliseconds 1000
      continue
    }
    $script:lastZcodeSeen = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    # re-acquire root every cycle: cached AutomationElement goes stale across layout toggles
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    # pick the BOTTOM-MOST matching edit: message inline-editors share the same class,
    # and the main composer is always the lowest one in document order
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $classCond)
    $best = $null; $bestBottom = -1.0
    foreach ($e in $edits) {
      try {
        $r = $e.Current.BoundingRectangle
        if ($r.Width -gt 100 -and $r.Height -gt 30 -and $r.Bottom -gt $bestBottom) { $best = $r; $bestBottom = $r.Bottom }
      } catch { }
    }
    if ($best) {
      Emit ($best.X + $best.Width + 21) ($best.Y - 21) ($best.Height + $EDITOR_TO_FORM) (Commit-Theme (Get-Theme $best))
      $script:misses = 0
    } else {
      # 降级锚:回合运行中 composer 非编辑态,Edit 节点掉出 a11y 树(Edit 数=0 属正常)。
      # 改锚工具条最右 Button(发送/加入队列):右缘+21 = form 右缘,底缘+21 = form 底缘,
      # 高度按运行期恒 1 行 = 182。主题采样用按钮矩形(同在 composer 内)。
      $zr = Get-ZCodeRect
      $bandTop = $zr.Bottom - 450
      $minX = $zr.Left + [int]($zr.Width / 2) - 100
      $btns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
      $fb = $null; $fbRight = -1.0
      foreach ($b in $btns) {
        try {
          $r = $b.Current.BoundingRectangle
          if ($r.Y -gt $bandTop -and $r.X -gt $minX -and ($r.X + $r.Width) -gt $fbRight -and $r.Width -lt 400) { $fb = $r; $fbRight = $r.X + $r.Width }
        } catch { }
      }
      if ($fb -and $fbRight -gt $minX) {
        Emit ($fbRight + 21) ($fb.Y + $fb.Height + 21 - 182) 182 (Commit-Theme (Get-Theme $fb))
        $script:misses = 0
      } else {
        # a11y tree warm-up takes a few seconds after launch; hide until it shows up
        $script:misses++
        $n = -1
        try { $n = $edits.Count } catch { }
        $j = '{{"t":{0},"mode":"phys","none":true,"n":{1}}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $n
        Set-Content -Path $out -Value $j -Encoding Ascii
      # UIA 客户端连接会劣化(实测:老进程对活着的窗口返回空树,新进程立即可见)。
      # 连续 ~5s 找不到 editor → 释放锁、拉起干净的自己、退场(先放锁再退,继任才能接管)
      if ($script:misses -ge 40) {
        try { $script:lockStream.Close() } catch { }
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -WindowStyle Hidden
        exit 0
      }
      }
    }
  } catch { }
  Start-Sleep -Milliseconds 120
}
