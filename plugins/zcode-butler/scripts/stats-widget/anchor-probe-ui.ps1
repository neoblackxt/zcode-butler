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
# ---- v0.13d 实时字符流:每 2 轮读一次转录区 Document 文本长度(UIA 投影层,~240ms 节拍) ----
# 增量写 ~/.zcode/stats-widget-live.jsonl {"t":ms,"chars":delta},正增量 only(思考块完成后
# 折叠会产生负增量,是渲染事件不是输出,跳过)。供 metrics.mjs tail 喂 oc-tps 滑窗。
# 教训内置:每 tick 重取元素+pattern(缓存引用返回旧快照,调研4实测);轮换防无限增长。
$liveFile = Join-Path $dot 'stats-widget-live.jsonl'
$script:liveLen = -1
$script:tickLive = 0
$script:lastLiveT = 0
$script:bootMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$docCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
function Read-LiveText {
  # 让位:stdio wrapper(方案B)心跳新鲜时由它供数(字符级含思考),UIA 采样退避防双计
  $hb = Join-Path $dot 'stats-widget-live2hb.json'
  if ((Test-Path $hb) -and (((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds -lt 10)) { return }
  try {
    $doc = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $docCond)
    if (-not $doc) { Diag 'live: no Document'; return }
    $tp = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $len = ($tp.DocumentRange.GetText(-1)).Length
    if ($script:liveLen -ge 0 -and $len -ne $script:liveLen -and ($len - $script:liveLen) -gt 2000) { Diag ('live: bigjump +' + ($len - $script:liveLen)) }
    if ($script:liveLen -ge 0 -and $len -gt $script:liveLen) {
      $d = $len - $script:liveLen
      $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      $gapMs = $nowMs - $script:lastLiveT
      # 积压过滤:探针重启/空闲期后的整段历史跳变不进滑窗——间隔>3s 或隐含速率
      # >600字符/s(≈200tok/s,远超解码上限)都判为积压,只重置基线
      $implied = $d / [Math]::Max($gapMs, 240) * 1000
      if ($gapMs -le 3000 -and $implied -le 600) {
        $line = '{{"t":{0},"chars":{1}}}' -f $nowMs, $d
        try {
          if ((Test-Path $liveFile) -and ((Get-Item $liveFile).Length -gt 1MB)) {
            Move-Item -Path $liveFile -Destination ($liveFile + '.old') -Force
          }
          Add-Content -Path $liveFile -Value $line -Encoding Ascii
        } catch { }
      } else { Diag ('live: skip backlog d=' + $d + ' gap=' + $gapMs) }
      $script:lastLiveT = $nowMs
    }
    $script:liveLen = $len
  } catch { Diag ('live ERR ' + $_.Exception.Message) }
}
# ---- v0.13f 会话视图通道:每 ~2s(16 tick)扫侧栏选中条目 → 写当前会话标题到
# stats-widget-view.json {"t":ms,"name":"标题 相对时间"}(单写者直写,UTF-8 无 BOM)。
# metrics.mjs 查 db session.title 映射回会话并切换重建——补 session.resumed 的盲区:
# 切回"已驻留"会话时 app log 完全静默(2026-09-30 实测:切走有 resumed、切回零事件,
# 直到发首条消息),UIA 侧栏选中态(bg-selected 的 task-row)是唯一能看见
# "用户在看哪个会话"的通道。侧栏收起/当前行不可见 → 无条目 → 不写,metrics 保持
# 上次归属;非聊天页同理,显隐不受影响。
$viewFile = Join-Path $dot 'stats-widget-view.json'
$script:tickView = 0
$script:lastViewName = $null
$script:lastViewT = 0
function Write-View {
  try {
    $btns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    $name = $null
    foreach ($b in $btns) {
      try {
        $cls = $b.Current.ClassName
        if ($cls -and $cls.Contains('task-row') -and $cls.Contains('bg-selected')) { $name = $b.Current.Name; break }
      } catch { }
    }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    if ($name -and (($name -ne $script:lastViewName) -or ($now - $script:lastViewT -gt 30000))) {
      $script:lastViewName = $name
      $script:lastViewT = $now
      $j = '{{"t":{0},"name":{1}}}' -f $now, ($name | ConvertTo-Json)
      [System.IO.File]::WriteAllText($viewFile, $j, (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch { }
}

# ---- v0.12.5g:探针只报真值 + 身份判定,不做任何节流 ----
# 确认期/十字校验/源闩锁/none 去抖全部拆除:宿主状态机已用「flux 即隐藏、稳定才现身」
# 消化一切过渡态,探针侧任何"憋值"都只会推迟消失(v0.12.5f 实测消失慢 ~360ms 即憋旧值所致)。
# 保留的身份判定(offscreen/带外邻接/降级近带)防的是「系统性错值」——会稳定驻留的错,
# 不是过渡态的错,宿主稳定期滤不掉,必须在源头拒。
$script:lastEditorR = 0.0    # 最近一次主锚右缘:降级锚的参考列(右侧面板按钮排除用)
$diagFile = Join-Path $env:TEMP 'stats-probe-diag.log'
$script:diagLast = 0
function Diag([string]$s) {
  # 限频单行诊断:事后取证幽灵是「两个元素」还是「提供方级交替」
  $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  if ($now - $script:diagLast -lt 2000) { return }
  $script:diagLast = $now
  try { Add-Content -Path $diagFile -Value ('{0} {1}' -f $now, $s) } catch { }
}
# 底部带状区内最右小 Button = 工具条尾(发送/队列)。与 editor 元素独立:
# 既当降级锚,又当主锚大位移的十字校验源。
# v0.12.5b:右侧面板开着时,带内最右 Button 是面板按钮(实测 3808,离 composer 右缘
# ~920px)→ 盲取最右 = 锚飞到面板/十字校验永假。改为「参考右缘 ±300 近带」:工具条跟着
# composer 走必在近带内,面板按钮远在外;refR≤0(无参考)退回盲取最右(老行为)。
function Get-FallbackAnchor($btns, $refR) {
  $zr = Get-ZCodeRect
  $bandTop = $zr.Bottom - 450
  $minX = $zr.Left + [int]($zr.Width / 2) - 100
  $fb = $null; $fbRight = -1.0
  foreach ($b in $btns) {
    try {
      $r = $b.Current.BoundingRectangle
      if ($r.Y -gt $bandTop -and $r.X -gt $minX -and $r.Width -lt 400) {
        $bRight = $r.X + $r.Width
        if ($refR -gt 0 -and ([Math]::Abs($bRight + 21 - $refR) -gt 300)) { continue }
        if ($bRight -gt $fbRight) { $fb = $r; $fbRight = $bRight }
      }
    } catch { }
  }
  if ($fb) { return @{ r = $fb; right = $fbRight + 21; top = $fb.Y + $fb.Height + 21 - 182 } }
  return $null
}

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
  # v0.13d:5 分钟定时自愈接力——长驻 UIA 客户端的 TextPattern 路径会静默劣化(实测
  # 新鲜探针读文本正常、跑了 ~15 分钟后 live 沉默而几何锚仍活),定时换代保文本路径新鲜
  if ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $script:bootMs -gt 300000) {
    try { $script:lockStream.Close() } catch { }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -WindowStyle Hidden
    exit 0
  }
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
    $zw = Get-ZCodeRect
    $best = $null; $bestBottom = -1.0; $cands = 0
    foreach ($e in $edits) {
      try {
        # offscreen 过滤:隐藏/陈旧视图副本报 IsOffscreen=true;幽灵矩形的疑凶之一
        if ($e.Current.IsOffscreen) { continue }
        $r = $e.Current.BoundingRectangle
        if ($r.Width -gt 100 -and $r.Height -gt 30) {
          $cands++
          if ($cands -gt 1) { Diag ('multi-edit cand=' + $cands + ' rect=' + [int]$r.X + ',' + [int]$r.Y + ',' + [int]$r.Width + 'x' + [int]$r.Height) }
          if ($r.Bottom -gt $bestBottom) { $best = $r; $bestBottom = $r.Bottom }
        }
      } catch { }
    }
    # v0.12.5c 候选身份判定:垂直位置区分不了「转写区行内编辑器」(编辑旧消息,同类名)
    # 与「欢迎态居中输入框」(空任务 hero 布局,实测 rect y=926)——但工具条邻接可以:
    # 真 composer(底置/居中皆然)紧下方 ~250px 内必有「切换模式」按钮,行内编辑器没有。
    # 带内候选免校验(零开销);带外候选过邻接判定,不过 = 行内编辑器,按无 Edit 处理
    # (降级锚落在真工具条上,胶囊钉在底部 composer 位,不跳进转写区)。
    if ($best -and $zw.Bottom -gt 0 -and $best.Bottom -lt ($zw.Bottom - 600)) {
      $ok = $false
      try {
        $sigEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
          (New-Object System.Windows.Automation.AndCondition($btnCond,
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '切换模式')))))
        if ($sigEl) {
          $sr = $sigEl.Current.BoundingRectangle
          $ok = ($sr.Y -ge ($best.Bottom - 20)) -and ($sr.Y -le ($best.Bottom + 250)) -and `
                ($sr.X -ge ($best.X - 120)) -and ($sr.X -le ($best.X + $best.Width + 120))
        }
      } catch { }
      if (-not $ok) {
        Diag ('reject out-of-band edit rect=' + [int]$best.X + ',' + [int]$best.Y + ',' + [int]$best.Width + 'x' + [int]$best.Height)
        $best = $null
      }
    }
    if ($best) {
      # ============ 主锚(editor 几何,每轮立即上报) ============
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
      $script:lastEditorR = $best.X + $best.Width + 21
      $script:misses = 0
    } else {
      # ============ 本轮无 Edit ============
      # 三种情形:①回合运行 composer 非编辑态(正常,降级锚顶上);
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
          # v0.12.5f:真 none 立即上报(用户语义:无输入框直接消失;"确定位置再显示"由宿主稳定期负责)
          $j = '{{"t":{0},"mode":"phys","none":true}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
          Set-Content -Path $out -Value $j -Encoding Ascii
        } else {
          # 降级锚:工具条最右 Button 右缘+21 = form 右缘;高度按运行期恒 1 行 182
          $fba = Get-FallbackAnchor $btns $script:lastEditorR
          if ($fba) {
            Emit ($fba.right) ($fba.top) 182 (Commit-Theme (Get-Theme $fba.r))
            $script:lastEditorR = $fba.right
            $script:misses = 0
          } else {
            # v0.12.5f:无降级锚可用 → none 立即上报
            $j = '{{"t":{0},"mode":"phys","none":true}}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            Set-Content -Path $out -Value $j -Encoding Ascii
          }
        }
      }
    }
  } catch { }
  # v0.13d:转录区字符流采样(每 2 轮 ≈240ms;重取防陈旧快照)
  $script:tickLive++
  if (($script:tickLive % 2) -eq 0) { Read-LiveText }
  # v0.13f:会话视图采样(每 16 轮 ≈2s;变化或 30s 心跳才写)
  $script:tickView++
  if (($script:tickView % 16) -eq 0) { Write-View }
  Start-Sleep -Milliseconds 120
}
