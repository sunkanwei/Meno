# Meno Windows

`MenoClipboard/` 是唯一的 Windows 托盘程序，负责共享剪贴板、文件、跨屏鼠标和键盘，并可把 Mac 麦克风音频写入 VB-CABLE；`WindowsAgent/` 作为内部库编译进同一个 `MenoClipboard.exe`，通过局域网 MCP 向 Mac 提供 Windows 调查与项目协作能力；`MenoVirtualMouse/` 是配套的 UMDF 2 虚拟 HID 驱动。

## 环境

- Windows 11 x64、PowerShell 5.1 或更高版本。
- Rust 1.96.1；`rust-toolchain.toml` 已固定工具链和 `x86_64-pc-windows-msvc` 目标。
- Visual Studio 2022 C++ Build Tools、Windows SDK 10.0.26100.0、WDK 10.0.26100.6584。

构建缓存统一放在 `%LOCALAPPDATA%\Meno\build-cache`，不写入源码目录。

Windows Agent 不生成独立 EXE 或托盘。它在 Meno 主进程的隔离后台运行时中监听既有 45900 端口，并继续使用 `_meno-agent._tcp.local.` 发现标识、原配置目录和 Windows 凭据。Agent 启动或任务失败不会中断鼠标、剪贴板及 MENO 主连接。

仓库中的 `third_party\VB-CABLE\VBCABLE_Driver_Pack45.zip` 是 VB-Audio 发布的原始 Pack 4.5 包。验证和 Release 构建会核对固定 SHA-256 与必要文件，防止无意中替换或拆改第三方驱动。

## 验证与构建

运行格式、Clippy、全部 Rust 测试和离线锁文件检查：

```powershell
.\verify-windows.ps1
```

只构建 Release 驱动：

```powershell
.\MenoVirtualMouse\build-driver.ps1
```

构建驱动和两个 Windows 程序并生成个人使用包：

```powershell
.\build-release.ps1
```

只重建用户态托盘程序、保留 `dist` 中已有驱动包且不编译或安装驱动：

```powershell
.\build-user-release.ps1
```

驱动脚本使用当前用户证书库中唯一有效的 `CN=Meno Virtual Mouse Test` 代码签名证书；存在多个证书时可给 `build-driver.ps1` 和 `build-release.ps1` 传入 `-SigningThumbprint`。脚本只构建和校验，不安装驱动、不修改系统启动设置，也不会重启 Windows。

`dist/` 最终包含：

- `MenoClipboard.exe`
- `MenoHidProbe.exe`
- `MenoVirtualMouse.dll`
- `MenoVirtualMouse.inf`
- `MenoVirtualMouse.cat`
- `MenoVirtualMouse.cer`
- `THIRD_PARTY_NOTICES.md`
- `SHA256SUMS.txt`

`MenoClipboard.exe` 内嵌 Meno 鼠标驱动和原始 VB-CABLE ZIP，因此用户不需要另行下载音频驱动；ZIP 保持官方压缩包原样，不会作为散落文件出现在 `dist/`。

`MenoClipboard.exe` 同时内置 Windows Agent 的17项 MCP 工具。托盘中的“Windows Agent”入口用于管理模型、项目和端口；退出 Meno 会同时正常停止 Agent 服务。

Meno 驱动是 UMDF 2 DLL，不生成自己的 `.sys`；包中出现 `MenoVirtualMouse.sys` 会被构建脚本拒绝。

## 安装和使用

首次运行 `dist\MenoClipboard.exe` 时，程序会复制到 `%LOCALAPPDATA%\Meno\MenoClipboard.exe` 并从固定位置重新启动。程序继承启动者权限，本身不会在普通启动时自动弹出 UAC。

只有用户主动点击托盘菜单中的“修复鼠标驱动”时，程序才会以管理员权限启动同一固定 EXE 的 `--install-driver` 模式，写出内嵌驱动包并执行安装；安装进程完成后直接退出，不会再启动一个高权限托盘。构建、驱动安装和当前已安装驱动是三件独立的事情。

“查看日志”打开 `%LOCALAPPDATA%\Meno\MenoClipboard.log`，“清理日志”会清空它。

麦克风共享使用 VB-Audio 的 VB-CABLE。全新安装后首次启动时，Meno 会先检测 `CABLE Input`；缺少设备时才会显示许可和安装确认，用户确认后再通过 UAC 启动内嵌的官方 x64 安装程序。安装所需的临时解压文件会在安装器退出后清理；用户也可以随时点击“安装音频驱动 (VB-CABLE)”执行同一流程，已安装时不会重复操作。安装完成后必须重启 Windows，Meno 不会自动重启或自动卸载驱动。托盘中的“VB-CABLE 官网与捐赠”会打开其[官方页面](https://vb-audio.com/Cable/)；VB-CABLE 的指定来源是 `www.vb-cable.com`，它是捐赠软件，所有参与和捐赠都受到欢迎，专业机构部署应遵循 VB-Audio 当前许可规则。

安装后应保持原扬声器或耳机为系统默认播放设备，Windows 语音软件选择录音端 `CABLE Output`。只有 Mac 控制连接同时协商麦克风能力和音频端口时，Windows 才会打开播放端 `CABLE Input`；收到首个有效 PCM 帧后才显示“麦克风可用”。音频错误只显示为附加状态，不会覆盖或中断主连接。

## 协议兼容边界

本目录只维护 Windows 端。通信继续使用明文、无认证的 `MENO`，只按个人可信局域网使用。

网络协议没有整体版本号。Hello/Ready 的 TLV 字段为：1 设备名、2 能力列表、3 驱动 ABI、4/5 主屏宽高、6 音频端口（非零 UInt16 大端）。能力编号固定为：1 文本剪贴板、2 PNG、3 鼠标、4 键盘、5 文件、6 远程关机、8 Mac 麦克风、9 定向跨屏交接、10 Windows 上线通知；编号 7 仍未分配。

麦克风使用独立 TCP 连接和既有 20 字节 `MENO` 帧头。控制 Ready 必须同时包含能力 8 与字段 6；音频 Hello/Ready 只含设备名和能力 8。`MicrophonePcm` 消息编号固定为 28，每帧 payload 为 1,920 字节，即 48 kHz、20 ms、960 个 Int16 大端单声道样本；该消息的 messageID 在每条音频连接中从 1 严格递增。音频失效不会拖断剪贴板；控制连接变化、暂停、重新发现、休眠或退出会停止音频并清空缓冲。

文件消息编号固定为 `FileOffer` 18、`FileAccept` 19、`FileChunk` 20、`FileComplete` 21、`FileResult` 22、`FileCancel` 23、`FileAck` 24。`ShutdownRequest` 25 仅在对端协商能力 6 后接受空 payload，并通过系统目录中的 `shutdown.exe` 强制关机。

`WindowsOnline` 消息编号固定为 30，payload 必须为空。Windows 只在控制连接完成 Ready、双方协商能力 10 后发送；每个 `MenoClipboard.exe` 进程最多成功发送一次，断线重连不重复，发送失败则允许在后续连接重试。

文件剪贴板单次最多 20,000 个条目、128 个顶层项目、64 层和 50 GiB 逻辑文件总量。已完成接收缓存合计也受 20,000 条目和 50 GiB 限制，并始终保留 1 GiB 可用磁盘空间；仍被当前剪贴板引用的缓存不会被淘汰。

虚拟 HID 驱动 ABI 为 6，Windows 程序要求驱动版本不低于 2.3.5。连续鼠标和键盘输入通过独立的 HID 代理进程写入；代理请求超过 50 ms、进程退出或通信损坏时会终止并重建代理，绝对位置、按键状态和重置最多安全重放一次，滚轮等不可重复事件绝不重放。纯移动在 Windows 端按最高 240 Hz 发布最新状态，按键、滚轮、键盘和重置仍严格有序。鼠标使用 0..32767 绝对坐标；所有网络侧鼠标和键盘控制消息仍保留现有非零 UInt64 controlID、大端格式、租约和全状态释放行为。
