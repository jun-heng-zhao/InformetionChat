# InformetionChat

个人维护、以开源分发为目标的本地信息工作台，提供本地使用环境和插件接口。没有官方团队、统一账号、后台或认证服务；远端服务由用户选择的连接器适配。

- [完整开发文档索引](docs/开发文档索引.md)
- [开发总文档](docs/开发总文档.md)
- [设计审查与修改记录](docs/设计审查与修改记录.md)
- [个人开发者交付基线](docs/adr/0008-solo-developer-delivery-baseline.md)
- [本地数据与备份恢复](docs/本地数据与备份恢复.md)
- [移动基础包与桌面完整包](docs/客户端交付与插件边界.md)
- [本地插件隔离与互通](docs/本地插件隔离与互通.md)
- [插件依赖、重复功能与能力复用](docs/插件依赖与能力复用.md)
- [Agent 接入契约](docs/contracts/agent-api.md)
- [连接方式与服务中立](docs/连接方式与服务中立.md)
- [通知分级与紧急提醒](docs/通知分级与紧急提醒.md)
- [插件清单](docs/contracts/plugin-manifest.schema.json)
- [本地格式转换原型](plugins/dev-format-converter/README.md)
- [原始需求资料](archive/2026-09-18/README.md)

当前只有设计、契约草案和早期页面原型，尚无生产宿主或四端安装包。先验证一个桌面平台，首版重点是插件加载、隔离和互通，同时实现 Agent 调用插件及授权紧急通知前台弹窗；其余平台与网络能力逐项推进。本地插件加载不以账号或签名为前提。仓库尚未设置项目级 LICENSE，首次对外分发前需确认许可。
