# 本地插件权限矩阵 v1.2 草案

所有插件使用相同规则。声明能力不等于已经授权；随包模块同样接受运行时检查。表中斜线是展示缩写，清单需分别写出完整权限名，例如 `storage.plugin.read` 和 `storage.plugin.write`。未知权限在激活时拒绝，不能静默赋予或把组合字符串当成通配符。M1 的 Agent 只使用预授权服务和资源；网络、通用事件及计划管理按阶段开放。

| 能力 | 授权范围 |
|---|---|
| `workspace.read` | 当前工作区非敏感上下文 |
| `storage.plugin.read/write` | 当前工作区、当前安装命名空间 |
| `file.pick` / `file.read` / `file.save` | 用户选择的输入或确认的输出，使用短期句柄 |
| `chat.search` / `chat.export` | 用户授权的会话与字段范围，不能因有插件安装权就读取全部内容 |
| `resource.create` | 在配额内创建当前安装或调用的临时结果，不允许写入任意路径 |
| `object.ref.read` / `attachment.metadata.read` | 当前授权资源引用或附件元数据 |
| `command.register/execute` | 只能注册清单命令；执行逐次检查，不能绕过服务授权 |
| `service.call` | 清单消费声明、提供者绑定、数据用途和传递范围共同限制 |
| `event.subscribe/publish` | 清单声明的主题；工作区、订阅者和正文访问分别检查 |
| `task.create/update/cancel` | 自身任务或受控调用链，取消向子调用传播 |
| `network.allowlisted` | 用户同意的目标与用途；离线插件无此权限 |
| `audit.append` | 追加自身诊断，真实调用身份由宿主补全 |
| `notification.publish` | 提交已登记类别的提醒，宿主决定实际展示等级 |
| `notification.read` | 查看自己发出的通知或用户授权的其他通知，正文仍受数据范围限制 |
| `notification.critical` | 用户为指定来源开启紧急弹窗；不赋予操作系统关键提醒权限 |
| `notification.acknowledge` | 代用户确认提醒需独立授权，普通插件/Agent 不默认获得 |

授权身份由受信通道绑定，不能相信插件消息中的工作区或用户 ID。跨插件传递为接收方派生更窄的资源句柄，不转发万能 token。停用、重启和工作区切换使旧会话句柄失效。

未签名包可以在本地授权加载；签名或作者身份不会扩大权限。组织 RBAC、平台账号和发布审批不属于当前阶段。
