# Codex Control other devices for Windows

[English](README.en.md) | 简体中文

在 Windows 版 Codex Desktop 中启用已经随应用打包、但因运行时缺陷无法正常出现的：

**设置 → 连接 → 控制其他设备（Control other devices）**

本项目不修改 `ChatGPT.exe`、`app.asar`，也不写入
`C:\Program Files\WindowsApps` 中的任何文件。安装后由托盘守护程序自动接管；
手动模式仍保留为保守回退入口。

> [!IMPORTANT]
> 设备注册时，请完成账号或工作区要求的 MFA、SSO 或 passkey 验证。本仓库测试
> 账号要求预先启用 MFA；如果授权流程提示 MFA，请先完成设置再开始设备注册。

> [!WARNING]
> 这是非官方、与客户端内部实现相关的运行时兼容方案。它会在随机的
> `127.0.0.1` 端口启用 Chromium 调试接口。只应在可信 Windows 电脑上运行，
> 并应在每次 Codex 更新后重新执行兼容性检查。

## 当前验证状态

| 项目 | 结果 |
|---|---|
| Windows | Windows 11，已通过 |
| Codex Desktop | `26.721.4979.0`，已完成端到端验证 |
| Node.js | `22.23.1`，已通过 |
| 功能 | 标签显示、控制器授权、设备列表、远程项目均可用 |
| 安装包修改 | 无 |

hunterbeach 的原始研究记录验证过 `26.715.7063.0`。本仓库不只检查版本号，还会
扫描本机 `app.asar` 中四个与该缺陷相关的文本哨兵，并检查原生模块是否存在。这是
针对已测试代码族的**启发式兼容检查**，可以拦截许多不匹配更新，但不能替代对新
版本控制流的人工审计。

## 解决了什么问题

受影响的 Windows 安装包同时具备以下状态：

1. Windows 控制其他设备所需的页面、文案和后端调用已经随包提供。
2. Statsig 门 `782640499` 在渲染端的使用逻辑与名称语义相反，门值为 `true`
   时反而隐藏 `showControlOtherDevices`。
3. 主进程设备密钥入口仍只允许 `process.platform === "darwin"`。
4. Windows 包没有附带 `remote-control-device-key.node`。

所以会出现一个很具体的症状：Windows 可以显示“控制此电脑”和“SSH”，手机或
平板也可以控制这台电脑，但 Windows 端没有“控制其他设备”标签，无法把这台电脑
注册成控制器。

官方的 [Remote connections 文档](https://learn.chatgpt.com/docs/remote-connections)
介绍了正常的设备配对、同账号/工作区、所需身份验证和远程主机要求。本项目只补齐
受影响 Windows 构建中的本地运行时缺口，不绕过账号授权、MFA/SSO/passkey、
工作区策略或服务器权限。

## 持久化托盘守护（推荐）

安装后会注册一个仅当前用户的登录计划任务，登录后自动启动常驻托盘图标：

- 无需每次手动运行启动脚本；
- Codex 正常启动后，守护程序最多自动关闭并重开一次，注入并验证桥接；
- 渲染端修复成功时托盘变绿，并显示“连接其他设备”标签；
- 兼容更新（`CandidateCompatible`）默认不自动尝试，除非显式开启
  `-EnableCandidateCompatibleUpdates`；
- 未知或不兼容构建（`UnknownOrIncompatible`、`NativeModulePresent`）保持普通
  会话，绝不接管；
- 已确认兼容的版本仅允许一次受控接管，失败即恢复普通会话，不会循环重试；
- 更新本项目或 Codex 后无需重新安装守护程序本体；升级安装器只会原子切换版本化
  运行时并让旧守护程序正常退出。

### 托盘图标、状态与双语菜单

托盘图标使用连接桥轮廓和状态圆点，而不是容易与普通应用混淆的字母图标。颜色只
表达当前守护状态，不改变安全策略：

| 颜色 | 状态 | 含义 |
|---|---|---|
| 灰色 | Waiting / Inspecting / Transitioning | 等待 Codex、检查当前会话或正在应用桥接 |
| 绿色 | Active / ActivePaused | 当前会话已验证可用；若自动修复暂停，仍保留绿色但菜单会反映暂停状态 |
| 黄色 | Suppressed | 兼容操作被抑制，需手动重试或新的运行时版本 |
| 红色 | Recovered / Error | 已安全恢复普通 Codex，或自动操作被阻止，需要查看日志 |

右键菜单是原生 WinForms 分组菜单，并按语义状态显示或隐藏操作：当前会话已就绪、
立即检查、上次重试、自动修复开关、兼容更新试运行、日志和卸载不会在无关状态下
伪装成可用操作。卸载必须先在菜单中确认；取消确认不会入队，也不会改变状态。

菜单语言默认跟随 Windows。语言根节点在中文界面显示为 `语言 / Language`，在
英文界面显示为 `Language / 语言`；子菜单提供：

- `跟随系统（中文）` / `Follow system (Chinese)`；
- `中文` / `Chinese`；
- `English`。

选择 `中文` 或 `English` 后，菜单和托盘提示会立即更新，无需重启 Supervisor 或
Codex。选择跟随系统会写入
`%LOCALAPPDATA%\CodexControlOtherDevices\state\ui-preferences.json` 的
`languageMode: "System"`。该文件只保存显示偏好，不属于自动化安全状态；缺失或损坏
时回退到跟随系统，且不会阻断兼容操作、改变授权开关或触发状态修复。

### 视觉 gallery 与截图

不想触碰当前 Codex 会话时，可以运行只读的托盘视觉 gallery：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File .\tests\manual\Show-TrayUiGallery.ps1 `
  -Locale All -State All -DurationSeconds 8
```

gallery 只在内存中接受菜单命令，始终拒绝卸载确认，不检查、停止、启动或修改
Codex，也不写入偏好和安全状态。仓库中的原生菜单截图：

- [中文菜单](docs/assets/tray-menu-zh-CN.png)
- [English menu](docs/assets/tray-menu-en-US.png)

### 安装

先执行只读预检：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Test-CodexControlOtherDevices.ps1
```

只有看到以下三项满足时才继续：
- `Ready: True`
- Node.js 版本不低于 22
- `Heuristic match: True`

安装并显式允许兼容更新候选：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Install-CodexControlOtherDevices.ps1 `
  -EnableCandidateCompatibleUpdates
```

第一次兼容更新尝试前，请先保存未提交的输入或前台工作：正常启动的 Codex 可能
会被关闭并立即重开一次。首次安装后，登录计划任务 `Codex Control Other Devices
Supervisor` 会在下次登录（或安装器立即启动）时运行托盘守护。

安装目录固定为：

```text
%LOCALAPPDATA%\CodexControlOtherDevices
```

### 显式状态修复

状态文件缺失或损坏时，守护程序会先隔离证据并关闭自动化。恢复必须显式执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Install-CodexControlOtherDevices.ps1 -RepairState
```

修复会重新创建 schema 1 状态，并将 `automationEnabled` 和
`candidateCompatibleOptIn` 都保持为 `false`；随后需在托盘中分别恢复自动化和
受控兼容更新授权。

### 卸载

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Uninstall-CodexControlOtherDevices.ps1
```

卸载默认：

1. 暂停自动化并取得 transition 互斥锁；
2. 若存在已通过验证的特殊会话，先关闭其调试端点并恢复一个普通 Codex 会话；
3. 删除计划任务、让守护程序退出（超时才终止其已验证 PID）；
4. 删除 bootstrap、运行时、状态和日志；
5. **保留** DPAPI 设备密钥文件。

只有显式 `-KeepCurrentSpecialSession` 才允许卸载后保留当前特殊实例，并会显示
renderer CDP 将继续开放且不再有托盘监视的警告。密钥相关参数：

```powershell
# 仅备份（移动为带时间戳的备份，不删除）
.\Uninstall-CodexControlOtherDevices.ps1 -BackupDeviceKeyStore

# 显式删除本地密钥（互斥，不可与备份同时使用）
.\Uninstall-CodexControlOtherDevices.ps1 -RemoveDeviceKeyStore
```

移动或删除本地密钥文件**不会**撤销服务器端授权；请先在 Codex 中撤销设备。

## 手动模式（保守回退）

守护程序不需要手动启动。若需要按会话手动启用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-CodexControlOtherDevices.ps1
```

停止特殊实例并正常重启 Codex，但保留设备密钥：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Reset-CodexControlOtherDevices.ps1
```

## 兼容更新行为与验证边界

- 首次出现的兼容包（`CandidateCompatible`）只在两个授权开关同时开启时尝试一次
  受控接管；动态确认成功后记录 `VerifiedCompatible`。
- 未知、不兼容或已检测到原生模块的构建保持普通会话，不关闭、不重开。
- 动态确认失败后会恢复普通实例并写入抑制键；手动“重试”或运行时升级才能清除。
- 模拟测试中的“重启/更新夹具”只是等价状态模拟，**不能**算作真实 Windows
  登录或真实 Microsoft Store 更新观察；这两项必须等到真实周期发生后再记录。

## 安全模型

### 调试端口

- 渲染端调试端口只绑定随机的 `127.0.0.1` 地址，并持续到 Codex 退出。
- 主进程 Inspector 同样只绑定 `127.0.0.1`，注入完成后必须确认关闭
  （`ECONNREFUSED`）；若未关闭，守护程序会停止特殊实例并恢复普通启动。
- 与当前 Windows 用户同权限的恶意进程可以访问这些端点，因此不要在不信任的
  电脑上使用。

### 设备私钥

设备私钥保存在：

```text
%CODEX_HOME%\remote-control-device-keys.windows.json
```

未设置 `CODEX_HOME` 时，默认路径为
`%USERPROFILE%\.codex\remote-control-device-keys.windows.json`。
私钥使用 Windows DPAPI `CurrentUser` 范围加密；其他 Windows 用户不能直接
使用该密文完成签名，但登录到同一 Windows 用户会话的恶意程序仍属于信任边界内。

桥接层报告 `os_protected_nonextractable` 以兼容 Codex 的密钥协议。本实现是
DPAPI 保护的软件密钥，**不等同于 TPM 或 Secure Enclave 中真正不可导出的硬件
密钥**。更多信息见 [SECURITY.md](SECURITY.md)。

## 诊断与日志

持久化安装的日志写入：

```text
%LOCALAPPDATA%\CodexControlOtherDevices\logs\
```

日志包含组件、阶段、稳定错误码和结果，不应包含账号密码或设备私钥。公开提交
日志前仍应检查其中的本机路径和其他环境信息。

## 常见问题

### 仍然没有“控制其他设备”标签

1. 确认托盘图标存在且为绿色；灰色表示等待 Codex 或自动化已暂停。
2. 重新运行预检，确认 `Ready: True`。
3. 查看 `%LOCALAPPDATA%\CodexControlOtherDevices\logs\supervisor.log` 与
   `install.log`。
4. 确认没有安全软件阻止 `node.exe` 访问本机回环端口。
5. 退出所有 Codex 进程后重试；守护程序最多自动重开一次。

### 更新 Codex 后预检失败

这是预期的保护行为。更新可能已经修复缺陷，也可能改变内部标识符或调用约束。
哨兵检查本身也不能证明未来版本兼容。不要为了“先跑起来”而删除检查；请提交
Issue，并附上：

- Codex 包版本；
- 预检中的布尔哨兵结果；
- 已脱敏的错误信息。

不要上传 `app.asar`、登录令牌或设备密钥。

### 点击“添加”后授权失败

- 完成账号或工作区提示的 MFA、SSO 或 passkey；如果提示必须先启用 MFA，请
  在重新开始设备注册前完成。
- 确认 Codex 与浏览器使用相同的 ChatGPT 账号和工作区。
- 如果是组织工作区，请确认管理员允许 Remote Control。

## 项目结构

```text
.
├── Install-CodexControlOtherDevices.ps1   # 安装/升级/状态修复 CLI
├── Uninstall-CodexControlOtherDevices.ps1 # 安全卸载 CLI
├── Start-CodexControlOtherDevices.ps1     # 兼容手动会话启动
├── Reset-CodexControlOtherDevices.ps1     # 兼容手动停用/密钥备份
├── Test-CodexControlOtherDevices.ps1      # 只读兼容性预检
├── src/
│   ├── check-package.mjs                   # 流式扫描 app.asar 文本哨兵
│   ├── runtime/                            # 隔离 clean-room 运行时实现
│   └── persistence/
│       ├── bootstrap.ps1                   # 自包含 active/previous 引导与回退
│       ├── Supervisor.ps1                  # WinForms/WMI 托盘守护主机
│       ├── SessionController.ps1           # Inspect/Apply/Recover 控制器
│       ├── StaticProbeWorker.ps1           # 独立静态探针子进程
│       └── modules/                        # 持久化/清单/状态/进程/任务/安装模块
├── tests/
│   ├── Validate.ps1                        # 仓库与 hermetic 全量验证
│   ├── PersistenceSelfTest.ps1             # PowerShell 持久化聚合测试
│   ├── CleanroomSelfTest.js                # DPAPI/兼容/渲染/端口自测
│   ├── persistence/                        # 各模块自测（含 InstallLifecycle）
│   └── manual/Show-TrayUiGallery.ps1       # 不触碰 Codex 的视觉 gallery
├── docs/
│   ├── TECHNICAL.md                        # 技术设计与信任边界
│   ├── CLEANROOM.md                        # 隔离实现记录与边界
│   └── assets/tray-menu-*.png              # 已检查的双语原生菜单截图
├── package.json                            # Node 版本约束与验证命令
├── SECURITY.md
└── NOTICE.md
```

## 开发验证

```powershell
npm test
```

验证内容包括：所有 PowerShell 文件解析、JavaScript/ESM 语法检查、临时目录中的
DPAPI 密钥生命周期、兼容/渲染/端口自测、全部持久化模块自测、清单与安装生命周期
测试、仓库必需文档，以及（未指定跳过时）本机已安装 Codex 的只读缺陷哨兵预检。

## 原创贡献与来源边界

本仓库根据 hunterbeach 发布的问题定位和运行时技术路线定义功能外约，并结合对
本机 Codex Desktop `26.721.4979.0` 安装包的只读检查与端到端验证。为避免把没有
明确开源许可的上游实现文本混入 MIT 代码，本仓库最终发布的 `src/runtime` 核心
采用隔离的 **clean-room 独立重写**：实现者只能看到所需行为、接口字段和本机包中
的公开调用契约，不能查看前期衍生原型、原始 Gist 代码或其他在线 workaround
源码。过程与测试记录见 [docs/CLEANROOM.md](docs/CLEANROOM.md)。

属于本仓库的主要原创工程贡献包括：

- 无外部依赖的安装包流式文本哨兵扫描；
- 随机回环端口与主 Inspector 关闭验证；
- 不匹配构建拒绝运行和失败自动恢复普通启动；
- 带版本结构、旧格式兼容和可恢复清理的 DPAPI 密钥存储；
- 版本化运行时、manifest 哈希、active/previous 原子切换与 ready 回退；
- 常驻托盘守护、WMI 能力降级链与三秒 reconcile 权威；
- 经过隔离重写、无运行时依赖的 CDP/Inspector 桥接代码；
- 安装/升级/修复/安全卸载生命周期与中英双语文档、自动验证。

核心问题定位与运行时注入方法来自 hunterbeach 的
[Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80)。
该 Gist 还注明其主进程思路来源于
[zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)，
渲染端注入模式参考了
[brunolemos 的 feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae)。
这些来源保持显式，以便上游发现不被表述为本仓库自己的原创发现；上游源码文本
不进入 clean-room 运行时。完整来源边界见 [NOTICE.md](NOTICE.md)。

本仓库不分发 OpenAI 的程序文件或资源，也不隶属于 OpenAI。

## 许可证

[MIT](LICENSE) © 2026 naipi11。MIT 许可覆盖本仓库新增代码与文档；上游项目和公开
技术资料仍适用各自的权利与许可条款。参见 [NOTICE.md](NOTICE.md)。
