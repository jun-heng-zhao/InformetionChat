# 本地插件包格式 v1.2 草案

阶段与宿主原则以 [ADR 0008](../adr/0008-solo-developer-delivery-baseline.md)为准。本规范用于本地加载；不要求账号、发布证书、审核状态或签名服务。

## 内容

插件可从桌面开发目录或 `.plugin.tgz` 包加载：

```text
manifest.json             # 必需
ui/index.html             # 声明 runtime.ui 时必需
ui/assets/*               # 按实际引用提供
worker/component.wasm     # 声明 runtime.worker 时必需
schemas/*.json            # 声明服务时提供输入/输出 schema
LICENSE                   # 开源分发时附带实际许可证
```

完整清单可表达 `runtime.ui` 与本地 `runtime.worker`，至少一项，声明两项时均视为必需。M1 仅激活纯离线 UI 包，Worker 和联网包明确返回能力不可用。Worker 在设备上运行，移动端未验证支持时拒绝依赖它的包。纯 UI 插件不要求 WIT，Worker 要求 `engines.wit`，UI 要求 `engines.uiBridge`。

## 本地加载校验

1. manifest 通过 v1.2 JSON Schema；平台、API、运行时及必需能力兼容。
2. 先复制包或开发目录到宿主管理暂存区；按实际打开的文件校验和复制，拒绝链接条目及设备等特殊文件。所有路径归一化后必须位于包根内，拒绝绝对路径、父目录跳转、重复或大小写冲突路径。只执行校验后的只读快照；源目录后续变化不能改变已授权代码。
3. 入口与 schema 文件存在，schema 引用限制在包内，不自动联网解析 `$ref`。
4. 初始限额：压缩包 50 MiB、解压总量 200 MiB、单文件 32 MiB、5,000 个文件，解包时累计检查并在超限后删除暂存区。对排序后的归一化路径、文件大小和每文件 SHA-256 建立内容清单，再计算整体摘要；摘要算法版本记入安装记录，开发目录采用相同规则。具体编码随加载器契约冻结，不把包摘要写回包内。
5. 解析依赖和服务绑定，拒绝来源冲突、必需依赖环、缺少的必需能力，以及同一插件内重复服务 ID/版本；具体规则见[依赖规范](../插件依赖与能力复用.md)。
6. 用宿主已知权限表校验声明；未知权限拒绝，权限名分别声明，展示缩写不能作为权限。例如 `storage.plugin.read/write` 需拆成 `storage.plugin.read` 与 `storage.plugin.write`。展示文件、数据、服务及通知范围后授权激活；M1 不接受网络权限。

这些检查不能证明插件业务代码无恶意，实际访问仍由运行时隔离。签名可留待后续作为独立来源元数据，不作为当前安装资格，也不能赋予额外权限。

## 清单语义

- `manifestVersion: 1.2` 与未冻结的 Host API `platform.v1` 分开标记。
- `publisher` 是可选的作者自述信息，不是经认证身份。
- `connectivity` 为 `offline` 或 `network`，描述网络需求，不限制中心化、联邦或去中心化协议。
- `hostCapabilities.required/optional` 表示运行时功能，不等于数据权限；与 `permissions` 分别检查，两组不得重叠。
- `dependencies` 指向不可替代的插件包；`services.consumes` 面向可替换能力，两者 `optional` 缺省为 false。
- `services.provides` 必须声明版本、参数/结果 schema、效果、`agentCallable` 和 `requiresUI`；声明不代替宿主对实际调用的授权。
- `notifications.categories` 声明通知类别、默认等级和请求上限；须有 `notification.publish`，请求 critical 还须声明 `notification.critical`。加载器检查类别唯一且默认等级不高于请求上限，用户策略决定实际允许等级。
- 离线插件不能通过必需/可选依赖、服务绑定、事件或后续升级绕过联网限制；检查整个实际调用链。已有离线安装不能原地获得网络出口。
- 依赖、服务与扩展 ID 的重复和语义冲突由加载器检查，JSON Schema 不解析 SemVer 范围或依赖图。

当前加载器只接受本规范声明的本地包格式，不自动改写不兼容包。原包如有签名，迁移后需由作者重新生成；当前没有生产版本的兼容承诺。

安装记录使用 discovered → validated → disabled → active；失败进入 failed，重新校验后才能再次激活。停用回到 disabled。更新先停止接单，备份旧包及数据，迁移成功后切换；失败同时恢复包与数据，恢复失败则保持停用并保留快照。发布审核状态不参与本地生命周期。
