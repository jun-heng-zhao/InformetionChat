# 本地 UI Bridge v1.2 草案

状态：设计，尚未实现。UI、Worker 及 Agent 传输适配器连接同一个本地权限代理，具体暴露方法按调用方授权裁剪。

## 握手与身份

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "host.handshake",
  "params": {"uiBridge":"1.2", "requestedCapabilities":["file.pick","file.read","file.save"]}
}
```

宿主通过已创建的 WebView 通道绑定工作区、安装、会话和包摘要。请求中的 pluginId/workspaceId 不能改变调用身份。响应包含选定协议版本、平台、可用运行时、工作区摘要、已批准能力和资源预算；不返回访问令牌或原生路径。1.2 是未发布草案，现有原型页面需要迁移，不能声称它已兼容本契约。

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

宿主从 manifest 读取服务列表，校验包内 schema 后创建候选注册项。UI 通过绑定通道握手后接收 `plugin.activate`，成功响应后服务变为 ready。调用时宿主向提供者发送 `plugin.service.invoke`，包含 callId、确定的服务版本、已校验参数和派生资源；提供者返回符合 outputSchema 的结果或标准错误。参数中的资源引用由宿主映射到接收者句柄，普通字符串本身不能取得访问权。

取消通过 `plugin.task.cancel` 传递 callId，停用发送 `plugin.deactivate`。提供者不响应取消或退出时，宿主关闭运行上下文并终止其任务。上述入站方法仅接受宿主创建的通道，调用身份及权限由宿主保存，不接受插件自报。停用先撤销注册和授权，不能等到插件同意才撤销。

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

- 顶层页面通过宿主创建的受信消息通道握手，禁止子框架或任意窗口冒充。
- 初始消息上限 1 MiB、普通调用 30 秒、每安装并发 4；大文件与长任务使用受控引用和 taskId。
- 工作区切换、停用、重启和授权撤销使旧通道与句柄失效；拒绝尚未完成的请求并传播取消。
- 网络、文件和私有数据访问必须经代理；CSP 与实际资源拦截同时启用。
- 平台不支持的方法返回 `CAPABILITY_UNAVAILABLE`，未授权返回 `CAPABILITY_DENIED`，需要用户操作返回对应交互状态。
- 运行日志记录请求 ID、结果与耗时，避免记录私有正文、文件内容和凭据。

## 错误和状态

JSON-RPC 协议错误采用标准数字码。业务错误统一使用 `error.code: -32000`，在 `error.data.code` 中返回 `CAPABILITY_DENIED`、`NEEDS_AUTHORIZATION`、`CONTRACT_MISMATCH`、`RESOURCE_EXPIRED`、`RESOURCE_LIMIT`、`PROVIDER_UNAVAILABLE`、`PROVIDER_SELECTION_REQUIRED`、`TIMEOUT`、`CANCELLED` 或 `CALL_CYCLE`，附 requestId；不泄露其他安装的数据。明确可申请权限的 Agent 请求可返回 NEEDS_AUTHORIZATION，插件越权返回 CAPABILITY_DENIED。

任务终态为 succeeded、failed、cancelled；取消请求已接受不等于任务已停止。`sideEffectStatus` 为 none、committed、partial、unknown，不能把已保存或已外发的结果因取消标为未发生。M1 本地转换不自动重试；跨会话的 taskId 查询拒绝。

本表定义设计语义。方法级机器 schema、成对请求/响应样例及错误样例仍需在 SDK 实现前补齐；当前不能据此声称已有可用 SDK。
