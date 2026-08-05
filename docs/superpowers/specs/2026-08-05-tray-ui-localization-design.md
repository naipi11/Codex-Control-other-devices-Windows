# 托盘 UI 与中英文本地化设计

状态：视觉方向和语言策略已由用户确认，等待书面规格复核

日期：2026-08-05

目标平台：Windows 11、Windows PowerShell 5.1、当前用户交互会话

功能分支：`codex/persistent-tray-supervisor`

## 背景

现有托盘 UI 使用四种纯色实心圆作为状态图标。右键菜单把状态、Codex 包版本、运行时版本和六个命令平铺在同一层，既没有视觉层级，也会长期显示当前状态下无意义的禁用操作。菜单文案仅有英文，不适合作为面向全球用户的开源项目界面。

本设计只改进托盘守护程序的用户界面和非安全语言偏好，不改变会话接管、包兼容分类、恢复事务、设备密钥或 DPAPI 行为。

## 已确认的产品决策

- 图标采用方案 A“连接桥”：深色圆角底、白色连接链路、右下角状态点。
- 提供完整的简体中文和英文 UI 资源。
- 默认跟随 Windows UI 语言。
- `语言 / Language` 子菜单允许手动选择“跟随系统”、中文或 English。
- 手动语言选择立即生效并跨重启保存。
- 中文和英文菜单采用相同的信息架构，不出现功能不对等。
- 日志、稳定错误码、状态协议和 JSON 字段保持英文，不随 UI 语言变化。

## 目标

1. 让 16 像素托盘图标具有明确的“设备连接桥”含义，并保留灰、绿、黄、红四种状态。
2. 把菜单改为状态、常用操作、偏好、诊断和危险操作的清晰分组。
3. 隐藏当前上下文无意义的操作，避免一串禁用灰色菜单项。
4. 为全部托盘提示、菜单、子菜单和确认对话框提供中英文资源。
5. 语言偏好损坏或缺失时只影响显示语言，不得阻塞守护、检查、接管或恢复。
6. 保持现有严格安全状态 schema 不变。

## 非目标

- 本次不加入第三种语言；资源结构必须允许社区以后新增语言。
- 不翻译日志、错误 ID、命令行参数、状态文件字段或机器可读结果。
- 不引入第三方 UI、图标或本地化依赖。
- 不使用自定义无边框窗口替代 Windows 原生托盘菜单。
- 不修改 Codex 安装包或 WindowsApps 内容。

## 视觉设计

### 连接桥图标

图标继续由 `System.Drawing` 在运行时生成，不提交不透明的二进制 `.ico` 资产。基础图形如下：

- 深色圆角方形底：`#20252D`；
- 两段白色链路组成连接桥；
- 右下角状态点带白色描边；
- 生成 16×16 和 32×32 两档缓存；
- 图形按像素网格对齐，并开启适合尺寸的抗锯齿；
- 浅色和深色任务栏上都必须保持可辨识边界。

状态点颜色：

| 状态 | 颜色 | 含义 |
|---|---|---|
| Gray | `#8A9099` | 等待 Codex、检查中或切换中 |
| Green | `#29B36F` | 当前特殊会话已验证 |
| Yellow | `#E3A008` | 当前构建或运行时被抑制，需要用户决定 |
| Red | `#D94A4A` | 已安全恢复普通会话或自动操作被错误阻塞 |

图标主体不随状态改变，只有状态点变化，避免每次状态更新都像换了一个应用。

### 原生菜单原则

生产实现使用原生 `ContextMenuStrip`、`ToolStripMenuItem` 和 `ToolStripSeparator`。视觉稿中的状态胶囊只表达信息层级；生产菜单不引入 owner-draw 或自定义窗口，以避免 DPI、主题、高对比度和资源释放问题。

菜单顶端使用带连接桥图标的粗体标题项和一行只读状态说明。包版本与运行时版本不再占据主菜单；需要排障时通过“打开日志”查看。

## 菜单结构

### 中文

```text
Codex 设备连接 — 运行正常
当前会话已启用“连接其他设备”
────────────────────────
✓ 当前会话已生效                 [只读；Active 时显示]
↻ 立即检查并修复                 [普通会话存在时显示]
↻ 重试上次修复                   [Suppressed/Recovered/Error 时显示]
✓ 自动修复新会话                 [开关]
✓ 允许兼容更新试运行             [独立开关]
────────────────────────
语言 / Language                 >
    ● 跟随系统（中文）
      中文
      English
打开日志
────────────────────────
卸载守护程序…
```

### English

```text
Codex Device Connection — Working
“Control other devices” is active for this session
──────────────────────────────────────────────
✓ Current session is ready          [read-only; shown when Active]
↻ Check and repair now              [shown when an ordinary session exists]
↻ Retry last repair                 [shown for Suppressed/Recovered/Error]
✓ Repair new sessions automatically [toggle]
✓ Allow compatible update trials    [independent toggle]
──────────────────────────────────────────────
Language / 语言                    >
    ● Follow system (English)
      中文
      English
Open logs
──────────────────────────────────────────────
Uninstall supervisor…
```

显示规则：

- `Current session is ready` 与 `Check and repair now` 互斥。
- `Retry last repair` 只在确有失败、恢复或抑制状态时出现，不在正常状态显示禁用项。
- 工作进程运行期间，涉及状态变更的项目禁用；语言切换和打开日志保持可用。
- 自动修复与兼容更新授权保持两个互不联动的复选项。
- `语言 / Language` 的顶层标签固定双语，确保用户即使误切语言也能找到切换入口。
- `卸载守护程序…` 使用省略号，表示点击后还有确认步骤。

## 本地化架构

### 资源文件

新增经过 runtime manifest 校验的 UTF-8 JSON 资源：

```text
src/persistence/resources/
├── ui.en-US.json
└── ui.zh-CN.json
```

每个资源文件使用相同的 schema：

```json
{
  "schemaVersion": 1,
  "locale": "en-US",
  "strings": {
    "Tray.Title": "Codex Device Connection"
  }
}
```

要求：

- 两个文件的资源键集合必须完全一致；
- 顶层字段、顺序、类型和 locale 必须严格验证；
- 所有字符串必须非空、无控制字符并满足 WinForms 文本长度上限；
- 未知资源键不得静默返回键名；
- 中文资源缺项时只允许回退英文资源；
- 英文资源本身不可用时使用代码内最小紧急英文文案并记录稳定错误码。

新增独立的 `UiLocalization.psm1`，负责加载和验证资源、解析有效语言、格式化 UI 文案。`TrayUi.psm1` 只消费已经验证的资源目录，不自行判断 Windows 语言。

### 语言解析

持久偏好枚举固定为：

- `System`
- `zh-CN`
- `en-US`

解析顺序：

1. 显式 `zh-CN` 或 `en-US` 优先；
2. `System` 使用当前 Windows UI culture；
3. 所有 `zh-*` culture 在当前两语言版本中映射到 `zh-CN`；
4. 其他 culture 映射到 `en-US`；
5. 任何解析异常回退 `en-US`，但不得改变安全状态。

切换语言后重新应用菜单文本、可见性、选中项和 tooltip，不重启 Supervisor，不重启或接管 Codex。

## 非安全语言偏好存储

语言偏好不得加入现有 `settings.json`。该文件承载自动接管授权、兼容更新授权和安装器验证的 Node 路径，是严格安全状态；把 UI 偏好加入其中会扩大 schema 迁移和 `StateDamaged` 风险。

新增：

```text
%LOCALAPPDATA%\CodexControlOtherDevices\state\ui-preferences.json
```

schema 1：

```json
{
  "schemaVersion": 1,
  "languageMode": "System",
  "updatedAtUtc": "2026-08-05T00:00:00.0000000Z"
}
```

规则：

- 安装器首次安装时写入 `System`；
- 升级保留已有合法偏好；
- 通过现有受控路径和原子 JSON 写入设施保存；
- 路径必须位于 state 根目录且不得经过 reparse point；
- 文件缺失、损坏、未知 schema 或非法枚举时，在内存中回退 `System`；
- UI 偏好错误记录固定、无敏感信息的诊断码，但不设置 `StateDamageBlocksActions`；
- 用户下一次选择语言时可用合法内容原子替换损坏偏好；
- 卸载时随 state 目录删除。

## 组件与数据流

1. Supervisor 完成 runtime manifest 和安全状态初始化。
2. 本地化模块读取 `ui-preferences.json`，解析有效 locale 并加载两套已验证资源。
3. Supervisor 把有效资源目录和当前语言模式交给 Tray UI。
4. Tray UI 创建连接桥图标缓存、原生菜单结构和语言子菜单。
5. 每次 reconciliation 只传递机器状态；本地化模块把状态映射为当前语言文案。
6. 用户选择语言时，Tray UI 入队严格的 `SetUiLanguage` 命令，值只能是三个固定枚举之一。
7. Supervisor 原子写入 UI 偏好，重新解析资源并立即刷新菜单。
8. 语言切换失败时保留上一套已验证文案，不影响控制器和 Codex 会话。

## 卸载菜单语义

现有 `Uninstall` 托盘命令不得继续作为无操作占位符。新行为：

1. 显示当前语言的确认对话框，明确会停止守护程序，并在特殊会话下恢复普通 Codex；
2. 用户取消时不入队、不写状态、不启动进程；
3. 用户确认后只解析活动 runtime manifest 已验证的卸载脚本绝对路径；
4. 以当前普通用户权限启动卸载脚本，并传入明确的安装根路径；
5. 启动失败时显示本地化错误并保留当前守护程序；
6. 不在命令字符串中拼接用户输入，不引入管理员权限。

## 错误处理与安全边界

- 本地化错误永远不能授权、停止、启动或接管 Codex。
- 资源目录和偏好数据不得进入控制器请求或状态协议。
- UI 显示文本不写入安全日志；日志继续使用稳定英文 action、stage 和 error code。
- 所有新增回调继续遵守当前队列上限、STA 线程归属和无输出回调约束。
- 资源、菜单项、图标和对话框对象必须沿用现有确切所有权和释放模型。
- 偏好写入失败时保留上一语言并显示无敏感信息的本地化错误。

## 测试设计

### 本地化模块

- 中英文资源键、顺序和类型完全一致；
- `System` 对中文及非中文 Windows culture 的映射；
- 三个显式偏好的优先级；
- 缺失、损坏、重复键、未知 schema、非法枚举和控制字符拒绝；
- 中文缺项回退英文，英文不可用时回退紧急英文；
- 偏好原子写入、路径 containment 和 reparse point 拒绝；
- UI 偏好损坏不改变任何安全状态开关。

### Tray UI

- 连接桥图标生成 16 和 32 像素、四种状态共八个缓存，并逐一释放；
- 菜单分隔符、项目顺序和上下文可见性；
- 中文与英文全部文案、tooltip、确认对话框和语言单选状态；
- 语言切换即时刷新且不重新分配无关控制器状态；
- 取消卸载不入队，确认卸载只入队一次；
- 高 DPI、浅色/深色任务栏和 Windows 高对比度人工检查。

### Supervisor 与安装生命周期

- `SetUiLanguage` 命令严格拒绝未知值、错误大小写和非字符串值；
- 偏好写入失败时保持旧 locale；
- 资源文件和本地化模块进入 runtime manifest；
- 首次安装创建 `System`，升级保留合法偏好；
- 旧安装缺少偏好文件时无损回退并可在首次选择后创建；
- 托盘卸载只启动 manifest 验证过的脚本；
- 全部现有持久化、runtime 和 clean-room 自测继续通过。

## 文档

- `README.md` 使用中文菜单截图和中文说明；
- `README.en.md` 使用英文菜单截图和英文说明；
- 两份 README 都说明默认跟随系统、手动切换路径和日志保持英文；
- `docs/TECHNICAL.md` 记录资源 schema、语言解析和非安全偏好边界；
- 不把浏览器 mockup 或 `.superpowers/brainstorm` 临时文件提交到仓库。

## 验收标准

1. 托盘显示连接桥图标，16 像素下可辨认，状态点颜色与会话状态一致。
2. 中文 Windows 首次显示中文；其他 Windows 语言首次显示英文。
3. `语言 / Language` 可切换 System、中文和 English，立即生效并在 Supervisor 重启后保留。
4. 正常状态不显示无意义的 `Manual retry`；失败状态提供明确的重试入口。
5. 主菜单不再平铺包版本和 runtime ID，操作按分隔符分组。
6. 中英文资源键完全一致，所有托盘 UI 和确认对话框均有两套文案。
7. 损坏的 UI 偏好只导致语言回退，不阻塞现有自动修复或安全恢复。
8. 自动修复与兼容更新授权仍然独立，语言切换不修改二者。
9. 卸载入口具有本地化确认，取消无副作用，确认后进入现有安全卸载流程。
10. 全部自动测试通过，并在真实中文 Windows 上完成两种语言和四种图标状态的人工验收。
