# ZCode 插件悬浮窗 UI 技术文档：从 HTML 到原生桌面

> **v2 定位:知识地图**(决策前认知文档)。2026-09-12 19:13:09 单次成文定稿;2026-09-14 随文档体系 v2 迁入 `docs/knowledge/` 正名(曾用名即本文标题，曾存 docs/ 根)。决策后冻结，以下原文一字未改——预测对质结果见 `docs/retrospectives/2026-09-13-悬浮窗渲染之路.md` §3.3。
> **显式预测(⚠️ 2026-09-14 补记，摘自原文 §6.3/§6.4/§7.3，当时未独立成节)**:①WebView2 `DefaultBackgroundColor=Transparent` 一行必加，否则白底;②Windows(WebView2) 还原度 ≈98%;③macOS(WKWebView) 92–95%(drawsBackground=false);④原生壳代码保留并加强，总量只减 30–40%;⑤字体缺失须打包;⑥macOS backdrop-filter 层级待实测。──实测(渲染之路 §3.3):①被证伪(本宿主无效，白底另有根因);②半对(内容 1:1，透明合成 0 分);④✓ 全应验;③⑥待真机。

> 本文整理自一次围绕「如何把一份 HTML 悬浮窗 UI 落地到 ZCode 插件」的技术讨论，按知识点重组，保留实测数据、路径、参数与踩坑记录。

---

## 0. 文档范围

本文覆盖以下问题：

1. ZCode 插件的形态到底是什么，悬浮窗属于哪一层
2. Figma 在这个流程中的能力边界
3. 为什么 Web 做 UI 比 Windows/macOS 原生容易
4. 圆环进度条在 SVG / WPF / AppKit 三种技术下的精确实现
5. HTML UI 迁移到桌面的三条路径与选型
6. WebView2 + WKWebView 方案的细节、还原度与坑
7. 原生壳的职责划分与实施路径
8. 教训沉淀与速查清单

---

## 1. ZCode 插件的形态

### 1.1 插件由哪些部分组成

从 `zcode-watch` 项目的实际文件结构看，一个 ZCode 插件由 **5 个部分组成**，各自独立：

| 部分     | 文件                                 | 形态                           | 作用                                   |
| -------- | ------------------------------------ | ------------------------------ | -------------------------------------- |
| 查询引擎 | `zcode-watch.mjs`                    | Node 脚本（零依赖，Node ≥ 18） | 唯一数据源                             |
| 技能     | `SKILL.md`                           | Markdown 提示词                | 让 AI 在对话里查用量                   |
| 命令     | `commands/watch.md`                  | Markdown                       | `/zcode-watch:watch` 触发              |
| Hook     | `hooks/hooks.json`                   | JSON                           | `SessionStart` 时拉起悬浮窗 + 注入提醒 |
| 悬浮窗   | `.ps1`（Windows）/ `.swift`（macOS） | **原生桌面窗口**               | 显示进度条的 UI                        |

### 1.2 悬浮窗不属于插件标准声明的一部分

ZCode 插件的声明清单（`.zcode-plugin/plugin.json`）里，字段只有：

```json
{
  "name": "zcode-watch"，
  "version": "0.5.0"，
  "commands": "commands"，
  "skills": "skills"，
  "hooks": "hooks"
}
```

**没有"UI"或"悬浮窗"这类声明。** 悬浮窗是通过 `hooks.json` 的 `SessionStart` 钩子，以**外部进程**的形式被拉起的：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "process"，
            "command": "node"，
            "args": ["${ZCODE_PLUGIN_ROOT}/skills/zcode-watch/scripts/widget-launch.mjs"]，
            "timeoutMs": 10000，
            "statusMessage": "确保 zcode-watch 悬浮窗在运行(Windows)"
          }
        ]
      }
    ]
  }
}
```

`widget-launch.mjs` 按 `process.platform` 分发：

- `win32` → `wscript.exe widget-launch.vbs`（免黑窗）→ `zcode-watch-widget.ps1`
- `darwin` → `open -g ZCodeWatchHUD.app`
- 其他 → 静默跳过

**结论**：悬浮窗是"插件通过 Hook 拉起的独立进程"，而不是"插件系统内置的 UI 层"。这决定了它的技术选型完全自由——WPF、AppKit、WebView、Tauri 都可以，只要 Hook 能把它拉起来。

---

## 2. Figma 的能力边界

### 2.1 Figma 是什么

Figma 设计稿的本质是**矢量图层 + 组件 + 变量 + 原型交互**的数据结构，存在云端或 `.fig` 文件里，用 Canvas/WebGL 实时渲染。它**不是 HTML**，没有 DOM 树；也**不是死图**，能做成带跳转、Smart Animate、组件变体、变量切换的交互原型。

### 2.2 能做什么

- 画视觉稿：圆角、进度环、颜色、间距、字体
- 做交互原型：点击、悬停、切主题
- 导出标注：尺寸、色值、圆角、间距
- 导出 SVG 图标

### 2.3 做不了什么

- 生成 **WPF / XAML** 代码
- 生成 **AppKit / Swift** 代码
- 变成 ZCode 插件（hook、命令、技能、拉起逻辑）
- 实现真实功能（读 Key、调接口、算加权）
- 做原生窗口行为（无边框、磨砂、置顶、全局快捷键、位置记忆）

Figma 的「转代码」插件（Anima、F2C、html.to.design 等）导出的是 **HTML/CSS/React**，不是 WPF 也不是 AppKit。

### 2.4 正确用法

把 Figma 当**图纸**：量出尺寸、圆角、间距、颜色，然后手动填进 `.ps1` 和 `.swift`。**不要指望它生成原生代码。**

---

## 3. 为什么 Web 做 UI 比原生容易

### 3.1 图形原语对比

**圆环：**

| 平台   | 实现                                                         | 说明                       |
| ------ | ------------------------------------------------------------ | -------------------------- |
| Web    | `<circle>` + `stroke-dasharray` + `stroke-dashoffset` + `linecap="round"` | 三行属性                   |
| WPF    | `Ellipse` + `StrokeDashArray`                                | **单位是线宽倍数**，需换算 |
| AppKit | `CAShapeLayer` + `strokeEnd`                                 | 吃 0–1 比例，反而简单      |

**不规则形状（内凹缺口）：**

| 平台   | 实现                                                         |
| ------ | ------------------------------------------------------------ |
| Web    | `clip-path: path("...")`，一行                               |
| WPF    | `Border.CornerRadius` 只能凸圆角，内凹需手画 `Path` Geometry |
| AppKit | `NSBezierPath` 手画；`maskedCorners` 也只能选哪几个角圆      |

**磨砂玻璃：**

| 平台   | 实现                                                         |
| ------ | ------------------------------------------------------------ |
| Web    | `backdrop-filter: blur(20px)`，一行                          |
| WPF    | P/Invoke `SetWindowCompositionAttribute`，手写 `Add-Type` 声明 Win32 结构体 |
| AppKit | `NSVisualEffectView`，简单                                   |

### 3.2 布局与样式

| 能力     | Web                            | WPF                           | AppKit            |
| -------- | ------------------------------ | ----------------------------- | ----------------- |
| 贴边定位 | `position: fixed; right: 0`    | 手算 `$win.Left`              | 手算 `origin`     |
| 单侧圆角 | `border-radius: 40px 0 0 40px` | `CornerRadius="40，0，0，40"` | `maskedCorners`   |
| 内凹弧   | `clip-path`                    | 手画 Geometry                 | 手画 NSBezierPath |
| 阴影     | `box-shadow`                   | `DropShadowEffect`            | `shadow` 属性     |
| 热重载   | 保存刷新                       | 重新编译                      | 重新编译          |

Web 的 `border-radius` 是**渲染引擎内置的圆角算法**；WPF 的 `CornerRadius` 本质是几何裁剪，复杂形状没有对应算法原语。

### 3.3 窗口与系统

这是**真正难的部分**。以下行为在 Web 里根本不存在（浏览器全包），在原生里每一项都要和 OS 对接：

无边框、背景透明、始终置顶、不抢焦点、不占 Dock/任务栏、拖动移动、位置记忆、全局快捷键、开机自启、点击穿透。

### 3.4 生态与反馈循环

| 维度     | Web                           | 原生                          |
| -------- | ----------------------------- | ----------------------------- |
| 组件库   | 无数圆环进度条组件，复制即用  | 每平台一套，无通用库          |
| 设计工具 | Figma 直接导出 HTML/CSS/React | 导出 WPF/Swift 的工具几乎没有 |
| 反馈速度 | 改一行刷新即见                | 编译数秒到数十秒              |
| 跨平台   | 一份代码三端跑                | 三套代码互不复用              |

### 3.5 核心结论

> **Web 把「画图形」和「管窗口」都做成了声明式的一等公民；原生把这两件事都拆成了需要手写的底层操作。**

不是"原生不行"，而是**这个 UI 的效果恰好落在 Web 最擅长、原生最费劲的交叉点上**。

---

## 4. 圆环进度条的精确实现

### 4.1 用户项目实际参数

来自 `ai-sidebar-widget.html`：

| 参数              | 值                                         |
| ----------------- | ------------------------------------------ |
| 舞台尺寸          | 430 × 1739 px                              |
| 圆环 viewBox      | 135 × 135                                  |
| 圆心              | cx=67.5， cy=67.5                          |
| 半径 r            | 61                                         |
| 线宽 stroke-width | 13                                         |
| 周长              | 2π×61 ≈ **383.27**                         |
| 起始角            | `rotate(-90 67.5 67.5)`（12 点方向）       |
| 端点              | `stroke-linecap: round`                    |
| 颜色              | 橙 `#ce6a47` / 绿 `#7fdca9` / 黄 `#eef67e` |
| 轨道色            | `#2e2e2e`                                  |
| 面板色            | `#030303`                                  |

### 4.2 SVG 方案（Web，推荐）

核心公式：

```
周长 C = 2πr
stroke-dasharray = "C × pct   C × (1 − pct)"
```

用户 HTML 中实测的三个 dasharray 值（均与 C=383.27 一致）：

| 进度 | dasharray     | 验算                               |
| ---- | ------------- | ---------------------------------- |
| 73%  | `279.8 103.5` | 383.27×0.73=279.79，×0.27=103.48 ✓ |
| 21%  | `80.5 302.8`  | 383.27×0.21=80.49，×0.79=302.78 ✓  |
| 52%  | `199.3 184`   | 383.27×0.52=199.30，×0.48=183.97 ✓ |

**关键点**：

- `rotate(-90 cx cy)` 把起点从 3 点方向转到 12 点
- `stroke-linecap="round"` 让弧线两端是圆的
- dash + gap 之和必须等于周长，否则弧会重复出现

### 4.3 WPF 方案

WPF 的 `StrokeDashArray` 单位是 **`StrokeThickness` 的倍数**，不是像素。公式：

```powershell
$thickness = 13
$radius    = 61
$C = 2 * [Math]::PI * $radius        # 383.27
$pct = $p / 100.0
$dashLen = $C * $pct / $thickness
$gapLen  = $C * (1 - $pct) / $thickness
$dashArr = "{0:F3} {1:F3}" -f $dashLen， $gapLen
```

XAML：

```xaml
<Grid Width="135" Height="135">
  <Ellipse Width="135" Height="135" Stroke="#2e2e2e" StrokeThickness="13"/>
  <Ellipse Width="135" Height="135" Stroke="$col" StrokeThickness="13"
           StrokeDashArray="$dashArr" StrokeDashCap="Round"
           RenderTransformOrigin="0.5，0.5">
    <Ellipse.RenderTransform>
      <RotateTransform Angle="-90"/>
    </Ellipse.RenderTransform>
  </Ellipse>
</Grid>
```

### 4.4 AppKit 方案

`CAShapeLayer` 的 `strokeEnd` 直接吃 0–1 比例，比 WPF 简单：

```swift
let ring = CAShapeLayer()
ring.path = NSBezierPath(ovalIn: bounds.insetBy(dx: thickness/2， dy: thickness/2)).cgPath
ring.strokeColor = tint.cgColor
ring.fillColor = nil
ring.lineWidth = 13
ring.lineCap = .round
ring.strokeStart = 0
ring.strokeEnd = CGFloat(pct / 100)
ring.transform = CATransform3DMakeRotation(-.pi / 2， 0， 0， 1)
```

### 4.5 参数对齐表（三平台必须一致）

| 参数     | 值                |
| -------- | ----------------- |
| 外径     | 135               |
| 线宽     | 13                |
| 起始角   | −90°（12 点）     |
| 方向     | 顺时针            |
| 端点     | 圆角（round cap） |
| 底环颜色 | `#2e2e2e`         |

**弧长算错一点，视觉立刻不对。** 这是"差距大"的根本原因。

---

## 5. HTML UI 迁移到桌面的三种路径

### 5.1 路径 A：继续原生（WPF + AppKit）

- **能做**，但内凹面板轮廓、精确圆环要手写 Geometry / CAShapeLayer
- **还原度约 85–90%**，做不到 100%
- 优点：保持现有架构，体积小，无额外运行时
- 缺点：每次调 UI 要编译，圆环参数调整痛苦

### 5.2 路径 B：WebView2 + WKWebView（**推荐**）

- 把 HTML **原样**塞进 WebView，1:1 还原，改 CSS 立刻生效
- 需要重写**悬浮窗壳**：把 WPF `Window` / `NSPanel` 换成 WebView 容器
- 透明背景、点击穿透、置顶、位置记忆、全局快捷键仍需原生处理
- **壳的复杂度换来了 UI 的自由度**

### 5.3 路径 C：Tauri / Electron

- 一套 HTML 两端跑，Windows 用 WebView2，macOS 用 WKWebView
- 最省心，但引入新框架，体积和启动时间增加

### 5.4 选型结论：B 优于 C

针对本项目（已有 ZCode Hook 事件触发 + 已有 Node 查询引擎）的具体权衡：

| 维度                     | WebView2 + WKWebView                       | Tauri                               |
| ------------------------ | ------------------------------------------ | ----------------------------------- |
| 与现有 Hook 触发机制兼容 | 直接替换 `widget-launch.mjs` 启动目标即可  | 需脚本指挥 Rust 进程，更绕          |
| 现有代码改动             | 只换悬浮窗壳                               | 引入 Rust 后端                      |
| 技术栈贴近度             | 贴近现有 C#/PowerShell 体系                | 新增 Rust + 新构建链                |
| 事件通信                 | `postMessage` / `ExposeFunctionAsync` 直接 | 跨语言事件系统，更复杂              |
| 性能优势                 | 无绝对优势                                 | 冷启动/包体积略优，常驻内存差距不大 |

**结论**：**首选 WebView2 (Windows) + WKWebView (macOS)**。

---

## 6. WebView2 与 WKWebView 方案详解

### 6.1 WebView2 是什么

- 微软的**嵌入式浏览器控件**，基于 Edge（Chromium）内核
- **Windows 专属**；macOS 对应 WKWebView，Linux 对应 WebKitGTK
- 宿主：Win32 / WPF / WinForms / WinUI / .NET / C++
- 运行时：共享系统 Edge 运行时，Win11 自带，Win10 通常也有
- **不是**：浏览器插件、不是 Electron、不是 Figma、不是跨平台方案

### 6.2 WKWebView 是什么

- macOS/iOS 的**嵌入式 WebView**，基于 Safari 的 WebKit 内核
- 与 WebView2 是**不同渲染引擎**（Chromium vs WebKit）

### 6.3 效果还原度（估计值，需实测验证）

| 平台               | 还原度   | 主要差异来源                                                 |
| ------------------ | -------- | ------------------------------------------------------------ |
| Windows (WebView2) | ≈ 98%    | Chromium 内核，与浏览器一致；字体亚像素渲染可能有极细微差异  |
| macOS (WKWebView)  | ≈ 92–95% | 字体渲染（CoreText vs Chromium）、`cubic-bezier` 亚像素插值、`backdrop-filter` 层级 |

**核心结论**：结构、布局、圆环、贴边、内凹、动画——**核心视觉全部 1:1**。差异只在字体手感这类像素级层面。

### 6.4 必须处理的坑

**坑 1：WebView 默认背景不透明**

如果不处理，圆角面板外面会出现白色（Windows）或灰底（macOS）矩形，破坏贴边悬浮效果。

```csharp
// Windows (WebView2)
webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;
```

```swift
// macOS (WKWebView)
webView.setValue(false， forKey: "drawsBackground")
```

**这一行必须加，否则视觉直接崩。**

**坑 2：字体缺失**

用户 HTML 里用了 `Segoe UI Variable Text`：

- Windows 11 自带
- Windows 10 可能回退到 `Segoe UI`
- macOS **没有**，会回退到 `PingFang SC` 或 `system-ui`

字重、字宽会有可见差异。要 100% 一致，需**把字体打包进插件**，用 `@font-face` + 相对路径引用。

**坑 3：MAC 端 `backdrop-filter` 层级 bug**

WKWebView 支持 `backdrop-filter`，但与透明窗口叠加时偶尔出现层级问题，需实测。

### 6.5 保证最接近的做法

1. 调 UI 时用 **Edge / Chrome**（对应 Windows WebView2）
2. macOS 端额外用 **Safari** 测一遍
3. **字体打包进去**，不依赖系统字体
4. **壳里一定要设透明背景**

---

## 7. 原生壳的职责划分

### 7.1 WebView 与原生壳的分工

**WebView 不是悬浮窗，它只是渲染 HTML 的控件。** 窗口行为必须由原生代码完成：

| 职责                       | 谁来做                            |
| -------------------------- | --------------------------------- |
| 画圆环、面板、动画         | **WebView (HTML/CSS/JS)**         |
| 创建无边框窗口             | 原生壳                            |
| 窗口置顶、不抢焦点         | 原生壳                            |
| 全局快捷键（Ctrl+Shift+G） | 原生壳（Carbon / RegisterHotKey） |
| 拖拽移动窗口               | 原生壳                            |
| 位置记忆、菜单栏图标       | 原生壳                            |
| 启动 Node 脚本、读 JSON    | 原生壳                            |
| 接收 ZCode Hook 触发       | 原生壳                            |

### 7.2 换 WebView 后原生代码的变化

**删掉的部分**：

- `New-KeyCard` 里所有画圆环、画横条的 XAML
- `BarView.draw()` / `RingView` 的绘图代码
- 主题颜色的 `DynamicResource` 切换逻辑（改由 CSS 变量控制）

**保留并强化的部分**（现有 `zcode-watch-widget.ps1` 里一大半代码属于此类）：

- 单实例互斥量（`Global\ZCode-Watch-Widget`）
- 唤醒文件轮询（`zcode-watch-widget.wake`）
- 全局快捷键注册（`RegisterHotKey`）
- 窗口置顶、透明、不抢焦点（`Topmost` / `ShowActivated="False"`）
- 位置记忆（`zcode-watch-widget.pos.json`）
- ZCode 进程探测（生命周期绑定）
- ZCode 主题深浅探测（像素采样）
- 调用 Node 脚本并解析 JSON

**新增**：WebView 初始化、加载 HTML、JS 通信桥。

### 7.3 代码量变化

**原生代码总量可能只减少 30–40%，而不是归零。**

准确表述：

> **原生的「绘图代码」被淘汰，原生的「窗口/系统代码」不但保留，还要加强。**

分层：

```
┌─────────────────────────────┐
│  WebView (HTML/CSS/JS)      │  ← 圆环、面板、动画、颜色
├─────────────────────────────┤
│  原生壳 (C# / Swift)         │  ← 窗口、快捷键、进程、通信
└─────────────────────────────┘
```

---

## 8. 实施路径

分四个阶段，**UI 调优与壳开发解耦**：

| 阶段       | 内容                                       | 是否需碰原生 |
| ---------- | ------------------------------------------ | ------------ |
| **阶段 1** | 浏览器里调 HTML UI，实时看效果             | 否           |
| **阶段 2** | 写 WebView 宿主壳（一次性）                | 是           |
| **阶段 3** | HTML 加数据接口 + 壳传数据                 | 少量         |
| **阶段 4** | hooks 触发壳启动（改 `widget-launch.mjs`） | 少量         |

### 阶段 3 的数据对接

HTML 目前是**写死的**（73%、21%、52% 均为常量）。真实运行需加数据接口：

```js
// 壳把数据传进来时调用
window.updateUsage = function(data) {
  // data = [{percent: 73， color: '#ce6a47'}， ...]
  // 更新三个圆环的 stroke-dasharray 和百分比文字
};
```

壳拿到 `zcode-watch.mjs --json` 的输出后，通过 `postMessage` 或 JS 调用把数据传给 HTML。

### 阶段 4 的 Hook 改动

`widget-launch.mjs` 的 darwin 分支：

```js
// 旧：open -g ZCodeWatchHUD.app
// 新：启动 WebView 宿主程序
```

改动量极小。**Hook 触发逻辑完全不变**，只替换"被启动的程序"。

---

## 9. 教训沉淀

### 9.1 最初误判插件形态

**现象**：初期把问题理解成"Chrome 扩展"或"网页"，给出的方案是 manifest.json + content script + Shadow DOM。

**修正**：看到实际文件后确认是 **ZCode 插件 + 原生桌面悬浮窗**，UI 不在浏览器里，是操作系统窗口。HTML 那套 `border-radius` / `position: fixed` 只能借鉴思路，不能直接搬。

**教训**：先看 `hooks.json`、`plugin.json`、`build.sh` 这类清单文件，再判断形态。不要默认"网页 UI = 浏览器扩展"。

### 9.2 最初低估 UI 迁移成本

**现象**：初期认为"HTML 效果能直接移植到原生"。

**修正**：**没有"移植"，只有"重写"**。HTML 与原生之间没有翻译器。这份 HTML 漂亮，是因为浏览器引擎帮你做了 SVG 路径平滑、`stroke-dasharray` 弧长计算、CSS transition 插值、`backdrop-filter` 合成——这些在原生里每一项都是你的代码。

**教训**：判断迁移成本时，先列出 UI 依赖的**引擎能力清单**（图形原语、动画、合成、字体），再逐项核对目标平台是否有对等物。

### 9.3 关于"ZCode Desktop Extension SDK"

讨论中曾提到 `@notmike101/zcode-extension-sdk` 作为 Desktop Extension 方案，但**该说法未在用户提供的任何文件中得到证实**。从实际文件看，悬浮窗是通过 `hooks.json` 的 `SessionStart` 拉起外部进程实现的，**不需要额外的 Extension SDK**。

> ⚠️ 本文档不将该 SDK 作为可行方案。

---

## 10. 速查清单

### 10.1 关键路径

| 用途             | 路径                                                         |
| ---------------- | ------------------------------------------------------------ |
| 用户配置         | `~/.zcode/zcode-watch.json`                                  |
| 机器缓存         | `~/.zcode/zcode-watch-cache.json`                            |
| 插件缓存根       | `~/.zcode/cli/plugins/cache`                                 |
| Windows 唤醒文件 | `~/.zcode/scripts/zcode-watch-widget.wake`                   |
| Windows 位置记忆 | `~/.zcode/scripts/zcode-watch-widget.pos.json`               |
| macOS HUD 配置   | `~/.zcode/zcode-watch-hud/config.json`                       |
| 引擎脚本（正本） | `plugins/zcode-watch/skills/zcode-watch/scripts/zcode-watch.mjs` |
| macOS 编译产物   | `macos/ZCodeWatchHUD.app`                                    |

### 10.2 关键常量（`zcode-watch.mjs`）

| 常量                    | 值                                |
| ----------------------- | --------------------------------- |
| `DEFAULT_MONTHLY_QUOTA` | `1750000000`（17.5 亿加权 token） |
| `MIN_WINDOW_HOURS`      | `2`                               |
| `PAGE_SIZE`             | `500`                             |
| `MAX_PAGES`             | `40`                              |
| `LEVEL_TTL_MS`          | `3600000`（1 小时）               |
| 默认刷新间隔            | `110` 分钟                        |
| 默认快捷键              | `ctrl+shift+g`                    |

### 10.3 关键 UI 参数（`ai-sidebar-widget.html`）

| 参数                  | 值                                                |
| --------------------- | ------------------------------------------------- |
| 舞台尺寸              | 430 × 1739                                        |
| 圆环 viewBox          | 135 × 135                                         |
| 圆环 r / stroke-width | 61 / 13                                           |
| 圆环周长              | 383.27                                            |
| 面板色                | `#030303`                                         |
| 轨道色                | `#2e2e2e`                                         |
| 橙 / 绿 / 黄          | `#ce6a47` / `#7fdca9` / `#eef67e`                 |
| 展开动画              | `0.62s cubic-bezier(0.16， 1， 0.3， 1)`          |
| 收起动画              | `0.42s cubic-bezier(0.55， 0.055， 0.675， 0.19)` |

### 10.4 关键操作命令

```bash
# 运行引擎（终端卡片输出）
node plugins/zcode-watch/skills/zcode-watch/scripts/zcode-watch.mjs

# 运行引擎（JSON 输出，供壳消费）
node plugins/zcode-watch/skills/zcode-watch/scripts/zcode-watch.mjs --json

# 运行引擎（SessionStart hook 模式）
node plugins/zcode-watch/skills/zcode-watch/scripts/zcode-watch.mjs --hook

# 跑单测
node --test plugins/zcode-watch/skills/zcode-watch/scripts/zcode-watch.test.mjs

# 编译 macOS HUD
cd macos && bash build.sh

# 手动启动 macOS HUD
open ZCodeWatchHUD.app
```

### 10.5 WebView 壳必设项

```csharp
// Windows (WebView2)
webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;
```

```swift
// macOS (WKWebView)
webView.setValue(false， forKey: "drawsBackground")
```

### 10.6 三条决策规则

1. **UI 在浏览器里调，不要在原生里调** —— 反馈速度差一个数量级。
2. **壳是一次性成本，UI 是反复调整的部分** —— 把反复调整的放到浏览器。
3. **原生只管窗口和系统，WebView 只管内容** —— 分层，不二选一。

---











## 文档调整

> ## 把"C:\Users\27844\Desktop\zcode-butler\docs\knowledge\"下的内容作为素材,构建新的技术文档:"C:\Users\27844\Desktop\桌面agent插件架构与技术选型\zcode插件架构与技术选型.md"

### 1.zcode插件的形态

这一章以zcode-watch为例，改成以zcode-butler为例

### 2，两个开发工具的作用: OpenDesign		zcode

### 3.根据对话，把开发UI过程梳理出来



1. OpenDesign 做出来的UI设计，属于UI原型(`C:\Users\27844\Desktop\zcode-butler\OpenDesign UI`)，OpenDesign 永远只碰UI原型，不直接碰项目源码；
2. OpenDesign预览环境宽松，需下载到(`C:\Users\27844\Desktop\zcode-butler\OpenDesign UI`)，使用**浏览器预览**:`http.server 18779` + 窄窗看缩放/文字/动画；
3. UI原型定稿 → ZCode合入项目UI源码 (`C:\Users\27844\Desktop\zcode-butler\plugins\zcode-butler\scripts\widget\butler-widget.html`)，拓展三桥是代码活，归ZCode，视觉设计归OpenDesign；
4. **浏览器预览**:`http.server 18779` + 窄窗看缩放/文字/动画；
5. **真机验证**:`%TEMP%\butler-ctl.ps1` 先 `kill` 再 `start` → `butler-shot.ps1` 截图。**必须走这条 ctl 链路**——它指向桌面正本，你看到的才是刚改的代码；如果只是新开个会话让 hook 自动拉起，看到的是缓存里的旧快照；
6. **定稿发布**:`git commit + push`(GitHub 同步)，建议顺手把 `plugin.json` 版本号 bump 一档(0.1.0→0.1.1)作为发布节奏；
7. **刷新缓存**：插件市场里对 zcode-butler 重新“更新”一次(版本号没变也会重新快照，你今天 17:14 那次就是证明)。不做这步，下次新会话 hook 拉起的还是旧 UI。



### 4.UI的架构和技术选型("C:\Users\27844\Desktop\zcode插件架构与技术选型.md")

Electron

WebView2(https://chat.deepseek.com/share/in6sgw34a3qschoqdm)

Tauri	

windows原生

### 5.UI代码维护(章节名字不确定，"项目UI维护"不一定符合内容)

三份UI文件同步和定位

**桌面** `C:\Users\27844\Desktop\zcode-butler\OpenDesign UI`	唯一开发正本 ， 所有修改只发生在这里，git 仓库也在这里。

**GitHub** `...\cache\zcode-plugins-personal\zcode-butler\0.1.0`	备份 + 未来分发渠道 ， push 即同步；以后想在别的机器装，把 marketplace.json 推上去、市场改成 github 型来源即可

**缓存** `ssbh163/zcode-butler	`运行时产物，不需要“保留”心态 ， 它是安装器生成的，删了会在下次“更新插件”时重建。永远不要手改它(下次更新会被静默覆盖)，它的唯一意义是“ZCode 的 SessionStart hook 实际运行的那份”

### 6.三桥

"C:\Users\27844\Desktop\三桥.md"

### 7.UI的AGENT.md

webview2视觉对象托管	三桥铁律

---

### 细化文档体系中每个文档的内容模版

开发日志.md已改,看下之前的wiki中的记录参数和之前dev record中的记录参数的是否合并入开发日志.md
