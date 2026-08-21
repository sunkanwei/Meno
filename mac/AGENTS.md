# Meno Mac 项目规则

## 模块地图

- `MenoApp/`：应用入口与协调中心。`AppModel` 汇总各功能状态并接线，菜单栏、设置页、开机启动在此；新功能通常先在对应 `Features/` 目录实现，再到这里接线。
- `Features/`：相互独立的功能模块，每个目录一个功能。最复杂的两个：
  - `CrossScreenMouse/`：Mac↔Windows 跨屏鼠标与键盘路由，含输入捕获、控制权租约、本机多屏与 Windows 之间的切换。
  - `SoftKVM/`：显示器物理/软切换、窗口迁移、桌面图标布局。
- `Platform/`：macOS 系统能力封装，不含业务逻辑：Accessibility（权限与 AX 读取）、EventTap（输入监听）、Finder（访达自动化、桌面坐标、右键菜单桥）、HID、M1DDCBridge（显示器 DDC，唯一 Objective-C）、Power（电源与合盖）、QuickLook。
- `Extensions/`：两个系统扩展，保持薄：`MenoFinderExtension`（Finder 右键"新建文档"）、`MenoMarkdownPreview`（Markdown 快速预览）。
- `Helpers/MenoPowerHelper`：合盖关机的特权助手，构建时嵌入应用 `Library/PrivilegedHelperTools`。
- `Vendor/FluxMarkdownRenderer/`：整体引入的 Markdown 渲染器固定副本，维护边界见下文专节。
- `Tests/`：纯逻辑测试，直接编译生产源码文件运行，不启动应用；新功能加入测试时须在 `project.yml` 的 MenoTests sources 登记对应源码文件。
- 跨端协议单一事实源：`Features/ClipboardSharing/ClipboardProtocol.swift`（MENO 帧格式、capability 与消息编号）+ `Features/CrossScreenMouse/MouseControlProtocol.swift`（鼠标键盘负载编码），固定字节测试在 `Tests/`。

## 稳定身份与系统授权

- 主应用 Bundle ID 固定为 `com.sunkanwei.Meno`，Finder 扩展 Bundle ID 固定为 `com.sunkanwei.Meno.FinderExtension`，Markdown 快速预览扩展 Bundle ID 固定为 `com.sunkanwei.Meno.MarkdownPreview`。不得通过改名或修改标识恢复权限。
- 每次构建和安装必须使用同一个专属 Meno 签名身份。不得混用无签名构建，不得挪用 HORA、FlashBall 或其他项目的证书。
- Meno 必须安装在固定位置，后续始终更新同一个已安装应用；不得从持续变化的构建目录直接运行。
- 首次申请辅助功能、输入监听、Finder 扩展等系统授权前，必须先确认 Bundle ID、Meno 专属签名身份和安装路径均已稳定。
- 更换 Bundle ID、签名身份或安装位置前，必须先说明系统可能要求重新确认授权，不得静默变更。
- 仅供个人本机使用时，优先创建独立的本地 Meno 签名身份；若接入 Apple 开发团队，签名团队和 Bundle ID 仍须保持固定。

## 构建、安装与真机验收

- 统一入口脚本：`Scripts/build.sh`（Debug 构建+全部测试）、`Scripts/build.sh test`（仅测试）、`Scripts/build.sh release`（签名 Release 构建）、`Scripts/install.sh`（Release 构建并安装到 `/Applications/Meno.app`，自动完成本节要求的校验、备份、扩展登记清理、Finder 重启和启动验证）。默认一律使用脚本，不要手工拼 `xcodebuild`、`ditto`、`pluginkit` 等命令；`xcodegen` 只在 `project.yml` 变更后手动运行并提交结果。
- 本节下列约束已固化在脚本中；脚本不可用必须手工操作时，仍须逐条遵守。
- 对会改变 Meno 实际行为、扩展、资源、权限、构建配置或打包内容的实现，完成必要测试和构建后，默认主动用 Release 产物更新固定安装位置 `/Applications/Meno.app`，再重新启动 Meno；不要等待用户再次要求安装。纯文档、纯测试、只读分析和未完成的实验性改动不更新安装副本。
- 更新前必须只读核对已安装主应用与 Finder 扩展的 Bundle ID 和 Meno 专属签名身份，与新产物一致后才覆盖；不从 DerivedData 或其他临时构建目录直接运行或验收。
- 更新 `/Applications/Meno.app` 时，安装命令不得包含 `rm`、`rmdir` 或其他删除、自动清理动作，也不得把安装与清理临时目录拼成同一条命令。必须先把旧版完整移动到带时间标识的临时备份目录，再安装新版；验证成功后保留该备份，不自动删除。安装失败时先把失败产物移动到另一临时位置，再恢复旧版，不得用删除作为恢复步骤。
- 更新后必须校验 `/Applications/Meno.app` 的嵌入扩展与签名，并确认新版进程已启动。若无法安全替换、签名不一致、固定路径不存在或启动失败，停止后续安装操作，明确说明阻塞原因；不得把“仅构建成功”说成“已安装并可测试”。
- 任何会生成 `Meno.app` 或 `MenoFinderExtension.appex` 的构建、测试、分析、归档或安装流程，都可能让系统登记临时 Finder 扩展。流程结束前必须清除 `com.sunkanwei.Meno.FinderExtension` 指向 DerivedData、项目构建目录和其他临时位置的注册，只保留并重新登记 `/Applications/Meno.app/Contents/PlugIns/MenoFinderExtension.appex`；此处只清理系统注册，不得因此删除构建产物或临时目录。若固定安装版不存在，或其 Bundle ID、签名不符合本项目约束，不得强行登记，必须停止并说明原因。
- 清理 Finder 扩展注册后必须终止仍从非固定路径运行的 Meno Finder 扩展进程并重新启动 Finder，再确认系统只登记固定安装版、实际扩展进程来自固定安装位置，且 Finder 文件夹空白处的右键菜单包含“新建文档”下的“文本文档”和“Markdown 文档”。未完成这些检查时，不得把构建安装流程报告为完成。

## Mac 与 Windows 协作边界

- 本目录只维护 Meno 的 Mac 端。Mac AI 可以读取仓库中的 `../windows/`，但不得修改或编译 Windows 源码、EXE、驱动及 Windows 构建配置。
- 软 KVM 的横向拓扑只以断开 Philips 前的完整三屏基线为真源：`macEdge = Philips 所在侧`，`windowsEdge = 其反侧`，另一块 Mac 屏必须位于反侧。Philips 断开后的两屏坐标只能用于验证和恢复排列，不得据此反推已缺失的 Philips 位置。
- 本机 Mac 屏之间的物理高度换算与 Mac/Windows 路由是两个独立机制；修改其中一个时不得顺带改变另一个的入口、墙体或坐标换算规则。
- `windows_agent` 是主要 Windows 协作入口。允许通过它查看和搜索 Windows 内容、启动正常应用、修改明确登记的代码项目并运行项目构建或测试，不逐次向用户确认；普通非项目目录仍只读。
- 可能损坏 Windows 的操作必须禁止或向用户确认，包括修改或删除系统文件、改变启动或磁盘分区、修改关键系统注册表、安装或替换驱动、批量删除未知目录，以及影响范围无法可靠判断的系统级操作。
- Mac Codex 根据任务复杂度、风险和现有工具能力，自主决定通过 `windows_agent` 完成，还是交给 Windows 上独立运行的 Codex；用户可以明确指定。
- Mac 端任务如果需要 Windows 配合，先读取 `../windows/` 当前源码并通过 Windows Agent 核对运行事实，完成 Mac 范围内能够独立确认的工作；远程入口不可用时明确说明运行证据缺口，不得根据记忆猜测 Windows 当前状态。
- 需要交给 Windows Codex 修改、编译、安装或实机验证时，必须直接生成一段可完整复制的任务提示词，不让用户自行整理技术背景。
- 交给 Windows AI 的提示词必须包含：现象与已确认事实、固定协议格式和精确数据格式、Windows 端所需行为、不得回退的既有能力、验收标准，以及需要回报给 Mac 的日志或结果。
- Windows AI 返回的构建或实测结果只作为跨端证据；需要 Mac 调整时仍须以当前 Mac 代码核对。双端真实测试完成前，不得声称跨平台功能已经完整验收。
- Mac 与 Windows 源码共同保存在本仓库中，`mac/` 与 `windows/` 平级；不得在 `mac/` 内另存 Windows 副本或 Windows 构建产物。

## 固定 MENO 跨端协议

- Mac 与 Windows 的网络协议固定使用 `MENO`，不设置整体协议版本、鼠标控制版本或键盘报告版本，也不保留旧格式、双轨实现或协议回退。
- 处理跨端任务时，当前两端源码和固定字节测试是唯一事实源；不得根据旧提示词、旧报告或“V 几”推测当前格式与兼容状态。涉及跨端格式变更时，必须先由一端确定完整格式、编号和固定字节测试，再生成完整提示词交给另一端同步；不得让两端同时独立修改同一格式。
- 新功能只能分配新的 capability、TLV field 或 message kind；不得改变、复用或重新解释已经发布的编号与含义。分配编号前必须搜索当前代码和测试，未知的新能力、字段和消息必须能够安全忽略。
- Windows 驱动 ABI 只描述 Windows EXE 与虚拟 HID 驱动之间的接口，不属于网络协议，也不得用于推测网络功能；网络功能只根据 Hello/Ready 的能力交集启用。
- 修改跨端格式后，必须同步固定字节测试，并通过双端完整格式、能力协商、Release 产物和不含用户输入内容的运行日志核对；不得回退现有剪贴板、低延迟鼠标、键盘状态、controlID、心跳租约、幂等释放和断线全状态清理。

## Markdown 快速预览维护边界

- Meno 接入 FluxMarkdown 的目标仅是让用户在 Finder 中选中 Markdown 文件并按空格后，获得与 FluxMarkdown 当前预览基本一致的渲染结果；不接入 FluxMarkdown 的独立应用界面、图标、设置页、欢迎页、更新和发布系统。
- 接入时必须把网页渲染器固定在独立目录，并把它视为整体引入的渲染组件。Meno 自行维护的接入层应控制在约 1000 行以内，只负责 Quick Look 扩展配置、文件读取、渲染器加载与通信、必要的文件访问限制和失败处理。
- FluxMarkdown 网页渲染器约 5300 行 TypeScript 和 CSS；Meno 使用的固定副本位于 `Vendor/FluxMarkdownRenderer/`，上游参考位于 `参考/FluxMarkdown/web-renderer/`。普通 Meno 功能、构建、安装、签名、Finder 扩展或 Quick Look 生命周期任务，不得因此通读、全面搜索或分析这部分源码，默认只检查 Meno 接入层及渲染器入口和构建清单。
- 只有用户明确要求处理渲染器，或证据已经把问题定位到 Markdown 排版、Mermaid、公式、代码高亮、渲染器构建或依赖安全时，才进入渲染器源码；先按错误现象定位到最小文件和函数，不得先扫描整个目录。
- 未经用户明确要求，不得重构、格式化、清理、升级依赖、同步上游或顺带修复渲染器。渲染器问题应作为独立任务处理，不得扩大普通 Meno 任务的阅读和修改范围。
- 验收 Markdown 快速预览时，必须确认实际生效的是 Meno 的 Quick Look 扩展，而不是本机已安装的 FluxMarkdown 扩展；两者的结果不得混为一谈。

## 图标资源

- Meno 自有的菜单栏、设置页、功能入口和自定义界面优先使用 Apple 官方 SF Symbols Beta 中的系统符号，并优先通过原生符号 API 调用；常见系统操作不得自行绘制图标或引入第三方图标库。
- 剪切、复制、粘贴、新建、返回、重命名等常见动作应先检索对应 SF Symbol；仅当系统符号无法准确表达且用户明确需要品牌化视觉时，才讨论自定义资源。
- SF Symbols 仅用于 Meno 可控制的界面。系统通知通常使用应用图标；平台不支持逐条指定独立图标时，不承诺使用独立 SVG，改用通知文字表达状态。
- 不得下载、复制或混入其他应用的图标资源。采用新符号前，须确认它在当前系统版本可用且在目标小尺寸下清晰可辨。
