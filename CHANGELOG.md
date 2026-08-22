# CodexRemote-fix release notes

This file keeps the short bilingual summary for every published release.

## Unreleased

No unreleased changes.

## v2.4.17

### English

- Major fix: authorized remote-control devices now survive Codex updates without re-pairing.
- Restored the preserved enrollment mapping through Codex's host bridge before refreshing remote connections.
- Patched already-cached native device-key addon exports in place so existing Codex consumers use the corrected implementation.
- Kept device keys, server-side authorization, and the normal Codex enrollment flow unchanged.

### 简体中文

- 重大修复：Codex 更新后，已授权的远程控制设备无需重新配对即可保留。
- 在刷新远程连接前，通过 Codex host bridge 恢复保留的 enrollment 映射。
- 原地修补已被缓存的原生设备密钥模块导出对象，使现有 Codex 调用方使用修复后的实现。
- 保持设备密钥、服务器端授权和 Codex 原生注册流程不变。

## v2.4.16

### English

- Fixed a Windows PowerShell redirected-input UTF-8 preamble that could make TrayHost exit before signaling readiness.
- Kept strict protocol validation and limited the compatibility path to one BOM on the initial bootstrap frame only.
- Added Windows GitHub Actions validation for pull requests and pushes to `main`.
- Added a concise before/after showcase image of the real Control other devices tab.

### 简体中文

- 修复 Windows PowerShell 重定向输入中的 UTF-8 前导标记导致 TrayHost 在报告就绪前退出的问题。
- 保持严格协议校验，仅允许初始 bootstrap 帧兼容一个 BOM，不放宽后续认证帧。
- 新增 GitHub Actions Windows CI，检查 Pull Request 和推送到 `main` 的变更。
- 新增真实“控制其他设备”标签的简洁修复前后展示图。

## v2.4.15

### English

- Rebuilt the tray UI as a compiled native Win32 TrayHost with the standard Windows context menu behavior.
- Added the CodexRemote-fix product icon, Start-menu entry, and desktop shortcut.
- Preserved bilingual tray controls: Follow system, 中文, and English.
- Hardened interrupted-session recovery and kept the encrypted device-key store unchanged.

### 简体中文

- 托盘 UI 重构为编译后的原生 Win32 TrayHost，使用 Windows 默认右键菜单行为。
- 新增 CodexRemote-fix 产品图标、开始菜单入口和桌面快捷方式。
- 保留双语托盘控制：跟随系统、中文、English。
- 加固中断会话恢复流程，保持加密设备密钥不变。

## Future releases

Each new tag should append one short `vX.Y.Z` section with matching English and Chinese bullets.
