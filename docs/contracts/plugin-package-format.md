# 本地插件包格式 v1.2 草案

阶段与宿主原则以 [ADR 0008](../adr/0008-solo-developer-delivery-baseline.md)和 [ADR 0009](../adr/0009-electron-desktop-plugin-runtime.md)为准。本规范用于桌面本地加载；不要求账号、发布证书、审核状态或签名服务。启用可执行插件前仍需确认来源、摘要和代码执行风险。

## 内容

插件可从桌面开发目录或 `.plugin.tgz` 包加载：

```text
manifest.json             # 必需
ui/index.html             # 声明 runtime.ui 时必需
ui/assets/*               # 按实际引用提供
extension/index.js        # 目标格式：声明 runtime.extension 时必需
worker/component.wasm     # 声明 runtime.worker 时必需
schemas/*.json            # 声明服务时提供输入/输出 schema
LICENSE                   # 开源分发时附带实际许可证
```

manifest 1.2 草案表达 `runtime.ui`、`runtime.extension` 与后续 `runtime.worker`。正式桌面服务入口使用 `extension/index.js`，声明 `node` 与 `extensionApi` 引擎范围；现有 `service/index.js` 仍是演示器约定，需要在 M1 打包前迁移。UI、Extension Host 或 Worker 声明为必需时必须全部可用。移动端不加载本规范的第三方插件包，只随应用构建内部模块。

桌面插件的 `platforms` 只接受 `linux`、`windows`。Android 和 iOS 不属于桌面插件目标，不能写入本清单；项目不规划 macOS。M1 Extension Host 只允许纯 JavaScript，不接受原生 Node addon、插件自带 Node、Python 或任意外部可执行文件。

## 本地加载校验

1. manifest 通过 v1.2 JSON Schema；平台、API、运行时及必需能力兼容。
2. 先复制包或开发目录到宿主管理暂存区；按实际打开的文件校验和复制，拒绝链接条目及设备等特殊文件。所有路径归一化后必须位于包根内，拒绝绝对路径、父目录跳转、重复或大小写冲突路径。只执行校验后的只读快照；源目录后续变化不能改变已授权代码。
3. 入口与 schema 文件存在，schema 引用限制在包内，不自动联网解析 `$ref`。
4. 初始限额：压缩包 50 MiB、解压总量 200 MiB、单文件 32 MiB、5,000 个文件，解包时累计检查并在超限后删除暂存区。对排序后的归一化路径、文件大小和每文件 SHA-256 建立内容清单，再计算整体摘要；摘要算法版本记入安装记录，开发目录采用相同规则。具体编码随加载器契约冻结，不把包摘要写回包内。
5. 解析依赖和服务绑定，拒绝来源冲突、必需依赖环、缺少的必需能力，以及同一插件内重复服务 ID/版本；具体规则见[依赖规范](../插件依赖与能力复用.md)。
6. 用宿主已知权限表校验声明；未知权限拒绝，权限名分别声明，展示缩写不能作为权限。例如 `storage.plugin.read/write` 需拆成 `storage.plugin.read` 与 `storage.plugin.write`。展示文件、数据、服务及通知范围后授权宿主 API。
7. 若包包含 Node.js Extension Host 入口，另行展示代码执行能力、真实来源、摘要和运行时；用户确认插件信任后才能激活。宿主 API 权限不限制插件直接调用 Node.js 或系统 API。

这些检查不能证明插件业务代码无恶意。Electron iframe 由浏览器边界隔离；Node.js Extension Host 采用用户信任模型并具有当前账号权限。签名可留待后续作为来源元数据和信任信号，不自动扩大宿主 API 权限。

## 清单语义

- `manifestVersion: 1.2` 与未冻结的 Host API `platform.v1` 分开标记。
- `publisher` 是可选的作者自述信息，不是经认证身份。
- `connectivity` 为 `offline` 或 `network`，描述网络需求和宿主代理行为。`offline` 不构成对已信任 Node.js Extension Host 的 OS 级断网保证。
- `hostCapabilities.required/optional` 表示运行时功能，不等于数据权限；与 `permissions` 分别检查，两组不得重叠。
- `dependencies` 指向不可替代的插件包；`services.consumes` 面向可替换能力，两者 `optional` 缺省为 false。
- `services.provides` 必须声明版本、参数/结果 schema、效果和 `requiresUI`；`agentCallable` 可选且缺省为 false，只有显式 true 才成为 Agent 模型工具候选。声明不代替宿主对实际调用的授权。
- `notifications.categories` 声明通知类别、默认等级和请求上限；须有 `notification.publish`，请求 critical 还须声明 `notification.critical`。加载器检查类别唯一且默认等级不高于请求上限，用户策略决定实际允许等级。
- 宿主代理不会让离线插件通过必需/可选依赖、服务绑定或事件间接取得代理网络能力；检查整个实际调用链。Node.js 插件直接使用系统网络属于插件信任风险，不能由 manifest 阻断。
- 依赖、服务与扩展 ID 的重复和语义冲突由加载器检查，JSON Schema 不解析 SemVer 范围或依赖图。

当前加载器只接受本规范声明的本地包格式，不自动改写不兼容包。原包如有签名，迁移后需由作者重新生成；当前没有生产版本的兼容承诺。

安装记录使用 discovered → validated → disabled → active；失败进入 failed，重新校验后才能再次激活。插件信任、工作区信任和宿主 API 授权分别保存。停用回到 disabled。摘要、来源或入口变化时撤销插件信任；更新先停止接单，备份旧包及数据，重新确认后切换，迁移失败同时恢复包与数据。发布审核状态不参与本地生命周期。
