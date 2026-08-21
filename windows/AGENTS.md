# Meno Windows 项目规则

1. 本目录只维护 Meno Windows 端；Windows AI 可以读取仓库中的 `../mac/`，但只修改、测试和构建本目录。`WindowsAgent/` 是 Meno Windows 的内置 Agent 源码。
2. Windows AI 负责 Windows 用户态程序、内置 Windows Agent、Rust 测试与 Release 构建、虚拟 HID 驱动、WDK 构建与签名、安装诊断和 Windows 实机验证。
3. 不得创建、恢复或修改 Mac Swift、Xcode 工程或 Mac 构建配置。
4. 任务需要 Mac 配合时，先完成 Windows 范围内能够独立确认的工作，说明必须由 Mac 配合的原因，并生成可直接交给 Mac AI 的完整中文提示词。
5. 给 Mac AI 的提示词必须包含：现象和 Windows 已确认事实、精确协议版本与消息格式、Mac 端行为、不得回退的能力、Mac 验收标准，以及 Windows 后续检查项。
6. 未完成双端实测前，不得声称跨平台功能已经完整验收。
7. 构建产物、缓存、日志和本地证书私钥不得与正式源码混放；PFX 和其他私钥文件必须保持在 Git 忽略范围内。
8. 不得启用全局 Driver Verifier。
9. 未经用户明确同意，不得安装新驱动、切换 TESTSIGNING、修改启动设置或重启 Windows。
10. 删除驱动包前必须精确确认硬件 ID、服务名和 `oemXX.inf`；不得批量删除 HID 或系统驱动。
11. 驱动编译、签名、安装和实机验证必须分开汇报。
12. 日常整理和用户态构建不得自动操作已经安装的驱动。
13. 不提交、不推送，除非用户明确要求。
14. 凡修改会影响 `MenoClipboard.exe` 的源码、资源、配置或行为，交付前必须完成以下流程，不能只停留在“编译成功”：
    - 运行直接相关测试并完成 Release 构建，生成新的 `dist\MenoClipboard.exe`；
    - 先正常关闭当前正在运行的 `MenoClipboard.exe`，确认未退出时再结束该进程，不能让旧托盘实例继续运行；
    - 用新 EXE 更新固定位置 `%LOCALAPPDATA%\Meno\MenoClipboard.exe`，并从该固定位置重新启动；
    - 确认新的托盘实例已经启动、运行路径正确，并核对运行文件与 `dist\MenoClipboard.exe` 的 SHA-256 一致；
    - 如果关闭、替换或重新启动失败，必须明确报告，不能让用户自行关闭托盘图标后再测试；
    - 此流程只更新和重启用户态 EXE，不得借机安装、修复或更换驱动。纯文档修改以及不影响 EXE 的构建脚本修改不需要重启应用。
15. Windows AI 直接读取 `../mac/` 的当前源码，不得在 `windows/` 内恢复、保存或维护 Mac 源码副本，也不得修改、编译、安装或操作 Mac。
16. 需要 Mac 修改、编译、安装或实机验证时，Windows OpenCode 必须自动生成可完整复制给 Mac Codex 的中文任务提示词，包含现象、Windows 已确认事实、涉及协议、准确文件、不得回退的能力、Mac 所需修改、验收方式和 Windows 需要的回传结果。
17. Mac 运行事实无法从当前仓库确认时必须明确说明证据缺口，不得根据旧报告或记忆猜测。
18. Mac 与 Windows 的网络协议固定使用 `MENO`，不存在整体协议版本号。
19. 不得重新引入 `MNCL`、外层版本、鼠标控制版本、键盘报告版本、新旧双轨或协议回退。
20. 新功能只能增加新的 capability、TLV field 或 message kind；不得改变已经发布的编号和含义。
21. 分配新编号前必须搜索当前全部编号，禁止重复使用；Windows 与 Mac 必须逐字节核对。
22. Windows 驱动 ABI 与网络协议分离，不得用驱动 ABI 判断网络功能；网络功能只根据能力协商。
23. 修改协议后必须回传字段、固定字节、测试、Release EXE 和协商日志给 Mac 端核对。
24. 排查问题先读诊断日志 `%LOCALAPPDATA%\Meno\MenoClipboard.log`（上一代轮转为 `.log.old`），格式为 `YYYY-MM-DD HH:MM:SS.mmm LEVEL 消息`，LEVEL ∈ ERROR/INFO/DEBUG。单文件 2 MB 封顶自动轮转；连续重复消息折叠成 `(previous message repeated N times)`；进程崩溃必有 `PANIC` 行，有 `session start` 而无 `session end` 即为异常退出。DEBUG 默认关闭，由托盘“详细日志”开关（注册表 `HKCU\Software\Meno\VerboseLogging`）控制，复现鼠标问题时可临时打开。排查时优先看：`Negotiated MENO capabilities`（协商结果）、`mouse acquire/release`（接管与释放全字段）、`clipboard` 相关 ERROR（剪贴板失败）、`startup`（driver_abi 与驱动包内嵌状态）。
25. Windows Agent 必须作为内部库编译进 `MenoClipboard.exe`，不得恢复独立 Agent EXE、独立托盘或独立开机任务。Agent 使用隔离后台运行时；启动、模型、截图、MCP 或项目任务失败不得中断鼠标、剪贴板、驱动注入或 MENO 主连接。
