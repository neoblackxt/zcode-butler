# ZCode 输入框性能浮标 · 定位方案(v0.11 设计稿)

> 前提:浮标是**独立悬浮窗**(不进包),形态见 `zcode-composer-stats-prototypes.html` 的 A–E。
> 目标:贴住输入框上沿,输入框动它就动,帧级无残影。
> 沿袭:码管家 stats-widget v0.10 的全部机制(DWM 可视帧锚 / WinEvent 帧级跟随 / owned 同层 / 生死绑定)。
> 铁律(v0.6–v0.8 血泪):**能在锚定几何上用常量解决的,不要做运行时感知。**

## 一、核心矛盾与解法

v0.10 之所以能"纯常量",是因为锚的是**窗口底边空带**(实测 35px,状态无关)。
现在锚点变成**输入框上沿**,它会因多行输入、侧栏折叠、面板开关而动——纯常量不再成立。

**但有一个关键洞察兜底:性能浮标只在流式生成期间有信息价值,而流式期间输入框通常是空的(刚提交)。空输入框 = 1 行 = 固定高度 108css → 上沿到窗口底边的距离是常量。**
也就是说:**在浮标可见的时段,常量锚几乎总是精确的**;用户边看速度边打字的场景里,浮标短暂被长高的输入框追平,可接受或直接隐藏。

所以架构是**两层**:

| 层 | 依赖 | 精度 | 成本 |
|---|---|---|---|
| **基线层(默认)** | 无,纯 v0.10 公式上移 | 流式期精确;非流式期/侧栏折叠后漂移 | 近零,照抄 v0.10 |
| **CDP 精确层(可选升级)** | ZCode 带 `--remote-debugging-port` 启动 | 任意状态逐帧精确 | 一个 node 探锚进程 |

两层共存:CDP 在 → 动态锚;CDP 不在 → 自动落回基线。**永不复活像素扫描**(v0.8 已证伪)。

## 二、变动源覆盖表(方案是否站得住的检验)

| 输入框位置变动源 | 频率 | 基线层 | CDP 层 |
|---|---|---|---|
| 窗口移动 / 缩放 / 换屏 / 最小化 | 高 | ✅ 现有 WinEvent 帧级跟随,原样复用 | 同左 |
| 任务切换 / 会话滚动 | 高 | ✅ 输入框钉底不动 | 同左 |
| 终端 / 预览侧面板开关 | 低 | ⚠️ 中心不变,边缘变:居中小条(A/E)无感;贴边条(B/C)漂移 | ✅ 实时 |
| 侧栏折叠 / 展开 | 低 | ⚠️ 沿用 v0.10 手动 `centerXOffset`(63↔0) | ✅ 自动 |
| 多行输入长高(max 160css) | 中 | ✅ 流式期=空输入=常量成立;打字期可隐藏 | ✅ ResizeObserver 实时 |
| Ctrl+滚轮缩放 / DPI 变化 | 低 | ❌ css 常量失效 | ✅ rect×dpr 自动 |
| ZCode 版本更新(内边距常量变) | 极低 | ⚠️ 常量漂移,配置可调 | ✅ 免疫 |
| 页面重载 / CDP 断开 | 低 | —(本来就没用) | 降级到基线层 |

## 三、基线层(v0.11:first slice)

照抄 v0.10,只把垂直公式从"底边锚"换成"底边锚 − 输入框常量高":

```
composerBottom  = VisibleBottom() − bottomGap          # bottomGap 实测 ≈ 20css×dpr(v0.10 实测 35px 含旧 margin,校准一次)
composerHeight  = 108css×dpr                            # p-3×2 + editor 40 + gap 12 + toolbar 32(空输入 1 行)
浮标底缘 y      = composerBottom − composerHeight − gapAbove(8css×dpr) −浮标高
水平            = 沿用 v0.10:窗口中心 + centerXOffset ± 变体偏移
```

- **实测定常量**:按 AGENTS.md 读图五步,拿同尺截图量一次 dpr 下的实际值,写进默认配置,`~/.zcode/stats-widget.json` 可调(扩展 `composerHeightPx`、`gapAbove`)。
- **变体适配**:A/E(居中/右移小条)基线即可;B/C(贴左右边、全宽)需要输入框左右边缘 → 基线下建议退化为 A 式居中,或直接上 CDP 层。
- 打字期防穿帮:编辑区非空且行数 >1 时浮标淡出(视觉层自己判断,数据通道已有)。

## 四、CDP 精确层(v0.12 设计 → v0.12.2 弃用,改 UIA 通道)

> **v0.12.2 通道切换(2026-09-28)**:CDP 路线被证伪——打包版 Electron 41 静默丢弃 `--remote-debugging-port`(带不带显式 `--user-data-dir` 都一样;源码核实 `packages/desktop/src/main/index.ts` 仅开发态 append 9229,无 removeSwitch,排除应用侧过滤;主进程 netstat 零监听为实证)。**改走 UIA 无障碍通道**:`anchor-probe-ui.ps1` 每 250ms 经 System.Windows.Automation 找"最底部 ClassName=min-h-10 max-h-40… 的 Edit"(LexicalChatInput 原版类名,行内编辑框同款故取最底者),输出 composer form 近似矩形(物理屏坐标):right=editor.right+21、top=editor.top−21、height=editor.height+111(182−71 校准)。Chromium 收到 UIA 查询自动启用 web 无障碍(WM_GETOBJECT 触发,启动后数秒 warm-up,期间浮标隐藏)。**无需任何启动开关,对运行中实例直接生效。** 已知近似:附件行(topContent)在 editor 上方,探测不含——附件态浮标可能与附件行重叠、阈值不计附件高度;后续可加 topContent 扫描。锚文件契约改为 `{"mode":"phys","right":R,"top":T,"height":H}`(物理屏坐标),消费端不再做 css 换算。

### 1. 通道(原文 CDP 设计,留档)

- ZCode 快捷方式加 `--remote-debugging-port=9222`(一次性设置;只在启动时生效,老进程不可后挂)。
- 探锚进程 `anchor-probe.mjs`(node,目录放 stats-widget/ 旁):CDP 连主窗口 target(按 title=ZCode 匹配),断线指数退避重连;页面重载后重新 subscribe。
- **注意 Job 连坐坑**:由 hook 链拉起时,必须走 `stats-launch.vbs` 同款 wscript/ShellExecute 中转,detached node 直拉会秒退 EXIT 0。

### 2. 探锚(源头数据,可信度第 1 梯)

页面里执行,每 33ms 轮询 + 页内 `ResizeObserver` 兜底:

```js
// 版本无关启发式,不依赖被构建打散的 testid:
// 主输入框 = 全文档最底部的「含 contenteditable 的 form」(消息行内编辑在中部,永不比主 composer 更低)
const forms = [...document.querySelectorAll('form')].filter(f => f.querySelector('[contenteditable="true"]'));
const r = forms.map(f => f.getBoundingClientRect())
               .sort((a, b) => b.bottom - a.bottom)[0];   // 最底者即主输入框
```

输出**视口相对坐标**(CSS px)。找不到(加载中/重载)→ 上报 null → 浮标隐藏。

### 3. 坐标合成(视口坐标 → 屏幕物理像素)

```
屏幕X = clientOrigin.ScreenX + rect.x × dpr
屏幕Y = clientOrigin.ScreenY + rect.y × dpr
```

- clientOrigin 用 Win32 `GetClientRect` + `ClientToScreen`(一次调用给客户区原点屏幕坐标),**免推算标题栏/边框常量**;
- dpr 用 `GetDpiForWindow / 96`;
- 窗口外框一律 DWM `ExtendedFrameBounds`(v0.10 结论:普通矩形含不可见缩放边框,会漂)。

### 4. IPC 与移动(v0.12 实现定稿:JSON 文件 + 统一偏移公式)

- node → PS1:**原子写 `~/.zcode/stats-widget-anchor.json`**(`{t,x,y,w,h}`,composer 视口 CSS px;200ms 心跳 + 变化即写)。放弃 HttpListener——PS1 侧 33ms tick 里 stat 文件(100ms 一次)足够轻,且免去 PS1 起 HTTP 服务器的复杂度。
- PS1 换算:`屏幕坐标 = ClientToScreen(clientOrigin) + rect.css × GetDpiForWindow/96`(物理像素);可见性 = `rect.h × dpr ≤ showMaxComposerPx`(默认 288,滞回 +24 防抖)。
- **统一偏移公式(关键重构)**:C# 帧级跟随从「常量公式」改为「窗口相对偏移」——`SetFollowParams(z, offX, offY, w, h)`,回调里 `x = r.Left + _offX; y = VisibleBottom() - _offY - _fwH`。PS1 每次算出目标位置后把偏移喂回 C#。这样**窗口拖动(C# 帧级)与布局变化(CDP 33ms)写同一个偏移源**,互不打架;无 CDP 时偏移由基线常量推出,行为与 v0.11 完全一致。
- 探锚进程由 PS1 启动时经 `anchor-probe-launch.vbs`(ShellExecute 逃 Job)拉起,单实例锁,断连指数退避,连续 60s 够不到 CDP 端口自退(下次宿主启动再拉)。

### 6. 出现时机状态机(v0.12 定稿)

源码导出的输入框变化全集(ChatPromptEditor/LexicalChatInput):**S0** 空/单行 104css(实测 182px)= 流式期典型态;**S1** 多行草稿 editor 增高至 max-h-40=160css 封顶;**S2** topContent 附件/引用行每行 ~36css;**S3** 工具行高度恒定。高度域 = [182, ~400px]。

| 状态 | 浮标行为 |
|---|---|
| composer 高 ≤ 288px(≈基线+60css) | **跟随显示**:右缘贴 composer 右缘、底缘 = composerTop − 8 |
| composer 高 > 312px(滞回线) | **隐藏**(被挤上会话内容区) |
| 高度回落 ≤ 288px | **恢复显示**(提交清空/删行/撤附件) |
| composer 在 DOM 找不到(加载/重载) | 隐藏 |
| CDP 不可用(无端口/探锚死/文件陈旧 >2s) | **降级基线**:常量锚定常显(v0.11 行为),日志记一次 |

阈值默认 288px≈基线+60css(约两行草稿余量),json `showMaxComposerPx` 可调。真数据接入后再叠加「无生成 N 秒淡出」时间维策略(v0.13,本文档只预留口径)。

### 5. 生死与降级

- ZCode 退出 / 目录被删 → 现有自退机制不动;
- CDP 断 → 落基线层 + 托盘气泡提示一次;composer 消失(重载中)→ 隐藏,不追残影;
- 多 ZCode 窗口:沿用单主窗口假设(v0.10 同),跟焦点窗口。

## 五、变体 → 锚规则(浮标形态落地时用)

| 变体 | x | y | 基线可用? |
|---|---|---|---|
| A 幽灵行(居中) | composerCenter − w/2 | composerTop − 8css − h | ✅ 直接 |
| **B+E 徽章仪表(右置,已定稿)** | composerRight − w | 同上 | ⚠️ 需右缘 → CDP,或短期退化:composerCenter + 半宽常量 |
| C 状态条(全宽) | composerLeft,w=composerWidth | 同上 | ⚠️ 需边缘 → CDP 或退化居中 |
| D 内嵌顶栏 | (浮动态=覆盖输入框内部顶缘,y=composerTop+1) | — | ❌ 只建议 CDP,或不做浮动形态 |

> **2026-09-28 应用定稿:B+E1(徽章仪表 · 双胶囊 · 右置 + 呼吸绿点)**。演进:原 B(胶囊左置)+ E(迷你仪表右置)→ 合并右置 → 加 C/D 同款呼吸绿点 → 三形态对比(双胶囊/无胶囊/单胶囊)→ 定稿双胶囊。锚点=输入框右缘,是 CDP 层的首个受益形态;基线层过渡期用"中心 + 半宽常量"近似。
> 原型归档:本目录 `zcode-composer-stats-prototypes.html`(自包含单文件,双击即看;B+E1 区块带定稿徽标,其余方案保留对照)。

## 六、备选:方案三 = 不做悬浮窗

ZCode 已开源,`ChatPromptEditor` 有现成 `topContent` 插槽——自编译包里塞 10 行 React 组件(原型 D),**定位问题整体消失**(flex 布局自己管),还白送主题联动。代价:每次官方更新要 rebase。仅作为"受够了锚定工程"时的出路记录在案。

## 七、实施切片

1. **v0.11** 基线层:ps1 垂直公式上移 + 实测常量 + 变体 A 形态 + 打字期淡出 → 先看真机效果;
2. **v0.12** CDP 层:launcher(带 flag)→ anchor-probe.mjs → HttpListener → SetDynamicAnchor → 变体 B/C/E 解锁;
3. 每片都按老规矩:代码进 stats-widget/,README + 开发日志双 commit,改缓存同步回桌面仓库。
