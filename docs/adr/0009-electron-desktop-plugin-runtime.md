# ADR 0009：Electron 桌面宿主与插件运行边界

状态：已接受，2026-09-18；实现与 M0 隔离验证待完成。

## 背景

首个客户端以 Linux 桌面为验证环境。Flutter 官方 `webview_flutter` 不支持 Linux；现有第三方绑定要么只能创建独立窗口，要么没有提供项目所需的逐请求拦截、逐安装存储隔离和可信消息通道。为第三方绑定补齐这些能力，实际需要长期维护浏览器内核适配层。

项目已有 Dart `host_core`、JSON-RPC 契约和独立子进程演示。技术选型应保留这些实现，并为桌面插件 UI 提供稳定的 Chromium 运行环境。

## 决策

1. 首个桌面客户端采用 Electron，先验证 Linux，再适配 Windows。桌面端不规划 macOS。Windows 完成后依次设计和验证 Android、iOS 信息收发器。Electron 随应用固定并分发 Chromium/Node.js，不再依赖 Flutter Linux WebView 插件、系统 WebKitGTK 或用户安装的 Node.js。
2. Electron 主进程是 Desktop Runtime Supervisor，负责窗口、插件 UI 容器、系统集成、进程监管和通道路由。现有 Dart `host_core` 构建为平台 AOT 子进程，继续负责安装、授权、服务绑定、资源、任务、通知规则和工作区持久化。每个 profile 只有一个 Supervisor 和一个 Core Host；第二窗口及 Agent client 连接已有实例。具体传输、单写者、背压和恢复规则按 [Desktop Core IPC](../contracts/desktop-core-ipc.md)执行。
3. 插件 UI 使用宿主创建的沙箱 iframe。每个安装和包摘要使用不可由插件选择的 `ichat-plugin://<originKey>/` 独立 origin，资源只从校验后的只读包快照提供；更新包摘要会更换 origin。宿主窗口启用 `nodeIntegration: false`、`contextIsolation: true` 和 `sandbox: true`；插件页面不取得 Electron、Node.js、原生路径或通用 IPC。origin 生成与请求阻断细节由 UI Bridge 冻结。
4. UI Bridge 使用宿主创建的 `MessageChannel`。通道绑定 `workspaceId`、`installationId`、会话、包摘要、登记的直接子 frame 和精确 origin；正文中的身份字段不能改变调用方。iframe 只负责界面和用户交互，不拥有服务生命周期。
5. 每个活动插件安装使用独立 Node.js Extension Host，以隔离崩溃、卡死、日志和生命周期。Extension Host 通过 Electron `utilityProcess` 复用应用内置 Node.js，不再分发第二套 Node 运行时。它按 VS Code 的信任模型运行，拥有启动用户授予应用的系统权限；独立进程不是恶意代码安全沙箱，也不阻止它直接读写文件、联网或启动子进程。服务激活、健康检查和退出只属于 Extension Host。
6. manifest 权限只约束宿主 API 和经宿主代理的数据，不约束插件使用 Node.js 或操作系统接口直接访问本机。`connectivity: offline` 表示插件声明和宿主代理不会提供网络能力，不构成对已信任插件代码的强制断网保证。UI iframe 仍通过 CSP、请求拦截和协议白名单禁止任意网络加载。
7. 插件 UI 与服务生命周期分离。声明 `requiresUI: false` 的服务不依赖页面可见或用户点击；关闭页面不终止仍获授权的服务。停用安装时先停止接单并撤销授权，再关闭 iframe、消息端口和服务进程，超时后强制终止。
8. 安装本地插件前展示真实来源、内容摘要、代码执行能力和权限声明，并要求用户明确确认。未签名包的 `publisher` 只是自述，不能作为身份认证；内容或来源变化后重新确认。后续若提供目录服务，再增加签名、恶意代码扫描、发布者信誉和阻止列表。
9. 工作区具有 `trusted` / `restricted` 状态。Restricted Mode 不启动第三方插件服务进程，不允许工作区内容触发插件代码，只保留基础查看、信任管理和诊断。信任工作区与信任插件分别记录，互不替代。
10. Electron/Chromium/Node.js、Dart AOT 工具链和 IPC 协议版本必须固定到构建记录。发布包不要求用户安装 Node.js 或 Dart SDK。Chromium 安全更新是桌面发布责任；升级后重新执行 M0 隔离回归。
11. Android、iOS 依次作为轻量信息收发器开发，不复用 Electron 运行时，也不提供插件市场、本地包导入、开发加载或第三方可执行插件。移动包只包含构建时选择、随应用编译并经过发布流程验证的少量内部连接模块，可以采用服务器、去中心或仅本地模式。账号、凭据、同步、冲突和后台到达由入包模块负责；移动宿主只提供共用界面、安全存储引用、任务和平台通知适配。移动端不追求桌面扩展性或功能对等，新增协议通过重新构建和发布应用交付。
12. 桌面进程组把总常驻内存 5 GiB 作为用户审查阈值。正在使用的插件不按 5 分钟定时策略回收；没有视图、任务、RPC 或获授权后台活动的插件连续闲置 5 分钟后关闭 iframe 和 Extension Host，下次按激活事件冷启动。超过阈值时按 [Desktop Core IPC](../contracts/desktop-core-ipc.md)停止预热并展示进程明细，建议用户审查；未经用户选择不终止正在使用的插件。
13. 项目不运营默认插件源、签名、扫描或阻止列表。首版接受由用户承担本地插件来源判断的边界；宿主只负责展示真实路径、内容摘要、代码执行等级和权限，并在内容变化后要求重新确认。未来只在存在可维护的外部基础设施时接入附加信任信号，不把它列为个人维护者的默认义务。

## M0 退出条件

- 跨安装的 DOM 存储、Cookie、缓存、Service Worker 和消息端口不可互访。
- 导航、重定向、远程子资源、`fetch`/XHR、WebSocket、WebRTC、Worker、弹窗、下载、外部协议和 `file:` 均按策略阻断。
- iframe、子框架和任意窗口不能伪造 Bridge 来源；插件无法取得 Electron、Node.js、宿主 preload 对象或通用 IPC。
- 未经插件信任确认或处于 Restricted Mode 时，不创建第三方插件服务进程；包摘要或来源变化后原信任不自动沿用。
- UI 卡死、服务超时、渲染进程崩溃和插件进程拒绝退出时，宿主可回收对应安装，其他安装继续工作。
- 同一 profile 只有一个 Core Host 写入工作区；第二窗口和 Agent client 连接现有 Supervisor，Core 重启不会恢复旧会话、任务或句柄。
- 使用中的插件不会被 5 分钟计时回收；符合闲置条件的插件在 5 分钟后退出并可重新激活。超过 5 GiB 时显示进程明细并建议用户审查，不自动终止使用中的插件。
- 测试记录包含 Electron/Chromium/Node.js/Dart AOT 版本、Linux 或 Windows 版本、架构、用例结果、包体和空闲/运行内存。

iframe 来源校验、Restricted Mode 或信任门槛失败时，只允许宿主基础功能运行，第三方插件入口保持关闭。

## 后果

- Linux 桌面不再受 Flutter WebView 支持范围限制，插件页面与宿主工作台共享 Web 技术栈。
- 桌面安装包包含 Chromium，包体、内存和安全更新成本高于系统 WebView。
- 保留 Dart 核心可以避免重写已经验证的权限与服务语义；AOT 交付避免用户安装 Dart，但仍需维护 Electron 到 Dart 的受信 IPC 适配器。
- Extension Host 复用 Electron 内置 Node，减少一套运行时分发和版本漂移；Electron、Node 上下文与 Dart AOT 仍增加构建、调试和内存成本，只有 M0 数据证明不可接受时才重新评估语言边界。
- 本项目采用 VS Code 的扩展信任边界。安装并启用插件等同于允许其以当前用户权限执行代码；宿主权限弹窗不能限制恶意插件绕过宿主 API。
- 当前 `SubprocessPluginRuntime` 已覆盖独立进程、IPC、超时和回收的基本形态，但还没有插件信任记录、Restricted Mode、Electron UI 容器和生产诊断。
- 没有官方 Marketplace 时，项目不承诺 VS Code Marketplace 的签名、扫描、信誉和自动阻止能力。首版准确展示来源与摘要，由用户决定是否信任；这是明确产品边界，不是待补的桌面首版功能。
- 完整插件生态、Agent 和开发工具集中在桌面端。移动端包更小、攻击面更窄，但桌面插件不能直接安装到移动端。

本决策细化并替代 [ADR 0008](0008-solo-developer-delivery-baseline.md) 中的 Flutter/WebView 桌面候选，不改变其个人开发、分阶段交付和失败时关闭外部插件入口的原则。
