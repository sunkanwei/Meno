# Meno 项目规则

## 仓库与文档

- 本仓库同时保存 Meno 的 Mac 与 Windows 当前源码；双方可以读取全仓库，默认只修改和验证自己的平台。用户明确要求跨端协议、共同规则或仓库结构调整时，才可同时修改两端。
- 根目录正常可见内容固定为 `build/`、`mac/`、`windows/`、`AGENTS.md`、`README.md` 和 `THIRD_PARTY_NOTICES.md`；Git 等隐藏内容不计入。
- `mac/` 和 `windows/` 只保存源码、资源、测试和构建脚本。所有本机构建内容统一放在 `build/mac/` 或 `build/windows/`，整个 `build/` 不进入 Git。
- `build/` 中的缓存和生成物可以重建；安装备份不属于缓存，删除前必须获得用户明确授权。
- 项目规则只维护在本文件，使用说明只维护在根目录 `README.md`，第三方归属和许可证只维护在根目录 `THIRD_PARTY_NOTICES.md`；不得在子目录新增重复说明。确有独立、长期且无法由这三份文件承载的文档时，先说明必要性再新增。

## Git 与双端同步

- 私有 GitHub 仓库是双端共同源码入口。开始修改前先拉取，完成本平台验证后再提交和推送，另一端随后拉取同一提交。
- 遇到未提交内容或合并冲突时停止自动覆盖，先确认归属；不得强制推送或改写共享历史。
- 不提交缓存、编译产物、日志、崩溃转储、证书、私钥、凭据、本机配置或嵌套 `.git`。
- 除非用户在当前任务明确要求，否则不得暂存、提交或推送；过去的授权不延续。
- Windows 首次迁移必须克隆到新目录，不覆盖或删除原工作目录。双端提交一致、构建通过且功能与迁移前一致后，新仓库才成为唯一权威源码；清理旧目录仍需用户明确授权。

## 共同协议与协作

- Mac 与 Windows 网络协议固定使用 `MENO`，不存在整体协议版本、鼠标控制版本或键盘报告版本，也不保留旧格式、双轨实现或协议回退。
- 当前两端源码和固定字节测试是协议唯一事实源。已发布的 capability、TLV field 和 message kind 不得改变、复用或重新解释；新增编号前必须搜索两端源码和测试，未知字段必须可安全忽略。
- Windows 驱动 ABI 与网络协议分离；网络功能只依据 Hello/Ready 的能力交集启用。
- 协议变更先由一端确定完整格式、编号和固定字节测试，再交给另一端同步；不得让两端同时独立设计同一格式。完成双端 Release、协商日志和真实联调前，不得声称跨平台完整验收。
- 一端需要另一端配合时，先完成本端可确认工作，再生成可直接复制给另一端 AI 的中文任务说明，包含现象、已确认事实、精确格式、不得回退的能力、验收标准和需要回传的结果。

## Mac 端

- `mac/MenoApp/` 是应用入口和协调层；功能在 `mac/Features/`，系统能力封装在 `mac/Platform/`，系统扩展在 `mac/Extensions/`，特权助手在 `mac/Helpers/`，纯逻辑测试在 `mac/Tests/`。新增测试直接编译生产源码时，必须在 `mac/project.yml` 的 MenoTests sources 登记对应文件。
- 跨端协议事实源为 `mac/Features/ClipboardSharing/ClipboardProtocol.swift` 和 `mac/Features/CrossScreenMouse/MouseControlProtocol.swift`，固定字节测试在 `mac/Tests/`。
- 主应用、Finder 扩展和 Markdown 预览扩展的 Bundle ID 固定为 `com.sunkanwei.Meno`、`com.sunkanwei.Meno.FinderExtension` 和 `com.sunkanwei.Meno.MarkdownPreview`。不得通过改名或更换身份恢复权限。
- 每次正式构建和安装必须使用固定的 Meno 专属签名身份，并只更新 `/Applications/Meno.app`；不得从构建目录直接运行或验收。
- 统一使用 `mac/Scripts/build.sh`、`mac/Scripts/build.sh test`、`mac/Scripts/build.sh release` 和 `mac/Scripts/install.sh`。只有 `project.yml` 变化时才手动运行 `xcodegen`。
- 会改变应用实际行为、扩展、资源、权限或打包内容的实现，在测试和 Release 构建后默认更新固定安装版并重启；纯文档、纯测试和未完成实验不安装。
- 安装前核对新旧 Bundle ID 与签名。旧版先移动到 `build/mac/backups/` 再覆盖；失败产物移开后恢复旧版，不用删除作为恢复手段。
- 任何生成应用或扩展的流程结束前，都必须清除指向 `build/` 等临时位置的扩展登记，只保留 `/Applications/Meno.app` 内正式扩展；重新启动 Finder，并确认实际扩展进程和“新建文档”右键菜单来自正式安装版。
- 软 KVM 横向拓扑只以断开 Philips 前的完整三屏基线为真源；Philips 断开后的两屏坐标不得反推缺失屏幕位置。本机屏幕物理高度换算与 Mac/Windows 路由是独立机制，不得顺带改变。
- `mac/Vendor/FluxMarkdownRenderer/` 是 Markdown Quick Look 的固定渲染组件。普通任务不得全面读取或修改；`dist/` 作为不透明资源使用。只有用户明确要求渲染问题或证据定位到具体功能时，才读取最小相关源码；不得顺带升级依赖、同步上游、重构或清理。验收时必须确认实际生效的是 Meno 扩展，而不是本机其他 Markdown 预览扩展。
- Meno 自有界面优先使用系统 SF Symbols；不得混入其他应用图标。采用新符号前确认系统版本和小尺寸可读性。
- 涉及 Windows 运行事实时主动使用 `windows_agent` 核对。系统范围只读；修改只限登记项目。安装驱动、修改关键注册表、启动或磁盘设置、批量删除等可能损坏 Windows 的操作必须禁止或先征得用户同意。

## Windows 端

- `windows/MenoClipboard/` 是唯一托盘程序；`windows/WindowsAgent/` 作为内部库编译进同一 EXE；`windows/MenoVirtualMouse/` 是 UMDF 2 虚拟 HID 驱动。
- Windows 统一使用 `verify-windows.ps1`、`build-release.ps1`、`build-user-release.ps1` 和 `MenoVirtualMouse/build-driver.ps1`。Cargo、WDK、驱动中间文件、驱动包和最终 `dist` 全部写入 `build/windows/`，不得写回源码目录。
- 驱动编译、签名、安装和实机验证必须分开报告。构建脚本不得安装驱动、启用全局 Driver Verifier、切换 TESTSIGNING、修改启动设置或重启 Windows。
- 删除驱动前必须精确确认硬件 ID、服务名和 `oemXX.inf`；不得批量删除 HID 或系统驱动。日常整理和用户态构建不得操作已安装驱动。
- 修改影响 `MenoClipboard.exe` 行为的源码、资源或配置后，必须运行相关测试和 Release 构建，先正常关闭旧进程，再更新 `%LOCALAPPDATA%\Meno\MenoClipboard.exe`，从固定位置重启，并确认运行文件与 `build\windows\dist\MenoClipboard.exe` 的 SHA-256 一致。纯文档和不影响 EXE 的构建脚本修改无需重启。
- Windows 诊断日志位于 `%LOCALAPPDATA%\Meno\MenoClipboard.log`，上一代为 `.log.old`。排查优先核对协商结果、鼠标接管与释放、剪贴板错误、启动时驱动 ABI 和驱动内嵌状态；不得记录用户输入内容。
- Meno 驱动是 UMDF 2 DLL，不应生成自己的 `.sys`。固定驱动 ABI、最低驱动版本、控制权租约、幂等释放、断线全状态清理和不可重复输入语义不得回退。
- VB-CABLE 必须保持官方原始 ZIP，不拆分、不修改；验证和 Release 构建须核对固定哈希与必要文件。安装只可由用户在托盘明确确认后进行，并与普通构建分离。

## 内置 Windows Agent

- Windows Agent 必须编译进 `MenoClipboard.exe`，保持一个正式 EXE、一个托盘和既有 17 项 MCP 工具；不得恢复旧远程参考 MCP、独立 Agent EXE、独立托盘或独立启动任务。
- Windows Agent 中的 Meno 项目必须登记共享仓库根目录，而不是单独登记 `windows/`；否则无法安全读取根规则、第三方声明或写入 `build/windows/`。平台规则仍限制 Windows AI 默认只修改 `windows/` 源码。
- 端口 45900、`_meno-agent._tcp.local.`、MCP 路径、配置目录、任务数据和 Windows 凭据名称属于兼容边界。
- Agent 在与鼠标、剪贴板和 MENO 主路径隔离的后台运行时中工作；任何 Agent、模型、截图或项目任务故障只能降级 Agent 自身。
- 截图工作进程只能复用同一个 `MenoClipboard.exe`。系统范围保持只读；项目写入和命令必须受登记根目录、哈希校验、程序白名单和自修改保护约束。
- Agent 通过 Windows 根验证与 Release 入口交付，不单独安装、启动或发布。

## 第三方边界

- 第三方组件的归属、许可证、版本和固定哈希统一维护在 `THIRD_PARTY_NOTICES.md`；Windows `dist` 和其他对外发布包必须继续携带适用声明。
- 不得为精简文档而删除、缩写或改写许可证正文、版权声明、来源信息和分发条件。
