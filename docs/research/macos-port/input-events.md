# macOS 全局输入监听与事件注入能力调研

- 对应问题：[GitHub issue #3「调研 macOS 全局输入监听与事件注入能力」](https://github.com/Nightchamp/arknights-frame-assistant/issues/3)
- 调研日期：2026-08-08
- 核对基线：Apple macOS 26.5 SDK 的公开头文件与 Apple 第一方文档/API 参考
- 边界：不关闭 SIP，不使用内核扩展，不注入游戏进程

## 结论摘要

**建议结论：有条件可行，应进入小范围原型验证，但尚不足以直接承诺完整移植。** 在既定边界内，公开的 CoreGraphics Quartz Event Services 已提供全局键鼠事件 tap、条件丢弃/替换、键盘/鼠标/滚轮事件构造，以及向系统事件流或指定 PID 投递事件的能力。[S2][S3] 因而，AFA 的“监听热键、按目标进程决定拦截或透传、再注入组合输入”在 API 层面不存在明确阻断。[S2][S3]

尚未由 Apple API 契约保证的是：目标游戏是否接受 `CGEventPostToPid` 或系统路由的合成事件、鼠标注入是否满足“不移动真实指针”的产品语义、Secure Event Input 开启时 event tap 与注入的实际表现，以及 16/33/166 ms 操作序列在负载下的抖动和可靠性。[S3][S6][S10] 这些必须在真实游戏、实际发布的 quarantined ad-hoc 构建和目标 macOS 版本上验证，不能从 API 存在性推导出来。

不建议把特权 helper 作为基础方案。root helper 由当前公开头文件明确增加的非弃用相关能力，是创建仅 root 可创建的 `kCGHIDEventTap`；用户会话级、标注会话级和按 PID 的 event tap 已覆盖当前需求的核心语义。[S2] 权限预检针对“当前进程”，窗口枚举还要求 Quartz GUI session，Secure Input 契约也没有提供 root 绕过接口，因此 helper 不会自动把主应用的 TCC 授权、目标窗口判断或 Secure Input 限制一起解决。[S4][S6][S8]

## 已确立事实

### 1. 全局键鼠观察

#### `NSEvent` 全局/本地 monitor

- `NSEvent.addGlobalMonitorForEvents` 接收系统发往其他应用的事件副本；事件异步送达，只能观察，不能修改事件或阻止其到达原目标，而且不会收到发往本应用的事件。[S1]
- `NSEvent.addLocalMonitorForEvents` 只处理本应用在 `NSApplication.sendEvent(_:)` 分发前的事件；返回 `nil` 可以停止本应用内分发，但它不是跨进程拦截机制。[S1]
- Apple 的 AppKit 头文件明确规定：`NSEvent` global monitor 监控按键相关事件需要 Accessibility 已启用或当前应用被信任为 Accessibility client。[S1][S5]

因此，`NSEvent` global monitor 适合只读状态或低风险快捷键提示，不适合 AFA 所需的全局条件拦截；local monitor 也不能拦截发往游戏的事件。[S1]

#### CoreGraphics event tap

- Quartz event tap 可以位于 HID 入口、用户 session 入口、已标注目标应用的 session 位置，或者指定进程的事件入口；tap 由事件 mask 选择键盘、鼠标、滚轮等事件类型。[S2]
- `CGEventTapCreateForPid` 的公开契约是报告路由到指定应用的事件；它可作为按进程天然限域的候选方案。[S2]
- event tap 分为 passive listener（`kCGEventTapOptionListenOnly`）和 active filter（`kCGEventTapOptionDefault`）。active filter 可以原样放行、修改、替换或丢弃事件；回调返回 `NULL` 即删除该事件。[S2]
- event tap 的 Mach port 必须加入 `CFRunLoop`；回调在承载该 source 的 run loop 上执行。[S2]
- 只有 root 进程能把 tap 放在 `kCGHIDEventTap`；非 root 调用会返回 `NULL`。公开 API 同时提供非 root 可使用的 session、annotated-session 和 per-PID tap 位置。[S2]

### 2. 拦截、透传与替换

- active tap 回调返回原事件即透传，返回修改后的原事件或新事件即替换，返回 `NULL` 即抑制原事件；listen-only tap 是被动监听器，不承担过滤语义。[S2]
- `CGEventTapPostEvent` 可从 tap 回调所在位置插入新事件；新事件先于回调返回的事件进入系统，并会被位于该 tap 之后的 taps 看到。[S3]
- `CGEventPost` 把事件投递到指定的 tap location，并使事件继续通过该位置之后的 taps。[S3]
- 每个事件有最多 64 位的 `kCGEventSourceUserData`；事件也公开源 PID 字段。AFA 可以据此给自身合成事件打标，并在自己的 tap 中跳过，以避免“拦截 -> 注入同键 -> 再拦截”的递归。[S2][S9]

上述接口足以表达 AFA 的两条基本路径：命中条件时删除原事件并执行动作；未命中条件时直接返回原事件。它也足以表达守卫失败后的“删除原事件，再补发等价 down/up”路径，但多键并发、修饰键和 key repeat 的状态机仍需原型验证。[S2][S3]

### 3. 事件构造与注入

- `CGEventCreateKeyboardEvent` 以 macOS virtual key code 创建 key-down/key-up；修饰组合需要显式生成修饰键和普通键的 down/up 序列。[S3]
- `CGEventCreateMouseEvent` 以全局显示坐标、鼠标事件类型和按钮创建鼠标事件；公开头文件记录当前事件系统最多支持 32 个按钮。[S3]
- `CGEventCreateScrollWheelEvent` 可创建按行或按像素计量的滚轮事件。[S3]
- `CGEventPost` 面向事件流位置投递，由系统继续正常路由；`CGEventPostToPid` 面向进程投递，并在该进程的 event taps 之前进入。[S3]
- `CGEventPostToPid` 的参数只有 PID 和事件，没有窗口句柄参数。因此它提供的是进程级而不是窗口级定向；同一进程多窗口时仍需由 AFA 自己判断应否投递。[S3]
- `CGEvent` 暴露 timestamp 的读写 API，但 Apple 的公开契约没有为 `CGEventPost` 或 `CGEventPostToPid` 声明投递截止时间、实时调度保证或与游戏逻辑帧对齐的保证。[S3][S10]

在本次审查的公开 Quartz Event Services 能力中，输入构造器覆盖键盘、鼠标和滚轮，没有与 Windows Touch Injection 等价的公开“无真实指针副作用的触摸注入”契约。[S3] 是否可用 `CGEventPostToPid` 实现 AFA 所需的后台/无指针移动点击语义，属于未决事实。[S3]

### 4. 目标进程和目标窗口限域

Apple 公开接口提供四种可组合的限域信号：

1. `NSWorkspace.frontmostApplication` 返回将接收键盘事件的最前台应用，可用 PID 或 bundle identifier 与游戏进程匹配。[S7]
2. `CGEventTapCreateForPid` 只报告路由到指定进程的事件，适合“游戏实际收到才触发”的严格进程限域。[S2]
3. annotated-session 位置处的事件已被标注将流向特定应用，`kCGEventTargetUnixProcessID` 暴露事件目标 PID。[S2]
4. 鼠标事件公开 `kCGMouseEventWindowUnderMousePointer` 和 `kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent` 字段；`CGWindowListCopyWindowInfo` 可返回当前用户 session 内按前到后排列的屏上窗口及其 bounds、window ID 和 owner PID。[S2][S8]

这些接口能实现“不在目标游戏时不吞键”的保守策略：键盘以事件目标 PID 或 frontmost PID 为准，鼠标以事件携带的窗口 ID 或前到后的窗口列表命中测试为准。[S2][S7][S8] 但是，哪些字段在目标游戏使用的窗口技术、全屏模式和事件类型上稳定填充，Apple 没有在上述字段契约中给出逐事件保证，仍需实测。[S2]

### 5. TCC：Input Monitoring、PostEvent 与 Accessibility

- macOS 10.15 起，CoreGraphics 公开 `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`，分别预检和请求当前进程的事件监听权限；请求可能触发系统提示。[S4]
- 同期公开的 `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` 分别预检和请求当前进程的事件合成/投递权限。[S4]
- Apple 的 PPPC payload 规范把 `ListenEvent` 定义为允许通过 CoreGraphics/HID API 监听所有进程的 CGEvent/HID 事件，把 `PostEvent` 定义为允许通过 CoreGraphics API 向系统事件流发送 CGEvent；规范将二者列为不同服务。[S4]
- `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` 检查的是当前进程是否为受信任的 Accessibility client；带 prompt 选项时提示是异步的，不改变本次返回值。[S5]
- `AXMakeProcessTrusted` 曾提供 root 进程把指定可执行文件标记为受信任 Accessibility client 的接口，并要求目标进程重启，但 Apple 自 macOS 10.9 起已将其弃用；它不是现代 TCC 方案的可用基础。[S5]
- `NSEvent` global monitor 的按键观察依赖 Accessibility trust；Apple DTS 对现代 macOS 的第一方说明则建议沙盒应用使用 listen-only `CGEventTap` 和 Input Monitoring，而不是 `NSEvent` global monitor。[S1][S12]
- Apple DTS 进一步说明，`ListenEvent` 和 `PostEvent` 是独立 TCC 服务：监听在系统设置中对应 Input Monitoring；投递权限显示在 Accessibility 区域，但不等同于获得完整 Accessibility API 能力。可分别使用上述 CoreGraphics preflight/request API 管理。[S13]

对 AFA 而言，被动监听应显式走 ListenEvent 检查；事件注入应显式走 PostEvent 检查。[S4] active filter 既读取又改变事件，但 Apple 的公开 API 文档没有给出“只授予 ListenEvent”“只授予 PostEvent”“两者都授予”时 `kCGEventTapOptionDefault` 的完整矩阵，因此 active suppression 的当前系统行为必须原型验证。[S2][S4][S13]

### 6. Secure Event Input

- `EnableSecureEventInput` 的公开契约是：开启后，键盘输入只进入拥有键盘焦点的应用，不再回显给可能通过 event monitor target 观察键盘输入的其他应用；密码控件会自动进入该模式。[S6]
- Secure Event Input 采用配对计数；只有启用者匹配调用 `DisableSecureEventInput` 才应关闭。进程崩溃时，若没有其他进程仍启用，系统会自动清除该状态。[S6]
- `IsSecureEventInputEnabled` 只能返回“是否有任意进程开启”，不能指出开启者；其公开注释还标明该 API 非线程安全。[S6]

因此 AFA 不能把“强制关闭别的应用启用的 Secure Event Input”作为受支持方案。可支持的行为是检测全局状态，在状态开启时停止依赖全局键盘观察的功能并给出明确状态；event tap 是否完全静默、鼠标是否仍可用、已授权的合成键是否被目标接受，需实测，Apple 的 Secure Event Input 契约没有逐项说明这些行为。[S6]

### 7. App Sandbox

- Apple 的 App Sandbox 文档把完整 Accessibility API 控制列为与沙盒不兼容的能力；因此依赖 AX UI hierarchy 控制其他应用不是可取的沙盒架构。[S11]
- Apple DTS 的第一方说明确认：macOS 10.15 起，获得用户 Input Monitoring 同意的 listen-only `CGEventTap` 可在沙盒应用和 Mac App Store 应用中工作。[S12]
- Apple DTS 的后续说明确认：`CGEventPost` 使用独立 PostEvent privilege，现代 macOS 上该 privilege 也可供沙盒应用使用，但它只允许事件投递，不授予完整 Accessibility API 访问。[S13]

所以，若 macOS 版 AFA 只使用 CoreGraphics 的 ListenEvent/PostEvent 能力和普通窗口元数据，而不依赖 AX 控制其他应用，App Sandbox 并非已知的绝对阻断项。[S4][S8][S12][S13] 但正式签名、notarized、sandboxed 构建与 Xcode 调试构建的 TCC 身份和首次授权流程必须分别验证，不能只以开发环境结果作结论。[S4][S12][S13]

### 8. 回调时序和失效约束

- event tap 回调运行在加入 tap Mach port source 的 `CFRunLoop` 上；其线程安全语义由该 run loop 及其环境决定。[S2]
- tap 无响应或被用户要求禁用时，回调会收到 `kCGEventTapDisabledByTimeout` 或 `kCGEventTapDisabledByUserInput`；可用 `CGEventTapEnable` 重新启用。[S2]
- `CGGetEventTapList` 暴露每个 tap 的最小、平均和最大微秒级延迟统计；读取列表会把最小/最大值重置为对应平均值。[S2]
- Apple 公开头文件没有声明触发 timeout 的固定毫秒阈值，也没有为事件注入声明实时调度或最大抖动保证。[S2][S3]

因此 tap 回调不应承担 16/33/166 ms 的等待或完整动作序列；它只应完成目标判断、状态更新、抑制/透传决定和任务入队，延迟序列在独立调度路径执行。[S2] AFA 仍需用 `CGGetEventTapList` 和自身 monotonic timestamps 量化回调延迟、注入间隔和 timeout 恢复，而不是把 `CGEvent.timestamp` 当成投递保证。[S2][S3]

### 9. 特权 helper 是否改变能力

**会改变一项能力，但不会把整体问题变成“无权限、无限制”的输入通道。**[S2][S4][S6][S8]

- root 进程可以创建 `kCGHIDEventTap`，普通用户进程不能；这是公开 API 明确赋予 privileged helper 的增量能力。[S2]
- 历史上的 root-only `AXMakeProcessTrusted` 已自 macOS 10.9 弃用，不能作为 helper 绕过现代用户授权的设计依据。[S5]
- event listening 和 event posting 的 preflight/request API 都检查“当前进程”。将 tap 或 posting 移入 helper，会把调用和授权边界移到 helper，而不是把 helper 的状态自动授予主应用。[S4]
- `CGWindowListCopyWindowInfo` 在调用者不位于 Quartz GUI session 或 WindowServer 不可用时返回 `NULL`；系统级 daemon 因而不能被假定具备与登录用户应用相同的窗口限域环境。[S8][S14]
- session、annotated-session、per-PID event tap 和 `CGEventPostToPid` 已公开提供 AFA 所需的观察、过滤和进程投递原语，并不要求使用 root-only HID tap。[S2][S3]
- Secure Event Input 的公开契约没有给 root/helper 提供绕过接口。[S6]

由此推导，helper 只在原型证明“必须在 HID 入口拦截”时才可能有价值；目前没有第一方证据表明 AFA 的目标游戏需要该 tap 位置，也没有证据表明 helper 能改善 Secure Input、窗口限域、注入接受度或时序保证。[S2][S3][S6][S8] 当前方案不应引入由 system launch daemon 带来的额外进程、IPC 和授权面。[S14]

## 对 AFA 的工程含义

以下是由上述事实推导的建议，不是 Apple 对目标游戏行为的保证。

### 推荐能力组合

| AFA 需求 | 首选公开能力 | 保守策略 | 依据 |
| --- | --- | --- | --- |
| 全局键鼠观察 | session/annotated-session 或 per-PID `CGEventTap` | 先检查 ListenEvent；无权限时完全不启用热键 | [S2][S4] |
| 条件吞键 | `kCGEventTapOptionDefault` active tap | 目标身份不明确时一律透传 | [S2][S7][S8] |
| 键盘目标限域 | per-PID tap、target PID、frontmost PID | 三者不一致时不拦截 | [S2][S7] |
| 鼠标目标限域 | 事件携带的 window ID，必要时结合前到后窗口列表 | owner PID 或窗口命中无法确认时不拦截 | [S2][S8] |
| 键盘/鼠标/滚轮注入 | `CGEventCreate*` + `CGEventPost` 或 `CGEventPostToPid` | 先验证目标游戏接受路径，再固定一种投递策略 | [S3] |
| 防止自身递归 | `kCGEventSourceUserData` 标记合成事件 | 自身标记事件永不进入动作匹配 | [S2][S9] |
| tap 失效恢复 | 处理 disabled event 并调用 `CGEventTapEnable` | 恢复期间停止吞键 | [S2] |
| Secure Input | `IsSecureEventInputEnabled` | 开启期间暂停键盘热键，不尝试关闭他人状态 | [S6] |

### 移植语义差异

- CoreGraphics 公开的 mouse event 使用全局显示坐标，没有公开的无指针副作用 touch-injection 契约；macOS 版不能在实测前承诺“鼠标不移动、焦点不变化”。[S3]
- AFA 的键盘焦点和鼠标悬停策略在 macOS 上需要组合 frontmost PID、event target PID、鼠标窗口字段和窗口列表，并优先失败开放（passthrough）。[S2][S7][S8]
- macOS event tap 存在 timeout-disable 机制，动作等待应移出 tap callback。[S2]
- macOS 用户至少需要完成监听和投递两类 TCC 授权流程；单纯取得 Input Monitoring 不能被当作已取得注入能力。[S4][S13]

## 需要原型确认的未决事实

下列问题没有被 Apple 的公开契约解析到足以支撑产品承诺的程度：

1. **权限矩阵**：在无授权、仅 ListenEvent、仅 PostEvent、两者都有四种状态下，listen-only tap、active tap、`CGEventPost`、`CGEventPostToPid` 分别如何返回或失效；撤销权限后是否需要重启。[S2][S4][S13]
2. **实际发布构建的 TCC 身份**：开发构建与外部下载、带 quarantine 的 ad-hoc 发布构建在首次提示、系统设置展示、升级覆盖和权限撤销时的行为；App Sandbox 与签名方式是两个独立维度，如架构仍考虑 sandbox，还需分别验证 sandboxed/unsandboxed 组合。[S4][S12][S13]
3. **目标游戏接受度**：游戏是否接收系统路由和 PID 定向的 virtual-key、修饰键、鼠标按钮、侧键、滚轮、autorepeat 及 down/up 序列；两种投递路径是否有差异。[S3]
4. **目标限域可靠性**：窗口化、原生全屏、多显示器、Mission Control、游戏失焦但鼠标悬停、启动器与游戏多进程场景下，per-PID tap、target PID、window-under-pointer 字段是否一致。[S2][S7][S8]
5. **鼠标副作用**：`CGEventPost` 与 `CGEventPostToPid` 的点击是否移动可见指针、改变焦点或被发送到错误窗口；能否满足现有 touch injection 的产品体验。[S3]
6. **Secure Input**：开启时，各 tap 位置是否收到键盘/鼠标事件，active suppression 是否继续生效，系统路由和 PID 定向的合成事件是否被目标接受。[S2][S3][S6]
7. **时序**：系统空闲和高负载下 16/33/166 ms 序列的实际中位数、P95/P99、事件顺序、丢失率，以及 tap timeout/恢复次数。[S2][S3]
8. **递归与物理状态**：自身 user-data 标记是否在两种投递路径中完整保留；多键并发、修饰键、key repeat、切出游戏时能否保证物理 up 不被吞。[S2][S3][S9]
9. **最低支持版本**：目标最低 macOS 版本上的 TCC UI 和 CoreGraphics 行为；监听/投递 preflight API 自 macOS 10.15 才公开。[S4]

原型通过标准应至少包括：目标外零误吞键、权限缺失或撤销时失败开放、Secure Input 时可恢复、连续压力输入无卡键、目标游戏中注入成功、16/33/166 ms 序列达到产品定义的容差，以及鼠标副作用可接受。[S2][S3][S4][S6]

## 推荐可行性结论

1. **基础全局热键和条件拦截：可行。** CoreGraphics active event tap 直接提供监听、修改、删除和按进程 tap 的公开能力。[S2]
2. **键盘/鼠标/滚轮注入：API 可行，产品兼容性待证。** Apple 提供构造和系统流/PID 投递接口，但没有保证特定游戏接受合成输入。[S3]
3. **目标窗口限域：可设计为保守可行。** 使用 PID 与窗口字段的多重确认，并在信息不一致时透传，可以避免把不确定事件吞掉；目标游戏上的字段稳定性仍需原型验证。[S2][S7][S8]
4. **权限：可管理但不可隐藏。** ListenEvent/PostEvent 必须作为独立能力检查和引导；不要以完整 AX Accessibility 控制作为基础依赖。[S4][S5][S11][S13]
5. **Secure Input：明确限制。** AFA 应检测并暂停相关能力，不能承诺绕过。[S6]
6. **App Sandbox：不是基础阻断项。** Apple DTS 明确支持现代 macOS 下经过用户同意的 CGEvent 监听和投递，但正式构建必须验证 active filtering 的完整权限矩阵。[S12][S13]
7. **特权 helper：暂不采用。** root-only HID tap 是真实增量，但当前没有证据证明它是必要条件，也不能据此推导 TCC、Secure Input、窗口 session 或时序问题消失。[S2][S4][S6][S8]

最终建议是：**批准一个仅验证输入链路的 prototype，prototype 通过后再把 macOS AFA 判定为可实施；在 prototype 之前，不引入 privileged helper，也不承诺无指针副作用点击和严格逻辑帧级时序。**[S2][S3][S6]

## 第一方来源

- **[S1]** Apple AppKit API reference: [`addGlobalMonitorForEvents(matching:handler:)`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29), [`addLocalMonitorForEvents(matching:handler:)`](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents%28matching%3Ahandler%3A%29); macOS 26.5 SDK `AppKit.framework/Headers/NSEvent.h`, “API for monitoring events in other processes” comments.
- **[S2]** Apple CoreGraphics API reference: [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services), [`CGEventTapCallBack`](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback), [`tapEnable(tap:enable:)`](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29); macOS 26.5 SDK `CoreGraphics.framework/Headers/CGEvent.h` and `CGEventTypes.h`, event tap comments, enums, callback contract, event fields and latency structure.
- **[S3]** Apple CoreGraphics API reference: [`CGEvent.post(tap:)`](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29), [`CGEvent.postToPid(_:)`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29), [`tapPostEvent(_:)`](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent%28_%3A%29); macOS 26.5 SDK `CoreGraphics.framework/Headers/CGEvent.h`, event construction and posting comments.
- **[S4]** Apple CoreGraphics API reference: [`CGPreflightListenEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess%28%29), [`CGRequestListenEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess%28%29), [`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29), [`CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29); Apple Platform Deployment, [Privacy Preferences Policy Control payload settings](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-settings-dep38df53c2a/web); macOS 26.5 SDK `CGEvent.h` permission comments.
- **[S5]** Apple Accessibility API reference: [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions); macOS 26.5 SDK `ApplicationServices.framework/.../Headers/AXUIElement.h` trust and asynchronous prompt contract.
- **[S6]** Apple Secure Event Input API and SDK specification: [`EnableSecureEventInput`](https://developer.apple.com/documentation/coreservices/1444623-enablesecureeventinput); macOS 26.5 SDK `Carbon.framework/.../Headers/CarbonEventsCore.h`, `EnableSecureEventInput`, `DisableSecureEventInput`, and `IsSecureEventInputEnabled` contracts.
- **[S7]** Apple AppKit API reference: [`NSWorkspace.frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication); macOS 26.5 SDK `AppKit.framework/Headers/NSWorkspace.h`, “application that will receive key events.”
- **[S8]** Apple CoreGraphics API reference: [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/1455137-cgwindowlistcopywindowinfo); macOS 26.5 SDK `CoreGraphics.framework/Headers/CGWindow.h`, window ordering, bounds, owner PID and Quartz GUI session requirements.
- **[S9]** Apple CoreGraphics API reference: [`CGEventSource.setUserData(_:)`](https://developer.apple.com/documentation/coregraphics/cgeventsource/setuserdata%28_%3A%29); macOS 26.5 SDK `CGEventSource.h` and `CGEventTypes.h`, 64-bit source user data and source fields.
- **[S10]** Apple CoreGraphics API reference: [`CGEvent.timestamp`](https://developer.apple.com/documentation/coregraphics/cgevent/timestamp); macOS 26.5 SDK `CGEvent.h`, timestamp accessors and posting contracts.
- **[S11]** Apple Security documentation: [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), “Review functionality that is incompatible with App Sandbox.”
- **[S12]** Apple Developer Forums, Apple DTS Engineer: [Accessibility permission in sandboxed app](https://developer.apple.com/forums/thread/707680), first-party clarification on `CGEventTap`, Input Monitoring, App Sandbox and Mac App Store use.
- **[S13]** Apple Developer Forums, Apple DTS Engineer: [Accessibility Permission In Sandboxed App](https://developer.apple.com/forums/thread/789896), first-party clarification on ListenEvent/PostEvent, `CGEventPost`, sandbox compatibility, and the distinction from full Accessibility API access; see also [thread 735204](https://developer.apple.com/forums/thread/735204) for active event tap permission discussion.
- **[S14]** Apple Service Management API reference: [`SMAppService.daemon(plistName:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon%28plistname%3A%29), identifying a privileged helper registered as a system launch daemon; combined with the Quartz GUI session requirement in [S8].
