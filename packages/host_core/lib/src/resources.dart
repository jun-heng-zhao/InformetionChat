// 文件职责：资源句柄表——宿主唯一能授予的文件/结果访问凭据，替代原生路径
// 依据：docs/contracts/plugin-ui-jsonrpc.md 的 host.file.* / host.resource.*

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// 句柄用途：区分为用户选择的输入、宿主生成的临时结果两类
class ResourceKind {
  static const input = 'input';          // 用户选择的输入，只读
  static const tempResult = 'temp-result'; // 插件或服务的输出，可被重新派生
}

/// 资源句柄：短期、可撤销、绑定接收者与用途，绝不能当作持久主键
class ResourceHandle {
  final String id;                       // 不可伪造的句柄 ID（宿主生成）
  final String workspaceId;              // 所属工作区
  final String sessionId;                // 创建它的运行会话，会话结束即失效
  final String owner;                    // 创建者（调用方安装 ID 或 agent 会话）
  final String recipient;                // 当前唯一有权读取的接收者
  final String kind;                     // 见 ResourceKind
  final String name;                     // 建议文件名，仅供展示
  final String mediaType;                // MIME 类型
  final int size;                        // 字节数
  final int version;                     // 资源版本，内容变化时递增
  final bool writable;                   // 是否允许写入（M1 仅临时结果允许派生，不允许原地写）
  final String scope;                    // 权限范围标识，形式 resource:<id>
  DateTime? expiresAt;                   // 到期时间，null 表示随会话结束
  DateTime? revokedAt;                   // 撤销时间，非空即失效
  final Uint8List bytes;                 // demo 直接持有内容；生产应改为受控 blob 引用

  ResourceHandle({
    required this.id,
    required this.workspaceId,
    required this.sessionId,
    required this.owner,
    required this.recipient,
    required this.kind,
    required this.name,
    required this.mediaType,
    required this.bytes,
    this.version = 1,
    this.writable = false,
    DateTime? expiresAt,
  })  : size = bytes.length,
        scope = 'resource:$id',
        expiresAt = expiresAt;

  /// 当前时刻句柄是否可用
  bool isValidAt(DateTime now) => revokedAt == null && (expiresAt == null || expiresAt!.isAfter(now));
}

/// 资源写入/创建请求的描述对象，避免调用处堆叠位置参数
class ResourceDraft {
  final String name;                     // 建议名称
  final String mediaType;                // MIME 类型
  final Uint8List bytes;                 // 内容
  final String kind;                     // 见 ResourceKind
  final bool writable;                   // 是否允许后续派生
  final Duration ttl;                    // 有效期

  const ResourceDraft({
    required this.name,
    required this.mediaType,
    required this.bytes,
    this.kind = ResourceKind.tempResult,
    this.writable = true,
    this.ttl = const Duration(minutes: 10),
  });
}

/// 句柄表：负责签发、派生、读取校验与撤销，是"跨插件传递不复制万能 token"的落点
class ResourceRegistry {
  static const maxReadBytes = 256 * 1024;        // 单次 read 最多 256 KiB
  static const maxInlineBytes = 512 * 1024;      // 演示输入与单个临时结果上限 512 KiB
  static const maxTempBytesPerInstall = 16 * 1024 * 1024; // 每安装临时资源总量上限 16 MiB

  final Map<String, ResourceHandle> _handles = {}; // 句柄 ID → 句柄
  final Map<String, int> _tempBytes = {};          // 安装 ID → 已占用的临时资源字节数
  int _seq = 0;                                    // 句柄序号，保证 ID 唯一且不可预测递增

  /// 签发句柄；内容超限直接拒绝，避免把大块字节塞进控制消息
  ResourceHandle issue({
    required String workspaceId,
    required String sessionId,
    required String owner,
    required String recipient,
    required ResourceDraft draft,
  }) {
    if (draft.bytes.length > maxInlineBytes) {
      throw HostException(ErrorCode.resourceLimit,
          '资源超过 ${maxInlineBytes ~/ 1024} KiB 上限：${draft.bytes.length} 字节');
    }
    if (draft.kind == ResourceKind.tempResult) {
      final used = (_tempBytes[owner] ?? 0) + draft.bytes.length;
      if (used > maxTempBytesPerInstall) {
        throw HostException(ErrorCode.resourceLimit,
            '临时资源总量超过 ${maxTempBytesPerInstall ~/ (1024 * 1024)} MiB：安装 $owner');
      }
      _tempBytes[owner] = used;
    }
    final handle = ResourceHandle(
      id: 'h-${(++_seq).toString().padLeft(4, '0')}-${sessionId.hashCode.toRadixString(16)}',
      workspaceId: workspaceId,
      sessionId: sessionId,
      owner: owner,
      recipient: recipient,
      kind: draft.kind,
      name: draft.name,
      mediaType: draft.mediaType,
      bytes: draft.bytes,
      writable: draft.writable,
      expiresAt: DateTime.now().add(draft.ttl),
    );
    _handles[handle.id] = handle;
    return handle;
  }

  /// 按接收者派生更窄的句柄，用于跨插件传递；调用方原句柄保持不变
  ResourceHandle derive(ResourceHandle source, {required String recipient, required String sessionId}) {
    final derived = ResourceHandle(
      id: 'h-${(++_seq).toString().padLeft(4, '0')}-${recipient.hashCode.toRadixString(16)}',
      workspaceId: source.workspaceId,
      sessionId: sessionId,
      owner: source.owner,
      recipient: recipient,
      kind: source.kind,
      name: source.name,
      mediaType: source.mediaType,
      bytes: source.bytes,
      version: source.version,
      // 派生句柄只读且沿用源过期时间，不允许借传递获得更长寿命
      writable: false,
      expiresAt: source.expiresAt,
    );
    _handles[derived.id] = derived;
    return derived;
  }

  /// 读取句柄内容：逐次校验接收者、工作区、有效期与范围，任何一项不符都拒绝
  ({Uint8List bytes, int nextOffset, bool eof}) read({
    required String handleId,
    required String recipient,
    required String workspaceId,
    int offset = 0,
    int? length,
    DateTime? now,
  }) {
    final handle = _resolve(handleId, recipient: recipient, workspaceId: workspaceId, now: now);
    if (offset < 0 || offset > handle.bytes.length) {
      throw HostException(ErrorCode.contractMismatch, 'offset 越界：$offset，资源大小 ${handle.bytes.length}');
    }
    final want = length ?? maxReadBytes;
    if (want > maxReadBytes) {
      throw HostException(ErrorCode.resourceLimit, '单次读取上限 ${maxReadBytes ~/ 1024} KiB，请求 $want 字节');
    }
    final end = (offset + want).clamp(0, handle.bytes.length);
    return (
      bytes: Uint8List.sublistView(handle.bytes, offset, end),
      nextOffset: end,
      eof: end >= handle.bytes.length,
    );
  }

  /// 只校验并返回句柄元信息，不返回内容
  ResourceHandle describe({
    required String handleId,
    required String recipient,
    required String workspaceId,
    DateTime? now,
  }) =>
      _resolve(handleId, recipient: recipient, workspaceId: workspaceId, now: now);

  /// 列出某会话可见的资源摘要，供 host.resource.list 分页使用
  List<ResourceHandle> list({required String recipient, required String workspaceId, DateTime? now}) {
    final at = now ?? DateTime.now();
    return _handles.values
        .where((h) => h.recipient == recipient && h.workspaceId == workspaceId && h.isValidAt(at))
        .toList();
  }

  /// 撤销指定句柄；用于调用结束、停用或授权撤销
  void revoke(String handleId) => _handles[handleId]?.revokedAt = DateTime.now();

  /// 撤销某会话或某调用方的全部句柄，返回撤销条数
  int revokeAll({String? sessionId, String? owner, String? recipient}) {
    var n = 0;
    for (final h in _handles.values) {
      if (h.revokedAt != null) continue;
      if (sessionId != null && h.sessionId != sessionId) continue;
      if (owner != null && h.owner != owner) continue;
      if (recipient != null && h.recipient != recipient) continue;
      h.revokedAt = DateTime.now();
      n++;
    }
    return n;
  }

  /// 内部解析：集中处理"句柄不存在 / 接收者不符 / 已过期"三类拒绝
  ResourceHandle _resolve(String handleId, {required String recipient, required String workspaceId, DateTime? now}) {
    final handle = _handles[handleId];
    if (handle == null || handle.workspaceId != workspaceId) {
      throw HostException(ErrorCode.notFound, '句柄不存在或不属于当前工作区：$handleId');
    }
    if (handle.recipient != recipient) {
      throw HostException(ErrorCode.denied, '句柄 $handleId 的接收者不是 $recipient，拒绝访问');
    }
    if (!handle.isValidAt(now ?? DateTime.now())) {
      throw HostException(ErrorCode.resourceExpired, '句柄已失效：$handleId');
    }
    return handle;
  }

  /// 句柄内容按 base64 编码返回，符合 Bridge 的"base64 字节"约定
  static String encode(Uint8List bytes) => base64Encode(bytes);
}
