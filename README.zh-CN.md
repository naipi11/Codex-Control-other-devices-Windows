# Codex 控制其他设备（Windows）

语言 / Language：**简体中文** · [English](README.md)

在 Windows 版 Codex Desktop 中启用随应用一起打包、但因运行时缺陷被隐藏的：

**设置 → 连接 → 控制其他设备（Control other devices）**

本项目不修改 `ChatGPT.exe`、`app.asar`，不写入
`C:\Program Files\WindowsApps` 中的任何文件。安装后由常驻托盘守护程序自动接管；手动模式保留为保守回退。

> [!IMPORTANT]
> 注册设备时请完成账号或工作区要求的 MFA、SSO 或 passkey 验证。
>
> [!WARNING]
> 这是非官方运行时兼容方案，会在随机 `127.0.0.1` 端口启用 Chromium 调试接口。请仅在可信的 Windows 电脑上运行，并在每次 Codex 更新后重新执行兼容性检查。

## 快速开始

运行只读预检，确认三项都满足再安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexControlOtherDevices.ps1
```

```text
Ready: True
Node.js: 22 或更高
Heuristic match: True
```

不想使用源码检出时，请优先使用发布安装包：

1. 从 [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases) 下载 `CodexControlOtherDevices-<version>-setup.exe` 并核对 SHA-256。
2. 运行安装包：支持文件会解包到 `%LOCALAPPDATA%\CodexControlOtherDevices-installer`，并在 `%LOCALAPPDATA%\CodexControlOtherDevices` 安装或升级常驻托盘守护程序。
3. 升级会保留现有设置与设备密钥，守护程序在下次登录时（或立即）自动启动。

安装常驻守护并允许兼容更新试运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -EnableCandidateCompatibleUpdates
```

安装目录固定为 `%LOCALAPPDATA%\CodexControlOtherDevices`。首次接管时，Codex 可能被自动关闭并立即重开一次，请先保存未提交的输入或前台工作。

已验证：Windows 11 · Codex Desktop `26.803.10989.0` · Node.js `22.23.1`；标签显示、控制器授权、设备列表、远程项目均可用。

## 日常使用

- 登录后计划任务 `Codex Control Other Devices Supervisor` 自动启动托盘守护，无需手动运行任何脚本。
- 托盘图标为绿色时，当前会话已生效；打开 **设置 → 连接 → 控制其他设备** 即可注册或使用。
- 新版 Codex 正常启动自带 `--remote-debugging-port`（没有 `--inspect`），守护程序已能识别这种启动方式并自动完成接管。
- 托盘菜单支持跟随系统、中文、English，切换即时生效，无需重启。
- 升级本项目或 Codex 后无需重装守护程序本体，安装器只会原子切换版本化运行时。

## 发布（Releases）

每个带 tag 的发布都会附带 Windows 安装包及其 SHA-256 校验文件。
`.github/workflows/release.yml` 会在 tag 上自动构建安装包，因此后续每次更新都会
提供可直接运行的 `CodexControlOtherDevices-<version>-setup.exe`。

最新版本：[v2.1.0](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases/tag/v2.1.0)

- 安装包：[CodexControlOtherDevices-2.1.0-setup.exe](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases/download/v2.1.0/CodexControlOtherDevices-2.1.0-setup.exe)
- SHA-256：`383d595aa11513c4ae1b57ef49b1ec55b3d3d1b7703f169bbdcb8503fdb37516`

Codex Desktop 更新后，请到 [Releases](https://github.com/naipi11/Codex-Control-other-devices-Windows/releases)
查看是否有更新安装包；也可以从本仓库运行兼容性检查，确认当前守护程序仍匹配。

## External renderer 共享 CDP

当已安装 External renderer Windows 运行时时，守护程序会自动使用其已保存的 renderer
端口；如果没有已保存状态，则在该回环端口可用于特殊 Codex 会话时使用 `9335`。
因此 renderer CDP 端口可以与 External renderer 共享；临时的 Electron 主进程 Inspector
保持独立，并会在桥接安装后关闭。

如果首选端口处于暂停状态、不可用、因已作为主进程 Inspector 端口而被排除，或被非
Codex 监听器占用，Codex Control Other Devices 会选择不同的动态回环 renderer 端口。
External renderer 的 `pause` 标记会跳过集成。External renderer 状态缺失或无效，以及 handoff
失败，都会安全处理而不会阻止 Codex 会话；在这些回退场景中，集成不保证 Browser-ID
或端口复用。

不会修改 Codex 或 External renderer 的安装文件。

## 托盘菜单

原生 WinForms 菜单按语义状态显示或隐藏操作：立即应用、重试、自动化开关、兼容更新试运行、日志、卸载。卸载必须先在菜单中确认。

| 颜色 | 状态 | 含义 |
|---|---|---|
| 灰色 | Waiting / Inspecting / Transitioning | 等待 Codex、检查当前会话或正在应用桥接 |
| 绿色 | Active / ActivePaused | 当前会话已验证可用 |
| 黄色 | Suppressed | 兼容操作被抑制，需手动重试或新运行时 |
| 黄色 | RendererHandoff | External renderer handoff 未完成；已验证的 Codex 会话仍保持可用 |
| 红色 | Recovered / Error | 已安全恢复普通 Codex，或自动操作被阻止 |

## 维护命令

修复损坏状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexControlOtherDevices.ps1 -RepairState
```

安全卸载（默认保留设备密钥）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CodexControlOtherDevices.ps1
```

卸载参数：`-BackupDeviceKeyStore` 备份密钥；`-RemoveDeviceKeyStore` 显式删除密钥（两者互斥）；`-KeepCurrentSpecialSession` 保留当前特殊会话（renderer CDP 会继续开放）。

手动启用或恢复普通会话（保守回退）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
```

## 它解决了什么

受影响的 Windows 包具备全部以下特征：

1. Windows 控制器页面、字符串和后端调用已随包提供。
2. Statsig 门 `782640499` 语义相反：`true` 反而隐藏 `showControlOtherDevices`。
3. 主进程设备密钥入口只接受 `process.platform === "darwin"`。
4. Windows 包未附带 `remote-control-device-key.node`。

官方文档见 [Remote connections](https://learn.chatgpt.com/docs/remote-connections)。本项目只修复本地 Windows 运行时缺口，不绕过账号授权、MFA/SSO/passkey、工作区策略或服务器权限。

## 安全模型

- 调试端口只绑定随机 `127.0.0.1`；主进程 Inspector 注入完成后必须关闭。
- 与当前 Windows 用户同权限的进程可访问这些端口，因此不要在不可信电脑上运行。
- 设备私钥保存在 `%CODEX_HOME%\remote-control-device-keys.windows.json`（未设置 `CODEX_HOME` 时为 `%USERPROFILE%\.codex\...`），使用 DPAPI 当前用户范围加密，是软件密钥而非 TPM 不可导出密钥。
- 移动或删除本地密钥不会撤销服务器端授权，请先在 Codex 中撤销设备。

详见 [SECURITY.md](SECURITY.md)、[docs/TECHNICAL.md](docs/TECHNICAL.md)。

## 诊断

日志位于 `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`，主要有 `install.log`、`supervisor.log`、`bootstrap.log`、`transactions.log`。

## 常见问题

仍没有“控制其他设备”标签？

1. 确认托盘图标为绿色（灰色表示等待 Codex 或自动化已暂停）。
2. 重跑预检，确认 `Ready: True`。
3. 查看 `logs\supervisor.log` 和 `logs\install.log`。
4. 确认安全软件没有阻止 `node.exe` 访问本机回环端口。
5. 退出所有 Codex 进程后重试；守护程序最多自动重开一次。

授权失败？

- 完成账号或工作区要求的 MFA/SSO/passkey。
- 确认 Codex 与浏览器使用同一 ChatGPT 账号和工作区。
- 组织工作区请确认管理员允许 Remote Control。

External renderer 未附加到已经运行的会话？

请按以下顺序手动重新绑定：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Reset-CodexControlOtherDevices.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-CodexControlOtherDevices.ps1
```

## 项目结构

```text
Install-CodexControlOtherDevices.ps1   安装/升级/修复 CLI
Uninstall-CodexControlOtherDevices.ps1 安全卸载 CLI
Start-CodexControlOtherDevices.ps1     手动会话启动
Reset-CodexControlOtherDevices.ps1     手动停止/密钥备份
Test-CodexControlOtherDevices.ps1      只读兼容性预检
src/persistence/                       引导、托盘守护、会话控制器、静态探测
src/runtime/                           clean-room 桥接实现
tests/                                 仓库自测、持久化测试、视觉 gallery
docs/                                  技术文档、隔离记录、双语截图
```

## 验证

```powershell
npm test
```

## 许可与来源

[MIT](LICENSE) © 2026 naipi11。问题定位与运行时技术来自
[hunterbeach 的 Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80)，
上游思路分别来自 [zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)
和 [brunolemos 的 feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae)。
最终 `src/runtime` 采用隔离 clean-room 独立重写，不包含无许可上游源码文本；原始贡献与来源边界见
[docs/CLEANROOM.md](docs/CLEANROOM.md) 和 [NOTICE.md](NOTICE.md)。
本项目非官方，与 OpenAI 无关，不分发 OpenAI 的程序文件或资源。
