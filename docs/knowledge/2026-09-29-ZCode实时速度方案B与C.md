# ZCode 性能胶囊·实时速度方案 B 与 C(含 B 失败复盘)

> 2026-09-29 · 码管家 stats-widget v0.13 系列 · 目标:胶囊实时速度达到 oc-tps 体感
> (每秒跳动数次,覆盖**思考+文字**全程;当前 v0.13d 只有文字段实时)

## 〇、背景:为什么"实时"这么难

oc-tps 之所以能实时,是因为它是 **OpenCode 进程内插件**,站在事件总线上直接收
`session.text.delta` 事件(30-70ms 一批);OpenCode 还额外提供官方 `serve /event` SSE
给外部进程。**ZCode 两者都没有**,已逐一证伪的外部通道:

| 通道 | 结论 |
|---|---|
| rollout 转录 JSONL | 只在**调用完成时**写一条,流式期间零写入 |
| db.sqlite part 表 | 行不增长(完成时一次性落库);"文件冻结"是 WAL 尺寸假象,但行也不流式 |
| hook 系统 | 契约仅 7 事件,无流式 |
| text_delta 事件 | 只存在于内存 event store → 桌面私有 stdio 管道,不落盘 |
| debug server | 只 watch 文件 mtime;网络抓包是 MITM(需 CA,排除) |
| UIA 读转录区 | **文字段实时(216ms/批)但思考不可见**(思考块折叠渲染,完成时大块到达) |

真实时(含思考)只剩两条侵入路:B(已阵亡)与 C(待决)。

---

## 一、方案 B:stdio wrapper(已失败,已放弃)

### 原理
ZCode 官方留有生产环境变量 `ZCODE_AGENT_SERVER_COMMAND`:桌面用它指定的命令替代内置 CLI
拉起 agent 进程。插入一个 tee 型 wrapper:字节级双向透传(fail-open),旁路解析
CLI→桌面管道上的流式帧(`{"method":"session/event","params":{"payload":{"kind":
"text_delta"|"reasoning_delta","delta":"..."}}}`)提取字符增量喂给胶囊。
**含思考全量,帧粒度 30-70ms。**

### 实施记录(2026-09-29)
- wrapper:`~/.zcode/stats-widget-wrapper.mjs`(node,零依赖);单元测试提取精确命中、
  透传逐字节保真;真实冒烟正确拉起 `D:\ZCode\ZCode.exe ... zcode.cjs app-server --stdio`
- 接线(用户级环境变量):
  - `ZCODE_AGENT_SERVER_COMMAND=D:\Java\Tools\nodejs\node.exe`
  - `ZCODE_AGENT_SERVER_ARGS_JSON=["C:/Users/27844/.zcode/stats-widget-wrapper.mjs","app-server","--stdio"]`
  (源码确认 ARGS_JSON 是**替换**默认参数,须自带 `app-server --stdio`)

### ⚠️ 失败复盘(18:1x 事故)
- **现象**:设置环境变量并重启后,**ZCode 桌面打不开**,卡在启动页。
- **根因**:ZCode **3.14.4** 把启动时的"独立存储准备"升级为硬性要求;自定义 Agent 命令
  没有配套的 storagePreparationEntry → 抛 `unsupported_runtime` → 启动死锁。
  (我读的源码是 3.14.3:该版本自定义命令只是"跳过握手";一天版本漂移让结论失效)
- **修复**:删除上述两个用户环境变量即恢复(由另一 agent 执行,provider/数据库未受影响)。
- **教训**:①动启动链前必须核对目标机实际版本;②冒烟测试必须覆盖宿主的完整启动路径,
  不能只验"子进程能拉起";③源码级结论有保质期。
- **状态**:**已放弃**。残留文件已全部清除(wrapper/live2/心跳/日志)。**不要恢复这两个
  环境变量,恢复即再坏。**(帧提取代码逻辑已存档于本文件与记忆,方案 C 的 SSE 解析可复用)

---

## 二、方案 C:本地反向代理(待决,当前唯一真实时活路)

### 原理
ZCode 的所有模型请求走 `~/.zcode/v2/config.json` 里 provider 的 baseURL。把这一个字段
指向本机代理,代理原样转发到智谱官网,回程 SSE 流逐帧透传给 ZCode 的同时旁路计数:

```
ZCode ──HTTP──▶ 127.0.0.1:端口(本地代理,只听本机)
                    │ 原样原头转发
                    ▼
            https://open.bigmodel.cn/api/anthropic
                    │ SSE 回程逐帧透传(不缓冲)
ZCode ◀────────────┘
                    └旁路:text_delta/thinking_delta 字符增量 → live2.jsonl → 胶囊滑窗
```

### 实施步骤(如启动)
1. 写本地代理(node,零依赖,127.0.0.1 监听;SSE 透传不缓冲;看门狗自动重启);
2. 离线测试:合成 SSE 流验证透传保真+计数精确;
3. **改 `~/.zcode/v2/config.json` 的 baseURL 一个字段——改前备份原文件+diff 给用户过目**;
4. 改后三验证:消息能发出/胶囊出实时数(含思考)/butler 用量面板正常;
5. 卸载 = baseURL 改回原值(30 秒恢复,ZCode 无感知)。

### 影响清单(诚实版)

| 维度 | 影响 |
|---|---|
| 红线文件 | 动 `~/.zcode/v2/config.json`(但只改 baseURL 一个字段;butler 凭证探测也读它,改后须验证) |
| **失败模式** | 代理挂 = **消息发不出去**,但 **ZCode 本体正常打开**;恢复=改回一个字段。**与 B 的本质区别:B 炸启动页(打不开),C 炸请求链(打得开、发不出)** |
| 性能 | 多一跳本机回环(<1ms),SSE 逐帧转发,体感无差 |
| 安全 | API key 经本机代理内存(不落盘),只监听 127.0.0.1,外部不可达 |
| 契约稳定性 | 只依赖智谱**公开 API 的 SSE 格式**(比 B 的内部 stdio 帧稳定得多),ZCode 升级不影响 |

### 智谱看到的请求有何不同?1.5 倍额度还在吗?

实测证据(rollout 里记录的 ZCode 请求头,2026-09-29):

```
user-agent: ZCode/3.14.4
x-zcode-app-version: 3.14.4        x-title: Z Code@electron
x-zcode-agent: glm                 x-release-channel: production
x-platform: win32-x64              x-os-category: windows
http-referer: https://zcode.z.ai   (另有 trace/session/query 全套识别头)
```

- **应用层:完全一致**。代理原样转发全部请求头与请求体,智谱看到的
  UA/`x-zcode-*`/referer/key 与现在逐字节相同——按这些标识识别 ZCode 流量的任何机制
  (包括 Coding Plan 的额度倍率)**不受影响**。
- **唯一理论残留:传输层指纹**。请求的 TLS/HTTP 栈从 Electron/Chromium 变为 node
  (JA3 指纹、头顺序、h2/h1.1 等连接层特征)。**无任何证据表明智谱按传输层指纹计费**,
  业界也没有供应商这样给客户端加权;但如实列出。
- **验证手段现成**:开启代理后用 butler 用量面板观察额度消耗速率是否符合 1.5x 口径,
  对比开/关两天的曲线即可实证;任何异常 → 改回 baseURL 立即回到原状。

### 追问:智谱到底靠什么验证"用的是 ZCode"?

智谱未公开识别机制。基于本机抓到的真实请求,线上可见的识别载体共三层:

1. **请求头全家桶(最可能的主载体)**:`user-agent: ZCode/3.14.4` + `x-zcode-app-version /
   x-zcode-agent / x-title / http-referer(zcode.z.ai)` + trace/session/query 全套。
   其他 agent 不发这些头——这正是"只有 ZCode 有折扣"的实现方式。理论上可伪造,
   但事实机制即此;代理场景下不是伪造,是真 ZCode 的真实头原样到达。
2. **Coding Plan 专属 key**:订阅与额度池挂在 key 上,代理不碰。
3. **辅助特征**:ZCode 注入的 system prompt 内容(请求体内),代理不碰。

三层全部在应用层,C 逐字节转发 → 识别结果不变。不能排除的只剩传输层指纹参与
(无证据,可用 butler 面板开/关对比实测,异常即回滚)。

**指纹风险的逻辑排除与可选加强**:①TLS 指纹在逻辑上就不可能是折扣判据——Claude Code
(node/undici 口音)、各类 Python/Go 工具、Cline(Electron=Chromium 口音)共用同一
Coding Plan 生态,折扣却只跟"是否 ZCode"走,明牌在请求头;②真需抹平时有成熟方案
(curl-impersonate / curl_cffi impersonate="chrome",ClientHello+HTTP/2 设置帧全部
Chrome 同款),作为**可选加强项**预留:实测额度口径异常时再上(半天工作量),不预置
(不为无证据假设引入二进制依赖)。

---

## 三、当前运行形态(无论 B/C 均为回退底座)

**v0.13d**:UIA 文字段实时(216ms 粒度,探针 5 分钟自愈接力防劣化)+ db 真值通道
(本轮平均=Σoutput/Σ(duration−TTFT)、TTFT 真值、字符比自校准)。
胶囊此刻的功能与准确度不依赖 B/C;B/C 只是把"实时"从文字段扩展到思考段。

## 四、决策点

- 选 C:按上述步骤执行(先离线测试,改 config 前 diff 过目)。
- 不选:维持 v0.13d,择日合并入仓库。
