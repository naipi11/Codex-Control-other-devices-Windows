# CodexRemote-fix release notes

This file keeps the short bilingual summary for every published release.

## Unreleased

### English

- Replaced generated UI mockups in the README with redacted captures from the real Codex Connections page and Windows tray menu.
- Added an AI-designed exhibition frame and before/after animation built only from those real captures.
- Added a one-shot post-injection refresh for the existing remote-control enrollment catalog.

### 简体中文

- 将 README 中的生成式 UI 示意图替换为真实 Codex“连接”页面和 Windows 托盘菜单的脱敏截图。
- 新增 AI 科技感展览外框与前后对照动图；动图面板全部来自真实截图。
- 新增注入完成后的一次远程控制授权设备目录刷新。

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
