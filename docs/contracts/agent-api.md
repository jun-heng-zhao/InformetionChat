# Agent API 与插件工具契约 v1.1 草案

状态：设计，尚未实现。API 模式借鉴 [DeepSeek Harness SDK](https://github.com/deepseek-ai/deepseek-harness) 的 profile、持久子进程、stdio JSON-RPC、显式 home/workspace 和结构化运行结果；不宣称协议或 SDK 兼容。应用不绑定模型厂商，模型通过适配器选择。Agent 与 UI、插件共用本地宿主的服务注册表、任务、资源和授权接口。

## 0. 两种运行模式

桌面端提供两个外壳，共用同一个 Agent runtime、会话日志、模型适配器、工具注册表和审批策略：

- 交互模式：用户在 Electron 桌面界面创建会话、输入消息、查看流式输出和处理审批。
- API 模式：本地 SDK 连接现有 Desktop Runtime Supervisor；若不存在，则启动不创建窗口的 headless Supervisor。Supervisor 创建固定版本的 Agent runtime，通过 stdio JSON-RPC 创建或恢复会话、提交一轮任务、接收事件、取消和关闭。

移动端不运行 Agent，也不开放 Agent API。

## 1. API profile 与进程协议

API 模式使用专用 `agent-api` profile。profile 显式选择模型适配器、工具集合、审批策略、持久化和资源预算；不存在“缺配置时退回桌面 profile”的行为。实现时可调整 profile 名称，但必须在协议版本冻结前固定。

SDK 每次启动必须提供绝对的 Agent home 和 workspace。Agent home 保存 profile、会话、工具配置及该 API 实例的数据；API 模式不会静默读取桌面客户端的数据目录。需要隔离凭据、插件工具和会话时使用不同 home，需要开始独立对话时使用新的 session ID。

SDK 延迟连接或启动随桌面包固定版本的 Supervisor，由 Supervisor 在多个 `run` 之间复用 Agent runtime。Agent SDK 与 runtime 的 stdout 只写按行分隔、带大小上限的 JSON-RPC 2.0 帧；日志和诊断只写 stderr。stdin EOF、`shutdown`、SIGINT 和 SIGTERM 都进入有界关闭流程，停止接单、取消任务、flush 会话并退出；超时后由 Supervisor 强制终止。Supervisor 与 Dart Core Host 的长度分帧协议是另一条内部通道，按 [Desktop Core IPC](desktop-core-ipc.md)执行，不与 SDK 的按行协议混用。

初始化握手至少绑定：协议版本、runtime 版本、profile、Agent home、workspace、会话预算、模型适配器/模型及可选推理参数。凭据通过系统安全存储引用、受保护环境或继承管道传递，不写命令行、会话事件或日志。不存在适配器、模型、profile 或工具依赖时，在接收用户任务前失败。

最小控制方法：

| 方法 | 作用 |
|---|---|
| `initialize` | 协商版本并建立 profile、workspace、模型、预算和事件能力 |
| `session.open` | 创建或恢复 session ID；并发所有权冲突时拒绝 |
| `agent.run` | 持久化输入，运行到该会话再次 idle，返回结构化结果 |
| `agent.cancel` | 取消当前轮次及可取消的插件任务，不伪造已发生副作用的回滚 |
| `session.close` | 释放 live 会话句柄，保留已提交日志 |
| `shutdown` | 有界关闭整个 API runtime |

`agent.run` 返回 `sessionId`、`finalResponse`、`finishReason`、本轮根会话事件摘要和通知。`finishReason` 至少区分 `completed`、`cancelled`、`max-tokens` 和 `error`。进度、模型增量、工具状态和审批请求作为带 session/turn/sequence 的 JSON-RPC notification 发送；已提交会话事件是恢复依据，瞬时流不能代替持久结果。

普通 RPC 为一元请求/结果。Agent 输出流、工具进度和通知使用独立事件协议，不能伪装成一个无限期 Remote 返回值。断线后客户端通过 session/turn 状态恢复，不假设所有瞬时增量都能重放。

## 2. 插件可选暴露 AI 工具

插件是否向 AI 暴露操作是可选项。服务只有同时满足以下条件才进入当前 Agent 会话的模型工具表：

1. 插件在服务声明中显式设置 `agentCallable: true`；省略或为 `false` 时不生成模型工具。
2. 服务提供完整 input/output schema、效果列表和稳定说明，且 `requiresUI: false`。
3. 插件已启用、提供者绑定有效、当前 Agent profile 允许该工具。
4. 用户为当前 Agent 会话授权服务、资源、效果和预算。

宿主从服务契约生成具体工具定义，不允许插件通过运行时消息临时增加未声明工具。工具名由宿主稳定命名并映射到绑定的服务提供者；模型不能通过参数选择另一安装。插件说明、网页、文件和聊天内容都按不可信提示数据处理，不能覆盖系统策略、审批或身份。

模型调用插件工具时沿用 `host.service.call`、task 和资源句柄语义。工具执行前后都校验 schema、会话、提供者、资源版本、效果和授权；长任务返回 taskId 并转成 Agent 工具进度，取消沿调用链传播。插件的 output 先校验再进入模型上下文，超限正文保存为受控资源引用。

M1 只把已预授权的本地 `read`/`write` 转换类服务加入工具表。`network`、`send`、`delete`、`install` 和系统命令默认不向 AI 暴露；后续必须接入 prepare/execute、效果预览和可信宿主审批。API 客户端、模型和插件都不能调用“批准自己”的方法。

插件服务运行在用户已信任的 Node.js Extension Host 中，可直接使用系统权限；Agent 工具授权只约束通过宿主工具管线的调用，不把该进程变成沙箱。

## 3. M1 验收目标

M1 实现本地 API profile、授权会话，以及 `host.context.get`、`host.service.discover/describe/call`、`host.binding.get`、`host.resource.list/read`、`host.task.get/cancel` 组成的内部工具执行面。调用沿用 [UI Bridge](plugin-ui-jsonrpc.md) 的参数、资源和错误语义，授权会话由可信宿主界面建立，Agent 不能自批。

最小流程：用户预选一份输入、绑定转换器并允许其作为 Agent 工具 → API client 初始化 profile 并打开会话 → `agent.run` 促使模型调用转换工具 → runtime 查询或取消 task 并读取结果 → 返回结构化 run 结果。结果保存由用户在宿主完成；将来允许 Agent 保存时，须先授予明确的输出目标。M1 不允许 Agent 安装插件、修改绑定或扩大工具表。

首个 SDK 通过 Linux 用户私有 UDS 或 Windows 当前用户 Named Pipe 连接 Supervisor，不监听网络端口。SDK 不直接启动第二个 Core Host；图形桌面已运行时复用现有 Supervisor，不存在时启动 headless Supervisor。凭据不写入命令行、公共配置或日志，断开及宿主重启后重新配对。本机 IPC 只是传输，不能代替 Agent 会话授权。

API 模式不要求 Electron 窗口常驻，但 headless Supervisor 仍使用同一 Electron 主进程代码、Dart Core Host、profile 和插件服务。每个 profile 只有一个 Core Host，并由它串行化工作区写入。交互模式要求桌面窗口运行。可用确定性假模型完成工具协议验收，测试不依赖模型账号或远端服务。`requiresUI: false` 必须由运行时验证，不能只看清单布尔值。

下文保留后续完整接口蓝图；M1 未实现的方法返回 `CAPABILITY_UNAVAILABLE`，发现结果不宣称其可用。

## 4. 接入边界

Agent 必须获得本地用户授予的独立会话，记录工作区、可发现/调用的服务、资源范围、允许的副作用、提供者绑定、有效期和调用预算。该会话不是宿主管理员身份。

传输优先验证 stdio JSON-RPC 和本机 IPC。后续可增加 Python/TypeScript SDK、MCP 或其他适配器，映射到同一 runtime；不能仅监听 localhost 就视为已经授权，也不默认开放 HTTP 或远程监听。外部 API client 不在插件边界内，其能够读取的数据必须由用户明确授权；应用不能控制它在宿主之外的行为。

插件服务只有声明 `agentCallable: true`、具有完整参数/结果 schema、已兼容激活且用户授权后才注册为该会话的模型工具。声明为 true 不等于授权。纯 UI 命令、`requiresUI: true` 服务或未描述副作用的操作不自动转换成 Agent 工具。

## 5. 内部工具接口蓝图（按阶段启用）

下列名称为 Agent runtime 调用 Dart Core Host 的内部工具方法，不是 API client 的控制协议。发现结果仅返回会话范围内可见的信息，未授权能力可以返回可申请的摘要，不泄露数据正文。

| 方法 | 输入/结果要点 |
|---|---|
| `host.context.get` | 当前工作区、平台、API 版本、会话授权和预算；不返回密钥 |
| `host.service.discover` / `describe` / `call` | 按能力与输入类型过滤；返回提供者、接口版本、输入/输出 schema、副作用、是否需 UI、当前可用性 |
| `host.binding.get` / `plan` | 查询默认提供者或生成变更计划；计划不改变授权 |
| `host.resource.list` / `read` | 列出已授权资源，分页/限量读取；返回资源版本和来源 |
| `host.search.query` | 在明确范围内查询，返回结构化引用、摘要、分页和覆盖范围 |
| `host.operation.prepare` | 校验服务、参数、资源版本、提供者和授权，生成 planId 与效果预览 |
| `host.operation.execute` | 执行 planId，携带幂等键；返回 taskId 或标准化结果 |
| `host.task.get` / `list` / `cancel` | 查看进度、结果引用及副作用状态；取消可控子任务 |
| `host.event.subscribe` / `unsubscribe` | 订阅授权范围内的任务与资源变化；断线后查询状态，不承诺事件永不丢失 |
| `host.plugin.list` / `dependency.plan` | 查询本地插件、依赖和兼容原因；不自动下载或启用 |
| `host.access.request` | 申请选定文件、服务连接或额外权限，返回 pending/granted/denied；授权由可信宿主界面完成 |
| `host.trace.get` | 返回该会话调用链及经脱敏的诊断，不能读取其他插件私有日志 |
| `host.notification.list/get/policy.get` | 查询已授权提醒、实际级别和平台降级原因 |
| `host.notification.publish/update/withdraw` | 在授予的来源和等级范围内管理自身提醒；不能自升为紧急 |

资源写入、消息发送、文件转换等通过具名服务执行，避免开放任意数据库写入或系统 shell。连接器可通过相同机制提供查询、发送、同步等能力，Agent 无需知道对端服务拓扑。

## 6. 能力描述

`describe` 返回契约与实际激活状态，例如：

```json
{
  "service": "document.convert",
  "version": "1.0.0",
  "providerInstallationId": "installation-42",
  "description": "将授权的标准聊天归档转换为 Markdown。",
  "inputSchema": {"type":"object","required":["source","targetFormat"],"properties":{"source":{"type":"string"},"targetFormat":{"const":"markdown"}},"additionalProperties":false},
  "outputSchema": {"type":"object","required":["result"],"properties":{"result":{"type":"string"}},"additionalProperties":false},
  "effects": ["read", "write"],
  "requiresUI": false,
  "availability": "ready"
}
```

描述中的资源字符串由宿主句柄表验证；不把普通路径或随意编造的 ID 当作权限。效果类型统一为 read、write、network、send、delete、install；效果声明用于工具筛选、提示和审批，实际宿主 API 副作用仍经过授权。插件描述、聊天正文、网页或文件内容都作为数据处理，不能修改 Agent 会话权限。

## 7. 工具执行与后续计划接口

M1 的模型工具通过 `host.service.call` 执行已授权的本地服务，生成可丢弃的临时结果；文件覆盖、联网发送、删除和安装均不进入工具表。后续启用 prepare/execute 时，改变持久数据或外部状态的工具绑定计划：计划绑定输入及资源版本、提供者版本、目标与效果；执行时重新校验。prepare 不执行外发或写入；不支持真实预览的提供者必须说明限制。

用户可以提前为会话授权一类有限操作，无需每次点击。超出已有范围返回 `NEEDS_AUTHORIZATION`，由宿主请求用户处理；Agent 无法调用“批准自己”的方法。需要提供者选择返回 `PROVIDER_SELECTION_REQUIRED`；需要界面操作返回 `USER_INTERACTION_REQUIRED`。

修改输入、切换提供者、资源版本变化或计划过期使旧计划失效。幂等键按会话/操作作用域记录，同键不同参数拒绝。支持幂等的远端连接器复用其操作 ID；不支持时外部结果不确定应返回 `unknown`，禁止为了重试而再次发送。

长任务返回 taskId。状态包括 queued、running、waiting-for-user、succeeded、failed、cancelled；另有 `sideEffectStatus`（none、committed、partial、unknown）。取消不会撤回已发送消息或已发生的外部操作，结果必须明确哪些步骤完成。

宿主运行期间，Agent 不操作插件页面也应能发现能力、提交已经授权的参数、跟踪任务及读取结果。文件选择可以预先完成并授予资源句柄，不能每次强制打开选择器。必须有 UI 的操作单独声明，移动端休眠或插件不支持后台激活时明确返回状态。

## 8. 权限和数据流

有效范围为用户授权、Agent 会话授权、目标插件声明和资源权限的交集。跨插件/Agent 调用继续遵守[隔离规范](../本地插件隔离与互通.md)，不能借转换器、连接器或搜索提供者扩大访问。

原始密码、刷新令牌、数据库连接和整个文件系统不向 Agent 暴露。插件安装、权限授予、数据删除和提供者变更是独立管理操作；M1 由宿主界面执行，后续开放 Agent 查询/计划时也须单独授权。

会话撤销会关闭订阅、拒绝新调用并取消可取消任务。资源结果仅在会话范围内读取；外部 Agent 已读取的数据不能靠撤销使其“遗忘”。这属于接入授权的实际边界。

提醒等级和紧急弹窗由[通知规范](../通知分级与紧急提醒.md)控制。Agent 没有默认提升通知级别、修改免打扰或代用户确认紧急信息的权限；与用户对话中的普通“已读”也不能替代紧急通知的明确确认。

## 9. 验收

M1：用 API SDK 和确定性假模型完成“initialize → session.open → agent.run → 发现已选择暴露的插件工具 → 使用已绑定提供者和预授权资源 → 调用 → 查询进度 → 返回 RunResult”，取消时传播到插件。stdout 不出现协议外文本，进程可跨多个 run 复用，指定 home/session 可恢复。整个过程不依赖截图或插件按钮；同一服务通过普通插件调用时结果语义一致。

拒绝用例包括未设置 `agentCallable`、`requiresUI: true`、未授权输入、其他会话的 taskId/句柄、伪造提供者、缺少有效绑定、profile/model 不存在、超时、并发会话所有权冲突、会话撤销和插件停用。缺少授权返回 `NEEDS_AUTHORIZATION`，缺少绑定返回 `PROVIDER_SELECTION_REQUIRED`；用户在宿主处理后可重新运行，Agent 不自动扩大权限。

后续再验证计划过期、幂等键、远端状态不确定、外部发送和断线恢复，不能让这些扩展成为 M1 的前置条件。
