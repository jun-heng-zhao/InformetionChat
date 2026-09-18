// 文件职责：JSON-RPC 2.0 信封的解析、构造与错误封装，是 UI Bridge 与 Agent 适配器的公共传输层

import 'errors.dart';

/// JSON-RPC 标准协议错误码；业务错误统一使用 businessErrorCode
class RpcErrorCode {
  static const parseError = -32700;      // 报文不是合法 JSON
  static const invalidRequest = -32600;  // 报文结构不符合 JSON-RPC 2.0
  static const methodNotFound = -32601;  // 方法名未知
  static const invalidParams = -32602;   // 参数结构不正确
  static const internalError = -32603;   // 宿主内部异常
  static const businessError = -32000;   // 业务错误，具体码见 error.data.code
}

/// JSON-RPC 请求：method 必填，id 为 null 时表示通知（不需要响应）
class RpcRequest {
  final Object? id;                      // 请求标识，int / String / null（通知）
  final String method;                   // 方法名，例如 host.service.call
  final Map<String, Object?> params;     // 命名参数，缺省为空表

  const RpcRequest({required this.id, required this.method, this.params = const {}});

  /// 是否为通知（无 id，不返回响应）
  bool get isNotification => id == null;

  /// 从已解析的 JSON 构造；结构非法时抛 HostException
  factory RpcRequest.fromJson(Object? raw) {
    if (raw is! Map) throw const HostException(ErrorCode.contractMismatch, '请求必须是 JSON 对象');
    final method = raw['method'];
    if (method is! String || method.isEmpty) {
      throw const HostException(ErrorCode.contractMismatch, '请求缺少 method 字段');
    }
    final params = raw['params'];
    if (params != null && params is! Map) {
      throw const HostException(ErrorCode.contractMismatch, 'params 必须是 JSON 对象');
    }
    return RpcRequest(
      id: raw['id'],
      method: method,
      params: (params as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  Map<String, Object?> toJson() => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
}

/// JSON-RPC 响应：成功带 result，失败带 error，二者互斥
class RpcResponse {
  final Object? id;                      // 与请求一致的标识
  final Object? result;                  // 成功结果
  final RpcError? error;                 // 失败信息

  const RpcResponse.success(this.id, this.result) : error = null;
  const RpcResponse.failure(this.id, this.error) : result = null;

  bool get isSuccess => error == null;

  /// 构造失败响应：协议错误带数字码，业务错误带 -32000 与 data.code
  factory RpcResponse.businessError(Object? id, HostException e) => RpcResponse.failure(
    id,
    RpcError(RpcErrorCode.businessError, e.message, data: {'code': e.code, if (e.detail != null) 'detail': e.detail}),
  );

  Map<String, Object?> toJson() => {
    'jsonrpc': '2.0',
    'id': id,
    if (error != null) 'error': error!.toJson() else 'result': result,
  };
}

/// JSON-RPC 错误体：data 中携带业务码与明细
class RpcError {
  final int code;                        // 协议码或 -32000
  final String message;                  // 可读描述
  final Map<String, Object?>? data;      // 业务码、明细与请求 ID

  const RpcError(this.code, this.message, {this.data});

  Map<String, Object?> toJson() => {'code': code, 'message': message, if (data != null) 'data': data};

  @override
  String toString() => 'RpcError($code, $message)';
}
