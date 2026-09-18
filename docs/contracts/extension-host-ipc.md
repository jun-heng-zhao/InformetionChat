# 桌面 Extension Host IPC v1.3 草案

状态：Electron 桌面 M1 冻结设计，尚未实现。UI Bridge 与 Extension Host 使用同一宿主方法语义，但运行位置和信任边界不同；进程所有权与总体预算见 [Desktop Core IPC](desktop-core-ipc.md)。

Electron Supervisor 为每个活动安装通过 `utilityProcess` 创建独立 Node.js Extension Host，复用 Electron 内置 Node.js，不使用系统 Node，也不附带第二套 Node。Extension Host 通过专用 `MessagePort` 连接 Supervisor；Supervisor 把通道身份绑定后转发到 Dart Core Host。控制消息采用带长度上限的 JSON-RPC 2.0。创建进程时绑定工作区、安装、会话、包摘要及限额；Extension Host 不通过参数选择其他身份，不监听公开网络端口。

生命周期方法：`host.start`、`host.handshake`、`plugin.activate`、`plugin.deactivate`、`plugin.health`、`host.shutdown`。这些方法只属于 Extension Host；iframe 使用 `host.handshake`、UI Bridge 方法和 `plugin.ui.dispose`，不能注册或激活服务。宿主根据 manifest 的 `activationEvents` 延迟启动和激活 Extension Host；安装或扫描包不能执行插件代码。运行调用使用与 UI Bridge 相同的服务、资源、任务及错误语义，传输适配不增加宿主 API 权限。

服务在 Extension Host 成功完成握手和 `plugin.activate` 后才进入 ready。`requiresUI: false` 的服务与视图生命周期分离；`requiresUI: true` 的服务仍在 Extension Host 执行，但调用时必须存在匹配安装的活动视图，否则返回 `USER_INTERACTION_REQUIRED`。关闭视图不停止其他服务，停用安装才撤销全部服务和运行通道。

Extension Host 采用 VS Code 式信任模型。它与 Electron 主进程、工作台 renderer 和 iframe 分离，以隔离崩溃、卡死、日志和生命周期；它仍以当前用户权限运行，可直接使用 Node.js 文件、网络和子进程 API。manifest 权限只约束经 Core Host 发起的调用，不构成恶意插件沙箱。

只有已确认插件信任且工作区不处于 Restricted Mode 时才创建 Extension Host。包摘要、入口或来源变化后停止旧进程并撤销信任，重新确认后生成新会话。移动端不创建 Extension Host。

宿主负责超时、并发、取消、调用栈、可见诊断和异常退出。停用先停止接单并撤销授权，再取消调用并释放运行时。不同安装不能共享可写数据；跨插件通信必须走宿主注册表。M1 只接受纯 JavaScript 入口，不加载原生 Node addon、插件自带 Node、Python 或任意外部可执行文件。

没有可见视图、运行或排队任务、未完成 RPC、获授权后台活动或待处理交互时，安装进入闲置候选；连续闲置 5 分钟后 Supervisor 发送 `plugin.deactivate`，超时则终止进程。正在使用的 Extension Host 不按定时策略回收。服务声明与绑定保留，下一次激活事件重新创建进程。

桌面进程组把 5 GiB 总常驻内存作为用户审查阈值。Extension Host 数量不设固定上限；接近阈值时停止后台预热并先回收已闲置 5 分钟的安装。超过 5 GiB 时显示各安装占用并建议用户审查；不得为了满足阈值自动终止正在使用的插件，只有用户选择停止后才取消任务并关闭对应运行时。

开发模式可为目标 Extension Host 开启绑定回环地址的 Node Inspector，并提供日志、Output 和 RPC Trace；正式模式不开放调试端口。开发宿主使用独立数据目录、安装 ID、存储和授权，不复用日常窗口状态。

当前 `SubprocessPluginRuntime` 和 `service/index.js` 只验证了 stdio JSON-RPC、超时和强制回收，尚未实现 activation events、插件信任、Restricted Mode、Electron `utilityProcess` 或正式 Extension SDK。后续 WASM Worker 使用独立 WIT 契约和更强能力隔离，不沿用 Node.js 的信任声明。
