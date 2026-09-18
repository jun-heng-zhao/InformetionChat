// 文件职责：宿主本体——组装加载器、权限、资源、服务、任务与通知，并编排一次跨插件调用
// 对应 docs/本地插件隔离与互通.md 第 3 节"一次调用的流程"

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'loader.dart';
import 'manifest.dart';
import 'notifications.dart';
import 'resources.dart';
import 'runtime.dart';
import 'services.dart';
import 'tasks.dart';
import 'version.dart';
import 'workspace.dart';

/// 用户选择的一份输入；演示中由回调提供，正式版来自系统文件选择器
class PickedInput {
  final String name;                     // 文件名，仅供展示
  final String mediaType;                // MIME 类型
  final Uint8List bytes;                 // 内容

  const PickedInput({required this.name, required this.mediaType, required this.bytes});
}

/// 输入选择回调：返回 null 表示用户取消（对应 CANCELLED）
typedef InputPicker = Future<PickedInput?> Function(String callerId, String purpose);

/// 输出保存回调：返回保存位置描述，null 表示用户取消
typedef SaveHandler = Future<String?> Function(String callerId, String suggestedName, Uint8List bytes);

/// 插件运行时工厂：把已激活安装转成可调用的运行时，便于替换成 WebView 实现
typedef RuntimeFactory = PluginRuntime Function(PluginInstallation installation, HostCallHandler hostCallBack);

/// 本地宿主：M1 全部能力的唯一入口，所有调用都必须经过它校验身份与权限
class LocalHost {
  static const demoMaxInputBytes = 512 * 1024; // 演示输入上限 512 KiB

  final String workspaceId;              // 当前工作区 ID
  final PackageLoader loader;            // 包加载器
  final PermissionBroker permissions = PermissionBroker(); // 授权表
  final ResourceRegistry resources = ResourceRegistry();   // 资源句柄表
  final ServiceRegistry services = ServiceRegistry();      // 服务注册表
  final TaskManager tasks = TaskManager();                 // 任务管理
  final NotificationEngine notifications = NotificationEngine(); // 通知引擎
  final Map<String, PluginInstallation> installs = {};     // 安装 ID → 安装记录
  final Map<String, PluginRuntime> _runtimes = {};         // 安装 ID → 运行中的插件运行时
  final Map<String, Map<String, Object?>> _storage = {};   // "工作区/安装" → 插件私有存储
  final RuntimeFactory runtimeFactory;   // 运行时工厂，测试与演示可注入替身

  InputPicker? inputPicker;              // 输入选择回调，未设置时 file.pick 返回 CANCELLED
  SaveHandler? saveHandler;              // 输出保存回调，未设置时 file.save 返回 CANCELLED
  HostCallHandler? hostCallHandler;      // host.* 方法处理入口，由 BridgeDispatcher 在装配阶段注入
  int _lastRevokedCount = 0;             // 最近一次停用撤销的授权条数，供演示输出

  LocalHost({
    required this.workspaceId,
    required this.loader,
    required this.runtimeFactory,
  });

  /// 加载并激活一个插件：校验 → 暂存 → 用户授权 → 注册服务 → 启动运行时
  ///
  /// [criticalCategories] 是用户在宿主界面明确开启紧急弹窗的类别；未列出的类别只能到默认等级。
  Future<PluginInstallation> install({
    required Directory sourceDir,
    required String installationId,
    required List<String> grantedPermissions,
    Set<String> criticalCategories = const {},
  }) async {
    // 1. 校验与暂存：源目录先复制成只读快照，后续变化不影响已授权代码
    final package = await loader.stage(sourceDir);
    final manifest = package.manifest;
    if (!manifest.platforms.contains('linux')) {
      throw HostException(ErrorCode.unavailable, '插件未声明支持当前平台 linux：${manifest.id}');
    }

    // 2. 授权范围必须是清单声明权限的子集，不能凭空扩大
    for (final p in grantedPermissions) {
      if (!manifest.permissions.contains(p)) {
        throw HostException(ErrorCode.denied, '授权项未在清单中声明：$p');
      }
    }

    // 3. 依赖解析：只认本地已安装候选，缺必需依赖直接拒绝
    for (final dep in manifest.dependencies) {
      if (dep.optional) continue;
      final candidates = installs.values.where((i) => i.pluginId == dep.id && i.state == InstallState.active);
      if (candidates.isEmpty) {
        throw HostException(ErrorCode.unavailable, '缺少必需依赖：${dep.id} ${dep.versionRange}');
      }
    }

    final installation = PluginInstallation(
      id: installationId,
      workspaceId: workspaceId,
      pluginId: manifest.id,
      version: manifest.version,
      sourceLabel: sourceDir.path,
      digest: package.digest,
      package: package,
      state: InstallState.active,
      grantedPermissions: grantedPermissions,
    );
    installs[installationId] = installation;

    // 4. 授予清单内的数据权限；服务调用权限单独授予，避免"装了就全放行"
    for (final p in grantedPermissions) {
      permissions.grant(PermissionGrant(
        workspaceId: workspaceId,
        caller: installationId,
        operation: p,
        purpose: '安装 ${manifest.id} 时用户授权',
      ));
    }

    // 5. 注册服务候选并解析 schema，供其他插件发现
    for (final svc in manifest.provides) {
      services.register(ProviderEntry(
        installationId: installationId,
        pluginId: manifest.id,
        providerDigest: package.digest,
        declaration: svc,
        inputSchema: jsonDecode(await package.file(svc.inputSchemaPath!).readAsString()) as Map<String, Object?>,
        outputSchema: jsonDecode(await package.file(svc.outputSchemaPath!).readAsString()) as Map<String, Object?>,
      ));
    }

    // 6. 通知策略由用户在宿主界面为具体来源开启：默认上限为 normal，
    //    只有用户明确开启紧急弹窗的类别才放宽到该类别声明的上限
    for (final category in manifest.categories) {
      final allowCritical = criticalCategories.contains(category.id);
      notifications.setPolicy(NotificationPolicy(
        workspaceId: workspaceId,
        installationId: installationId,
        sourceId: installation.sourceId,
        category: category.id,
        maxLevel: allowCritical ? category.requestedMaxLevel : NotifyLevel.normal,
        allowInterrupt: allowCritical,
      ));
    }

    // 7. 启动运行时；插件代码不进入宿主进程
    final runtime = runtimeFactory(installation, handleHostCall);
    await runtime.start();
    _runtimes[installationId] = runtime;

    // 8. 通知插件已激活，提供者在此之后才对外可用
    await runtime.call('plugin.activate', {
      'installationId': installationId,
      'workspaceId': workspaceId,
      'grantedPermissions': grantedPermissions,
      'offlineOnly': true,
    });
    return installation;
  }

  /// 停用安装：停止接单 → 撤销授权与句柄 → 取消任务 → 关闭运行时 → 保留数据
  Future<bool> deactivate(String installationId) async {
    final installation = installs[installationId];
    if (installation == null) throw HostException(ErrorCode.notFound, '安装不存在：$installationId');
    services.stopProvider(installationId);
    final revoked = permissions.revokeAllOf(installationId);
    resources.revokeAll(owner: installationId);
    resources.revokeAll(recipient: installationId);
    tasks.cancelAllOf(installationId);
    notifications.revokeSource(workspaceId: workspaceId, installationId: installationId);
    final forced = await _runtimes.remove(installationId)?.dispose() ?? false;
    installation.state = InstallState.disabled;
    _lastRevokedCount = revoked;
    return forced;
  }

  /// 最近一次停用撤销的授权条数
  int get lastRevokedGrantCount => _lastRevokedCount;

  /// 卸载：移除服务注册并删除安装记录，数据按需另行清理
  void uninstall(String installationId) {
    services.removeProviderOf(installationId);
    installs.remove(installationId);
    _runtimes.remove(installationId)?.dispose();
  }

  /// 插件私有存储读取；按工作区+安装命名空间隔离，不接受命名空间参数
  ({bool found, Object? value}) storageGet(String installationId, String key) {
    final map = _storage[_storageKey(installationId)];
    if (map == null || !map.containsKey(key)) return (found: false, value: null);
    return (found: true, value: map[key]);
  }

  /// 插件私有存储写入，超出配额直接拒绝
  void storageSet(String installationId, String key, Object? value) {
    final map = _storage.putIfAbsent(_storageKey(installationId), () => {});
    final encoded = jsonEncode(value);
    if (encoded.length > 64 * 1024) {
      throw const HostException(ErrorCode.resourceLimit, '存储单项超过 64 KiB 上限');
    }
    map[key] = value;
  }

  String _storageKey(String installationId) => '$workspaceId/$installationId';

  /// 用户选择一份输入并签发只读句柄；用户取消时返回 null
  Future<ResourceHandle?> pickInput({required String callerId, required String sessionId, String purpose = ''}) async {
    final picked = await inputPicker?.call(callerId, purpose);
    if (picked == null) return null;
    if (picked.bytes.length > demoMaxInputBytes) {
      throw HostException(ErrorCode.resourceLimit, '演示输入超过 ${demoMaxInputBytes ~/ 1024} KiB 上限');
    }
    return resources.issue(
      workspaceId: workspaceId,
      sessionId: sessionId,
      owner: callerId,
      recipient: callerId,
      draft: ResourceDraft(
        name: picked.name,
        mediaType: picked.mediaType,
        bytes: picked.bytes,
        kind: ResourceKind.input,
        writable: false,
        ttl: const Duration(minutes: 30),
      ),
    );
  }

  /// 一次跨插件服务调用：校验权限与绑定 → 派生句柄 → 创建任务 → 转发给提供者
  Future<LocalTask> callService({
    required String callerId,
    required String sessionId,
    required String serviceId,
    required String versionRange,
    required Map<String, Object?> input,
    bool agentSession = false,
    String? purposeScope,
  }) async {
    // 1. 调用权限：越权直接拒绝，不降级
    permissions.require(workspaceId: workspaceId, caller: callerId, operation: 'service.call');

    // 2. 绑定查找：没有绑定就报 PROVIDER_SELECTION_REQUIRED，由用户在宿主界面选择
    final binding = services.requireBinding(workspaceId: workspaceId, consumer: callerId, serviceId: serviceId);
    final providerEntry = services.describe(serviceId: serviceId, version: binding.contractVersion);
    if (providerEntry == null || providerEntry.availability != 'ready') {
      throw HostException(ErrorCode.providerUnavailable, '绑定的提供者不可用：${binding.providerInstallationId}');
    }
    if (!VersionRange.parse(versionRange).allows(binding.contractVersion)) {
      throw HostException(ErrorCode.contractMismatch,
          '绑定版本 ${binding.contractVersion} 不在消费方声明的范围 $versionRange 内');
    }
    if (agentSession && !providerEntry.agentCallable) {
      throw HostException(ErrorCode.denied, '服务 ${providerEntry.serviceId} 未声明 agentCallable，Agent 会话不可调用');
    }

    // 3. 参数校验：按提供者的 inputSchema 检查必需字段与额外字段
    _validateSchema(input, providerEntry.inputSchema, '输入');

    // 4. 资源引用重写：把调用方的句柄派生成提供者专用的只读句柄，不转发万能 token
    final providerInstall = binding.providerInstallationId;
    final derivedHandleIds = <String>[];   // 本次调用派生的句柄，结束后只撤销这些
    final rewrittenInput = <String, Object?>{};
    for (final entry in input.entries) {
      final value = entry.value;
      if (value is String && value.startsWith('resource:')) {
        final handleId = value.substring('resource:'.length);
        final source = resources.describe(
          handleId: handleId,
          recipient: callerId,
          workspaceId: workspaceId,
        );
        final derived = resources.derive(source, recipient: providerInstall, sessionId: sessionId);
        derivedHandleIds.add(derived.id);
        rewrittenInput[entry.key] = 'resource:${derived.id}';
      } else {
        rewrittenInput[entry.key] = value;
      }
    }

    // 5. 调用链与任务：成环或超深在创建阶段即被拒绝
    final task = tasks.create(
      workspaceId: workspaceId,
      sessionId: sessionId,
      caller: callerId,
      providerInstallationId: providerInstall,
      serviceId: serviceId,
    );

    final runtime = _runtimes[providerInstall];
    if (runtime == null || !runtime.isAlive) {
      tasks.popChain(sessionId, providerInstall);
      tasks.fail(task, ErrorCode.providerUnavailable, '提供者运行时不可用');
      return task;
    }

    // 6. 向提供者投递 plugin.service.invoke；不要求用户点击插件页面
    try {
      final result = await runtime.call('plugin.service.invoke', {
        'callId': task.callId,
        'service': serviceId,
        'version': binding.contractVersion,
        'input': rewrittenInput,
      });
      _validateSchema(result, providerEntry.outputSchema, '结果');

      // 7. 结果以临时资源形式回给调用方：这是"输出重新派生给调用方"，
      //    因此归属方是调用方而不是提供者——提供者随后被停用也不应撤销已交付的结果
      final resultBytes = _materializeResult(result);
      final resultHandle = resources.issue(
        workspaceId: workspaceId,
        sessionId: sessionId,
        owner: callerId,
        recipient: callerId,
        draft: ResourceDraft(
          name: '${serviceId.replaceAll('.', '-')}-result',
          mediaType: '${result['mediaType'] ?? 'text/markdown'}',
          bytes: resultBytes,
          kind: ResourceKind.tempResult,
          ttl: const Duration(minutes: 10),
        ),
      );
      tasks.succeed(task, {
        ...result,
        'result': 'resource:${resultHandle.id}',
        'resultSize': resultHandle.size,
      });
    } on HostException catch (e) {
      tasks.fail(task, e.code, e.message);
    } catch (e) {
      tasks.fail(task, ErrorCode.providerUnavailable, '提供者调用异常：$e');
    } finally {
      // 8. 无论成败都只撤销本次派生给提供者的临时句柄并出栈，
      //    不能按接收者批量撤销，否则会误伤该安装在同一会话中的其他句柄
      for (final id in derivedHandleIds) {
        resources.revoke(id);
      }
      tasks.popChain(sessionId, providerInstall);
    }
    return task;
  }

  /// 把 result 里的内联内容转成字节；约定服务输出用 result 字段携带正文
  Uint8List _materializeResult(Map<String, Object?> result) {
    final text = result['result'] ?? result['resultText'];
    if (text is String) return Uint8List.fromList(utf8.encode(text));
    return Uint8List.fromList(utf8.encode(jsonEncode(result)));
  }

  /// 极简 schema 校验：检查 required 与 additionalProperties，够 demo 用
  /// 已知缺口：未覆盖 type/pattern/enum/嵌套对象，正式版应换成完整 JSON Schema 校验器
  void _validateSchema(Map<String, Object?> value, Map<String, Object?> schema, String label) {
    final required = (schema['required'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    for (final key in required) {
      if (!value.containsKey(key)) {
        throw HostException(ErrorCode.contractMismatch, '$label 缺少必需字段：$key');
      }
    }
    if (schema['additionalProperties'] == false) {
      final allowed = (schema['properties'] as Map?)?.keys.map((e) => '$e').toSet() ?? const <String>{};
      for (final key in value.keys) {
        if (!allowed.contains(key)) {
          throw HostException(ErrorCode.contractMismatch, '$label 含未声明字段：$key');
        }
      }
    }
  }

  /// 处理插件或 Agent 发起的 host.* 调用；身份由通道绑定，报文里的自述 ID 一律忽略
  Future<Object?> handleHostCall(String callerId, String method, Map<String, Object?> params) async {
    final handler = hostCallHandler;
    if (handler == null) {
      throw const HostException(ErrorCode.unavailable, '宿主尚未装配 host.* 分发器');
    }
    return handler(callerId, method, params);
  }

  /// 供 Bridge 使用的运行时访问器
  PluginRuntime? runtimeOf(String installationId) => _runtimes[installationId];

  /// 当前活跃安装快照
  List<PluginInstallation> get activeInstalls =>
      installs.values.where((i) => i.state == InstallState.active).toList();
}
