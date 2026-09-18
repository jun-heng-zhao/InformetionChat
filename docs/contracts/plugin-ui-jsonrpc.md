# 本地 UI Bridge v1.2 草案

状态：Electron iframe 设计，尚未实现。iframe UI、Extension Host 及 Agent 传输适配器连接同一个 Dart 本地权限代理，具体暴露方法按调用方授权裁剪。

## 握手与身份

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "host.handshake",
  "params": {"uiBridge":"1.2", "requestedCapabilities":["file.pick","file.read","file.save"]}
}
```

Electron 宿主为已登记的顶层沙箱 iframe 创建 `MessageChannel`，并把消息端口绑定到 iframe origin、工作区、安装、会话和包摘要。只接受匹配的顶层 frame、origin 与端口；子框架、弹窗和任意窗口不能取得或替换通道。请求中的 pluginId/workspaceId 不能改变调用身份。响应包含选定协议版本、平台、可用运行时、工作区摘要、已批准能力和资源预算；不返回访问令牌、原生路径、Electron 对象或通用 IPC。1.2 是未发布草案，现有原型页面需要迁移，不能声称它已兼容本契约。

### 独立 origin 与资源装载

桌面端注册标准且安全的 `ichat-plugin` 自定义协议。每个安装快照的页面 origin 为 `ichat-plugin://<originKey>`；`originKey` 由 profile 私钥对 `workspaceId + installationId + packageDigest` 计算 HMAC-SHA-256 后编码生成，插件不能声明、预测其他安装或复用旧摘要的 origin。更新导致摘要变化时必须创建新 origin、通道和运行会话。

协议处理器根据 Supervisor 保存的映射读取只读包快照。URL 路径归一化后必须留在该快照根目录，拒绝目录跳转、链接、特殊文件和未列入内容清单的资源。iframe 使用 `sandbox="allow-scripts allow-same-origin"`；不授予导航、弹窗、下载、表单提交、顶层跳转或其他 sandbox 能力。插件浏览器存储只作为该 origin 的非权威缓存，不能代替 `host.storage.*`；更新、卸载或清理数据时按 origin 清除。Service Worker 始终禁用。

Supervisor 和工作台同时阻断 `http:`、`https:`、`ws:`、`wss:`、`file:`、`ftp:`、`data:`、`blob:`、WebRTC、Worker、外部协议及未登记的自定义协议。只允许当前 `ichat-plugin` origin 内、内容清单存在的静态资源请求。CSP 是宿主固定下限，插件只能收紧。所有导航、新窗口、下载和权限请求由 Electron 的导航、窗口、session 请求拦截及 permission handler 拒绝，不能只依赖页面 CSP。

工作台只向登记的直接子 iframe 传递一次性 `MessagePort`，使用精确 target origin，不使用 `*`。创建时记录 Electron frame 标识、originKey、安装、摘要和会话；frame 导航、重载、分离、工作区切换或摘要变化立即关闭旧端口。子 iframe、弹窗及取得旧端口的页面均不能重新绑定身份。

## M1 必需接口

M1 实现握手/上下文、自身存储、文件选择/读取/保存、临时资源创建/读取、服务发现/描述/调用、绑定查询、任务查询/取消及前台通知。通用事件、操作计划、绑定管理和 Agent 安装管理为后续接口。已知但未实现的方法返回 `CAPABILITY_UNAVAILABLE`；未知 JSON-RPC 方法返回标准 `-32601`。

| 方法 | M1 参数与结果约定 |
|---|---|
| `host.storage.get/set` | 当前安装内的 key / JSON value；get 返回 found 和 value；宿主检查配额，不接收命名空间参数 |
| `host.file.pick` | 用户选择单个输入；返回 handle、name、mediaType、size、version、expiresAt；取消返回 CANCELLED |
| `host.file.read` / `host.resource.read` | handle、offset、length；返回 base64 字节、nextOffset、eof；每次读取仍校验会话和范围 |
| `host.resource.create` | mediaType、base64 内容、建议名称；生成不可修改的临时结果 handle，绑定当前安装/调用，不获得文件系统写权限 |
| `host.resource.list` | cursor、limit；仅列出当前会话已授权的资源摘要，返回 items 和 nextCursor |
| `host.file.save` | 已授权的结果 handle 和 suggestedName；由宿主选择输出位置，返回 saved 或 CANCELLED，不返回原生路径 |
| `host.service.discover/describe` | 按服务 ID/版本范围筛选可见提供者；describe 返回确定版本、参数/结果 schema、效果及实际可用性 |
| `host.binding.get` | 服务 ID；返回绑定提供者与契约版本，缺失时返回 PROVIDER_SELECTION_REQUIRED；M1 只由宿主界面变更绑定 |
| `host.service.call` | service、versionRange、input；只能调用既有绑定，返回 taskId，具体结果通过 task.get 读取 |
| `host.task.get/cancel` | taskId；get 返回 state、progress、output、sideEffectStatus 和错误；cancel 返回取消请求是否已接受，终态仍需查询 |
| `host.notification.*` | 参数、修订和状态使用[通知规范](../通知分级与紧急提醒.md)；确认仅由可信宿主 UI 完成 |

M1 演示输入与临时结果分别限制在 512 KiB，单次 read 最多 256 KiB；临时资源总量每安装 16 MiB。大文件流式写入另行扩展，超限返回 `RESOURCE_LIMIT`，不能把大量字节塞进控制消息。创建临时资源是独立 `resource.create` 权限，直接读取仍需资源范围授权。

结果以宿主管理的临时资源保存；提供者结束后撤销输入授权，输出重新派生给调用方。结果至少保留到任务结束后 10 分钟或调用方会话结束，以先到者为准，响应明确 expiresAt。停用、撤销或工作区切换可提前失效，用户应在有效期内保存。

## 服务进入与退出

宿主从 manifest 读取服务列表，校验包内 schema 后创建候选注册项。服务只由 Extension Host 激活和执行；iframe 完成 UI Bridge 握手只表示视图 ready，不能使服务变为 ready，也不接收 Extension Host 的 `plugin.activate` 生命周期方法。调用时宿主向已激活的 Extension Host 发送 `plugin.service.invoke`，包含 callId、确定的服务版本、已校验参数和派生资源；提供者返回符合 outputSchema 的结果或标准错误。参数中的资源引用由宿主映射到接收者句柄，普通字符串本身不能取得访问权。

`requiresUI: false` 的服务不依赖 iframe，可由普通插件或 Agent 在页面关闭时调用。`requiresUI: true` 的服务仍由 Extension Host 实现，但调用前必须已有匹配安装的活动视图会话；否则返回 `USER_INTERACTION_REQUIRED`。Extension Host 与自身 iframe 的插件私有消息由 Supervisor 路由并绑定同一安装，不能借此访问其他插件或绕过宿主服务授权。

取消通过 `plugin.task.cancel` 传递 callId，停用向 Extension Host 发送 `plugin.deactivate`，视图只接收 `plugin.ui.dispose`。提供者不响应取消或退出时，宿主关闭对应 Extension Host 并终止其任务；关闭视图本身不终止 `requiresUI: false` 的服务。上述入站方法仅接受宿主创建的消息端口，调用身份及权限由宿主保存，不接受插件自报。停用先撤销注册和授权，不能等到插件同意才撤销。

同一调用固定提供者安装、包摘要和服务版本，更新前停止接单并清理旧调用；不能在执行中切换实现。M1 统一异步返回 taskId，避免调用方混用同步结果和长任务。Agent 使用相同语义，无需点击提供者页面。

## 全部接口蓝图（按阶段启用）

| 组 | 方法 |
|---|---|
| 上下文 | `host.context.get` |
| 自身存储与资源 | `host.storage.get/set`、`host.object.get`、`host.resource.create/list/read` |
| 文件 | `host.file.pick/read/save` |
| 服务 | `host.service.discover/describe/call`、`host.binding.get/plan` |
| 命令 | `host.command.execute`，只能调用已声明和授权的命令 |
| 事件 | `host.event.subscribe/unsubscribe/publish` |
| 任务 | `host.task.get/list/cancel` |
| 操作计划 | `host.operation.prepare/execute` |
| 授权 | `host.access.request`；宿主界面处理用户授权，插件不能自批 |
| 诊断 | `host.trace.get`，仅当前调用方有权查看的记录 |
| 通知 | `host.notification.publish/update/withdraw/list/get/acknowledge/policy.get`，按来源与提醒等级授权 |

服务参数、结果和提供者由注册表解析。`host.service.call` 不能绕过实际资源授权；M1 可直接调用的本地操作须已在会话策略中明确授权，后续开放计划接口时再附加计划检查。详情见[互通规范](../本地插件隔离与互通.md)与[Agent API](agent-api.md)。

`file.pick` 通过系统选择器返回短期句柄；`file.read` 限定数量和范围；`file.save` 读取结果句柄并使用用户确认的输出位置，不接受原型中的任意 content/path 参数。预授权资源可直接经资源接口读取，Agent 不依赖每次弹出选择器。跨插件传递由宿主派生接收者句柄，不复制万能 token。

## 约束

- 顶层 iframe 通过宿主创建的 `MessageChannel` 握手；同时校验 frame、origin、端口和会话，禁止子框架、弹窗或任意窗口冒充。
- iframe origin 固定为宿主派生的 `ichat-plugin://<originKey>`；originKey 绑定工作区、安装和包摘要，更新后不得复用。
- 初始消息上限 1 MiB、普通调用 30 秒、每安装并发 4；大文件与长任务使用受控引用和 taskId。
- 工作区切换、停用、重启和授权撤销使旧通道与句柄失效；拒绝尚未完成的请求并传播取消。
- iframe 的网络、文件和私有数据访问必须经代理；宿主 CSP 与请求拦截同时启用。Node.js Extension Host 是用户已信任代码，可使用系统接口绕过宿主代理，这部分不属于 UI Bridge 安全保证。
- 平台不支持的方法返回 `CAPABILITY_UNAVAILABLE`，未授权返回 `CAPABILITY_DENIED`，需要用户操作返回对应交互状态。
- 运行日志记录请求 ID、结果与耗时，避免记录私有正文、文件内容和凭据。

## 错误和状态

JSON-RPC 协议错误采用标准数字码。业务错误统一使用 `error.code: -32000`，在 `error.data.code` 中返回 `CAPABILITY_DENIED`、`NEEDS_AUTHORIZATION`、`CONTRACT_MISMATCH`、`RESOURCE_EXPIRED`、`RESOURCE_LIMIT`、`PROVIDER_UNAVAILABLE`、`PROVIDER_SELECTION_REQUIRED`、`TIMEOUT`、`CANCELLED` 或 `CALL_CYCLE`，附 requestId；不泄露其他安装的数据。明确可申请权限的 Agent 请求可返回 NEEDS_AUTHORIZATION，插件越权返回 CAPABILITY_DENIED。

任务终态为 succeeded、failed、cancelled；取消请求已接受不等于任务已停止。`sideEffectStatus` 为 none、committed、partial、unknown，不能把已保存或已外发的结果因取消标为未发生。M1 本地转换不自动重试；跨会话的 taskId 查询拒绝。

本表定义设计语义。方法级机器 schema、成对请求/响应样例及错误样例仍需在 SDK 实现前补齐；当前不能据此声称已有可用 SDK。
