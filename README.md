# Meno

Meno 是一个同时包含 Mac 与 Windows 源码的私有项目。两端共享同一个 GitHub 仓库，但仍分别构建、安装和运行。

## 目录

- `build/`：两端本地缓存和编译产物，不进入 Git。
- `mac/`：Mac 应用、系统扩展、测试和构建脚本。
- `windows/`：Windows 托盘程序、虚拟 HID 驱动、测试和构建脚本。
- `AGENTS.md`：两端 AI 共同遵守的项目规则。
- `THIRD_PARTY_NOTICES.md`：第三方来源、版权和许可证。

正常构建后，根目录可见内容只应有上述三个文件夹和三个 Markdown。证书、凭据、本机设置、日志、缓存、EXE、DLL 和驱动生成物均不会上传 Git。

## Mac

进入 `mac/` 后使用：

```bash
./Scripts/build.sh
./Scripts/build.sh test
./Scripts/build.sh release
./Scripts/install.sh
```

缓存、编译产物和安装备份统一位于 `build/mac/`。正式应用固定安装在 `/Applications/Meno.app`。

Mac 端不再提供 Windows Agent 的发现、状态检查或 Codex 连接配置维护。跨屏键鼠、双向剪贴板和远程开关机使用独立通道，不受影响。

### 跨屏键鼠与剪贴板

Mac 端支持与 Windows 切换键鼠、共享剪贴板，不再采集或传送麦克风音频，也不再提供麦克风共享设置或音频连接端口。Windows 使用自己的本地话筒。Mac 本地的粘贴提示音继续保留。

使用全局快捷键（默认 Shift + F12）或菜单“启用 Windows 穿屏”，Meno 会迁移飞利浦上的 Mac 窗口，通过 Mac 的 HDMI 发送切换指令，读回确认飞利浦已选中 Windows 的 DP 后开放键鼠穿屏。再按同一快捷键或选择“恢复 Mac 屏幕”，Meno 会收回键鼠，确认飞利浦已回到 HDMI 2 并恢复 Mac 三屏和窗口。仅操作显示器按钮不会同步 Meno 的键鼠状态。

MENO 已发布的麦克风能力编号 8、Hello 音频端口字段 6、音频消息编号 28 永久保留，禁止复用。两端忽略这些退役能力、字段和消息；其他能力、消息格式与未知字段的安全忽略规则不变。

### Markdown 空格预览

Finder 中选中 Markdown 文件并按空格时，由 Meno 自带扩展显示接近 MarkText 0.19.1 的排版，同时保留原来的半透明毛玻璃窗口。预览支持常用 Markdown、任务列表、表格、代码高亮、数学公式、脚注、Mermaid、Vega 图表和内嵌图片；浅色和深色模式会自动跟随系统。由于 macOS 只允许空格预览扩展读取当前 Markdown 文件，同目录图片和网络图片会显示简洁提示，不会联网或显示破图框。

预览器完全随应用离线提供，不读取网络资源。Markdown 文件大小、图表数量与大小、渲染时间都受严格限制，避免一个不可信 Markdown 文件拖住 Finder。

## Windows

环境要求：Windows 11 x64、PowerShell 5.1 或更高、Rust 1.96.1、Visual Studio 2022 C++ Build Tools、Windows SDK 10.0.26100.0 和 WDK 10.0.26100.6584。

进入 `windows\` 后使用：

```powershell
.\verify-windows.ps1
.\MenoVirtualMouse\build-driver.ps1
.\build-release.ps1
.\build-user-release.ps1
```

首次检出必须先运行完整 Release 构建；之后才能使用只重建托盘程序的快速构建。缓存、驱动包和最终程序统一位于 `build\windows\`，最终发布文件在 `build\windows\dist\`。

首次运行 `build\windows\dist\MenoClipboard.exe` 时，程序会复制到 `%LOCALAPPDATA%\Meno\MenoClipboard.exe` 并从固定位置重新启动。构建不会自动安装驱动；鼠标驱动只有在用户从托盘明确选择并确认后才安装。Windows 使用本地话筒，Meno 不再接收 Mac 麦克风音频，也不携带音频驱动安装包。已安装的虚拟声卡不会随程序更新自动卸载。

Windows 端不再内置 Windows Agent：托盘只保留连接状态、暂停、重新发现、开机启动、光标主题、驱动修复和日志等项，程序不再监听固定端口，也不提供 MCP 工具、截图或 Codex 连接配置。跨屏键鼠、双向剪贴板和远程开关机使用 MENO 独立通道，不受影响。

## 日常维护

1. 开始修改前拉取 GitHub 最新内容。
2. 默认只修改当前平台；协议或共同规则变更必须核对两端。
3. 完成本平台测试和构建后，经用户明确授权再提交和推送。
4. 另一台电脑拉取同一提交，再完成对应平台验证。

Git 不保存缓存和本机数据。另一端拉取后不会缺少源码，只需完成该平台首次完整构建。
