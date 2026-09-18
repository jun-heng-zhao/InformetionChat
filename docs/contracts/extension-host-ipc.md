# 本地 Extension Host IPC v1.2 草案

状态：后续 Worker 设计，M1 使用 UI Bridge；本契约不作为首版前置依赖。

Core Host 与本地 Worker 使用受信本机 IPC，控制消息采用 JSON-RPC 2.0。创建 Worker 时由宿主绑定工作区、安装、会话、包摘要及限额；Worker 不通过参数选择其他身份。

生命周期方法：`host.start`、`host.handshake`、`plugin.activate`、`plugin.deactivate`、`plugin.health`、`host.shutdown`。运行调用使用与 UI Bridge 相同的服务/资源/任务语义，传输适配不增加权限。

插件代码只在声明的运行时执行；WASM 不默认导入文件系统、环境或网络。桌面使用独立 Worker 进程并叠加资源限制；移动只有在完成隔离适配后才公布相应能力。

宿主负责超时、并发、取消、调用栈、可见诊断和异常退出。停用先停止接单并撤销授权，再取消调用并释放运行时。不同安装不能共享可写数据；跨插件通信必须走宿主注册表。

正式 Worker 的 WIT 契约尚待定义和编译验证，不存在可用 SDK。接口应由插件 import 宿主能力、export 操作入口，身份从绑定会话获取。
