# InformetionChat

个人维护、以开源分发为目标的本地信息工作台，提供本地使用环境和插件接口。没有官方团队、统一账号、后台或认证服务；远端服务由用户选择的连接器适配。

这是我的第一个真正的项目，希望它会有一个好结果。

- [完整开发文档索引](docs/开发文档索引.md)
- [开发总文档](docs/开发总文档.md)
- [完整架构图](docs/完整架构图.md)
- [设计审查与修改记录](docs/设计审查与修改记录.md)
- [个人开发者交付基线](docs/adr/0008-solo-developer-delivery-baseline.md)
- [Electron 桌面宿主决策](docs/adr/0009-electron-desktop-plugin-runtime.md)
- [Desktop Supervisor 与 Dart Core IPC](docs/contracts/desktop-core-ipc.md)
- [桌面插件开发与调试](docs/桌面插件开发.md)
- [本地数据与备份恢复](docs/本地数据与备份恢复.md)
- [移动信息收发器与桌面完整包](docs/客户端交付与插件边界.md)
- [本地插件隔离与互通](docs/本地插件隔离与互通.md)
- [插件依赖、重复功能与能力复用](docs/插件依赖与能力复用.md)
- [Agent 接入契约](docs/contracts/agent-api.md)
- [连接方式与服务中立](docs/连接方式与服务中立.md)
- [通知分级与紧急提醒](docs/通知分级与紧急提醒.md)
- [插件清单](docs/contracts/plugin-manifest.schema.json)
- [开发环境与运行说明](docs/开发环境与运行说明.md)
- [格式转换插件](plugins/dev-format-converter/README.md)
- [原始需求资料](archive/2026-09-18/README.md)

## 当前状态

宿主核心与三个示例插件已可运行，覆盖插件加载、权限与资源句柄、服务互通与复用、Agent 会话调用和授权紧急提醒。演示范围、替身与尚未实现的部分见[开发环境与运行说明](docs/开发环境与运行说明.md)。

```bash
dart pub get
dart run tools/demo_runner/bin/demo.dart
```

桌面技术路线已确定为 Electron Supervisor、沙箱 iframe 插件 UI、Dart AOT Core Host 和每安装独立 Electron Node `utilityProcess`。每个 profile 只允许一个 Core Host 写入工作区；正在使用的插件不做 5 分钟定时回收，闲置 5 分钟后回收。桌面进程组超过 5 GiB 总常驻内存时提示用户审查，不自动终止使用中的插件。开发顺序固定为 Linux、Windows、Android、iOS，不规划 macOS。当前还没有 Electron 客户端、iframe 隔离实现、Agent API runtime/SDK 或安装包，也没有平台支持结论。架构决策见 [ADR 0009](docs/adr/0009-electron-desktop-plugin-runtime.md)，IPC 契约见 [Desktop Core IPC](docs/contracts/desktop-core-ipc.md)，实现差距见[审查记录](docs/设计审查与修改记录.md)第 7 节。

仓库尚未设置项目级 LICENSE，首次对外分发前需确认许可。
