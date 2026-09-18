# Desktop Supervisor 与 Dart Core IPC v1.0

状态：桌面 M0 冻结设计，Linux 首先验证，Windows 随后验证。实现偏离本文件时必须新增 ADR，不能在适配器中形成第二套进程所有权或身份规则。

## 1. 进程所有权

Electron 主进程是 Desktop Runtime Supervisor。图形模式创建工作台窗口；headless Agent 模式运行同一个 Supervisor，但不创建窗口。每个应用 profile 同时只允许一个 Supervisor，它负责：

- 启动、监控一个 Dart Core Host AOT 子进程；
- 创建工作台 renderer、插件 iframe 和每安装 Extension Host；
- 为每条通道绑定调用方身份，再把获准请求转发给 Core Host；
- 汇总 Electron、Core Host 和 Extension Host 的资源用量；
- 在 Core Host 或插件进程异常退出时执行恢复和诊断。

第二个桌面窗口或 API client 不创建第二个 Core Host，而是连接现有 Supervisor。Linux 使用用户私有 Unix Domain Socket，Windows 使用仅当前用户可访问的 Named Pipe。端点文件、锁和认证材料位于 profile 目录；端点不监听 TCP，也不接受远程连接。

Core Host 是工作区持久数据的唯一写入宿主。一个 Core Host 可以打开多个工作区，并为每个工作区串行化事务；其他窗口、Agent 和插件只能通过它写入。profile 锁失败时，新进程连接现有 Supervisor；无法验证现有端点时进入诊断，不强行夺锁或直接打开数据库。

## 2. 运行时交付

Electron 包固定 Chromium 和 Node.js 版本。Node.js Extension Host 优先通过 Electron `utilityProcess` 使用随应用分发的同一 Node.js，不再附带第二套独立 Node 运行时。图形与 headless 模式均由 Supervisor 创建 utility process，因此行为一致。

Dart Core Host 使用固定 Dart SDK 构建为平台 AOT 可执行文件。发布包包含该可执行文件，用户不需要安装 Dart SDK。保留 Dart Core 可以复用现有权限、资源、服务和任务语义；若 M0 数据证明 AOT Core 的包体、常驻内存或调试成本无法接受，再以 ADR 评估迁移，不在首版同时维护 TypeScript 和 Dart 两套核心实现。

插件 M1 只支持纯 JavaScript Extension Host 入口，不支持原生 Node addon、Python、任意外部可执行文件或插件自带 Node。这样可避免 Node ABI、系统动态库和 CPU 架构造成未声明的兼容差异。

## 3. Electron 与 Core Host 传输

Supervisor 通过专用 stdin/stdout 管道连接其 Core Host 子进程。stdout 只承载协议，stderr 只承载有界诊断日志。每个消息使用 4 字节大端无符号长度加 UTF-8 JSON-RPC 2.0 正文；正文上限为 1 MiB。大文件、附件和服务结果只传资源句柄，不进入控制消息。

启动握手固定以下信息：IPC 协议版本、应用版本、Core Host 版本、profile ID、启动随机数、平台、架构、能力表和资源预算。profile、工作区、安装、会话和调用方类型由 Supervisor 创建的通道绑定；请求正文中的同名字段只能用于关联，不能切换身份。

每条客户端通道最多保留 64 个未完成请求和 8 MiB 待发送控制数据。达到上限时暂停读取并返回 `RESOURCE_LIMIT`；不能无限缓存。请求取消、超时和连接关闭必须传播到 Core Host。未知方法返回 `-32601`，已知但当前平台不可用的方法返回 `CAPABILITY_UNAVAILABLE`。

外部窗口或 API client 与 Supervisor 握手时同时依赖操作系统当前用户权限和 256 位随机 profile token。token 存入仅当前用户可读的 profile 文件或等价系统安全存储，不写命令行、日志或插件可读环境。连接建立后，Supervisor 为客户端创建新的会话 ID；旧连接报文不能在重连后复用。

## 4. 通道路由

| 调用方 | 到 Supervisor | Supervisor 到 Core Host | 身份来源 |
|---|---|---|---|
| 工作台 renderer | Electron 限定 IPC | Core JSON-RPC | 窗口、profile、工作区和会话绑定 |
| 插件 iframe | 专用 `MessagePort` 经工作台转交 | Core JSON-RPC | frame、origin、安装、摘要和会话绑定 |
| Extension Host | `utilityProcess` 专用 `MessagePort` | Core JSON-RPC | 安装、摘要、激活会话和预算绑定 |
| Agent runtime | Supervisor 创建的私有管道 | Core JSON-RPC | profile、workspace、Agent session 和授权绑定 |
| API SDK | UDS/Named Pipe 连接 Supervisor | 由 Agent runtime 间接调用 | 当前用户、profile token 和 API session 绑定 |

插件之间没有直连通道。跨插件请求必须经过 Core Host 服务注册表、提供者绑定、权限检查和资源句柄派生。Supervisor 只路由和绑定身份，不复制业务授权逻辑。

## 5. 崩溃与恢复

Core Host 意外退出后，Supervisor 停止接受新写操作，关闭全部插件通道并把未完成任务标记为 `HOST_RESTARTED`。Supervisor 最多自动重启一次；新 Core Host 从持久安装记录、授权、服务绑定和数据库恢复，但不恢复旧会话、短期句柄、运行任务或已打开的 Extension Host。

同一启动周期再次崩溃时进入安全模式，只开放基础查看、诊断、备份和插件管理，不自动启动第三方代码。数据库恢复使用事务/WAL 规则，不能以重新启动进程代替一致性检查。

Extension Host 崩溃只影响对应安装。仍在使用的其他安装继续运行；崩溃安装需要重新激活并获得新会话。工作台 renderer 崩溃不会改变 Core Host 的持久状态，重建窗口后重新握手。

## 6. 资源预算与回收

桌面进程组把 5 GiB 总常驻内存作为用户审查阈值。统计范围包含 Electron 主进程和 renderer、Dart Core Host、所有 Extension Host 及插件 iframe。Supervisor 每秒采样进程 RSS；该阈值用于诊断和准入提示，不是自动终止上限。

- 总量达到 4 GiB 时停止后台预热，并优先回收已连续闲置 5 分钟的插件运行时。
- 总量达到 4.5 GiB 时拒绝新的后台激活；用户主动操作需要启动插件时，先回收符合闲置条件的运行时并展示预计增量。
- 总量超过 5 GiB 时保持正在使用的插件运行，向用户显示按进程排序的内存、任务、视图和最近增长，建议用户审查并选择停止任务、关闭视图或停用插件。宿主不因越过该阈值自动终止使用中的插件，也不能把提示写成系统内存安全保证。

插件满足以下全部条件后开始计算闲置时间：没有可见或聚焦视图、没有运行或排队任务、没有未完成 RPC、没有用户允许的后台活动、没有待处理交互。连续闲置 5 分钟后，Supervisor 关闭其 iframe 和 Extension Host，撤销运行会话与短期句柄，但保留安装、持久存储、服务声明和提供者绑定。下次命令、视图或服务调用重新激活该安装。

正在使用的插件不执行 5 分钟定时回收。插件不能通过空心跳维持活跃；只有宿主可证明的视图、任务、调用或已授权后台活动才计为使用中。超过 5 GiB 只触发用户审查建议，不自动终止使用中的插件。M0/M1 测试记录空闲基线、每插件增量、峰值、回收后内存和冷启动耗时。

## 7. 验收

- 同一 profile 同时只有一个 Supervisor 和一个 Core Host；多个窗口与 Agent client 共用该 Core Host。
- 第二进程不能绕过 profile 锁直接写工作区，伪造正文身份不能切换工作区或安装。
- 协议外 stdout、超长帧、积压超限、旧会话重放和非当前用户连接均被拒绝。
- Core Host 重启后持久数据保持一致，旧任务、句柄和插件会话不复活；连续崩溃进入安全模式。
- Extension Host 使用 Electron 内置 Node，发布机和目标机都不依赖系统 Node 或 Dart SDK。
- 使用中的插件不会因 5 分钟计时被回收；符合闲置条件的插件在 5 分钟后退出，并可按激活事件重新启动。
- 检测到总 RSS 超过 5 GiB 后，宿主显示可定位到进程、安装和任务的审查建议；用户选择停止后才终止正在使用的插件运行时。
- Linux 和 Windows 分别记录 IPC、profile 锁、崩溃恢复、内存预算和打包结果；未实测平台不进入支持名单。
