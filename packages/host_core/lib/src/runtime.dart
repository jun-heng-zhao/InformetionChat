// 文件职责：插件运行时抽象与"独立子进程"实现
// 说明：帧格式与 docs/contracts/plugin-ui-jsonrpc.md 完全一致（newline-delimited JSON-RPC 2.0）。
//      演示阶段用子进程代替 WebView：它提供真实的进程隔离、真实超时与真实回收；
//      第二步接入 WebView 时只需另写一个 PluginRuntime 实现，上层分发逻辑不需改动。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'jsonrpc.dart';

/// 插件运行时启动配置
class PluginRuntimeConfig {
  final String installationId;           // 安装 ID，入站请求的身份由宿主绑定而非插件自报
  final String workspaceId;              // 工作区 ID
  final String pluginId;                 // 自述插件 ID，仅用于展示
  final String workingDirectory;         // 插件代码根目录（只读快照路径）
  final String executable;               // 承载插件代码的可执行文件
  final List<String> arguments;          // 传给可执行文件的参数
  final Duration callTimeout;            // 普通调用超时，超时即回收运行时
  final int maxMessageBytes;             // 单帧大小上限

  const PluginRuntimeConfig({
    required this.installationId,
    required this.workspaceId,
    required this.pluginId,
    required this.workingDirectory,
    required this.executable,
    this.arguments = const [],
    this.callTimeout = const Duration(seconds: 30),
    this.maxMessageBytes = 1024 * 1024,
  });
}

/// 插件 → 宿主 的调用回调；返回 JSON-RPC 结果或抛 HostException
typedef HostCallHandler = Future<Object?> Function(String installationId, String method, Map<String, Object?> params);

/// 插件运行时接口：宿主只通过它向插件投递入站方法，不共享内存或文件系统
abstract class PluginRuntime {
  /// 启动运行时；失败抛 PROVIDER_UNAVAILABLE
  Future<void> start();

  /// 向插件发起一次调用并等待响应（宿主 → 插件）
  Future<Map<String, Object?>> call(String method, Map<String, Object?> params);

  /// 向插件发送通知，不等待响应（例如 plugin.deactivate）
  void notify(String method, Map<String, Object?> params);

  /// 关闭运行时；超时未退出则强杀，返回是否发生过强制终止
  Future<bool> dispose();

  /// 运行时是否仍然存活
  bool get isAlive;
}

/// 独立子进程运行时：以 stdio 承载 JSON-RPC，进程即隔离边界
class SubprocessPluginRuntime implements PluginRuntime {
  final PluginRuntimeConfig config;      // 启动与限额配置
  final HostCallHandler onHostCall;      // 插件回调宿主的处理入口

  Process? _process;                     // 子进程句柄
  StreamSubscription<String>? _stdoutSub; // 逐行读取子进程输出
  final Map<Object, Completer<Map<String, Object?>>> _pending = {}; // 请求 ID → 等待中的调用
  int _seq = 0;                          // 宿主侧请求序号
  bool _alive = false;                   // 是否处于可调用状态
  final List<String> _stderrTail = [];   // 保留子进程错误输出尾部，便于诊断

  SubprocessPluginRuntime(this.config, {required this.onHostCall});

  @override
  bool get isAlive => _alive;

  /// 启动子进程并挂上 stdout 解析；工作目录固定为包快照根
  @override
  Future<void> start() async {
    try {
      _process = await Process.start(
        config.executable,
        config.arguments,
        workingDirectory: config.workingDirectory,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw HostException(ErrorCode.providerUnavailable, '插件运行时启动失败：${e.message}');
    }
    _alive = true;
    _stdoutSub = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      _onLine,
      onError: (_) => _markDead(),
      onDone: _markDead,
    );
    // 子进程错误输出只保留尾部若干行，避免日志无界增长
    _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _stderrTail.add(line);
      if (_stderrTail.length > 20) _stderrTail.removeAt(0);
    });
    // 进程意外退出时，让所有等待中的调用立刻失败，而不是一直挂到超时
    unawaited(_process!.exitCode.then((code) {
      _markDead();
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(HostException(ErrorCode.providerUnavailable, '插件进程已退出，退出码 $code'));
        }
      }
      _pending.clear();
    }));
  }

  /// 处理子进程的一行输出：既可能是响应，也可能是插件对宿主的请求
  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    // 单帧大小上限：超过即视为异常输入，直接断开而不是继续解析
    if (line.length > config.maxMessageBytes) {
      _stderrTail.add('入站消息超过 ${config.maxMessageBytes} 字节上限，已丢弃');
      return;
    }
    Map<String, Object?> message;
    try {
      message = (jsonDecode(line) as Map).cast<String, Object?>();
    } catch (_) {
      _stderrTail.add('无法解析的报文：${line.substring(0, line.length.clamp(0, 120))}');
      return;
    }
    if (message.containsKey('method')) {
      unawaited(_handleInbound(message)); // 插件 → 宿主 的请求
    } else {
      _settle(message);                   // 宿主 → 插件 的响应
    }
  }

  /// 处理插件发起的 host.* 调用：身份由运行时绑定，忽略报文里的任何自述 ID
  Future<void> _handleInbound(Map<String, Object?> message) async {
    final request = RpcRequest.fromJson(message);
    Object? result;
    RpcError? error;
    try {
      result = await onHostCall(config.installationId, request.method, request.params);
    } on MethodNotFoundException catch (e) {
      // 未知方法走 JSON-RPC 标准错误码，便于调用方与业务错误区分
      error = RpcError(RpcErrorCode.methodNotFound, '未知方法：${e.method}');
    } on HostException catch (e) {
      error = RpcError(RpcErrorCode.businessError, e.message, data: {'code': e.code, if (e.detail != null) 'detail': e.detail});
    } catch (e) {
      error = RpcError(RpcErrorCode.internalError, '宿主内部错误：$e');
    }
    if (request.isNotification || _process == null) return;
    final payload = error != null
        ? RpcResponse.failure(request.id, error).toJson()
        : RpcResponse.success(request.id, result).toJson();
    _write(payload);
  }

  /// 完成一个等待中的调用
  void _settle(Map<String, Object?> message) {
    final completer = _pending.remove(message['id']);
    if (completer == null || completer.isCompleted) return;
    final err = message['error'];
    if (err is Map) {
      completer.completeError(HostException(
        '${(err['data'] is Map ? (err['data'] as Map)['code'] : null) ?? ErrorCode.providerUnavailable}',
        '${err['message']}',
      ));
    } else {
      completer.complete((message['result'] as Map?)?.cast<String, Object?>() ?? const {});
    }
  }

  /// 向插件发起调用；超时或运行时已死时抛错，由上层转成任务失败
  @override
  Future<Map<String, Object?>> call(String method, Map<String, Object?> params) async {
    if (!_alive || _process == null) {
      throw HostException(ErrorCode.providerUnavailable, '插件运行时不可用：${config.installationId}');
    }
    final id = ++_seq;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _write(RpcRequest(id: id, method: method, params: params).toJson());
    return completer.future.timeout(config.callTimeout, onTimeout: () {
      _pending.remove(id);
      throw HostException(ErrorCode.timeout, '插件调用超时（${config.callTimeout.inSeconds}s）：$method',
          detail: {'stderrTail': _stderrTail});
    });
  }

  /// 单向通知：不分配请求 ID，也不建立等待
  @override
  void notify(String method, Map<String, Object?> params) {
    if (!_alive || _process == null) return;
    _write({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  /// 关闭运行时；宽限期内未退出则强杀，并返回是否发生强制终止
  @override
  Future<bool> dispose() async {
    final process = _process;
    if (process == null) return false;
    notify('plugin.deactivate', {'reason': 'host-shutdown'});
    _alive = false;
    await _stdoutSub?.cancel();
    var forced = false;
    try {
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill); // 不响应取消或退出的提供者由宿主强制回收
      forced = true;
    }
    _process = null;
    return forced;
  }

  /// 写一帧到子进程 stdin
  void _write(Map<String, Object?> payload) {
    try {
      _process?.stdin.writeln(jsonEncode(payload));
    } catch (_) {
      _markDead();
    }
  }

  void _markDead() => _alive = false;

  /// 最近的后端诊断信息，仅用于宿主界面与日志，不向其他插件暴露
  List<String> get diagnostics => List.unmodifiable(_stderrTail);
}
