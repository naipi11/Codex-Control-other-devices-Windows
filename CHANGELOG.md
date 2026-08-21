# CodexRemote-fix release notes

This file keeps the short bilingual summary for every published release.

## Unreleased

### English

- Refreshed the README visuals with a privacy-safe animated workflow, verified-state control view, and native Windows-style tray menu illustration.

### 简体中文

- 更新 README 展示素材：新增隐私安全的动图工作流程、已验证状态界面和 Windows 原生风格托盘菜单示意图。

## v2.4.15

### English

- Rebuilt the tray UI as a compiled native Win32 TrayHost with the standard Windows context menu behavior.
- Added the CodexRemote-fix product icon, Start-menu entry, and desktop shortcut.
- Preserved bilingual tray controls: Follow system, 中文, and English.
- Hardened interrupted-session recovery and kept the encrypted device-key store unchanged.
- Known issue: an updated Codex profile can still show an empty **Control other devices** device list. The enrollment/profile migration fix is being developed separately.

### 简体中文

- 托盘 UI 重构为编译后的原生 Win32 TrayHost，使用 Windows 默认右键菜单行为。
- 新增 CodexRemote-fix 产品图标、开始菜单入口和桌面快捷方式。
- 保留双语托盘控制：跟随系统、中文、English。
- 加固中断会话恢复流程，保持加密设备密钥不变。
- 已知问题：Codex 更新后，**控制其他设备** 下的已授权设备列表可能为空；profile enrollment 映射修复正在单独开发。

## Future releases

Each new tag should append one short `vX.Y.Z` section with matching English and Chinese bullets.
