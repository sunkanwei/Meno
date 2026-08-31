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

### 鼠标侧键语音

在“键盘快捷键”设置中开启“鼠标侧键语音输入”，并在 G HUB 中将需要使用的按钮设为“鼠标侧键 4”，不要分配键盘宏。保持豆包输入法的右 Alt 按住说话设置：按住鼠标侧键时模拟右 Alt 按下，松开时释放，键盘右 Alt 原有用法不变。

功能需要 Meno 的辅助功能和输入监听权限，仅在 Mac 本地接管鼠标侧键 4，替代该侧键原来的前进或后退操作。所有输出该信号的鼠标按钮都会生效，建议只分配一个按钮。按住期间不进入 Windows 跨屏控制；关闭功能、切换共享屏幕、系统睡眠、切换用户或退出 Meno 时结束模拟按键。系统和用户会话恢复后才能重新触发。Meno 不录音、不识别语音，也不切换输入法。

### 快捷运行

Meno 菜单栏中的“快捷运行”用于手动执行一次性 zsh 脚本，不打开终端。默认脚本目录为 `mac/QuickScripts/`，设置中的“快捷运行”可以选择其他目录或恢复默认目录。

- 只读取所选目录第一层的 `.zsh` 文件，菜单名称取自文件名并隐藏后缀。
- 新增或修改脚本后，重新打开菜单即可读取，不需要重新构建 Meno。
- 脚本不会自动执行；同一个脚本结束前不能重复启动。
- 脚本必须自行结束，不得等待终端输入或作为长期后台服务运行。
- 脚本由系统自带的 `/bin/zsh` 执行，当前工作目录为脚本所在目录，标准输入关闭，输出只用于显示本次结果且不会保存为永久日志。
- 脚本结束或 Meno 退出时，仍留在本次进程组中的后台子进程会被停止。

仓库自带的 `Skill开关.zsh` 用于启用或停用 Nexus UI Web Skill 映射。运行成功后，重新启动 Codex 或新建任务以确认 Skill 可见状态。

“放大服务”用于切换本机图片放大服务：未运行时在后台启动，确认服务就绪后自动打开网页；运行时正常关闭并终止计算任务。关闭会丢失尚未保存的内存结果，已保存图片不受影响。服务独立于本次菜单脚本运行，环境、锁文件和服务日志均留在放大项目内，不设置开机自启。

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
