// 文件职责：任务管理——M1 统一异步语义（调用即返回 taskId，结果经 task.get 读取）
// 依据：docs/contracts/plugin-ui-jsonrpc.md 的 host.task.get/cancel 与错误和状态一节

import 'errors.dart';

/// 任务终态与中间态；终态为 succeeded / failed / cancelled
class TaskState {
  static const queued = 'queued';            // 已接受，等待提供者开始
  static const running = 'running';          // 提供者执行中
  static const waitingForUser = 'waiting-for-user'; // 需要用户在插件页面操作
  static const succeeded = 'succeeded';      // 成功，output 可读
  static const failed = 'failed';            // 失败，error 说明原因
  static const cancelled = 'cancelled';      // 已取消

  static const terminal = {succeeded, failed, cancelled};
  static const all = {queued, running, waitingForUser, succeeded, failed, cancelled};
}

/// 副作用状态：取消不能把已经发生的写入/外发说成没发生
class SideEffectStatus {
  static const none = 'none';                // 无副作用或未产生
  static const committed = 'committed';      // 已完整生效
  static const partial = 'partial';          // 部分生效
  static const unknown = 'unknown';          // 无法确定（例如外部结果不确定）
}

/// 任务记录：绑定调用方会话与提供者安装，跨会话查询一律拒绝
class LocalTask {
  final String id;                           // taskId，宿主生成
  final String workspaceId;                  // 所属工作区
  final String sessionId;                    // 发起调用的运行会话
  final String caller;                       // 调用方（安装 ID 或 agent:<sessionId>）
  final String providerInstallationId;       // 锁定的提供者安装
  final String serviceId;                    // 服务 ID
  final String callId;                       // 传给提供者的 callId，用于取消与日志关联
  final int depth;                           // 该调用在调用链中的深度，用于环检测
  final DateTime createdAt;                  // 创建时间
  DateTime expiresAt;                        // 结果保留截止时间

  String state;                              // 见 TaskState
  double progress;                           // 0.0 ~ 1.0
  Map<String, Object?>? output;              // 符合服务 outputSchema 的结果
  String sideEffectStatus;                   // 见 SideEffectStatus
  String? errorCode;                         // 失败时的业务码
  String? errorMessage;                      // 失败说明

  LocalTask({
    required this.id,
    required this.workspaceId,
    required this.sessionId,
    required this.caller,
    required this.providerInstallationId,
    required this.serviceId,
    required this.callId,
    required this.depth,
    required this.expiresAt,
    this.state = TaskState.queued,
    this.progress = 0,
    this.output,
    this.sideEffectStatus = SideEffectStatus.none,
    this.errorCode,
    this.errorMessage,
  }) : createdAt = DateTime.now();

  bool get isTerminal => TaskState.terminal.contains(state);

  /// 对外快照，字段与契约中的 task.get 返回一致
  Map<String, Object?> toJson() => {
    'taskId': id,
    'service': serviceId,
    'state': state,
    'progress': progress,
    'output': output,
    'sideEffectStatus': sideEffectStatus,
    if (errorCode != null) 'error': {'code': errorCode, 'message': errorMessage},
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// 任务管理器：创建、查询、取消、终态写入，并维护调用链深度防止成环
class TaskManager {
  static const maxCallDepth = 4;              // 调用链深度上限
  static const resultTtl = Duration(minutes: 10); // 任务结束后结果至少保留 10 分钟

  final Map<String, LocalTask> _tasks = {};   // taskId → 任务
  final Map<String, List<String>> _stack = {}; // 会话 ID → 进行中的调用链（提供者安装 ID）
  int _seq = 0;                               // 任务序号

  /// 创建任务；入栈前检查环与深度，超限抛 CALL_CYCLE
  LocalTask create({
    required String workspaceId,
    required String sessionId,
    required String caller,
    required String providerInstallationId,
    required String serviceId,
  }) {
    final chain = _stack.putIfAbsent(sessionId, () => []);
    if (chain.contains(providerInstallationId)) {
      throw HostException(ErrorCode.callCycle, '调用链成环：$providerInstallationId 已在当前调用链中',
          detail: {'chain': [...chain, providerInstallationId]});
    }
    if (chain.length >= maxCallDepth) {
      throw HostException(ErrorCode.callCycle, '调用链深度超过 $maxCallDepth 上限',
          detail: {'chain': chain});
    }
    chain.add(providerInstallationId);
    final task = LocalTask(
      id: 't-${(++_seq).toString().padLeft(4, '0')}',
      workspaceId: workspaceId,
      sessionId: sessionId,
      caller: caller,
      providerInstallationId: providerInstallationId,
      serviceId: serviceId,
      callId: 'c-${_seq.toString().padLeft(4, '0')}',
      depth: chain.length,
      expiresAt: DateTime.now().add(resultTtl),
    );
    _tasks[task.id] = task;
    task.state = TaskState.running;
    return task;
  }

  /// 调用结束出栈；无论成功失败都必须调用，否则后续同链调用会误判成环
  void popChain(String sessionId, String providerInstallationId) {
    final chain = _stack[sessionId];
    if (chain == null) return;
    chain.remove(providerInstallationId);
    if (chain.isEmpty) _stack.remove(sessionId);
  }

  /// 查询任务；跨会话或跨工作区一律按不可见处理
  LocalTask get({required String taskId, required String workspaceId, required String sessionId}) {
    final task = _tasks[taskId];
    if (task == null || task.workspaceId != workspaceId || task.sessionId != sessionId) {
      throw HostException(ErrorCode.notFound, '任务不可见或不存在：$taskId（跨会话 taskId 查询被拒绝）');
    }
    return task;
  }

  /// 标记成功；sideEffectStatus 由调用方按实际效果填写，不能一律写 none
  void succeed(LocalTask task, Map<String, Object?> output,
      {String sideEffectStatus = SideEffectStatus.none}) {
    task.output = output;
    task.progress = 1;
    task.state = TaskState.succeeded;
    task.sideEffectStatus = sideEffectStatus;
    task.expiresAt = DateTime.now().add(resultTtl);
  }

  /// 标记失败
  void fail(LocalTask task, String code, String message,
      {String sideEffectStatus = SideEffectStatus.none}) {
    task.errorCode = code;
    task.errorMessage = message;
    task.state = TaskState.failed;
    task.sideEffectStatus = sideEffectStatus;
    task.expiresAt = DateTime.now().add(resultTtl);
  }

  /// 请求取消；返回"取消请求是否被接受"，终态仍需重新查询
  bool cancel(LocalTask task) {
    if (task.isTerminal) return false;
    task.state = TaskState.cancelled;
    task.expiresAt = DateTime.now().add(resultTtl);
    return true;
  }

  /// 取消某会话的全部未完成任务，用于会话撤销或工作区切换
  int cancelAllOf(String sessionId) {
    var n = 0;
    for (final task in _tasks.values) {
      if (task.sessionId == sessionId && !task.isTerminal && cancel(task)) n++;
    }
    return n;
  }
}
