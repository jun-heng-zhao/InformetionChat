// 文件职责：M1 端到端演示器——装配宿主、加载三个示例插件、走通互通/Agent/通知三条主线与负向用例
// 运行：dart run tools/demo_runner/bin/demo.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_core/host_core.dart';
import 'package:path/path.dart' as p;

// 运行参数与固定标识
const workspaceId = 'ws-demo';                       // 演示工作区
const converterId = 'inst-converter';                // 转换器安装 ID
const viewerId = 'inst-viewer';                      // 查看器安装 ID
const alertId = 'inst-alert';                        // 提醒插件安装 ID
const agentCallerId = 'agent-local-1';               // Agent 会话调用方标识
var _passCount = 0;                                  // 通过用例计数
var _failCount = 0;                                  // 失败用例计数

/// 项目根目录：从当前目录向上查找含 plugins/dev-format-converter 的目录，避免依赖调用位置
Directory get projectRoot {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory(p.join(dir.path, 'plugins', 'dev-format-converter')).existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('找不到项目根目录（应包含 plugins/dev-format-converter），请在仓库内运行');
}

/// 打印小节标题
void section(String title) => print('\n── $title ${'─' * (56 - title.length).clamp(0, 56)}');

/// 打印普通说明
void note(String text) => print('   $text');

/// 记录一条通过，并打印
void pass(String text) {
  _passCount++;
  print('   ✓ $text');
}

/// 记录一条失败，并打印
void fail(String text) {
  _failCount++;
  print('   ✗ $text');
}

/// 把 dynamic 结果安全地当作 Map 使用
Map<String, Object?> asMap(Object? value) => (value as Map).cast<String, Object?>();

/// 断言期望的失败：调用成功或错误码不符都记为失败
Future<void> expectFailure(String label, String expectedCode, Future<void> Function() action) async {
  try {
    await action();
    fail('$label：预期被拒绝（$expectedCode），实际调用成功');
  } on HostException catch (e) {
    if (e.code == expectedCode) {
      pass('$label → 已拒绝，码 $expectedCode');
    } else {
      fail('$label：预期 $expectedCode，实际 ${e.code}（${e.message}）');
    }
  }
}

Future<void> main() async {
  print('InformetionChat M1 演示：插件加载 / 隔离 / 互通 / 复用 / Agent / 紧急通知');

  // 准备：临时暂存区与输出目录，全部落在系统临时目录，不污染仓库
  final workDir = Directory.systemTemp.createTempSync('informetionchat-demo-');
  final stagingRoot = Directory(p.join(workDir.path, 'staging'))..createSync(recursive: true);
  final outputDir = Directory(p.join(workDir.path, 'output'))..createSync(recursive: true);
  note('工作目录：${workDir.path}');

  final loader = PackageLoader(stagingRoot);
  final host = LocalHost(
    workspaceId: workspaceId,
    loader: loader,
    runtimeFactory: _runtimeFactory,
  );
  final sessions = <String, String>{};               // 安装 ID → 通道会话 ID

  // 装配真实分发器，并把插件回调解到对应通道会话
  final dispatcher = BridgeDispatcher(host);
  host.hostCallHandler = (installationId, method, params) {
    final sessionId = sessions[installationId];
    if (sessionId == null) {
      throw HostException.denied('安装 $installationId 尚未建立通道，拒绝其 host.* 调用');
    }
    return dispatcher.handle(sessionId, method, params);
  };

  // 用户选择输入：演示固定返回夹具归档，正式版由系统文件选择器提供
  final fixture = File(p.join(projectRoot.path, 'tools', 'demo_runner', 'fixtures', 'chat-archive.json'));
  host.inputPicker = (callerId, purpose) async => PickedInput(
        name: 'chat-archive.json',
        mediaType: 'application/json',
        bytes: await fixture.readAsBytes(),
      );

  // 保存结果：写入演示输出目录，并向调用方返回人类可读位置（不回传原生路径）
  host.saveHandler = (callerId, suggestedName, bytes) async {
    final target = File(p.join(outputDir.path, suggestedName));
    await target.writeAsBytes(bytes);
    return 'output/$suggestedName（${bytes.length} 字节）';
  };

  // 安装辅助：先建通道再安装，使插件启动后的 host.* 回调能对上身份
  Future<PluginInstallation> installPlugin({
    required String id,
    required String relativeDir,
    required List<String> permissions,
    Set<String> criticalCategories = const {},
  }) async {
    final session = dispatcher.bindChannel(callerId: id, kind: 'plugin');
    sessions[id] = session.sessionId;
    return host.install(
      sourceDir: Directory(p.join(projectRoot.path, relativeDir)),
      installationId: id,
      grantedPermissions: permissions,
      criticalCategories: criticalCategories,
    );
  }

  // Agent 会话先于主流程建立，便于收尾阶段关闭通道
  final agentSession = dispatcher.bindChannel(callerId: agentCallerId, kind: 'agent');

  try {
    // ── 步骤 1：加载三个插件 ───────────────────────────────────────────
    section('步骤 1：加载插件（校验 → 暂存快照 → 授权 → 注册服务 → 启动运行时）');
    final converter = await installPlugin(
      id: converterId,
      relativeDir: 'plugins/dev-format-converter',
      permissions: ['storage.plugin.read', 'storage.plugin.write', 'file.pick', 'file.read', 'file.save', 'service.call', 'audit.append'],
    );
    pass('转换器已激活：${converter.pluginId}@${converter.version}，摘要 ${converter.digest.substring(0, 12)}…');

    final viewer = await installPlugin(
      id: viewerId,
      relativeDir: 'plugins/dev-chat-viewer',
      permissions: ['storage.plugin.read', 'storage.plugin.write', 'file.pick', 'file.read', 'file.save', 'resource.create', 'service.call', 'audit.append'],
    );
    pass('查看器已激活：${viewer.pluginId}@${viewer.version}，包内 ${viewer.package.files.length} 个文件');

    final alert = await installPlugin(
      id: alertId,
      relativeDir: 'plugins/dev-local-alert',
      permissions: ['notification.publish', 'notification.critical', 'notification.read', 'service.call', 'audit.append'],
      criticalCategories: {'local-test-alert'},      // 用户只为该类别开启了紧急弹窗
    );
    pass('提醒插件已激活：${alert.pluginId}@${alert.version}，登记类别 '
        '${alert.manifest.categories.map((c) => '${c.id}(上限 ${c.requestedMaxLevel})').join('、')}');
    note('来源 ID 由安装记录生成：${alert.sourceId}（插件无法在正文里自报来源）');

    note('已注册服务提供者：${host.services.providers.map((e) => '${e.serviceId}@${e.version}').join('、')}');

    // ── 步骤 2：用户绑定提供者 ─────────────────────────────────────────
    section('步骤 2：用户绑定服务提供者（绑定后新安装不得抢占）');
    for (final consumer in [viewerId, agentCallerId]) {
      host.services.bind(ServiceBinding(
        workspaceId: workspaceId,
        consumer: consumer,
        serviceId: 'document.convert',
        contractVersion: '1.0.0',
        providerInstallationId: converterId,
        providerDigest: converter.digest,
      ));
    }
    // 插件自身页面上的按钮与 Agent 调用的是同一份服务实现，因此也各自需要绑定
    for (final self in [viewerId, alertId]) {
      final serviceId = self == viewerId ? 'archive.export' : 'alert.notify-test';
      host.services.bind(ServiceBinding(
        workspaceId: workspaceId,
        consumer: self,
        serviceId: serviceId,
        contractVersion: '1.0.0',
        providerInstallationId: self,
        providerDigest: host.installs[self]!.digest,
      ));
    }
    // Agent 会话也绑定 archive.export，用于验证"已绑定但未声明 agentCallable 仍不可调用"
    host.services.bind(ServiceBinding(
      workspaceId: workspaceId,
      consumer: agentCallerId,
      serviceId: 'archive.export',
      contractVersion: '1.0.0',
      providerInstallationId: viewerId,
      providerDigest: viewer.digest,
    ));
    // Agent 会话是独立授权单位：显式授予调用与读取权限，Agent 无法自批
    host.permissions.grant(PermissionGrant(
      workspaceId: workspaceId,
      caller: agentCallerId,
      operation: 'service.call',
      purpose: '用户为本地 Agent 会话授权的转换调用',
    ));
    host.permissions.grant(PermissionGrant(
      workspaceId: workspaceId,
      caller: agentCallerId,
      operation: 'file.read',
      purpose: '用户为本地 Agent 会话授权的结果读取',
    ));
    pass('查看器与 Agent 会话均绑定 document.convert → $converterId');

    // ── 步骤 3：插件互通 ───────────────────────────────────────────────
    section('步骤 3：插件互通（查看器 → archive.export → document.convert → 保存结果）');
    final viewerSession = sessions[viewerId]!;
    final handshake = asMap(await dispatcher.handle(viewerSession, 'host.handshake', {
      'uiBridge': '1.2',
      'requestedCapabilities': ['file.pick', 'file.read', 'file.save'],
    }));
    pass('握手完成：uiBridge ${handshake['uiBridge']}，预算 ${asMap(handshake['budget'])}');

    final picked = asMap(await dispatcher.handle(viewerSession, 'host.file.pick', {'purpose': '选择要导出的归档'}));
    pass('用户选定输入：${picked['name']}（${picked['size']} 字节），句柄 ${picked['handle']}');

    final exportTaskId = await _callService(
      dispatcher,
      viewerSession,
      'archive.export',
      {'source': 'resource:${picked['handle']}', 'targetFormat': 'markdown'},
    );
    final exportTask = asMap(await dispatcher.handle(viewerSession, 'host.task.get', {'taskId': exportTaskId}));
    String? exportResultHandle;                      // 导出结果句柄，供后续测试停用后的失效行为
    if (exportTask['state'] == 'succeeded') {
      final output = asMap(exportTask['output']);
      exportResultHandle = '${output['result']}';
      pass('任务 ${exportTask['taskId']} 成功，由 ${output['convertedBy']} 完成，共 ${output['messageCount']} 条消息');
      note('结果以临时资源返回：$exportResultHandle（${output['resultSize']} 字节）');

      final body = await _readAll(dispatcher, viewerSession, exportResultHandle);
      note('结果正文前 120 字符：${body.replaceAll('\n', ' ⏎ ').substring(0, body.length.clamp(0, 120))}');
      final saved = asMap(await dispatcher.handle(viewerSession, 'host.file.save', {
        'handle': exportResultHandle.replaceFirst('resource:', ''),
        'suggestedName': 'archive-export.md',
      }));
      pass('结果已保存：${saved['label']}');
    } else {
      fail('任务未成功：${exportTask['state']} ${exportTask['error']}');
    }

    // ── 步骤 4：Agent 调用同一服务 ─────────────────────────────────────
    section('步骤 4：Agent 会话调用同一服务（全程不依赖插件页面点击）');
    final discovered = asMap(await dispatcher.handle(agentSession.sessionId, 'host.service.discover', {
      'service': 'document.convert',
      'versionRange': '^1.0.0',
    }));
    pass('发现候选：${discovered['candidates']}');

    final described = asMap(await dispatcher.handle(agentSession.sessionId, 'host.service.describe', {'service': 'document.convert'}));
    pass('描述服务：agentCallable=${described['agentCallable']}，requiresUI=${described['requiresUI']}，effects=${described['effects']}');

    final binding = asMap(await dispatcher.handle(agentSession.sessionId, 'host.binding.get', {'service': 'document.convert'}));
    pass('使用既有绑定：${binding['providerInstallationId']}@${binding['contractVersion']}');

    final agentInput = await host.pickInput(callerId: agentCallerId, sessionId: agentSession.sessionId, purpose: 'Agent 预授权输入');
    final agentTaskId = await _callService(
      dispatcher,
      agentSession.sessionId,
      'document.convert',
      {'source': 'resource:${agentInput!.id}', 'targetFormat': 'markdown'},
    );
    final agentTask = asMap(await dispatcher.handle(agentSession.sessionId, 'host.task.get', {'taskId': agentTaskId}));
    String? agentResultHandle;                       // Agent 会话的结果句柄，用于验证停用不影响其他安装
    if (agentTask['state'] == 'succeeded') {
      final agentOutput = asMap(agentTask['output']);
      agentResultHandle = '${agentOutput['result']}';
      final agentBody = await _readAll(dispatcher, agentSession.sessionId, agentResultHandle);
      pass('Agent 调用成功，结果 ${agentBody.length} 字符，与插件链路使用同一实现');
    } else {
      fail('Agent 调用未成功：${agentTask['state']}');
    }

    // ── 步骤 5：紧急通知 ───────────────────────────────────────────────
    section('步骤 5：授权来源的紧急通知与去重/降级/撤回');
    final alertSession = sessions[alertId]!;
    final firstEvent = 'demo-event-${DateTime.now().millisecondsSinceEpoch}';

    final first = await _notify(dispatcher, alertSession, {
      'category': 'local-test-alert',
      'eventId': firstEvent,
      'revision': 1,
      'requestedLevel': 'critical',
      'title': '紧急提醒测试',
      'body': '这是一条用户主动触发的本地测试事件。',
      'expiresInSeconds': 60,
    });
    if (first['effectiveLevel'] == 'critical' && first['state'] == 'displayed') {
      pass('授权来源的紧急提醒已在前台弹窗（notificationId ${first['notificationId']}）');
    } else {
      fail('预期 critical/displayed，实际 ${first['effectiveLevel']}/${first['state']}');
    }

    final repeat = await _notify(dispatcher, alertSession, {
      'category': 'local-test-alert',
      'eventId': firstEvent,
      'revision': 1,
      'requestedLevel': 'critical',
      'title': '紧急提醒测试',
      'body': '这是一条用户主动触发的本地测试事件。',
      'expiresInSeconds': 60,
    });
    repeat['notificationId'] == first['notificationId']
        ? pass('同修订同内容重复提交：返回既有通知，不重复弹窗')
        : fail('重复提交产生了新通知');

    await expectFailure('同修订但内容不同', ErrorCode.contractMismatch, () => _notify(dispatcher, alertSession, {
          'category': 'local-test-alert',
          'eventId': firstEvent,
          'revision': 1,
          'requestedLevel': 'critical',
          'title': '被篡改的标题',
          'body': '内容与同修订的既有记录不一致。',
          'expiresInSeconds': 60,
        }));

    await expectFailure('较低修订覆盖新状态', ErrorCode.contractMismatch, () => _notify(dispatcher, alertSession, {
          'category': 'local-test-alert',
          'eventId': firstEvent,
          'revision': 0,
          'requestedLevel': 'critical',
          'title': '旧事件',
          'body': '试图用更低修订回退状态。',
          'expiresInSeconds': 60,
        }));

    final downgraded = await _notify(dispatcher, alertSession, {
      'category': 'local-test-info',
      'eventId': 'demo-info-${DateTime.now().millisecondsSinceEpoch}',
      'revision': 1,
      'requestedLevel': 'critical',
      'title': '未授权类别请求紧急',
      'body': '该类别上限为 normal，宿主应按策略降级。',
      'expiresInSeconds': 60,
    });
    downgraded['effectiveLevel'] == 'normal'
        ? pass('未授权类别自报 critical：降级为 ${downgraded['effectiveLevel']}，原因 ${downgraded['reason']}')
        : fail('未按策略降级，实际 ${downgraded['effectiveLevel']}');

    await expectFailure('未知通知类别', ErrorCode.unknownCategory, () => _notify(dispatcher, alertSession, {
          'category': 'not-registered',
          'eventId': 'demo-unknown-1',
          'revision': 1,
          'requestedLevel': 'normal',
          'title': '未知类别',
          'body': '动态创建已授权紧急来源应被拒绝。',
          'expiresInSeconds': 60,
        }));

    // 这一条直接走 host 接口：插件总会补上 expiresAt，只有直连才能验证宿主的强制校验
    await expectFailure('缺少 expiresAt 的紧急提醒', ErrorCode.contractMismatch, () async {
      await dispatcher.handle(alertSession, 'host.notification.publish', {
        'category': 'local-test-alert',
        'eventId': 'demo-no-expiry-${DateTime.now().millisecondsSinceEpoch}',
        'revision': 1,
        'requestedLevel': 'critical',
        'title': '无有效期',
        'body': '紧急提醒必须提供 expiresAt。',
      });
    });

    // 应用切到后台：只记录 received，不能把未展示写成已展示
    host.notifications.foreground = false;
    final background = await _notify(dispatcher, alertSession, {
      'category': 'local-test-alert',
      'eventId': 'demo-bg-${DateTime.now().millisecondsSinceEpoch}',
      'revision': 1,
      'requestedLevel': 'critical',
      'title': '后台事件',
      'body': '应用不在前台时应记录 received 并返回降级原因。',
      'expiresInSeconds': 60,
    });
    background['state'] == 'received' && '${background['reason']}'.contains('FOREGROUND_REQUIRED')
        ? pass('应用后台：状态 received，原因含 FOREGROUND_REQUIRED')
        : fail('后台事件处理不符预期：${background['state']} / ${background['reason']}');
    host.notifications.foreground = true;

    // 撤回后不得复活
    final withdrawTarget = 'demo-withdraw-${DateTime.now().millisecondsSinceEpoch}';
    await _notify(dispatcher, alertSession, {
      'category': 'local-test-alert',
      'eventId': withdrawTarget,
      'revision': 1,
      'requestedLevel': 'normal',
      'title': '待撤回事件',
      'body': '随后会被来源撤回。',
      'expiresInSeconds': 300,
    });
    final withdrawn = asMap(await dispatcher.handle(alertSession, 'host.notification.withdraw', {
      'eventId': withdrawTarget,
      'revision': 2,
    }));
    pass('撤回成功：${withdrawn['notificationId']} → ${withdrawn['state']}');
    await expectFailure('已撤回且未过期的事件重新发布', ErrorCode.notFound, () => _notify(dispatcher, alertSession, {
          'category': 'local-test-alert',
          'eventId': withdrawTarget,
          'revision': 3,
          'requestedLevel': 'critical',
          'title': '重放尝试',
          'body': '撤回记录在有效期结束前必须阻止重放。',
          'expiresInSeconds': 60,
        }));

    await expectFailure('插件代用户确认通知', ErrorCode.denied, () async {
      await dispatcher.handle(alertSession, 'host.notification.acknowledge', {'notificationId': first['notificationId']});
    });

    // ── 步骤 6：越权与失败处理 ─────────────────────────────────────────
    section('步骤 6：越权、跨会话句柄、未授权能力与停用回收');

    await expectFailure('查看器读取其他会话的句柄', ErrorCode.denied, () async {
      await dispatcher.handle(viewerSession, 'host.resource.read', {'handle': agentInput.id, 'offset': 0});
    });

    await expectFailure('Agent 调用已绑定但未声明 agentCallable 的服务', ErrorCode.denied, () async {
      await _callService(dispatcher, agentSession.sessionId, 'archive.export', {
        'source': 'resource:${agentInput.id}',
        'targetFormat': 'markdown',
      });
    });

    await expectFailure('未获授权的调用方发起服务调用', ErrorCode.denied, () async {
      final stranger = dispatcher.bindChannel(callerId: 'inst-stranger', kind: 'plugin');
      await dispatcher.handle(stranger.sessionId, 'host.service.call', {
        'service': 'document.convert',
        'versionRange': '^1.0.0',
        'input': {'source': 'resource:${agentInput.id}', 'targetFormat': 'markdown'},
      });
    });

    await expectFailure('后续阶段接口', ErrorCode.unavailable, () async {
      await dispatcher.handle(viewerSession, 'host.operation.prepare', {});
    });

    await expectFailure('未知方法', 'METHOD_NOT_FOUND', () async {
      try {
        await dispatcher.handle(viewerSession, 'host.不存在的接口', {});
      } on MethodNotFoundException {
        throw const HostException('METHOD_NOT_FOUND', '未实现');
      }
    });

    // 停用提供者：绑定保留但调用报不可用，句柄与授权一并撤销
    final forced = await host.deactivate(converterId);
    pass('转换器已停用（强制回收：$forced），撤销授权 ${host.lastRevokedGrantCount} 条');
    await expectFailure('绑定仍指向已停用的提供者', ErrorCode.providerUnavailable, () async {
      await _callService(dispatcher, viewerSession, 'document.convert', {
        'source': 'resource:${picked['handle']}',
        'targetFormat': 'markdown',
      });
    });
    host.resources.list(recipient: converterId, workspaceId: workspaceId).isEmpty
        ? pass('停用后转换器名下句柄全部撤销')
        : fail('停用后仍存在对转换器有效的句柄');
    if (exportResultHandle != null) {
      try {
        await _readAll(dispatcher, viewerSession, exportResultHandle);
        pass('已交付给调用方的结果不因下游提供者停用而失效（结果句柄绑定调用方会话）');
      } catch (e) {
        fail('调用方已获得的结果被下游停用误撤：$e');
      }
    }
    host.services.discover(serviceId: 'document.convert').isEmpty
        ? pass('转换器停用后不再出现在可用提供者中（绑定仍保留，不偷偷换实现）')
        : fail('转换器仍是可用提供者');
    if (agentResultHandle != null) {
      try {
        await _readAll(dispatcher, agentSession.sessionId, agentResultHandle);
        pass('停用一个安装不影响其他安装已授权的句柄（隔离边界成立）');
      } catch (e) {
        fail('停用转换器误伤了 Agent 会话的句柄：$e');
      }
    }
  } finally {
    // 收尾：关闭全部运行时并清理临时目录
    for (final id in sessions.keys.toList()) {
      await host.deactivate(id);
    }
    dispatcher.closeChannel(agentSession.sessionId);
  }

  // 汇总
  section('结果汇总');
  print('   通过 $_passCount 项，失败 $_failCount 项');
  final ok = _failCount == 0;
  print(ok ? '   演示全部通过：M1 三条主线与负向用例均符合设计契约。' : '   存在未通过项，请检查上面的 ✗ 标记。');
  if (!ok) exitCode = 1;
}

/// 创建子进程插件运行时：以 node 承载演示插件代码，进程即隔离边界
PluginRuntime _runtimeFactory(PluginInstallation installation, HostCallHandler hostCallBack) => SubprocessPluginRuntime(
      PluginRuntimeConfig(
        installationId: installation.id,
        workspaceId: installation.workspaceId,
        pluginId: installation.pluginId,
        workingDirectory: installation.package.stagingDirPath,
        executable: 'node',
        arguments: const ['service/index.js'],
      ),
      onHostCall: hostCallBack,
    );

/// 调用服务并返回 taskId；失败时打印原因后原样抛出
Future<String> _callService(BridgeDispatcher dispatcher, String sessionId, String serviceId, Map<String, Object?> input) async {
  final result = asMap(await dispatcher.handle(sessionId, 'host.service.call', {
    'service': serviceId,
    'versionRange': '^1.0.0',
    'input': input,
  }));
  return '${result['taskId']}';
}

/// 触发提醒插件的服务，返回其输出
Future<Map<String, Object?>> _notify(BridgeDispatcher dispatcher, String sessionId, Map<String, Object?> input) async {
  final taskId = await _callService(dispatcher, sessionId, 'alert.notify-test', input);
  final task = asMap(await dispatcher.handle(sessionId, 'host.task.get', {'taskId': taskId}));
  if (task['state'] != 'succeeded') {
    final error = task['error'] is Map ? asMap(task['error']) : const <String, Object?>{};
    throw HostException('${error['code'] ?? ErrorCode.providerUnavailable}', '${error['message'] ?? task['state']}');
  }
  return asMap(task['output']);
}

/// 分块读取资源句柄直到 EOF，返回完整文本
Future<String> _readAll(BridgeDispatcher dispatcher, String sessionId, String handleRef) async {
  final handleId = handleRef.replaceFirst('resource:', '');
  final buffer = BytesBuilder();
  var offset = 0;
  for (;;) {
    final chunk = asMap(await dispatcher.handle(sessionId, 'host.resource.read', {
      'handle': handleId,
      'offset': offset,
    }));
    buffer.add(base64Decode('${chunk['bytes']}'));
    if (chunk['eof'] == true) break;
    offset = chunk['nextOffset'] as int;
  }
  return utf8.decode(buffer.takeBytes());
}
