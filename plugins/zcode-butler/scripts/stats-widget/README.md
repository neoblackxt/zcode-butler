# 码管家·性能浮标(stats-widget)v0.12.3

zcode-butler 双悬浮窗之二(另一个是右缘「用量面板」butler-widget)。悬浮在 ZCode
输入框**右上方**,流式生成期间显示首 token 延迟与 decode 速度:

```
(● ⚡ 首 token 0.86s)(▁▃▅ 38.4 tok/s)      ← B+E1 双胶囊,右缘贴输入框右缘
```

当前为**假数据**(页面内四态周期轮播:空闲→等首token→流式中→完成)。真数据接入点见文末。

## 定位与自适应(UIA 通道,v0.12.2 起)

**架构**:独立探针进程 `anchor-probe-ui.ps1`(宿主启动时经 `anchor-probe-launch.vbs`
拉起,ShellExecute 逃 Job 连坐)每 120ms 读一次 ZCode 输入框的实时几何,原子写
`~/.zcode/stats-widget-anchor.json`;宿主 33ms tick 消费锚文件换算目标位置。

| 层 | 机制 |
|---|---|
| **探锚** | UIA 无障碍树找 `ClassName='min-h-10 max-h-40…'`(LexicalChatInput 原版类名)的 Edit,**取最底部者**(消息行内编辑同款类名);回合运行中 Edit 掉出 a11y 树时降级锚**工具条最右 Button**(发送/加入队列,右缘+21=form 右缘,高恒 182) |
| **输出契约** | `{"mode":"phys","right":R,"top":T,"height":H,"theme":"dark|light"}`(物理屏坐标,宿主免换算直用) |
| **跟随** | 宿主 33ms tick 滑翔插值(每 tick 向目标走 45%,2px 吸附,布局切换 ~200ms 滑翔不闪现);窗口拖动/缩放由 C# WinEvent 帧级跟随按「窗口相对偏移」贴住(滑翔期烘焙当前位,防终值抢拍抖动);OnLocChange 只认主窗口 HWND |
| **出现时机** | 状态机:composer 高 >312px 隐藏(滞回 24px)、≤288px 恢复;**输入框不在(设置/搜索/自动化/插件市场等页面或被覆盖)直接隐藏**;附件行(topContent)计入探测(Image 角色带状扫描,form 顶=chipsTop−21);探针失联 ≤10s 保持原位、>10s 落基线常量锚(v0.11 公式,composerHeight=182/halfWidth=841 实测常量,json 可调) |
| **主题** | 探针采样编辑器右/下留白亮度(避开字形),20 采滑动窗口 ≥16 一致 + 切换后 5s 驻留 → 宿主 PostJson `{"type":"theme"}` → 页面切换 zai-light/zai-dark 双配色 |
| **数值显示(v0.12.4)** | 默认**常驻空闲稳态**(数值 —、点灰、火花线趴平)——空白/非生成会话不轮播不闪现;四态语法由真数据(v0.13 rollout)或宿主 PostJson `{"type":"state"}` 驱动,`{"type":"demo"}` 显式开启轮播演示 |
| **探针生命周期** | 独占句柄锁(`FileShare.None`,进程死 OS 自动释放,零竞态);UIA 连接劣化(老进程对活窗口返回空树)→ 连续 5s 失锚自愈接力(先放锁再拉继任);ZCode 消失 >10s 自退 |

**为何是 UIA 而非 CDP**:打包版 Electron 41 静默丢弃 `--remote-debugging-port`
(带显式 `--user-data-dir` 同样无效;`packages/desktop/src/main/index.ts` 仅开发态
append 9229;实测主进程零监听)——CDP 路线对发行版 ZCode 是死路。UIA 无需任何启动
开关,对运行中实例直接生效;代价:启动后数秒 a11y 树预热期浮标隐藏。完整决策记录见
`docs/knowledge/2026-09-28-性能浮标定位通道选型.md`。

## 样式(B+E1 定稿,2026-09-28)

双胶囊 mention chip 同族:24px 高 / 11px 字 / surface 底(5% 白)+ 发丝边框(10% 白)。
第一枚 `呼吸绿点(#46bf72/#1e8a3e)+⚡+首token 等宽数值`;第二枚 `sky 火花线(12 根
3px,#4099ff/#0b7fff)+tok/s`。色值逐值取自 zai-org/ZCode `theme-zai-light/dark`
token;设计原稿见仓库 `ZCode UI/zcode-composer-stats-prototypes.html`(八方案对照,
B+E1 带定稿徽标)。

**四态数值动画** `body[data-state]`:idle(灰点静止/数值 —/火花线趴平)、
waiting(sky 点快闪+ttft 计数)、streaming(绿点呼吸+火花线全动+数值跳动)、
done(定格 2.5s)。页面写 CSS px(WebView2 按 dpr 1.75 光栅化,视口=窗口物理÷1.75,
写物理像素会被放大裁切)。

## 文件

| 文件 | 职责 |
|---|---|
| `stats-widget.ps1` | 宿主:透明窗口 + DComp/WebView2 合成、滑翔跟随、状态机、主题推送(UTF-8 **带 BOM**) |
| `stats-widget.html` | 视觉层:双胶囊 + 四态动画 + 双主题(宿主 PostJson 驱动) |
| `anchor-probe-ui.ps1` | UIA 探针:几何+主题采样 → 锚文件;独占句柄锁+自愈接力(纯 ASCII 防 BOM 坑) |
| `anchor-probe-launch.vbs` | 探针启动器(ShellExecute 逃 Job 连坐) |
| `launch.mjs` / `stats-launch.vbs` | SessionStart 钩子启动链(单实例) |
| `stop.ps1` | 停宿主 + 连带清探针 |

## 启动 / 停止 / 配置

- 自启:插件 hooks.json SessionStart → `launch.mjs`
- 停止:`stop.ps1`;显隐:**Ctrl+Alt+S**
- `~/.zcode/stats-widget.json`(全部可选,1.75dpr 物理像素):`composerHeightPx`(182)、
  `composerHalfWidthPx`(841)、`gapAbovePx`(8)、`showMaxComposerPx`(288)、
  `centerXOffset`(63)、`winW`/`winH`(0=自动 600x52)

## 真数据接入(待办 v0.13)

数据源 `~/.zcode/cli/rollout/model-io-sess_<会话ID>.jsonl`(每行一次请求,含
durationMs 与 response.usage)→ 宿主 tail 计算 → PostJson 推
`{"type":"state","v":"waiting|streaming|done|idle"}` + 数值,页面四态语法已就绪:
首token=请求延迟、tok/s=滑动窗口 output÷duration。
