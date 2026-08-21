# Meno

Meno 是一个同时包含 Mac 与 Windows 源码的私有双端项目。两个平台共享同一个 GitHub 仓库，但仍分别构建、测试和运行。

## 目录

- `mac/`：Mac 应用、系统扩展、测试和构建脚本。
- `windows/`：Windows 托盘程序、内置 Windows Agent、虚拟 HID 驱动、测试和构建脚本。
- `docs/`：双端协作和共同说明。

Git 只保存能够重新构建程序的源码、资源、依赖锁定文件和脚本。EXE、DLL、驱动生成物、缓存、日志、证书、私钥、凭据和本机设置不会上传；它们由各自平台重新生成或继续保留在本机。

## Mac

在 `mac/` 中使用现有统一脚本：

```bash
./Scripts/build.sh
./Scripts/build.sh release
./Scripts/install.sh
```

## Windows

在 `windows/` 中使用现有 PowerShell 脚本：

```powershell
.\verify-windows.ps1
.\build-release.ps1
.\build-user-release.ps1
```

全新检出后应先运行完整 Release 构建，生成本机的 `dist` 和驱动嵌入文件；之后才能使用只重建用户态程序的快速构建。

## 日常维护

1. 修改前拉取 GitHub 最新内容。
2. 只修改当前平台目录；协议或共同规则变更同时核对另一端。
3. 完成本平台测试和构建后提交、推送。
4. 另一台电脑拉取最新提交，再完成该平台的必要检查。

更详细的首次迁移和日常同步说明见 `docs/协作.md`。
