# Codex Control other devices 持久托盘守护程序设计

状态：设计内容已逐段确认，等待书面规格审阅

日期：2026-08-02

目标平台：Windows 11、Microsoft Store/MSIX 版 OpenAI Codex、当前交互用户

## 背景

当前项目通过一次性的特殊启动解决 Windows Codex 缺少“连接其他设备”入口的问题。启动器先检查已安装包，再以随机回环 CDP 端口和短时 Node Inspector 启动 Codex，向主进程与 renderer 注入 clean-room bridge。修复只存在于该 Codex 进程中；普通启动、崩溃重启、Windows 重启或 Codex 更新后的新进程都不会继承修复。

普通 Codex 顶层进程不带 `--remote-debugging-port` 或 `--inspect`，也没有可发现的 TCP 调试端点。因此外部程序不能在普通进程启动后直接完成现有注入。持久化方案必须检测普通启动，先做兼容性验证，再自动关闭并特殊重开一次。

本设计将现有会话修复扩展为当前用户范围的计划任务与托盘守护程序。它不修改、重打包或替换 Codex MSIX 文件，也不使用管理员服务、IFEO 或永久 WMI consumer。

## 已确认的产品决策

- 用户接受普通 Codex 启动后自动关闭并重开一次。
- 证据不完整或不兼容的 `UnknownOrIncompatible` 包，以及出现原生模块的 `NativeModulePresent` 包，必须失败关闭并保留普通 Codex，禁止盲目注入。
- 用户预先授权首次出现但全部静态证据完整满足的 `CandidateCompatible` 包执行一次受控动态确认；这项授权是兼容更新自动生效的前提，不等于信任任意新版本。
- 安装副本位于 `%LOCALAPPDATA%\CodexControlOtherDevices`，运行不依赖 Git checkout。
- 使用当前用户、普通权限的登录计划任务。
- 提供常驻托盘图标以及状态、重试、暂停、恢复、日志和卸载入口。
- 卸载默认保留 DPAPI 设备密钥；本地操作不得冒充服务器撤权。

## 目标

1. Windows 登录后自动启动守护程序。
2. 用户通过开始菜单、任务栏、协议或其他正常入口启动 Codex 时，自动应用修复。
3. 兼容的 Codex 更新、崩溃重启和更新自重启无需重新运行项目。
4. 单次失败后恢复一个普通实例，绝不形成重启循环。
5. 保持现有随机回环端口、主 Inspector 关闭验证、renderer 探针、DPAPI 存储及 clean-room 边界。
6. 支持无管理员权限的安装、升级、暂停、恢复和完整卸载。

## 非目标

- 不保证任意未来 Codex 版本都兼容；无法取得完整兼容证据的版本必须安全降级。
- 不修改 Codex 账号、MFA、令牌、工作区策略或服务器端设备授权。
- 不自动执行 `git pull`，不从网络下载并直接运行未验证代码。
- 不隐藏 renderer CDP 的同用户风险，也不创建网络或防火墙例外。
- 正常状态下不在用户主动退出 Codex 后擅自重新打开应用；唯一例外是已提交 `StopRequested` 后控制器同时崩溃、无法区分用户退出与控制器停止的保守恢复窗口，详见“中断事务恢复”。
- 不支持同一 Windows 账号同时运行多个交互会话；守护程序只控制其启动所在的 Windows Session，其他 Session 的进程保持普通状态。

## 总体架构

### 1. 稳定引导器

计划任务固定执行：

`%LOCALAPPDATA%\CodexControlOtherDevices\bootstrap.ps1`

引导器只承担以下职责：

1. 读取并严格验证 `active.json`；其中只允许带 schema 版本的当前/上一 `runtime-id`，拒绝绝对路径、目录穿越和 reparse point。
2. 解析当前版本化运行目录。
3. 对照该目录的 `manifest.json` 校验所需文件大小和 SHA-256。
4. 使用一次性随机 ready token 启动托盘守护程序，并在 15 秒内等待其完成互斥锁、状态读取、托盘和进程监视初始化。
5. 作为计划任务所跟踪的父进程持续等待守护程序；守护程序异常退出时返回非零状态，以便计划任务执行有限重启。
6. 当前运行时在 ready 前失败时，仅尝试一次已验证的上一运行时；上一运行时 ready 后再原子回写 `active.json`。两者都失败则记录 bootstrap 日志并退出，不修改 Codex 进程。

引导器不包含注入逻辑，以便保持小型、稳定和易审计。守护程序主动退出返回零状态，避免卸载或用户退出时被任务重新拉起。

### 2. 版本化运行目录

安装布局：

```text
%LOCALAPPDATA%\CodexControlOtherDevices\
├── bootstrap.ps1
├── active.json
├── runtime\
│   └── <runtime-id>\
│       ├── manifest.json
│       ├── Supervisor.ps1
│       ├── SessionController.ps1
│       ├── Test-CodexControlOtherDevices.ps1
│       └── src\runtime\...
├── state\
│   ├── settings.json
│   ├── status.json
│   ├── verified-packages.json
│   └── transition.json
└── logs\
```

`runtime-id` 由项目版本和运行内容哈希组成。安装器先将完整版本复制到新目录，生成并复核清单，再通过同卷临时文件替换 `active.json`。`active.json` 同时记录 `activeRuntime` 和 `previousRuntime`。失败时旧版本仍保持激活；成功切换后至少保留一个上一版本用于回退。

文件契约固定如下：

- `runtime-id` 只允许 1–96 个 ASCII 字母、数字、点、下划线或连字符。
- `active.json` schema 1 只包含 `schemaVersion`、`activeRuntime`、`previousRuntime` 和 `updatedAtUtc`；`previousRuntime` 在首次安装时可为 `null`。
- `manifest.json` schema 1 包含 `runtimeId`、项目版本、生成时间和按相对路径排序的 `files`；每项必须有唯一规范化相对路径、字节长度和小写 SHA-256。
- 清单不得包含自身、绝对路径、空路径、重复路径、目录穿越、symlink 或 reparse point。bootstrap 只执行清单中已验证且位于所选 runtime 根内的文件。

`manifest.json` 的哈希用于发现复制不完整、磁盘损坏和意外修改，不构成对当前用户恶意篡改的代码签名。安装源可信度仍由用户选择的本地 checkout 和 Git 审查保证。

安装、引导和卸载都先规范化目标路径，并确认其位于 `%LOCALAPPDATA%\CodexControlOtherDevices` 内且路径链没有 reparse point；任何越界或重解析路径都失败关闭。运行目录、状态和日志 ACL 允许当前用户、SYSTEM 和本机管理员访问，不授予其他普通用户写权限。

### 3. 登录计划任务

任务名称固定为 `Codex Control Other Devices Supervisor`，配置如下：

- principal 使用安装用户 SID、`LogonType=InteractiveToken` 的交互式登录触发器；
- `RunLevel=Limited`，不请求管理员权限；
- `MultipleInstances=IgnoreNew`；
- 异常失败后每隔 1 分钟重启，最多重试 3 次；
- 不因电池模式停止；
- 无 72 小时执行上限；
- 操作目标始终为稳定引导器的绝对路径；
- 不保存其他账号密码。

任务设置显式使用 `ExecutionTimeLimit=PT0S`、`DisallowStartIfOnBatteries=false` 和 `StopIfGoingOnBatteries=false`。任务 action 固定使用 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`，参数为 `-NoProfile -ExecutionPolicy Bypass -STA -File <bootstrap>`，工作目录为稳定安装根。安装器创建或更新任务。卸载器先禁用并删除任务，再停止守护程序。

### 4. 托盘守护程序

守护程序使用 Windows PowerShell 5.1 与内置 WinForms/Management API，不引入新的第三方 UI 依赖。它持有当前用户 SID 和 Windows Session ID 派生的命名互斥锁，保证目标 Session 内单实例。对象名格式为 `Local\CodexControlOtherDevices.<Kind>.<SID>.<SessionId>`，`Kind` 至少包括 `Supervisor`、`Transition` 和 `Shutdown`；ACL 仅允许当前用户、SYSTEM 和本机管理员。ready 对象另加 bootstrap 生成的随机 token，禁止复用旧 ready 信号。任务已在另一个同账号 Session 运行时，新 Session 不接管 Codex。

现有 JavaScript 检查器与注入 orchestrator 仍要求 Node 22 或更高版本。安装器只把安装当次发现并通过版本/能力验证的 `node.exe` 规范化绝对路径写入 `nodeCandidates`；守护程序不依赖计划任务继承的 `PATH`，也不自行增加候选。全部已验证候选失效时保留普通 Codex并在托盘报告依赖错误，用户需重新运行安装器发现新路径。

进程检测采用能力降级链，事件只负责降低延迟，reconciliation 才是权威来源：

- 优先尝试临时 `Win32_ProcessStartTrace` 订阅；
- 当前 token 若被 WMI 拒绝，则降级为临时 `__InstanceCreationEvent WITHIN 1` 进程订阅；
- 两种事件订阅都不可用时仅记录能力状态，不提权、不修改 WMI ACL；
- 每 3 秒一次的进程 reconciliation，用于覆盖登录竞争、休眠恢复和漏失事件。

检测结果进入串行队列。重型会话切换由独立的隐藏 PowerShell 子进程执行，托盘 UI 保持响应。跨线程 UI 更新统一回到 WinForms 消息线程。

`settings.json`、`status.json`、`verified-packages.json` 和 `transition.json` 都带 schema 版本，并通过同目录临时文件原子替换。无法解析的状态不得被当成成功证据；守护程序将其隔离、记录错误并从实时进程状态重新 reconciliation。

- `settings.json` schema 1 保存 `automationEnabled`、独立的 `candidateCompatibleOptIn`、安装器当次逐一验证过的 `nodeCandidates` 绝对路径数组和更新时间。守护程序不得从计划任务继承的 `PATH` 增加新候选；候选全部失效时必须由用户重新运行安装器。
- `status.json` schema 1 保存 supervisor PID/创建时间/Session ID、runtime ID、会话状态，以及可选的 Codex PID/创建时间/包身份/端口/探针结果。
- `verified-packages.json` schema 1 以包全名、`app.asar` 哈希和 runtime ID 的组合键保存静态与动态确认结果；它只是缓存，实时身份和会话探针仍是权威。
- 遇到未知 schema 版本时失败关闭；不得静默改写为当前 schema。

安装器必须在首次启动任务前原子创建全部状态文件，因此守护程序运行时的“缺失”与“损坏”同样处理，不能当作首次安装。安全默认值逐文件固定为：

- `settings.json` 缺失/损坏：`automationEnabled=false`，不接管新进程；
- `verified-packages.json` 缺失/损坏：禁止 `CandidateCompatible` 自动试验，避免遗失历史失败后再次注入；
- `transition.json` schema 1 始终存在，以 `activeTransaction=null` 表示没有活动事务；文件缺失、损坏或字段非法时禁止任何停止、启动或恢复动作，并关闭自动化；
- `status.json` 缺失/损坏：只允许通过完整实时身份和探针重建，重建完成前不接管普通实例。

损坏文件先以时间戳名称隔离并保留证据。恢复必须由用户显式运行安装器的 `-RepairState`：它重新创建 schema 1 状态，并将 `automationEnabled`、`candidateCompatibleOptIn` 都保持为 `false`；随后用户需在托盘中分别恢复自动化和受控兼容更新授权。

日志采用固定上限轮转：每个日志文件最多 2 MiB，每类最多保留 10 个历史文件。轮转失败不得阻断失败恢复，也不得退化为无限增长。

托盘状态：

- 灰色：等待 Codex，或自动化已暂停且当前没有特殊会话；
- 绿色：当前 Codex 已通过修复验证；即使此时暂停后续自动化，也保持绿色并在图标 overlay/tooltip 标明“当前会话已修复，后续自动化已暂停”；
- 黄色：版本不兼容、检测到原生模块或版本被抑制；
- 红色：接管失败且已恢复普通 Codex。

菜单包含：当前状态、Codex 包版本、运行时版本、立即应用、手动重试、暂停/恢复自动化、允许/禁止受控兼容更新验证、打开日志、卸载。兼容更新授权与自动化开关相互独立，切换其中一个不得隐式改变另一个。暂停不会关闭当前 Codex；恢复后在下一次正常启动时生效。“立即应用”只接管一个已经运行的普通 Codex，不在 Codex 未运行时主动打开它。“手动重试”清除当前包与运行时组合的动态抑制；对静态不兼容只重新执行检查，绝不绕过失败条件。若普通 Codex 正在运行则排队尝试一次，否则等待用户下次正常启动。

### 5. 会话控制器

会话控制器复用并重构现有 `Start-CodexControlOtherDevices.ps1` 的功能，保持手动启动脚本兼容。控制器提供机器可读结果，托盘程序不解析面向用户的文本。

控制器每次执行均重新：

1. 解析 `Get-AppxPackage OpenAI.Codex`；
2. 获取当前包全名、包族、版本、安装路径和入口；
3. 运行包哨兵、原生模块和 Node 能力预检；
4. 分配两个不同的随机 `127.0.0.1` 端口；
5. 仅停止已验证属于目标包族的 Codex 顶层进程及其进程树；
6. 以 renderer CDP 和主 Inspector 参数启动新实例；
7. 安装 main bridge，要求主 Inspector 达到明确 `ECONNREFUSED`；
8. 向当前及随后创建或导航到精确 `app://-/index.html` 的 renderer 文档安装 bridge，并要求非空 Statsig 探针成功；
9. 返回会话 PID、端口、包版本、探针和日志位置。

现有 main/renderer payload、设备密钥协议和 DPAPI 存储格式不变。

## 进程识别规则

只有同时满足以下条件的进程才可进入接管判断：

- 运行在当前交互用户与会话中；
- 映像名称为 `ChatGPT.exe`；
- 是不含 `--type=` 的顶层 Electron 进程；
- 包族为 `OpenAI.Codex_2p2nqsd0c76g0`；
- 映像路径与本次动态解析的 Codex MSIX 入口一致。

特殊实例还必须满足：

- 命令行含预期的回环调试参数；
- `status.json` 中 PID、进程创建时间、包版本和 renderer 端口一致；
- renderer 端点返回精确 `app://-/index.html` 目标并通过 bridge 探针。

父 PID 或“曾尝试启动”记录不能单独证明修复有效。

## 运行状态机

主要会话状态：`Waiting`、`Inspecting`、`Transitioning`、`Active`、`Suppressed`、`Recovered` 和 `Error`。`settings.json` 中的 `automationEnabled` 是与会话状态正交的持久开关，因此当前会话可以同时是 `Active` 且后续自动化已暂停。

### 启动与 reconciliation

- 无 Codex：进入 `Waiting`，不主动启动应用。
- 已验证的特殊实例：进入 `Active`，不重复接管。
- 普通实例且自动化开启：排队进入 `Inspecting`。
- 普通实例且 `automationEnabled=false` 或当前包已抑制：保持普通运行。

### 普通实例接管

1. 获取按当前用户 SID 和 Windows Session ID 派生的 transition 互斥锁。
2. 再次确认目标 PID、创建时间、包身份和普通启动状态，防止使用陈旧事件。
3. 完成静态预检后，立即再次确认同一 PID、创建时间、包身份仍存活且仍是普通实例；目标已经自然退出则取消转换，不启动任何 Codex。
4. 写入 transition intent，包含事务 ID、PID、创建时间、包全名/哈希、运行时 ID、阶段和时间戳。
5. 通过返回明确结果的 compare-and-stop 操作停止该精确进程；只有操作确认 `StoppedByController=true` 才允许特殊启动，目标在操作前自然退出则取消转换。
6. 以特殊参数启动并验证 main/renderer；全部成功后写入 `status.json` 与已验证包记录，进入 `Active`。

同一 PID 和创建时间组合最多自动尝试一次。

### 用户退出、崩溃和更新

- 用户退出后进入 `Waiting`，守护程序不会重开 Codex。
- 用户下次普通启动时，在自动化开启且版本未被抑制的前提下重新接管。
- 崩溃或更新触发的新普通进程按新 PID、新创建时间和新包版本重新判断。
- 每次更新都重新解析 WindowsApps 路径，长期状态中不得保存可执行文件路径作为可信身份。

### 中断事务恢复

`transition.json` 顶层固定为 `schemaVersion` 和可为空的 `activeTransaction`。活动事务的固定字段为 `transactionId`、`stage`、源 PID/创建时间、包全名/包哈希、运行时 ID、两个端口、特殊/恢复 PID 与创建时间，以及创建/更新时间。每次阶段变化都先通过同目录临时文件原子提交，再开始下一项外部动作。阶段依次为 `IntentWritten`、`StopRequested`、`OrdinaryStopped`、`SpecialLaunchRequested`、`SpecialStarted`、`Validated`、`RecoveryLaunchRequested` 和 `Recovered`。

守护程序或控制器意外退出后，新守护程序必须先回放未完成事务，再处理新的进程事件：

- `IntentWritten` 且普通进程仍在时，保留实时普通实例并结束该事务；
- `StopRequested` 时在已打开的精确进程句柄上观察最多 5 秒；观察到退出则不尝试特殊启动并执行一次普通恢复，5 秒后仍为同一存活进程才取消事务。取消后继续对该精确 PID 保留 5 秒守卫，守卫期内延迟退出且没有新实例时执行一次普通恢复；
- `OrdinaryStopped` 或 `SpecialLaunchRequested` 时，先按当前 Session、精确包入口、事务端口和事务时间窗查找唯一特殊顶层进程。找到后验证并收养；找不到或验证失败则关闭可确认的调试端点并恢复普通实例，不在回放期间重新尝试特殊启动；
- `SpecialStarted` 时验证 journal 中的 PID/创建时间；PID 尚未提交但存在唯一符合事务端口和时间窗的特殊进程时允许收养，多个候选则失败关闭并进入普通恢复；
- 实时特殊实例已完整通过探针时，可补写 `Validated` 后进入 `Active`；
- `RecoveryLaunchRequested` 时先观察最多 5 秒；只要当前 Session 出现精确包身份的普通顶层进程就收养而不重复启动。观察期内始终没有普通实例时，才在 transition 锁内启动一个并立即提交 PID/创建时间；
- 无法证明安全恢复时，不接管新实例，记录错误并抑制该包与运行时组合。

事务终态会归档到日志，并通过原子写将 `activeTransaction` 设回 `null`。恢复动作仍受 transition 互斥锁约束，最多执行一次。极端情况下，用户恰好在已提交 `StopRequested` 后主动退出且控制器同时崩溃，恢复逻辑会优先恢复一个普通实例；这是避免控制器可能已经关闭 Codex却永久不恢复所必需的保守选择，日志必须明确记录该场景。

### 去重、忽略与抑制键

- 尝试去重键：`sourcePid + sourceCreationTime`，只在该进程生命周期内有效，防止重复事件再次接管。
- 恢复忽略键：`recoveryPid + recoveryCreationTime + transactionId`，在该恢复进程退出或事务归档后失效，防止恢复实例立刻被事件监听器接管。
- 兼容性抑制键：`packageFullName + appAsarSha256 + runtimeId`，动态失败后跨进程持续有效，只由手动重试或不同 runtime ID 清除。
- 静态不兼容键：`packageFullName + appAsarSha256`，在包内容变化前持续有效；手动重试只能重新执行静态检查，不能绕过失败条件。

## 更新与版本验证

每个包构建先执行静态分类。这里的术语固定如下：

- 已出现 Windows 原生设备密钥模块：分类为 `NativeModulePresent`，不注入并保留普通 Codex；托盘只显示“检测到原生模块，兼容桥已停用”，不能据此宣称标签、gate 或签名流程已经由官方完整支持；
- 四个行为哨兵、Node 环境或包身份不满足，或证据无法完整取得：分类为 `UnknownOrIncompatible`，不停止普通实例并抑制该包版本；
- 首次出现但所有静态证据完整满足：分类为 `CandidateCompatible`，不是“未知”状态；允许一次受控接管，用运行时探针完成动态确认；
- 同一包哈希和运行时 ID 已有成功动态记录：分类为 `VerifiedCompatible`，仍需在每个新进程上运行会话探针。

动态确认成功后记录：

- Package Full Name、Package Family Name 和版本；
- `app.asar` SHA-256；
- 哨兵和原生模块结果；
- 运行时 ID、main/renderer 探针结果和确认时间。

动态确认失败或未完成事务需要普通恢复后，写入 `packageFullName + appAsarSha256 + runtimeId` 兼容性抑制键。抑制期间后续普通启动均保持普通状态；只有项目运行时升级或用户显式“手动重试”才清除对应抑制。系统不自动 `git pull`。

## 失败恢复与防循环

### 停止普通 Codex 前失败

保留普通进程，记录错误，进入 `Suppressed` 或 `Error`。不执行恢复启动，因为用户实例未被中断。

### 停止普通 Codex后失败

1. 停止本次特殊实例及其目标进程树；
2. 确认分配的主 Inspector 和 renderer 端口不再监听；
3. 只启动一个不带调试参数的普通 Codex；
4. 记录恢复进程 PID、创建时间、失败阶段和抑制键；
5. 守护程序忽略该恢复实例以及抑制仍有效时的后续普通实例，直到用户手动重试或项目运行时升级。

任何事件回调、计划任务重复启动或托盘命令都必须经过 supervisor 与 transition 两级互斥。失败恢复不得由事件监听器再次自动接管。

## 安装、升级与卸载

### 安装

`Install-CodexControlOtherDevices.ps1`：

- 支持 `ShouldProcess`；
- 验证源仓库、PowerShell/JavaScript 语法和 clean-room 自测；
- 生成版本化清单并复制到新运行目录；
- 复核所有哈希后切换 `active.json`；
- 注册登录计划任务并启动它；
- 已有普通 Codex 时由守护程序按正常状态机处理。

### 升级

安装器不会就地覆盖活动运行时。新版本验证后原子切换，然后通过命名退出事件让旧守护程序正常退出，并重新启动计划任务；当前已验证的特殊 Codex 不被重启，新守护程序通过 reconciliation 接管其监视。新 supervisor 无法在 15 秒 ready 超时内完成初始化时，bootstrap 按“稳定引导器”一节的规则回退上一个已验证运行时并记录错误。bootstrap 自身也通过临时文件、复核和替换更新，并保留一个可恢复副本。

### 卸载

`Uninstall-CodexControlOtherDevices.ps1`：

1. 暂停自动化并取得 transition 互斥锁；
2. 普通 Codex 保持运行；当前为特殊实例时，默认停止该精确进程树、确认 main/renderer 端口关闭并恢复一个普通实例；
3. 删除计划任务，通过当前用户命名事件请求守护程序退出；
4. 超时后只终止已验证的守护程序 PID；
5. 删除 bootstrap、运行目录、状态和日志；
6. 默认保留现有 bridge 解析出的设备密钥文件：显式设置 `CODEX_HOME` 时位于该目录，否则默认为 `%USERPROFILE%\.codex\remote-control-device-keys.windows.json`；
7. 只有显式参数才备份或删除本地密钥，并明确提示服务器授权仍需在 Codex 中撤销。

只有显式 `-KeepCurrentSpecialSession` 才允许卸载后保留当前特殊实例。交互式命令和托盘入口必须再次确认，并显示 renderer CDP 将继续开放且不再有托盘监视的警告；在非交互模式中，该显式参数本身视为确认，未提供时一律恢复普通会话。

## 安全模型

- 不写入 Codex 安装包或 WindowsApps。
- 不创建管理员服务、IFEO、永久 WMI consumer、防火墙规则或非回环监听。
- main Inspector 暴露窗口保持最短，并要求关闭验证。
- renderer CDP 在特殊会话期间持续存在，托盘必须反映其状态；同用户恶意进程仍在威胁边界内。
- 所有端口随机选择并仅绑定 IPv4 loopback。
- 状态与日志严禁记录私钥、令牌、签名载荷或账号凭据。
- 守护程序不处理 MFA、SSO、登录和服务器撤权。
- 包身份、进程创建时间、PID 和探针必须组合验证，避免 PID 复用或同名进程误判。

## 测试设计

测试不新增第三方依赖。

### 单元测试

- 顶层/子进程、普通/特殊实例和包族分类；
- 状态机合法与非法转换；
- 同 PID 去重、恢复忽略、抑制和手动重试；
- supervisor 与 transition 互斥；
- runtime manifest、文件哈希和 `active.json` 原子切换；
- ready token、父进程退出码、版本回退与损坏运行目录拒绝；
- 托盘命令映射到状态操作，不直接测试像素布局。

### 模拟集成测试

通过可替换的包解析器、进程控制器和会话启动器模拟：

- Windows 登录时 Codex 已经运行；
- 普通启动后只重开一次；
- 兼容更新、自重启和崩溃重启；
- `UnknownOrIncompatible`、`NativeModulePresent` 和静态预检失败；
- main 或 renderer 注入失败后的单次普通恢复；
- 事件重复、任务重复与启动/退出竞争；
- 控制器在停止普通实例后崩溃，随后由 transition journal 单次恢复；
- 预检期间用户退出，以及 compare-and-stop 前目标自然退出；
- 每个 transition 阶段突然终止、延迟停止、外部启动成功但 PID 尚未提交、状态文件截断和重复恢复；
- 各状态文件缺失/损坏后的安全默认值，以及 `-RepairState` 后仍保持自动化关闭；
- `active.json` 路径逃逸、reparse point 与 manifest 篡改；
- 计划任务环境没有 Node `PATH`，但保存的绝对 Node 路径有效或失效；
- `Win32_ProcessStartTrace` 拒绝后降级到 `__InstanceCreationEvent`，以及所有 WMI 订阅失效后由 3 秒 reconciliation 补获进程；
- 其他用户/Session 进程忽略、日志轮转和磁盘上限；
- 暂停、恢复、手动重试，以及卸载默认恢复普通会话/显式保留特殊会话。

### 实机验收

1. 当前 Node 运行 `npm test` 通过，现有 12 项 clean-room 自测保持通过。
2. 当前已安装 Codex 包预检通过。
3. 安装后计划任务配置符合最小权限和长期运行要求，托盘图标出现。
4. 从开始菜单普通启动 Codex，最多自动重开一次，main Inspector 关闭且 renderer 探针通过。
5. 再次退出并启动 Codex，自动化重复生效。
6. 暂停后普通启动不被接管，恢复后下次启动生效。
7. 使用测试替身证明 `UnknownOrIncompatible` 不会停止普通 Codex，`CandidateCompatible` 只尝试一次，且两者都不会循环重试。
8. 卸载默认将特殊会话恢复为普通会话并确认调试端口关闭；随后无计划任务、守护进程、bootstrap 或 runtime 残留，设备密钥保持不变。

涉及 Windows 登录和 Store 实际更新的最终确认需在真实登录/更新周期观察；自动化测试提供等价状态模拟，但不得把模拟结果写成已完成的实机更新验证。

## 文档与交付

- 同步更新 `README.md`、`README.en.md`、`docs/TECHNICAL.md`、`docs/CLEANROOM.md` 和 `SECURITY.md`。
- 手动会话模式继续保留，作为诊断和保守回退入口。
- 当前正式开发 checkout 为 `C:\Users\33384\Documents\Codex-Control-other-devices-Windows`。
- 功能分支为 `codex/persistent-tray-supervisor`。
- 旧日期归档 checkout 保持不变。
- 设计文档独立提交；后续实施计划与代码提交分离，便于审查。

## 验收标准

实现只有在以下条件全部满足时才可称为完成：

1. Windows 登录后托盘守护程序自动出现且单实例运行。
2. 任何普通 Codex 顶层启动最多被自动重开一次，并在成功时提供“连接其他设备”。
3. 兼容更新后不需要重新运行项目；守护程序动态解析新包并重新验证。
4. `UnknownOrIncompatible` 更新保留普通 Codex；`CandidateCompatible` 最多受控尝试一次；两者都不产生重复关闭、重开或后台无限重试。
5. 失败恢复后调试端口关闭，只有一个普通 Codex 实例存活。
6. 暂停、恢复、手动重试、日志和卸载菜单可用。
7. 卸载完整移除持久化组件、默认关闭特殊会话的调试端点并恢复普通 Codex，同时保留 DPAPI 设备密钥。
8. 全部自动测试、当前包预检和实机会话探针通过。
