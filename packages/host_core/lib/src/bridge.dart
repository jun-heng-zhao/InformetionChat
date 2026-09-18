// 文件职责：host.* 方法分发器——把受信通道绑定的调用方身份映射到宿主能力
// 依据：docs/contracts/plugin-ui-jsonrpc.md（M1 必需接口）与 docs/contracts/agent-api.md

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'errors.dart';
import 'host.dart';
import 'manifest.dart';
import 'notifications.dart';
import 'resources.dart';

/// 通道绑定上下文：调用方身份、工作区与运行会话由宿主保存，报文自报的 ID 一律无效
class CallerSession {
  final String callerId;                 // 插件安装 ID 或 agent:<sessionId>
  final String kind;                     // plugin / agent
  final String workspaceId;              // 绑定的工作区
  final String sessionId;                // 运行会话，句柄与任务都绑在它上面
  final Set<String> capabilities;        // 握手时批准的宿主能力，用于回归检查

  const CallerSession({
    required this.callerId,
    required this.kind,
    required this.workspaceId,
    required this.sessionId,
    this.capabilities = const {},
  });
}

/// 分发器：实现 M1 必需接口，未实现的方法明确返回 CAPABILITY_UNAVAILABLE
class BridgeDispatcher {
  static const uiBridgeVersion = '1.2';  // 当前草案版本，握手时回给插件

  final LocalHost host;                  // 宿主本体
  final Map<String, CallerSession> _sessions = {}; // 通道 ID → 会话上下文
  int _sessionSeq = 0;                   // 会话序号

  BridgeDispatcher(this.host);

  /// 建立通道绑定并返回会话；真实实现由宿主在创建通道时调用
  CallerSession bindChannel({required String callerId, required String kind, Set<String> capabilities = const {}}) {
    final session = CallerSession(
      callerId: callerId,
      kind: kind,
      workspaceId: host.workspaceId,
      sessionId: '${kind == 'agent' ? 'agent' : 'plugin'}-s${++_sessionSeq}',
      capabilities: capabilities,
    );
    _sessions[session.sessionId] = session;
    return session;
  }

  /// 通道关闭：撤销句柄与任务，使旧会话恢复不了旧授权
  void closeChannel(String sessionId) {
    host.resources.revokeAll(sessionId: sessionId);
    host.tasks.cancelAllOf(sessionId);
    _sessions.remove(sessionId);
  }

  /// 会话查询，供演示与宿主界面展示
  CallerSession? sessionOf(String sessionId) => _sessions[sessionId];

  /// 统一入口：按调用方身份与运行时分配去处理
  Future<Object?> handle(String sessionId, String method, Map<String, Object?> params) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw HostException(ErrorCode.denied, '通道未绑定或已关闭：$sessionId');
    }
    switch (method) {
      case 'host.handshake':
        return _handshake(session, params);
      case 'host.context.get':
        return _context(session);
      case 'host.storage.get':
        return {'found': host.storageGet(session.callerId, '${params['key']}').found,
                'value': host.storageGet(session.callerId, '${params['key']}').value};
      case 'host.storage.set':
        host.storageSet(session.callerId, '${params['key']}', params['value']);
        return {'ok': true};
      case 'host.file.pick':
        return _filePick(session, params);
      case 'host.file.read':
      case 'host.resource.read':
        return _read(session, params);
      case 'host.file.save':
        return _fileSave(session, params);
      case 'host.resource.create':
        return _resourceCreate(session, params);
      case 'host.resource.list':
        return _resourceList(session, params);
      case 'host.service.discover':
        return _serviceDiscover(session, params);
      case 'host.service.describe':
        return _serviceDescribe(session, params);
      case 'host.service.call':
        return _serviceCall(session, params);
      case 'host.binding.get':
        return _bindingGet(session, params);
      case 'host.task.get':
        return _taskGet(session, params);
      case 'host.task.cancel':
        return _taskCancel(session, params);
      case 'host.notification.publish':
      case 'host.notification.update':
        return _notificationPublish(session, params);
      case 'host.notification.withdraw':
        return _notificationWithdraw(session, params);
      case 'host.notification.list':
        return _notificationList(session);
      case 'host.notification.get':
        return _notificationGet(session, params);
      case 'host.notification.policy.get':
        return _notificationPolicy(session, params);
      case 'host.notification.acknowledge':
        throw HostException.denied('确认通知只由可信宿主界面完成，插件与 Agent 无代确认权限');
      case 'host.event.subscribe':
      case 'host.event.unsubscribe':
      case 'host.event.publish':
      case 'host.operation.prepare':
      case 'host.operation.execute':
      case 'host.access.request':
      case 'host.trace.get':
      case 'host.search.query':
      case 'host.plugin.list':
      case 'host.binding.plan':
      case 'host.command.execute':
        throw HostException.unavailable('$method 属于后续阶段接口，M1 未实现');
      default:
        throw MethodNotFoundException(method);
    }
  }

  /// 握手：返回协议版本、平台、已批准能力与预算，不返回令牌或原生路径
  Map<String, Object?> _handshake(CallerSession session, Map<String, Object?> params) {
    final requested = (params['requestedCapabilities'] as List?)?.map((e) => '$e').toSet() ?? const <String>{};
    return {
      'uiBridge': uiBridgeVersion,
      'platform': 'linux',
      'kind': session.kind,
      'workspaceId': session.workspaceId,
      'sessionId': session.sessionId,
      'grantedCapabilities': requested.toList(),
      'budget': {'messageBytes': 1024 * 1024, 'callSeconds': 30, 'concurrencyPerInstall': 4, 'callDepth': 4},
      'resultRetentionSeconds': 600,
    };
  }

  /// 上下文查询：只返回调用方自身可见的信息
  Map<String, Object?> _context(CallerSession session) => {
    'workspaceId': session.workspaceId,
    'sessionId': session.sessionId,
    'callerId': session.callerId,
    'kind': session.kind,
    'uiBridge': uiBridgeVersion,
    'offlineOnly': true,
  };

  /// 文件选择：用户取消返回 CANCELLED，成功返回短期只读句柄
  Future<Object?> _filePick(CallerSession session, Map<String, Object?> params) async {
    host.permissions.require(
      workspaceId: session.workspaceId,
      caller: session.callerId,
      operation: 'file.pick',
    );
    final handle = await host.pickInput(
      callerId: session.callerId,
      sessionId: session.sessionId,
      purpose: '${params['purpose'] ?? ''}',
    );
    if (handle == null) throw const HostException(ErrorCode.cancelled, '用户取消了文件选择');
    return _handleSummary(handle);
  }

  /// 读取：每次读取都重新校验会话、接收者与范围
  Object? _read(CallerSession session, Map<String, Object?> params) {
    final handleId = '${params['handle']}';
    // 权限按具体句柄范围申请，避免一次 file.read 授权覆盖任意资源
    host.permissions.require(
      workspaceId: session.workspaceId,
      caller: session.callerId,
      operation: 'file.read',
      scope: 'resource:$handleId',
    );
    final result = host.resources.read(
      handleId: handleId,
      recipient: session.callerId,
      workspaceId: session.workspaceId,
      offset: (params['offset'] as num?)?.toInt() ?? 0,
      length: (params['length'] as num?)?.toInt(),
    );
    return {
      'bytes': base64Encode(result.bytes),
      'nextOffset': result.nextOffset,
      'eof': result.eof,
    };
  }

  /// 保存：只接受已授权的结果句柄，输出位置由宿主决定，不回传原生路径
  Future<Object?> _fileSave(CallerSession session, Map<String, Object?> params) async {
    host.permissions.require(workspaceId: session.workspaceId, caller: session.callerId, operation: 'file.save');
    final handle = host.resources.describe(
      handleId: '${params['handle']}',
      recipient: session.callerId,
      workspaceId: session.workspaceId,
    );
    final suggested = '${params['suggestedName'] ?? handle.name}';
    final saved = await host.saveHandler?.call(session.callerId, suggested, handle.bytes);
    if (saved == null) throw const HostException(ErrorCode.cancelled, '用户取消了输出位置选择');
    return {'saved': true, 'label': saved};
  }

  /// 创建临时结果：独立权限，创建不等于可以读取
  Object? _resourceCreate(CallerSession session, Map<String, Object?> params) {
    host.permissions.require(
      workspaceId: session.workspaceId,
      caller: session.callerId,
      operation: 'resource.create',
    );
    final handle = host.resources.issue(
      workspaceId: session.workspaceId,
      sessionId: session.sessionId,
      owner: session.callerId,
      recipient: session.callerId,
      draft: ResourceDraft(
        name: '${params['name'] ?? 'temp-result'}',
        mediaType: '${params['mediaType'] ?? 'application/octet-stream'}',
        bytes: Uint8List.fromList(base64Decode('${params['base64'] ?? ''}')),
        kind: ResourceKind.tempResult,
      ),
    );
    return _handleSummary(handle);
  }

  /// 列出当前会话已授权的资源摘要
  Object? _resourceList(CallerSession session, Map<String, Object?> params) {
    host.permissions.require(workspaceId: session.workspaceId, caller: session.callerId, operation: 'file.read');
    final limit = (params['limit'] as num?)?.toInt() ?? 50;
    final items = host.resources
        .list(recipient: session.callerId, workspaceId: session.workspaceId)
        .take(limit)
        .map((h) => _handleSummary(h))
        .toList();
    return {'items': items, 'nextCursor': null};
  }

  /// 服务发现：只返回摘要，不暴露提供者私有对象
  Object? _serviceDiscover(CallerSession session, Map<String, Object?> params) {
    final serviceId = '${params['service'] ?? ''}';
    final candidates = host.services.discover(
      serviceId: serviceId,
      versionRange: '${params['versionRange'] ?? '*'}',
      agentCallableOnly: session.kind == 'agent',
    );
    return {
      'service': serviceId,
      'candidates': candidates
          .map((e) => {'providerInstallationId': e.installationId, 'version': e.version, 'pluginId': e.pluginId})
          .toList(),
      'selectionRequired': candidates.isNotEmpty &&
          host.services.bindingOf(
                workspaceId: session.workspaceId,
                consumer: session.callerId,
                serviceId: serviceId,
              ) ==
              null,
    };
  }

  /// 服务描述：返回确定版本的 schema、效果与可用性
  Object? _serviceDescribe(CallerSession session, Map<String, Object?> params) {
    final serviceId = '${params['service']}';
    final version = params['version'] as String?;
    final entry = version != null
        ? host.services.describe(serviceId: serviceId, version: version)
        : host.services
            .discover(serviceId: serviceId, agentCallableOnly: session.kind == 'agent')
            .firstOrNull;
    if (entry == null) {
      throw HostException(ErrorCode.providerUnavailable, '找不到可用提供者：$serviceId${version == null ? '' : '@$version'}');
    }
    if (session.kind == 'agent' && !entry.agentCallable) {
      throw HostException(ErrorCode.denied, '服务 $serviceId 未声明 agentCallable');
    }
    return entry.describe();
  }

  /// 服务调用：M1 统一异步，立即返回 taskId
  Future<Object?> _serviceCall(CallerSession session, Map<String, Object?> params) async {
    final input = (params['input'] as Map?)?.cast<String, Object?>();
    if (input == null) throw const HostException(ErrorCode.contractMismatch, '缺少 input 参数');
    final task = await host.callService(
      callerId: session.callerId,
      sessionId: session.sessionId,
      serviceId: '${params['service']}',
      versionRange: '${params['versionRange'] ?? '*'}',
      input: input,
      agentSession: session.kind == 'agent',
    );
    return {'taskId': task.id, 'state': task.state};
  }

  /// 绑定查询：缺失时返回 PROVIDER_SELECTION_REQUIRED
  Object? _bindingGet(CallerSession session, Map<String, Object?> params) {
    final serviceId = '${params['service']}';
    final binding = host.services.requireBinding(
      workspaceId: session.workspaceId,
      consumer: session.callerId,
      serviceId: serviceId,
    );
    return {
      'service': serviceId,
      'contractVersion': binding.contractVersion,
      'providerInstallationId': binding.providerInstallationId,
      'providerDigest': binding.providerDigest,
    };
  }

  /// 任务查询：跨会话的 taskId 一律不可见
  Object? _taskGet(CallerSession session, Map<String, Object?> params) => host.tasks
      .get(
        taskId: '${params['taskId']}',
        workspaceId: session.workspaceId,
        sessionId: session.sessionId,
      )
      .toJson();

  /// 任务取消：返回"取消请求是否被接受"，终态仍需重新查询
  Object? _taskCancel(CallerSession session, Map<String, Object?> params) {
    final task = host.tasks.get(
      taskId: '${params['taskId']}',
      workspaceId: session.workspaceId,
      sessionId: session.sessionId,
    );
    host.permissions.require(workspaceId: session.workspaceId, caller: session.callerId, operation: 'task.cancel');
    final providerInstall = task.providerInstallationId;
    final accepted = host.tasks.cancel(task);
    // 把取消传播给提供者，避免只停止等待而让插件代码继续工作
    host.runtimeOf(providerInstall)?.notify('plugin.task.cancel', {'callId': task.callId});
    return {'accepted': accepted, 'state': task.state};
  }

  /// 通知发布与更新：等级与状态由通知引擎计算
  Object? _notificationPublish(CallerSession session, Map<String, Object?> params) {
    host.permissions.require(workspaceId: session.workspaceId, caller: session.callerId, operation: 'notification.publish');
    final installation = host.installs[session.callerId];
    if (installation == null) throw HostException(ErrorCode.notFound, '安装不存在：${session.callerId}');
    final expRaw = params['expiresAt'] as String?;
    final result = host.notifications.publish(
      NotifyRequest(
        installationId: session.callerId,
        // 来源 ID 取自安装记录，忽略报文里的自报值，防止插件冒充其他来源
        sourceId: installation.sourceId,
        category: '${params['category']}',
        eventId: '${params['eventId']}',
        revision: (params['revision'] as num?)?.toInt() ?? 1,
        requestedLevel: '${params['requestedLevel'] ?? NotifyLevel.normal}',
        title: '${params['title'] ?? ''}',
        body: '${params['body'] ?? ''}',
        occurredAt: DateTime.tryParse('${params['occurredAt']}') ?? DateTime.now(),
        expiresAt: expRaw == null ? null : DateTime.tryParse(expRaw),
        actionCount: (params['actions'] as List?)?.length ?? 0,
      ),
      workspaceId: session.workspaceId,
      hasPublishPermission: true,
      hasCriticalPermission: host.permissions.allows(
        workspaceId: session.workspaceId,
        caller: session.callerId,
        operation: 'notification.critical',
      ),
      declaredCategories: installation.manifest.categories,
    );
    return {
      'notificationId': result.notification.id,
      'effectiveLevel': result.notification.effectiveLevel,
      'state': result.notification.state,
      'shouldPopup': result.shouldPopup,
      if (result.notification.reason != null) 'reason': result.notification.reason,
    };
  }

  /// 撤回：需要更高修订
  Object? _notificationWithdraw(CallerSession session, Map<String, Object?> params) {
    host.permissions.require(workspaceId: session.workspaceId, caller: session.callerId, operation: 'notification.publish');
    final installation = host.installs[session.callerId];
    if (installation == null) throw HostException(ErrorCode.notFound, '安装不存在：${session.callerId}');
    final n = host.notifications.withdraw(
      workspaceId: session.workspaceId,
      installationId: session.callerId,
      sourceId: installation.sourceId,
      eventId: '${params['eventId']}',
      revision: (params['revision'] as num?)?.toInt() ?? 1,
    );
    return {'notificationId': n.id, 'state': n.state};
  }

  /// 列出本调用方可见的通知
  Object? _notificationList(CallerSession session) => {
    'items': host.notifications
        .list(workspaceId: session.workspaceId, installationId: session.callerId)
        .map((n) => n.toJson())
        .toList(),
  };

  /// 按 ID 查询单条通知
  Object? _notificationGet(CallerSession session, Map<String, Object?> params) {
    final target = host.notifications
        .list(workspaceId: session.workspaceId, installationId: session.callerId)
        .where((n) => n.id == '${params['notificationId']}')
        .firstOrNull;
    if (target == null) throw HostException(ErrorCode.notFound, '通知不可见：${params['notificationId']}');
    return target.toJson();
  }

  /// 通知策略查询：返回实际允许等级与前台能力
  Object? _notificationPolicy(CallerSession session, Map<String, Object?> params) {
    final installation = host.installs[session.callerId];
    if (installation == null) throw HostException(ErrorCode.notFound, '安装不存在：${session.callerId}');
    final policy = host.notifications.policyOf(
      workspaceId: session.workspaceId,
      installationId: session.callerId,
      sourceId: installation.sourceId,
      category: '${params['category']}',
    );
    return {
      'granted': policy != null,
      'maxLevel': policy?.maxLevel ?? NotifyLevel.normal,
      'allowInterrupt': policy?.allowInterrupt ?? false,
      'foreground': host.notifications.foreground,
      'platformCapability': 'foreground-popup',
    };
  }

  /// 句柄摘要：对外只暴露句柄 ID 与元信息，不含原生路径
  Map<String, Object?> _handleSummary(ResourceHandle h) => {
    'handle': h.id,
    'name': h.name,
    'mediaType': h.mediaType,
    'size': h.size,
    'version': h.version,
    'expiresAt': h.expiresAt?.toUtc().toIso8601String(),
  };
}
