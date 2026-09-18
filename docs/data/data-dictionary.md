# 数据字典：本地宿主与插件模型

## 当前本地模型草案

按 [ADR 0008](../adr/0008-solo-developer-delivery-baseline.md)分阶段实现。M1 以插件、服务、资源、Agent 会话和通知为核心；标准归档与完整备份在 M2 完善。下列为逻辑对象，不要求逐个建表。

| 对象 | 关键字段 | 说明 |
|---|---|---|
| LocalWorkspace | id、policy | 本地隔离范围，不依赖组织账号 |
| PluginInstallation | id、workspaceId、pluginId、version、source、digest、state、offlineOnly、dataVersion | 包缓存可复用，运行状态和数据不共享；离线标记随升级/恢复保留 |
| PermissionGrant | workspaceId、caller、operation、resourceScope、purpose、expiresAt、revokedAt | 按调用方和用途授权；恢复时重新批准 |
| ServiceBinding | workspaceId、consumer、serviceId、contractVersion、providerInstallationId、providerDigest、resourceScope | 用户选择并锁定的实现；升级重新检查 |
| ResourceHandle | id、workspaceId、sessionId、recipient、resourceVersion、scope、expiresAt | 短期、可撤销的资源引用；不可作为持久对象主键 |
| LocalTask | id、workspaceId、sessionId、caller、providerInstallationId、state、progress、output、sideEffectStatus | output 符合服务结果 schema，其中资源引用受会话和有效期限制 |
| AgentSession | id、workspaceId、grants、budget、expiresAt | 独立且可撤销的自动化会话 |
| NotificationPolicy | workspaceId、installationId、sourceId、category、maxLevel、allowInterrupt | M1 来源/类别授权，仅宿主可信界面可提高等级 |
| Notification | id、installationId、sourceId、eventId、revision、requestedLevel、effectiveLevel、occurredAt、expiresAt、state、reason | 宿主去重并保存展示/确认/撤回状态，正文受权限限制 |
| Connection（后续） | id、providerInstallationId、configRef、capabilities | 用户配置的连接，拓扑由连接器决定 |

M1 私有存储至少保存插件数据版本和配额；升级快照包含同一安装的包摘要、数据版本、离线约束及内容校验，恢复后生成新运行会话。工作区完整备份的模型见下表及[数据规范](../本地数据与备份恢复.md)。

## 归档与备份模型（M2 完善）

| 对象 | 关键字段 | 说明 |
|---|---|---|
| LocalImport | id、workspaceId、sourceWorkspaceId、sha256、schemaVersion、state、createdAt | 同一工作区同一输入摘要避免重复导入 |
| LocalSourceMap | importId、objectType、sourceId、localId | 来源标识隔离；同 ID 的不同导入不能覆盖 |
| LocalChannel | id、workspaceId、importId、sourceId、type、name | 来源 visibility 仅为元数据，不建立本地权限 |
| LocalMessage | id、workspaceId、channelId、sourceId、authorId、createdAt、body、revision、withdrawn | 保留原记录语义，插件停用不删除 |
| LocalAttachment | id、workspaceId、sha256、size、mediaType、filename、contentState、blobRef | 清单与实际文件分离，缺失内容可明确展示 |
| MessageAttachment | messageId、attachmentId | 双方必须处于同一工作区，导入时校验引用 |
| LocalIndex | workspaceId、sourceId、indexVersion、completeAt | 可重建，未完成时报告搜索覆盖范围 |
| WorkspaceBackup | formatVersion、hostVersion、dataVersion、pluginDataVersions、entries | 条目含安全相对路径、字节数和摘要；不恢复有效授权 |

骨科患者、手术、随访、量表和转换业务数据由对应插件提供独立 schema、迁移和导出策略，宿主只保存通用任务和资源引用。
