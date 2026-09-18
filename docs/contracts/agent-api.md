# Agent 接入契约 v1 草案

状态：设计，尚未实现。Agent 泛指用户选择的自动化客户端；应用不绑定模型、厂商或中心化/去中心化服务。Agent 与 UI、插件共用本地宿主的服务注册表、任务、资源和授权接口。

## 0. M1 简单目标

Agent 是插件服务的一个调用方。M1 只实现本地授权会话，以及 `host.context.get`、`host.service.discover/describe/call`、`host.binding.get`、`host.resource.list/read`、`host.task.get/cancel`。调用沿用 [UI Bridge](plugin-ui-jsonrpc.md) 的参数、资源和错误语义，授权会话由可信宿主界面建立，Agent 不能自批。

最小流程：用户预选一份输入并绑定转换器 → Agent 发现并描述服务 → 调用 `host.service.call` → 查询或取消 task → 读取结果。结果保存可由用户在宿主完成；将来允许 Agent 保存时，须先授予明确的输出目标。M1 不要求 Agent 安装插件、修改绑定、自动规划或托管模型。

首个适配器采用 stdio 与受认证的本机 IPC 相连：宿主界面创建一次性配对凭据，经受保护的继承管道交给适配器；IPC 限制为当前系统用户，并在配对后绑定会话。凭据不写入命令行、公共配置或日志，断开及宿主重启后重新配对。stdio 只是传输，不能代替本地会话授权。实际 IPC 机制在 M0 选型记录中确定。

M1 要求宿主运行；“不依赖 UI 点击”表示服务能直接处理调用，不承诺宿主关闭后仍常驻。可用本地脚本代替模型完成契约验收，测试不依赖模型账号或远端服务。`requiresUI: false` 必须由运行时验证，不能只看清单布尔值。

下文保留后续完整接口蓝图；M1 未实现的方法返回 `CAPABILITY_UNAVAILABLE`，发现结果不宣称其可用。

## 1. 接入边界

Agent 必须获得本地用户授予的独立会话，记录工作区、可发现/调用的服务、资源范围、允许的副作用、提供者绑定、有效期和调用预算。该会话不是宿主管理员身份。

传输优先验证本地 IPC 或 stdio 的 JSON-RPC 适配。后续可增加 MCP 等协议适配器，映射到同一 API；不能仅监听 localhost 就视为已经授权，也不默认开放远程监听。外部 Agent 进程不在插件沙箱内，其能够读取的数据必须由用户明确授权；应用不能控制它在宿主之外的行为。

插件服务只有声明 `agentCallable: true`、具有完整参数/结果 schema、已兼容激活且用户授权后才对该会话可调用。声明为 true 不等于授权。纯 UI 命令或未描述副作用的操作不自动转换成 Agent 工具。

## 2. 完整接口蓝图（按阶段启用）

下列名称为同一宿主 API 的设计方法。发现结果仅返回会话范围内可见的信息，未授权能力可以返回可申请的摘要，不泄露数据正文。

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

## 3. 能力描述

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

描述中的资源字符串由宿主句柄表验证；不把普通路径或随意编造的 ID 当作权限。效果类型统一为 read、write、network、send、delete、install；效果声明仅供规划，实际文件/网络等副作用仍经过代理授权。插件描述、聊天正文、网页或文件内容都作为数据处理，不能修改 Agent 会话权限。

## 4. 直接调用与后续计划接口

M1 通过 `host.service.call` 执行已授权的本地服务，生成可丢弃的临时结果；文件覆盖、联网发送、删除和安装均不在该 Agent 会话范围内。后续启用 prepare/execute 时，改变持久数据或外部状态的操作绑定计划：计划绑定输入及资源版本、提供者版本、目标与效果；执行时重新校验。prepare 不执行外发或写入；不支持真实预览的提供者必须说明限制。

用户可以提前为会话授权一类有限操作，无需每次点击。超出已有范围返回 `NEEDS_AUTHORIZATION`，由宿主请求用户处理；Agent 无法调用“批准自己”的方法。需要提供者选择返回 `PROVIDER_SELECTION_REQUIRED`；需要界面操作返回 `USER_INTERACTION_REQUIRED`。

修改输入、切换提供者、资源版本变化或计划过期使旧计划失效。幂等键按会话/操作作用域记录，同键不同参数拒绝。支持幂等的远端连接器复用其操作 ID；不支持时外部结果不确定应返回 `unknown`，禁止为了重试而再次发送。

长任务返回 taskId。状态包括 queued、running、waiting-for-user、succeeded、failed、cancelled；另有 `sideEffectStatus`（none、committed、partial、unknown）。取消不会撤回已发送消息或已发生的外部操作，结果必须明确哪些步骤完成。

宿主运行期间，Agent 不操作插件页面也应能发现能力、提交已经授权的参数、跟踪任务及读取结果。文件选择可以预先完成并授予资源句柄，不能每次强制打开选择器。必须有 UI 的操作单独声明，移动端休眠或插件不支持后台激活时明确返回状态。

## 5. 权限和数据流

有效范围为用户授权、Agent 会话授权、目标插件声明和资源权限的交集。跨插件/Agent 调用继续遵守[隔离规范](../本地插件隔离与互通.md)，不能借转换器、连接器或搜索提供者扩大访问。

原始密码、刷新令牌、数据库连接和整个文件系统不向 Agent 暴露。插件安装、权限授予、数据删除和提供者变更是独立管理操作；M1 由宿主界面执行，后续开放 Agent 查询/计划时也须单独授权。

会话撤销会关闭订阅、拒绝新调用并取消可取消任务。资源结果仅在会话范围内读取；外部 Agent 已读取的数据不能靠撤销使其“遗忘”。这属于接入授权的实际边界。

提醒等级和紧急弹窗由[通知规范](../通知分级与紧急提醒.md)控制。Agent 没有默认提升通知级别、修改免打扰或代用户确认紧急信息的权限；与用户对话中的普通“已读”也不能替代紧急通知的明确确认。

## 6. 验收

M1：用 Agent 测试客户端完成“发现/描述 → 使用已绑定提供者和预授权资源 → 调用 → 查询进度 → 读取结果”，取消时传播到插件。整个过程不依赖截图或插件按钮。相同服务同时通过普通插件调用，校验结果语义一致。

拒绝用例包括未授权输入、其他会话的 taskId/句柄、伪造提供者、缺少有效绑定、超时、会话撤销和插件停用。缺少授权返回 `NEEDS_AUTHORIZATION`，缺少绑定返回 `PROVIDER_SELECTION_REQUIRED`；用户在宿主处理后可重新调用，Agent 不自动扩大权限。

后续再验证计划过期、幂等键、远端状态不确定、外部发送和断线恢复，不能让这些扩展成为 M1 的前置条件。
