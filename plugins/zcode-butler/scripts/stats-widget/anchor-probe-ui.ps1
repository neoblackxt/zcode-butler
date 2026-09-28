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
# debounce: 20 采滑动窗口 ≥16 一致才切 + 切换后 5s 驻留(打字/光标/选区压采样点的瞬态被滤掉)
$script:committedTheme = 'dark'
$script:themeWin = New-Object System.Collections.Queue
$script:lastThemeSwitch = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
function Commit-Theme([string]$sampled) {
  $script:themeWin.Enqueue($sampled)
  while ($script:themeWin.Count -gt 20) { [void]$script:themeWin.Dequeue() }
  $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  if ($now - $script:lastThemeSwitch -lt 5000) { return $script:committedTheme }
  $light = 0
  foreach ($t in $script:themeWin) { if ($t -eq 'light') { $light++ } }
  $new = $script:committedTheme
  if ($script:committedTheme -eq 'dark' -and $light -ge 16) { $new = 'light' }
  if ($script:committedTheme -eq 'light' -and ($script:themeWin.Count - $light) -ge 16) { $new = 'dark' }
  if ($new -ne $script:committedTheme) { $script:committedTheme = $new; $script:lastThemeSwitch = $now }
  return $script:committedTheme
}

$classCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ClassNameProperty, $editorClass)
$btnCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$imgCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Image)
$script:misses = 0
$script:tick = 0
$script:chipTop = $null

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
      # v0.12.4:附件行(topContent)在 editor 上方,editor 锚看不到会叠进行内。
      # 每 5 轮一次 Image 带状扫描(行内 [editor.top-320, editor.top-24] × form 列宽),
      # 命中则 form 顶 = chips 顶 − 21(胶囊缩略图必然是 Image 角色)。
      $script:tick++
      if (($script:tick % 5) -eq 1 -and $root) {
        try {
          $imgs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $imgCond)
          $chipTop = 1e9
          foreach ($im in $imgs) {
            try {
              $r = $im.Current.BoundingRectangle
              if ($r.Y -gt ($best.Y - 320) -and $r.Y -lt ($best.Y - 24) -and $r.X -gt ($best.X - 40) -and ($r.X + $r.Width) -lt ($best.X + $best.Width + 40) -and $r.Y -lt $chipTop) { $chipTop = $r.Y }
            } catch { }
          }
          if ($chipTop -lt 1e8) { $script:chipTop = $chipTop } else { $script:chipTop = $null }
        } catch { }
      }
      $formTopSrc = $best.Y
      if ($script:chipTop -ne $null -and $script:chipTop -lt $best.Y - 10) { $formTopSrc = $script:chipTop }
      Emit ($best.X + $best.Width + 21) ($formTopSrc - 21) (($best.Y + $best.Height + 91) - ($formTopSrc - 21)) (Commit-Theme (Get-Theme $best))
      $script:misses = 0
    } else {
      # Edit 掉出 a11y 树的三种情形:①回合运行 composer 非编辑态(正常,降级锚顶上);
      # ②非聊天页(设置/搜索/插件市场,无 composer)→ none → 浮标隐藏;③UIA 劣化整树空 → 计数自愈
      $btns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
      $btnCount = -1
      try { $btnCount = $btns.Count } catch { }
      if ($btnCount -le 0) {
        # ③ 树空/剪枝:计 miss,24 轮(~3s)释放锁自愈接力
        $script:misses++
        $eCnt = -1
        try { $eCnt = $edits.Count } catch { }
        $j = '{{"t":{0},"mode":"phys","none":true,"n":0,"e":{1}}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $eCnt
        Set-Content -Path $out -Value $j -Encoding Ascii
        if ($script:misses -ge 24) {
          try { $script:lockStream.Close() } catch { }
          Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -WindowStyle Hidden
          exit 0
        }
      } else {
        # 门槛:聊天页签名 = composer 工具条「切换模式」按钮在(名字随 UI 语言,中文环境稳定)
        $nameCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '切换模式')
        $andCond = New-Object System.Windows.Automation.AndCondition($btnCond, $nameCond)
        $sig = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $andCond)
        if (-not $sig) {
          $j = '{{"t":{0},"mode":"phys","none":true}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
          Set-Content -Path $out -Value $j -Encoding Ascii
        } else {
          # 降级锚:工具条最右 Button 右缘+21 = form 右缘;高度按运行期恒 1 行 182
          $zr = Get-ZCodeRect
          $bandTop = $zr.Bottom - 450
          $minX = $zr.Left + [int]($zr.Width / 2) - 100
          $fb = $null; $fbRight = -1.0
          foreach ($b in $btns) {
            try {
              $r = $b.Current.BoundingRectangle
              if ($r.Y -gt $bandTop -and $r.X -gt $minX -and ($r.X + $r.Width) -gt $fbRight -and $r.Width -lt 400) { $fb = $r; $fbRight = $r.X + $r.Width }
            } catch { }
          }
          if ($fb) {
            Emit ($fbRight + 21) ($fb.Y + $fb.Height + 21 - 182) 182 (Commit-Theme (Get-Theme $fb))
          } else {
            $j = '{{"t":{0},"mode":"phys","none":true}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            Set-Content -Path $out -Value $j -Encoding Ascii
          }
        }
      }
    }
  } catch { }
  Start-Sleep -Milliseconds 120
}
