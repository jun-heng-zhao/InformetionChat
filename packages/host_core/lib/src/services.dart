// 文件职责：服务注册表与提供者绑定——插件互通和能力复用的中枢
// 依据：docs/插件依赖与能力复用.md 第 3 节、docs/contracts/plugin-ui-jsonrpc.md

import 'errors.dart';
import 'manifest.dart';
import 'version.dart';

/// 提供者候选：由宿主从 manifest 读取并校验 schema 后创建，声明不等于已授权
class ProviderEntry {
  final String installationId;           // 提供者安装 ID，调用时锁定的身份
  final String pluginId;                 // 自述 ID，仅用于展示
  final String providerDigest;           // 提供者包摘要，升级即视为不同实现
  final ProvidedService declaration;     // 清单中的服务声明
  final Map<String, Object?> inputSchema;  // 已解析的输入 schema
  final Map<String, Object?> outputSchema; // 已解析的输出 schema
  String availability;                   // ready / stopping / stopped

  ProviderEntry({
    required this.installationId,
    required this.pluginId,
    required this.providerDigest,
    required this.declaration,
    required this.inputSchema,
    required this.outputSchema,
    this.availability = 'ready',
  });

  String get serviceId => declaration.id;   // 服务 ID
  String get version => declaration.version; // 接口版本
  bool get agentCallable => declaration.agentCallable; // 是否允许被 Agent 会话调用

  /// 对外暴露的描述对象，字段与 Agent 契约第 3 节的 describe 结果一致
  Map<String, Object?> describe({String? providerInstallationId}) => {
    'service': serviceId,
    'version': version,
    'providerInstallationId': providerInstallationId ?? installationId,
    'providerPluginId': pluginId,
    'providerDigest': providerDigest,
    'description': '${declaration.id} 由插件 $pluginId 提供',
    'inputSchema': inputSchema,
    'outputSchema': outputSchema,
    'effects': declaration.effects,
    'agentCallable': declaration.agentCallable,
    'requiresUI': declaration.requiresUI,
    'availability': availability,
  };
}

/// 服务绑定：用户为某消费方选定并锁定的实现，新安装不得抢占
class ServiceBinding {
  final String workspaceId;              // 所属工作区
  final String consumer;                 // 消费方安装 ID 或 agent 会话 ID
  final String serviceId;                // 服务 ID
  final String contractVersion;          // 锁定的接口版本
  final String providerInstallationId;   // 锁定的提供者安装
  final String providerDigest;           // 锁定的提供者摘要
  final String resourceScope;            // 允许传递的数据范围

  const ServiceBinding({
    required this.workspaceId,
    required this.consumer,
    required this.serviceId,
    required this.contractVersion,
    required this.providerInstallationId,
    required this.providerDigest,
    this.resourceScope = 'workspace',
  });
}

/// 服务注册表：候选注册、发现过滤、绑定查询与变更
class ServiceRegistry {
  final List<ProviderEntry> _providers = [];   // 全部候选与已就绪提供者
  final List<ServiceBinding> _bindings = [];   // 用户确认过的绑定

  /// 注册提供者；同一安装内重复服务 ID/版本在清单层已被拒绝，这里只做兜底
  void register(ProviderEntry entry) {
    final dup = _providers.any((e) => e.installationId == entry.installationId &&
        e.serviceId == entry.serviceId && e.version == entry.version);
    if (dup) {
      throw HostException(ErrorCode.contractMismatch, '重复注册提供者：${entry.serviceId}@${entry.version}');
    }
    _providers.add(entry);
  }

  /// 按服务 ID 与版本范围发现可用提供者；不返回其他安装的私有对象
  List<ProviderEntry> discover({required String serviceId, String versionRange = '*', bool agentCallableOnly = false}) {
    final range = VersionRange.parse(versionRange);
    return _providers.where((e) {
      if (e.serviceId != serviceId) return false;      // 只匹配目标服务
      if (e.availability != 'ready') return false;     // 停用中的提供者不参与
      if (!range.allows(e.version)) return false;      // 接口版本必须落在消费方声明范围内
      if (agentCallableOnly && !e.agentCallable) return false; // Agent 会话只看见 agentCallable 的服务
      return true;
    }).toList();
  }

  /// 描述某个确定版本的服务；不存在时返回 null 由调用方决定错误语义
  ProviderEntry? describe({required String serviceId, required String version}) {
    for (final e in _providers) {
      if (e.serviceId == serviceId && e.version == version) return e;
    }
    return null;
  }

  /// 查询绑定；缺失时抛 PROVIDER_SELECTION_REQUIRED 并附候选摘要
  ServiceBinding requireBinding({required String workspaceId, required String consumer, required String serviceId}) {
    for (final b in _bindings) {
      if (b.workspaceId == workspaceId && b.consumer == consumer && b.serviceId == serviceId) return b;
    }
    final candidates = discover(serviceId: serviceId);
    throw HostException(
      ErrorCode.providerSelectionRequired,
      '服务 $serviceId 尚未为 $consumer 绑定提供者',
      detail: {'candidates': candidates.map((e) => {'installationId': e.installationId, 'version': e.version}).toList()},
    );
  }

  /// 只查询不抛异常的绑定查询，供 host.binding.get 使用
  ServiceBinding? bindingOf({required String workspaceId, required String consumer, required String serviceId}) {
    for (final b in _bindings) {
      if (b.workspaceId == workspaceId && b.consumer == consumer && b.serviceId == serviceId) return b;
    }
    return null;
  }

  /// 建立绑定；同一消费方同一服务已有绑定时不覆盖，避免新安装抢占默认提供者
  ServiceBinding bind(ServiceBinding binding) {
    final existing = bindingOf(
      workspaceId: binding.workspaceId,
      consumer: binding.consumer,
      serviceId: binding.serviceId,
    );
    if (existing != null) return existing;
    _bindings.add(binding);
    return binding;
  }

  /// 提供者停用：标记不可用，但保留绑定，调用时报 PROVIDER_UNAVAILABLE 而不是偷偷换实现
  void stopProvider(String installationId) {
    for (final e in _providers) {
      if (e.installationId == installationId) e.availability = 'stopped';
    }
  }

  /// 按安装移除注册的提供者，返回移除条数
  int removeProviderOf(String installationId) {
    final before = _providers.length;
    _providers.removeWhere((e) => e.installationId == installationId);
    return before - _providers.length;
  }

  /// 当前已注册提供者快照，便于诊断与演示输出
  List<ProviderEntry> get providers => List.unmodifiable(_providers);
}
