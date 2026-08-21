# Meno

Meno 是一个同时包含 Mac 与 Windows 源码的私有项目。两端共享同一个 GitHub 仓库，但仍分别构建、安装和运行。

## 目录

- `build/`：两端本地缓存和编译产物，不进入 Git。
- `mac/`：Mac 应用、系统扩展、测试和构建脚本。
- `windows/`：Windows 托盘程序、内置 Windows Agent、虚拟 HID 驱动、测试和构建脚本。
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

首次运行 `build\windows\dist\MenoClipboard.exe` 时，程序会复制到 `%LOCALAPPDATA%\Meno\MenoClipboard.exe` 并从固定位置重新启动。构建不会自动安装驱动；鼠标驱动和 VB-CABLE 只有在用户从托盘明确选择并确认后才安装。

Windows Agent 的 Meno 项目路径应登记为共享仓库根目录，例如 `D:\APP\Meno`，不要只登记 `D:\APP\Meno\windows`；这样它才能读取共同规则并使用根目录的构建目录。

## 日常维护

1. 开始修改前拉取 GitHub 最新内容。
2. 默认只修改当前平台；协议或共同规则变更必须核对两端。
3. 完成本平台测试和构建后，经用户明确授权再提交和推送。
4. 另一台电脑拉取同一提交，再完成对应平台验证。

Git 不保存缓存和本机数据。另一端拉取后不会缺少源码，只需完成该平台首次完整构建。
