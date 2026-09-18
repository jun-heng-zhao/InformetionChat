// 文件职责：定义宿主统一错误码与异常类型，供所有接口层（UI Bridge / Agent）复用
// 约定：业务错误走 JSON-RPC error.code = -32000，真实语义放在 error.data.code

/// 业务错误码集合，取值与 UI Bridge 1.2、Agent 契约中的 error.data.code 一一对应
class ErrorCode {
  static const denied = 'CAPABILITY_DENIED';                             // 越权：调用方未被授权该操作
  static const unavailable = 'CAPABILITY_UNAVAILABLE';                   // 当前阶段或平台尚未实现该能力
  static const needsAuthorization = 'NEEDS_AUTHORIZATION';               // 可申请授权，须由宿主界面处理
  static const contractMismatch = 'CONTRACT_MISMATCH';                   // 参数或结果与服务 schema 不符
  static const resourceExpired = 'RESOURCE_EXPIRED';                     // 句柄过期、已撤销或接收者不相符
  static const resourceLimit = 'RESOURCE_LIMIT';                         // 超出配额（消息体、包体、临时资源）
  static const providerUnavailable = 'PROVIDER_UNAVAILABLE';             // 提供者停用、超时或校验失败
  static const providerSelectionRequired = 'PROVIDER_SELECTION_REQUIRED'; // 缺少有效绑定，需用户选择提供者
  static const timeout = 'TIMEOUT';                                      // 调用超时
  static const cancelled = 'CANCELLED';                                  // 调用方主动取消
  static const callCycle = 'CALL_CYCLE';                                 // 调用链成环或超过最大深度
  static const userInteractionRequired = 'USER_INTERACTION_REQUIRED';    // 必须有界面操作才能继续
  static const foregroundRequired = 'FOREGROUND_REQUIRED';               // 应用不在前台，无法展示提醒
  static const rateLimited = 'RATE_LIMITED';                             // 触发限流阈值
  static const unknownCategory = 'UNKNOWN_CATEGORY';                     // 通知类别未在清单登记
  static const notFound = 'NOT_FOUND';                                   // 对象不存在或不在当前会话可见范围
}

/// 宿主业务异常：携带业务码、可读消息与可选明细，由分发层转成 JSON-RPC 错误
class HostException implements Exception {
  final String code;                     // 业务错误码，见 ErrorCode
  final String message;                  // 面向开发者/用户的可读说明
  final Map<String, Object?>? detail;    // 附加信息，例如缺失的依赖链、可选提供者摘要

  const HostException(this.code, this.message, {this.detail});

  /// 便捷构造：越权
  static HostException denied(String message, {Map<String, Object?>? detail}) =>
      HostException(ErrorCode.denied, message, detail: detail);

  /// 便捷构造：能力未实现
  static HostException unavailable(String message) => HostException(ErrorCode.unavailable, message);

  @override
  String toString() => 'HostException($code): $message';
}
