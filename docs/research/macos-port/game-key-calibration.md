# 目标游戏键位发现与用户校准路径

- 对应问题：[GitHub issue #4「确定目标游戏键位的发现与校准路径」](https://github.com/Nightchamp/arknights-frame-assistant/issues/4)
- 调研日期：2026-08-08
- 平台边界：Apple Silicon macOS 上直接运行的官方 `明日方舟.app`，即 iOS App on Mac
- 证据边界：Apple 公开文档、公开 framework/SDK 接口、Hypergryph/Arknights 第一方公开记录、仓库源码与历史
- 排除项：不读取目标游戏的用户容器、defaults、keychain 或其他用户数据；不逆向目标二进制；不解析或依赖未公开的 Unity/游戏配置格式

## 建议结论

**未找到可支持“从另一个 iOS App on Mac 应用枚举当前游戏语义键位或 Touch Alternatives 状态/映射”的公开 macOS API。** Apple 的公开接口分别能看到物理键鼠设备与事件、部分可访问 UI 和菜单快捷键，以及在权限允许时枚举/读取一个已知 preferences domain 的原始 key/value；这些表面都不是跨进程的游戏语义绑定注册表。Touch Alternatives 的公开契约是系统提供的通用触摸替代方式和由目标开发者声明的 onboarding 类别，不是 `释放技能 -> 某键` 这样的游戏动作映射。[A1][A2][A3][A4][A6]

因此，macOS 实现应采用以下路径：

1. 不实现目标容器/defaults 扫描、AX 设置页抓取或 Unity 格式解析，也不把它们作为 fallback。
2. 只校准 issue #2 最终纳入首个公开版本、且确实需要发送键盘或鼠标输入的语义动作；不要求用户录入目标游戏的完整键位表。
3. 每项映射由用户在小助手前台本地录入，再在用户明确触发的安全测试中向目标游戏发送一次，由用户确认语义结果。只有确认后的映射可启用依赖功能。
4. macOS 的默认状态是“未映射”。Windows 参考实现中的默认键只可作为未验证提示，不能直接激活。
5. 校准数据只持久化到小助手自己的设置域，并记录目标 bundle ID、目标版本/build 和验证状态。目标游戏更新后保留候选值但暂停依赖功能，完成快速复验后再启用。
6. 拦截策略不再依赖“枚举目标游戏全部键位”。当且仅当目标身份明确、功能依赖已验证且动作已成功入队时，才消费该小助手触发键；任一条件不满足都原样透传。

该结论已经足以关闭“自动发现还是用户校准”的路线选择。issue #2 仍需决定具体必需动作，issue #10 必须证明校准后的一个可逆动作能端到端生效并满足失败开放。

## 调研方法与结论分类

本次先读取 `CONTEXT.md`、`docs/agents/domain.md`、issue #4、`docs/research/macos-port/` 下已完成报告，以及 Windows 参考实现的 `game_keys`、热键录制、动作调用、冲突和持久化代码。互联网检索与网页发现使用 `agent-reach` 的 GitHub/`gh` 和 Exa 路径；Exa 达到免费限额后，没有改用非 `agent-reach` 搜索路径。Apple 文档结论同时以本机 macOS 26.5 SDK 的公开 headers/Swift interfaces 复核。

下文严格分为四类：

- **事实**：公开契约或仓库源码直接说明的内容。
- **证据推论**：由事实支持、但不是 Apple 或 Hypergryph 明示保证的结论。
- **产品决策**：本报告建议采用的行为契约。
- **prototype 检查**：文档不能证明、必须由 issue #10 在真实目标游戏中验证的行为。

## 已确认事实

### 1. Touch Alternatives 是通用输入转换，不是游戏语义绑定 API

Apple 说明，iOS App on Mac 会自动获得 Touch Alternatives 设置页；Touch Alternatives 为 tap、swipe、drag、多点触控和设备倾斜等触摸行为提供键盘、鼠标或触控板替代。[A1] Apple 的 WWDC22 第一方记录进一步说明：

- 箭头键可模拟从窗口中心开始的 swipe，空格可模拟 tap。
- 目标开发者可以在 app bundle 内提供 `com.apple.uikit.inputalternatives.plist`。
- 公开示例只声明 `defaultEnablement`、`requiredOnboarding` 和 `Tap`、`Arrow Swipe`、`Scroll Drag`、`Tilt`、`Trackpad Capture` 等通用类别。
- Apple 仍建议目标应用直接实现键盘和指针支持。[A2]

这些字段既不包含目标游戏动作名称，也不包含任意 `动作 -> 键` 表。它们描述默认启用与 onboarding 展示；所引 Apple 材料没有记录读取用户当前 Touch Alternatives 状态或从另一个进程查询映射的 API。[A2]

本机已安装目标的签名 bundle 内含 `com.apple.uikit.inputalternatives.plist`，静态声明 `defaultEnablement=true`，以及 `Arrow Swipe`、`Scroll Drag`、`Trackpad Capture`、`Tilt` 四类 onboarding。这只确认目标采用 Apple 文档中的通用 Touch Alternatives 声明面；bundle 静态值不等于用户当前开关状态，也不提供任何游戏语义动作映射。

对 macOS 26.5 SDK 的公开 `*.h`、`*.swiftinterface` 和 module map 做大小写不敏感搜索，没有发现名为 `Touch Alternatives`、`inputAlternatives` 或同义公开 API 的声明。此观察只能证明所审查 SDK 没有公开符号，不能证明系统内部没有私有实现。

### 2. GameController 公开的是本进程可用的输入设备和物理元素

`GCKeyboard` 表示连接到设备的键盘，`keyboardInput` 提供当前键状态；`GCMouse` 表示连接的鼠标，`mouseInput` 提供按钮、滚轮和移动 delta。[A3] `GCPhysicalInputProfile` 可以枚举控制器的物理/逻辑元素，并查询用户在系统层对控制器元素做的 remap。[A3]

该 profile 的“logical element”是 `Button A`、方向键等设备元素，不是“切换倍速”“释放技能”等目标应用动作。公开类型没有目标 PID、bundle ID 或另一应用动作表参数，也没有 Touch Alternatives 查询方法。[A3]

### 3. Accessibility 最多提供目标显式暴露的 UI 信息

Accessibility API 可为指定进程创建 `AXUIElement`，列出某元素实际支持的 attributes，并读取支持的 attribute value；调用进程需要成为受信任的 Accessibility client。[A4] 标准 AX 常量中确实有 `kAXMenuItemCmdCharAttribute`、`kAXMenuItemCmdVirtualKeyAttribute`、`kAXMenuItemCmdGlyphAttribute` 和 `kAXMenuItemCmdModifiersAttribute`，但这些常量被明确归类为 **menu-specific attributes**。[A4]

因此 AX 可以在目标确实暴露标准菜单项时读取菜单快捷键，也可能读取一个可访问设置控件的标签和值。公开契约不保证自绘游戏内容、游戏内部键位、鼠标绑定或系统 Touch Alternatives 面板会以完整、稳定、带游戏语义的 AX 模型出现。AX 调用也可能返回 attribute unsupported、invalid element、cannot complete 或目标未完整实现 Accessibility API。[A4]

Apple 将完整 Accessibility API 控制其他应用列为与 App Sandbox 不兼容的能力；这与经过用户许可的 CoreGraphics ListenEvent/PostEvent 是不同能力。[A7]

### 4. Preferences API 不等于已发布的目标配置协议

Core Foundation 的 `CFPreferencesCopyAppValue` 接受应用 bundle identifier；低层 `CFPreferencesCopyKeyList` 可以枚举指定 application/user/host domain 的 key，`CFPreferencesCopyMultiple` 也可取得指定 key 或整个 domain 的值。[A6] 这说明非沙盒 macOS 工具在一般意义上存在读取其他 preference domain 的 API 表面。

同时存在以下限制：

- Apple 的 `UserDefaults` 文档明确说，sandboxed app 不能访问或修改另一个无关 app/process 的设置；把无关 bundle ID 传给 suite API 不会授予访问权。例外是自身 extension 或双方共同拥有 entitlement 的 App Group。[A5]
- Apple 记录了 `com.apple.security.temporary-exception.shared-preference.read-only` 等临时例外 entitlement，但它只放宽指定 preference domain 的访问，不会提供 key schema、语义或 Touch Alternatives 契约。[A6]
- iOS/macOS app 的用户数据位于系统管理的容器中；Apple 要求应用通过 Foundation 获取自身目录，而不是构造物理路径。macOS 14 及以后还将容器与代码签名关联，另一个 app 的访问可能需要用户授权。[A7]
- Apple 的 preferences 指南把物理 plist 视为系统管理实现细节，不应由应用直接修改。[A5][A6]

即使产品最终选择 unsandboxed 架构，`CFPreferences` 也只能枚举/读取原始 key/value。所定位第一方记录没有提供可把这些值解释为当前语义键位的 domain、schema、版本兼容或 Touch Alternatives 契约。本票又明确排除读取目标用户数据。

### 5. 第一方公开记录没有提供可采用的 macOS 动作默认表

本次 `agent-reach` 官方域名检索定位到的 Arknights 第一方记录包括中国区 App Store 产品记录和 Hypergryph 的 PC 客户端安装指引。[H1][H2] App Store 记录确认 iPhone/iPad app 可在 Apple Silicon Mac 运行；PC 指引描述另一个 PC 客户端。所定位记录均未发布 iOS App on Mac 的 `游戏动作 -> 键盘/鼠标` 表。

这是“本次没有找到可用第一方默认表”的检索结果，不是“该记录绝不可能存在”的全网证明。

### 6. Windows 参考实现维护两套不同的键位

Windows 参考实现必须区分以下概念：

1. **目标游戏语义绑定**：`GameKeys` 从 `HKCU\Software\HyperGryph\Arknights` 的 `KEYBOARD_SETTING_V*` 值读取二进制内容，按其实现假定转成 UTF-8 JSON，再把其中 function/key ID 转成 AHK 键名。[R4]
2. **小助手触发键**：`KeyBinder` 在小助手设置界面使用 `InputHook` 录制用户希望触发 AFA 动作的键盘/鼠标输入，写入 AFA 自己的设置，并通知冲突检查。[R5][R7]

`GameKeys` 的目标游戏绑定行为包括：

- 启动时读取，失败时回退到硬编码 Windows 默认键并警告。
- 每 10 秒比较注册表原始值，变化时重新解析并重建热键。
- 解析所有能识别的 function/key pair；动态拦截正则使用整张已读绑定表，而不只使用 AFA 会发送的动作。
- 输出通过 `Get`、`SendDown`、`SendUp`、`Tap` 按语义 function 查询，不在各动作中硬编码键。
- 默认表有 13 项；当前动作代码实际调用其中 12 项，`homeKey` 没有 `GameKeys` callsite。[R4][R8]

仓库历史显示，这条路径在提交 `a9728a1` 中一次性加入，提交消息明确记载注册表、Unity KeyId、六层 fallback 和 10 秒轮询；后续 `6c69485` 又补齐鼠标 key ID，`25a6829` 再增加完整映射/回退日志。[R9][R10][R11]

Windows 的小助手触发键录制支持修饰键、键盘、鼠标侧键和滚轮，并用 Backspace/Delete 清除。冲突检查只比较会同时启用的组：常规作战加快捷操作互检，卫戍协议作为另一组；启停键分别加入两组检查。[R5][R6]

## 证据支持的推论

### I1. 没有可采用的支持性自动发现路径

本报告不能从“文档没有一个名字完全匹配的方法”证明系统内部绝对没有数据，但可以对产品支持面作出结论：

- GameController 枚举设备/元素，不枚举另一 app 的动作绑定。
- Touch Alternatives 公开的是通用 gesture alternatives 和目标开发者 onboarding 声明，不是另一进程可查询的语义 map。
- AX 只读取目标实际暴露的 UI/菜单属性，既不完整也不稳定，并受 TCC、目标实现和 App Sandbox 限制。
- CFPreferences 至少需要目标 domain；即使枚举出全部 key，缺少发布 schema 的原始 key/value 也不是由 Apple 或 Hypergryph 支持的 Arknights 绑定协议。
- 未找到 Hypergryph 发布的 macOS 语义默认表。

所以，“自动发现”在当前允许的公开、文档化、非侵入边界内不可用。继续寻找目标私有文件、私有 AX 结构或二进制符号只会跨出本票边界，而不会形成 Apple 支持的 API 契约。

AX 设置页抓取不能改变这个结论：偶然可读的控件仍不是 sandboxed/unsandboxed 架构共同支持的完整绑定协议。读取 raw preferences 也不能改变这个结论：没有发布 schema 时只能得到无法支持性解释的目标用户数据。

### I2. Touch Alternatives 不能作为 Windows 键位表的替代来源

Touch Alternatives 把键鼠输入转换为 tap/swipe/drag 等触摸原语；最终游戏效果还取决于指针位置、画面状态和目标 app 如何处理触摸。[A1][A2] 例如 Apple 的公开示例把 Space 描述为通用 tap，而 Windows 参考实现把 Space 当作 `pauseBattle` 默认键。[R4] 两者不能互相推导。

如果某项首版功能只能通过 Touch Alternatives 完成，它需要的是“用户选择的 Touch Alternatives 状态 + 手势/坐标链路”验证，而不是把某个通用替代键标记成游戏语义键。该能力应作为 issue #2/#10 的独立范围选择。

### I3. 完整游戏键表不是失败开放的必要条件

Windows 通过读取整张目标绑定表来决定哪些 AFA 触发键需要去掉 AHK 的透传前缀。[R4] macOS 可以把机制改成更直接的行为契约：

- AFA 动作未准备好时，事件原样返回。
- AFA 动作已准备好时，该触发键是本次动作的显式输入，可被消费，避免它同时触发目标游戏的未知原生动作。
- 合成事件带 AFA 自身标记并绕过动作匹配，避免递归。

这让用户只需校准 AFA 要发送的语义输出，而不是复制目标游戏全部设置。是否能在 active event tap 中可靠满足这条契约，属于 issue #10 的 prototype gate。[A8]

### I4. Windows 机制不是 macOS 协议

`game_keys.ahk` 的提交历史、平台注册表路径和持续补充的 Unity/mouse key ID 表明它是 Windows 目标的适配机制，而不是仓库声明的跨平台接口。[R4][R9][R10][R11] macOS 实现应保留“按语义发送用户当前绑定”“同时活动范围内检查冲突”和“异常时不误吞键”的行为意图，不继承注册表、Unity key ID 或完整目标键表解析。

## 建议的最小用户校准契约

以下是本报告建议的产品行为，不是 Apple 或 Hypergryph 已提供的功能。

### 1. 三类输入必须分开建模

| 类别 | 含义 | 是否进入本票校准表 |
|---|---|---|
| 小助手触发键 | 用户按什么来触发 AFA 动作，如“按下暂停” | 否。由 AFA 自己的热键设置管理，但参与冲突与失败开放检查。 |
| 目标游戏语义绑定 | AFA 为取得某个游戏语义结果应向目标发送什么键/鼠标按钮，如“释放技能” | 是。仅包含 issue #2 选中功能实际依赖的语义。 |
| 直接输入原语 | Escape、主鼠标点击、指定坐标点击、drag/tap 等，不对应可发现的游戏 function | 否。作为输入链路/坐标能力单独验证，不伪装成语义键位。 |

持久化时应使用 AFA 自有的稳定语义标识，不存储或依赖 Windows 注册表中的 function 名、Unity key ID 或目标私有 schema。

### 2. 语义动作库存边界

下表是 Windows 参考实现中实际被动作代码消费的候选库存，不等于首版承诺。Windows 默认值只用于说明来源，不是 macOS 默认值。[R4][R8]

| 目标语义 | Windows function / 默认键 | 当前 Windows 行为依赖 | macOS 处置 |
|---|---|---|---|
| 切换倍速 | `changeSpeed` / `F` | 切换倍速 | issue #2 纳入该功能时校准。可作为 issue #10 的候选测试语义，但测试场景必须对候选键被错误解释成任意其他动作也安全。 |
| 战斗暂停/继续 | `pauseBattle` / `Space` | 松开暂停、三档过帧、开局自动暂停 | issue #2 纳入任一依赖时校准；不能从 Apple 的 Space=tap 推导。 |
| 释放技能 | `releaseSkill` / `E` | 单位技能、一键技能、暂停技能 | issue #2 纳入任一依赖时校准。 |
| 单位撤退 | `retreatChar` / `Q` | 单位撤退、一键撤退、暂停撤退、卫戍撤退 | issue #2 纳入任一依赖时校准。 |
| 打开放弃行动弹窗 | `battleLeftPopup` / `V` | 放弃行动；“返回上级菜单”可选组合 | 仅在 issue #2 明确包含该行为时校准。 |
| 查看敌人 | `autochessViewEnemy` / `W` | 卫戍协议查看敌人 | 卫戍协议进入首版时才出现。 |
| 打开调度中心 | `autochessShop` / `A` | 卫戍协议调度中心 | 同上。 |
| 冻结 | `autochessFreeze` / `S` | 卫戍协议冻结 | 同上。 |
| 刷新 | `autochessRefresh` / `D` | 卫戍协议刷新 | 同上。 |
| 升级 | `autochessLevelUp` / `G` | 卫戍协议升级 | 同上。 |
| 出售/销毁 | `autochessSale` / `X` | 卫戍协议出售、一键出售 | 同上。 |
| 准备就绪 | `autochessReady` / `C` | 卫戍协议准备 | 同上。 |

`homeKey` / `Tab` 虽在 Windows 默认表中，但当前没有 `GameKeys` 调用点，应从 macOS 校准库存排除。未知目标动作、AFA 不发送的目标动作以及完整目标键表也不进入校准库存。

直接原语另列为 capability：

| 原语 | Windows 用途示例 | 本票结论 |
|---|---|---|
| Escape down/up | 按下暂停、过帧、返回 | 不是用户语义映射；由 issue #10 验证目标接受度和焦点行为。 |
| 当前指针处主键点击 | 一键技能/撤退、模拟左键 | 不是语义映射；由输入 prototype 验证鼠标副作用。 |
| 指定坐标 tap/click | 暂停选中、跳过、收取、购买等 | 依赖窗口/坐标和输入机制；是否进首版由 issue #2 决定。 |
| Touch Alternatives gesture | 系统将键鼠转换为 tap/swipe/drag 等 | 不自动发现；仅当 issue #2 需要且 issue #10 黑盒验证成功时另建能力。 |

### 3. 必需与可选规则

- 不存在“安装后必须校准全部 12 项”的全局规则。
- 某映射是 **required**，当且仅当 issue #2 选中的首版核心功能没有其他实现路径并直接依赖该语义输出。
- 某映射是 **optional**，当其仅服务可选/延期功能；未映射时只禁用依赖功能，不阻止小助手启动、设置和其他已验证功能。
- 一个复合功能必须在所有语义输出和直接原语都验证后才可启用。例如“暂停技能”至少依赖释放技能映射、暂停/坐标原语以及时序链路，不能因为 `releaseSkill` 已校准就宣称可用。
- 首次设置只展示 issue #2 选中的动作。延期动作不占据界面，也不要求用户理解 Windows 全功能表。

### 4. 捕获

最小捕获流程如下：

1. 用户在小助手中选择一个明确命名的目标语义动作。
2. 小助手成为前台并使用正常 AppKit key/mouse handling 或 local `NSEvent` monitor 录制下一次输入。local monitor 只处理本应用事件，不需要为此观察其他进程。[A8]
3. 最小 baseline 只接受一个非系统保留、无 Command/Control/Option/Shift 修饰的键盘主键；issue #2 若要求 modifier-only、组合序列、鼠标按钮、滚轮或触控板 gesture，必须把对应表示与注入序列交给 issue #10 单独验证。
4. baseline 键盘候选至少保留 `NSEvent.keyCode`、仅用于显示/变化检测的 `charactersIgnoringModifiers`，并记录验证时的当前 keyboard input source identifier；`keyCode` 是 AppKit 公开的 device-independent key number，但字符解释和 dead-key 行为取决于当前输入源。[A8][A10]
5. 鼠标候选保存 `CGMouseButton` 编号和显示名；CoreGraphics 公开 primary、secondary、center 和 USB 顺序的其他按钮模型。[A8]
6. 自动重复、同时出现多个主键、录制窗口失焦或用户取消时不产生 candidate。编辑已有映射时，旧的 validated 值保持有效，直到新 candidate 完成验证。

如果 issue #2 要求组合键，不能只持久化聚合 `modifierFlags`：Caps Lock、numeric-pad、Function 等状态与 Command/Control/Option/Shift 不同，且 AppKit 聚合 flags 不足以表达左右 modifier。prototype 必须定义规范表示，并显式生成 modifier 与主键的完整 down/up 序列。[A8]

如果 prototype 证明目标按字符而不是物理 key code 解释键盘，应比较 `charactersByApplyingModifiers`、当前 input source 与 `CGEventKeyboardSetUnicodeString` 等受支持表面；Unicode payload 是否被目标框架采纳仍是目标特定事实，不能预先作为 fallback 保证。[A8][A10]

### 5. 验证

1. 验证前确认运行目标的 bundle ID 为 `com.hypergryph.arknights`，当前 PID/窗口身份无歧义，并完成 PostEvent 权限预检。[A8][R12]
2. UI 显示即将验证的语义和候选输入，由用户明确开始。验证不因录制完成而自动发送。
3. baseline 只发送一个有界的无修饰键 down/up；如果 issue #2 要求组合键，则发送 issue #10 已验证的显式 modifier/main-key down/up 序列。具体采用系统 event stream 还是 `CGEventPostToPid` 由 issue #10 选择。[A8]
4. 用户是语义 oracle：确认“产生了预期动作且没有额外动作”后，candidate 才变为 validated。没有确认、超时、目标切换或结果错误都不激活映射。
5. 验证不得读取目标 defaults/container，不通过 AX 抓设置值，也不通过未公开格式自证正确。
6. 验证场景必须在 candidate 被目标解释成任意其他键位动作时仍无不可逆后果；不能仅因为预期语义可逆就视为安全。对无法提供这种 disposable context 的动作，不提供直接测试按钮；它只能在 issue #2 定义安全验证场景后进入首版，或保持 optional/disabled。

### 6. 默认值

- macOS operational default 一律为 `unmapped`。
- UI 可以把 Windows 默认键显示为“Windows 参考提示”，但必须标记 unverified，且在用户录制和确认前不能发送、不能参与拦截。
- 不根据键盘布局、窗口标题、Apple 的通用 Touch Alternatives 图示或未验证的社区说明猜测 Arknights 语义。
- 如果以后找到 Hypergryph 发布且明确覆盖 iOS App on Mac 当前版本的键位表，也只可作为 candidate seed；用户当前自定义和 Touch Alternatives 状态仍需验证。

### 7. 持久化与目标更新

校准 profile 只保存在小助手自己的 Application Support/UserDefaults 范围。最小持久化字段为：

| 字段 | 作用 |
|---|---|
| calibration schema version | 让小助手能拒绝无法解释的数据，而不是错误发送。 |
| target bundle identifier | 固定校验 `com.hypergryph.arknights`，防止 profile 被用于其他 app。 |
| target short version/build | 在 issue #10 先验证 outer wrapper/inner bundle 归一化与实际读取路径后，记录最后验证所对应的公开 bundle metadata；不是用户数据。[A9] |
| input route | `direct-keyboard` 或经 issue #10 单独批准的其他 route；不能静默切换。 |
| semantic action | AFA 自有稳定语义标识。 |
| normalized input | key code/modifiers 或 mouse button；显示文本不是权威值。 |
| validation state | `unmapped`、`validated` 或 `stale`；未通过的新 candidate 不覆盖旧 validated 值。 |
| validation record | 最后验证时间和当时用于提示用户的显示值；不保存目标画面或目标配置原文。 |

生命周期规则：

- 目标 relaunch 只重新解析 PID/窗口，不使 profile 失效。
- 在已验证的归一化路径上，目标 `CFBundleShortVersionString` 或 `CFBundleVersion` 改变时，将已有值保留为 `stale`，暂停依赖功能并要求快速复验；如果版本无法可靠读取，也不能据此推断映射仍新鲜，更不能静默回退 Windows 默认值。[A9]
- 如果 route 依赖 Touch Alternatives，macOS 大版本变化也应标记 stale，因为该行为由系统提供。
- 用户在游戏或 Touch Alternatives 中改设置后，必须通过明确的“我已更改游戏控制”入口复验。本边界内没有支持性 API 能自动检测该变化。
- 小助手卸载/更新不得把校准写进 app bundle；profile 与发布包分离。权限丢失只影响可用性，不应删除用户映射。

### 8. 冲突处理

| 冲突 | 处理 |
|---|---|
| 同时启用的两个 AFA 动作使用同一触发键 | 阻止保存/启用，延续 Windows 参考实现按活动组检查的行为意图。[R6] |
| 同一活动模式中的两个不同目标语义映射到同一输出 | 阻止二者同时成为 validated，除非 issue #2 明确证明它们按上下文互斥并分属不同 profile。 |
| AFA 触发键等于某个已校准目标输出 | 不自动判为错误。它可能是有意的“触发键替代原游戏键”关系；只有 issue #10 证明消费原事件、合成事件标记和无递归后才允许。 |
| AFA 触发键可能等于未录入的其他游戏键 | 不要求复制完整游戏键表。功能 ready 时消费该显式 AFA 触发键；功能不 ready 时透传，并由 issue #10 验证不存在双触发。 |
| 系统保留组合、无法稳定表示的 gesture 或 prototype 未覆盖的鼠标按钮 | baseline 拒绝录制，不做猜测性降级。 |

冲突比较使用规范化输入身份，不使用本地化显示字符串。模式互斥边界必须来自 issue #2，不能仅因为 Windows 当前 GUI 有两个标签页就视为 macOS 规格。

### 9. 失败开放

以下任一状态都必须做到“不注入、不消费原事件、只禁用依赖功能”：

- 映射缺失、stale、未验证或有冲突。
- 目标 app 未运行、PID/窗口身份有歧义、目标上下文不符合功能条件。
- ListenEvent/PostEvent 权限缺失或被撤销。
- active event tap 被系统禁用、动作队列无法接受任务、Secure Event Input 或其他状态使行为不可确认。
- input route 与校准时不同，或需要的直接原语尚未通过 prototype。

事件 tap callback 必须先完成 readiness 判定和成功入队，再返回 `NULL` 消费事件。若动作在消费后失败，执行路径应释放所有已合成 down 状态，并在能够可靠重放时补发等价原事件；如果 prototype 无法证明这条恢复路径，就不能为该功能启用消费模式。[A8]

## 依赖 issue #2 的产品决策

[Issue #2](https://github.com/Nightchamp/arknights-frame-assistant/issues/2) 仍是开放的首版功能边界票。本报告不替它决定以下事项：

1. 首版是否只包含常规作战核心，还是还包含快捷操作、自动开局暂停和卫戍协议。
2. 上表 12 个候选语义中哪些是 required、哪些 optional、哪些完全不出现在首版。
3. 是否接受任何坐标点击、mouse button 或 Touch Alternatives-dependent 功能；只做键盘语义输出会显著缩小校准和 issue #10 范围。
4. 是否保留 Windows 的按下暂停、松开暂停和三档过帧全部行为，还是只承诺其中一个核心链路。
5. 模式是否互斥，从而允许同一输入在不同 profile 中复用。
6. 哪些动作允许用户执行一次验证，哪些动作因副作用必须采用单独验证场景或延期。
7. 是否在 UI 中展示 Windows 参考键提示。无论选择什么，提示都不能自动成为 validated mapping。

issue #2 收口后，应从“功能 -> 目标语义/直接原语”的依赖图自动得到设置页字段和 release gate，不应先照搬 Windows 的 12 项表再删除。

## Issue #10 prototype 检查

[Issue #10](https://github.com/Nightchamp/arknights-frame-assistant/issues/10) 应验证一条最小、黑盒、端到端链路，不再尝试证明自动发现。若 issue #2 包含切换倍速，可把它作为首个候选语义；无论选择什么动作，都必须先建立一个在 candidate 实际对应任意其他游戏动作时仍可安全退出的 disposable context，不能只依赖预期语义“可逆”。

### 必测路径

1. 在小助手前台录制一个候选键，确认 key code、modifiers、显示字符和 key-up 状态完整，录制不需要全局 ListenEvent。
2. 用户启动验证后，分别记录 `CGEventPost` 和 `CGEventPostToPid` 对该语义的接受度，最终只保留一条可靠 route。[A8]
3. 用户确认目标动作恰好发生一次；候选才转为 validated。错误、无响应和额外动作均保持 disabled。
4. 使用一个与目标原生键可能重合的 AFA 触发键，验证 ready 时原事件被消费、合成动作只发生一次，AFA 标记事件不递归触发自身。
5. 验证 not-ready 矩阵：目标身份不明、映射 missing/stale、权限缺失或撤销、tap timeout/disabled、动作队列拒绝，以及 issue #2/#10 最终选定的焦点条件不满足。每种状态都必须让原键恰好透传一次且零合成动作；“必须 frontmost”目前只是安全候选策略，不是本票已确定事实。
6. 在 key down 后切换焦点、松键、长按 repeat 和快速多次输入，确认无卡键、无漏 up、无重复动作；如果消费后的动作失败，验证原事件恢复策略。
7. 更改捕获 candidate 并取消/验证失败，确认旧 validated 映射仍有效；验证运行中应用的 outer wrapper/inner bundle 归一化和版本读取，再模拟目标 build 变化，确认 profile 变 stale 且失败开放。
8. 至少在两种键盘输入源下确认持久化的 key code/字符策略。如果结果语义随布局变化，回到设计阶段决定按物理键还是字符持久化。

### 条件性检查

- issue #2 包含鼠标绑定时，重复上述流程验证 primary/secondary/auxiliary button、窗口命中和真实指针/焦点副作用。
- issue #2 需要 Touch Alternatives 时，由用户通过系统 UI 分别置为明确的开/关状态，黑盒测试目标结果；prototype 不读取其 defaults 或 AX 私有结构。两种状态必须被当成不同 input route，不能自动猜测。
- 架构票若仍比较 sandboxed 与 unsandboxed 构建，应在实际发布签名方式下复测；AX/settings 抓取不因某一构建偶然成功而进入产品路径。

### 通过门槛

只有同时满足以下条件，校准契约才可进入规格：

- 一个用户校准的语义动作在真实目标游戏中稳定发生一次。
- 目标外、权限异常和 mapping 异常时零误吞键。
- 合成事件标记可阻止递归，down/up 和焦点切换后无卡键。
- 不读取目标用户数据，不依赖目标私有格式或二进制分析。
- 目标 build 变化和用户取消编辑不会静默启用猜测值。

如果“注入成功”和“失败开放”任一不通过，issue #10 应阻断依赖该 route 的首版功能，而不是回退到 Windows 默认键或目标私有配置读取。

## 未决事项

1. Issue #2 的首版动作集合及 required/optional 分类。
2. Issue #10 的首个测试语义与 disposable context；切换倍速是候选，但安全性必须覆盖 candidate 实际触发任意其他动作的情况。
3. baseline 是否只接受单键，还是必须支持 modifier-only、组合键、鼠标按钮或滚轮。
4. 目标对 virtual key code 与当前键盘字符的实际解释，进而决定持久化权威字段。
5. 是否存在需要 Touch Alternatives 的首版功能；若有，如何让用户声明并复验当前 route。
6. 游戏每个 build 更新都强制复验的摩擦是否可接受；放宽前需要版本间 prototype 证据，不能默认映射稳定。
7. 模式/profile 边界和跨模式输入复用规则，必须由 issue #2 确定。
8. 是否展示 Windows 参考键提示；无论是否展示，macOS 不能自动激活这些值。

## 第一方与仓库来源

### Apple

- **[A1]** Apple Developer, [Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos): iOS App on Mac、系统自动提供 Touch Alternatives、键鼠/触控板替代行为。
- **[A2]** Apple WWDC22, [Bring your iOS app to the Mac](https://developer.apple.com/videos/play/wwdc2022/10076/): Touch Alternatives 的固定交互示例、`com.apple.uikit.inputalternatives.plist`、`defaultEnablement`、`requiredOnboarding` 和五类 onboarding 值。
- **[A3]** Apple GameController references: [`GCKeyboard`](https://developer.apple.com/documentation/gamecontroller/gckeyboard), [`GCMouse`](https://developer.apple.com/documentation/gamecontroller/gcmouse), [`GCPhysicalInputProfile`](https://developer.apple.com/documentation/gamecontroller/gcphysicalinputprofile); macOS 26.5 SDK `GameController.framework/Headers/GCKeyboard.h`, `GCKeyboardInput.h`, `GCMouse.h`, `GCMouseInput.h`, `GCPhysicalInputProfile.h`。
- **[A4]** Apple Accessibility references: [`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h), [AX attribute constants](https://developer.apple.com/documentation/applicationservices/axattributeconstants_h); macOS 26.5 SDK `ApplicationServices.framework/.../Headers/AXUIElement.h` 与 `AXAttributeConstants.h`。
- **[A5]** Apple Foundation, [`UserDefaults`](https://developer.apple.com/documentation/foundation/userdefaults), 尤其 Sandbox considerations；[Preferences and Settings Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)。
- **[A6]** Apple Core Foundation, [`CFPreferencesCopyKeyList`](https://developer.apple.com/documentation/corefoundation/cfpreferencescopykeylist(_:_:_:)), [Preferences Programming Topics: Using the Low-Level API](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFPreferences/Tasks/UsingLowAPI.html), [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html); macOS 26.5 SDK `CoreFoundation.framework/Headers/CFPreferences.h`。
- **[A7]** Apple Security, [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。
- **[A8]** Apple AppKit/CoreGraphics references: [`NSEvent` local/global monitors](https://developer.apple.com/documentation/appkit/nsevent), [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services), [`CGEvent.postToPid(_:)`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)); macOS 26.5 SDK `AppKit.framework/Headers/NSEvent.h` 与 `CoreGraphics.framework/Headers/CGEvent.h`。
- **[A9]** Apple Bundle Resources, [`CFBundleShortVersionString`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring) 与 [`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)。
- **[A10]** Apple AppKit/Input Method Kit references: [`charactersByApplyingModifiers(_:)`](https://developer.apple.com/documentation/appkit/nsevent/charactersbyapplyingmodifiers(_:)), [`NSTextInputContext.selectedKeyboardInputSource`](https://developer.apple.com/documentation/appkit/nstextinputcontext/selectedkeyboardinputsource), Text Input Source Services in macOS 26.5 SDK `HIToolbox.framework/Headers/TextInputSources.h`, and CoreGraphics `CGEventKeyboardSetUnicodeString` in `CGEvent.h`。

### Arknights / Hypergryph

- **[H1]** Apple App Store 第一方产品记录，[明日方舟](https://apps.apple.com/cn/app/%E6%98%8E%E6%97%A5%E6%96%B9%E8%88%9F/id1454663939): 开发者/provider 与 Apple Silicon Mac 兼容记录。
- **[H2]** Hypergryph 明日方舟官网，[《明日方舟》PC 下载安装指引](https://ak.hypergryph.com/news/0717): 第一方 PC 客户端范围记录，不是 iOS App on Mac 键位表。

### Repository

- **[R1]** [Issue #4](https://github.com/Nightchamp/arknights-frame-assistant/issues/4): 本调研问题。
- **[R2]** [Issue #2](https://github.com/Nightchamp/arknights-frame-assistant/issues/2): 首个公开版本的核心价值与功能边界。
- **[R3]** [Issue #10](https://github.com/Nightchamp/arknights-frame-assistant/issues/10): 目标游戏核心热键链路 prototype。
- **[R4]** Windows reference [`game_keys.ahk`](https://github.com/Nightchamp/arknights-frame-assistant/blob/007df8532c5be88e52ffb818965a644669463913/src/lib/game_keys.ahk#L5-L568): 目标游戏绑定发现、默认值、轮询、语义发送和拦截表。
- **[R5]** Windows reference [`key_bind.ahk`](https://github.com/Nightchamp/arknights-frame-assistant/blob/007df8532c5be88e52ffb818965a644669463913/src/lib/key_bind.ahk#L2-L379): AFA 触发键录制、清除和保存通知。
- **[R6]** Windows reference [`hotkey_conflict_validator.ahk`](https://github.com/Nightchamp/arknights-frame-assistant/blob/007df8532c5be88e52ffb818965a644669463913/src/lib/settings/hotkey_conflict_validator.ahk#L3-L87): 同时活动组的冲突规则。
- **[R7]** Windows reference [`config.ahk`](https://github.com/Nightchamp/arknights-frame-assistant/blob/007df8532c5be88e52ffb818965a644669463913/src/lib/config.ahk#L24-L240): AFA 动作库存、活动组、触发键默认和自身 INI 路径。
- **[R8]** Windows reference [`hotkey_actions.ahk`](https://github.com/Nightchamp/arknights-frame-assistant/blob/007df8532c5be88e52ffb818965a644669463913/src/lib/hotkey_actions.ahk#L103-L803): 目标语义 callsites 与直接输入原语。
- **[R9]** Repository commit [`a9728a1`](https://github.com/Nightchamp/arknights-frame-assistant/commit/a9728a18fec706a4b06e4d764b8ff3c7430a64ce): 初次加入 Windows registry/Unity KeyId/轮询路径。
- **[R10]** Repository commit [`6c69485`](https://github.com/Nightchamp/arknights-frame-assistant/commit/6c694851ae208cd670e7bc2faeb9904af7a1f503): 补充目标游戏鼠标按键识别。
- **[R11]** Repository commit [`25a6829`](https://github.com/Nightchamp/arknights-frame-assistant/commit/25a682996342ab0e25dd3ae282f4649c175068d6): 增加完整按键映射与读取回退日志。
- **[R12]** [Decision map #1](https://github.com/Nightchamp/arknights-frame-assistant/issues/1): 目标 bundle ID、原生游戏环境和公开 macOS 实现的既定范围。
