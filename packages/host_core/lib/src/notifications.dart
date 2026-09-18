// 文件职责：通知引擎——来源授权、等级降级、修订去重、限流与状态机
// 依据：docs/通知分级与紧急提醒.md（M1 只做应用前台弹窗）

import 'package:collection/collection.dart';

import 'errors.dart';
import 'manifest.dart';

/// 通知状态：区分"宿主收到"与"用户看到"，不能把未展示写成已展示
class NotifyState {
  static const received = 'received';            // 已接收，等待展示（例如应用不在前台）
  static const displayed = 'displayed';          // 已在前台弹窗或列表展示
  static const acknowledged = 'acknowledged';    // 用户确认已看到（仅本地确认，不回执来源）
  static const withdrawn = 'withdrawn';          // 来源主动撤回
  static const expired = 'expired';              // 超过有效期
}

/// 通知来源策略：用户为具体安装/来源/类别设定的实际允许上限
class NotificationPolicy {
  final String workspaceId;              // 所属工作区
  final String installationId;           // 授权安装
  final String sourceId;                 // 来源标识，由宿主安装记录生成
  final String category;                 // 通知类别
  final String maxLevel;                 // 实际允许的最高等级，只能由宿主界面提高
  final bool allowInterrupt;             // 是否允许突破应用内免打扰
  DateTime? revokedAt;                   // 撤销时间

  NotificationPolicy({
    required this.workspaceId,
    required this.installationId,
    required this.sourceId,
    required this.category,
    this.maxLevel = NotifyLevel.normal,
    this.allowInterrupt = false,
  });

  bool get isValid => revokedAt == null;
}

/// 通知记录：以 (工作区, 安装, 来源, eventId) 为去重键，revision 单调递增
class HostNotification {
  final String id;                       // 宿主通知 ID
  final String workspaceId;              // 所属工作区
  final String installationId;           // 提交方安装
  final String sourceId;                 // 来源标识
  final String eventId;                  // 来源事件 ID，配合修订号去重
  final String category;                 // 通知类别
  int revision;                          // 修订号，更高修订才能覆盖
  final String requestedLevel;           // 插件请求的等级
  String effectiveLevel;                 // 宿主计算的展示等级
  String title;                          // 标题
  String body;                           // 正文
  DateTime occurredAt;                   // 事件发生时间
  DateTime? expiresAt;                   // 到期时间，紧急提醒必填
  String state;                          // 见 NotifyState
  String? reason;                        // 降级或拒绝原因，插件可查询
  int popupCount;                        // 该事件已弹窗次数，避免同事件循环重弹

  HostNotification({
    required this.id,
    required this.workspaceId,
    required this.installationId,
    required this.sourceId,
    required this.eventId,
    required this.category,
    required this.revision,
    required this.requestedLevel,
    required this.effectiveLevel,
    required this.title,
    required this.body,
    required this.occurredAt,
    this.expiresAt,
    this.state = NotifyState.received,
    this.reason,
    this.popupCount = 0,
  });

  /// 事件是否已过有效期；过期的紧急事件不得因重连或重启再次弹出
  bool isExpiredAt(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  Map<String, Object?> toJson() => {
    'notificationId': id,
    'category': category,
    'sourceId': sourceId,
    'eventId': eventId,
    'revision': revision,
    'requestedLevel': requestedLevel,
    'effectiveLevel': effectiveLevel,
    'title': title,
    'body': body,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'state': state,
    if (reason != null) 'reason': reason,
  };
}

/// 发布请求的入参，避免调用点堆叠长参数列表
class NotifyRequest {
  final String installationId;           // 提交方安装 ID
  final String sourceId;                 // 来源标识
  final String category;                 // 类别
  final String eventId;                  // 事件 ID
  final int revision;                    // 修订号
  final String requestedLevel;           // 请求等级
  final String title;                    // 标题
  final String body;                     // 正文
  final DateTime occurredAt;             // 事件发生时间
  final DateTime? expiresAt;             // 到期时间
  final int actionCount;                 // 携带的动作数量，用于上限校验

  const NotifyRequest({
    required this.installationId,
    required this.sourceId,
    required this.category,
    required this.eventId,
    required this.title,
    required this.body,
    required this.occurredAt,
    this.revision = 1,
    this.requestedLevel = NotifyLevel.normal,
    this.expiresAt,
    this.actionCount = 0,
  });
}

/// 通知引擎：M1 只负责策略计算、状态流转与前台弹窗决策，不实现系统通知
class NotificationEngine {
  static const maxTitleLength = 120;     // 标题长度上限
  static const maxBodyLength = 2000;     // 正文长度上限
  static const maxActions = 2;           // 动作数量上限
  static const criticalWindow = Duration(minutes: 5); // 紧急提醒有效期上限
  static const rateLimitPerMinute = 3;   // 每来源每分钟最多弹出的紧急提醒数

  final List<NotificationPolicy> _policies = []; // 用户授权策略
  final List<HostNotification> _notifications = []; // 全部通知记录
  final List<DateTime> _criticalPopups = [];     // 近期紧急弹窗时间戳，用于限流
  bool foreground = true;                        // 应用是否在前台，由宿主界面同步
  int _seq = 0;                                  // 通知序号

  /// 写入或更新用户策略；等级提升属于敏感操作，只应由宿主界面调用
  void setPolicy(NotificationPolicy policy) {
    _policies.removeWhere((p) => p.workspaceId == policy.workspaceId &&
        p.installationId == policy.installationId &&
        p.sourceId == policy.sourceId &&
        p.category == policy.category);
    _policies.add(policy);
  }

  /// 查询某来源类别的有效策略
  NotificationPolicy? policyOf({
    required String workspaceId,
    required String installationId,
    required String sourceId,
    required String category,
  }) {
    for (final p in _policies) {
      if (p.workspaceId == workspaceId &&
          p.installationId == installationId &&
          p.sourceId == sourceId &&
          p.category == category &&
          p.isValid) {
        return p;
      }
    }
    return null;
  }

  /// 计算实际展示等级：取"用户策略上限"与"来源历史实际上限"的较小值
  ({String level, String? reason}) resolveLevel({
    required String requested,
    required String policyMax,
    required bool hasCriticalPermission,
  }) {
    // 缺少紧急权限时，即使策略允许也只能降到 important，绝不因正文自称紧急而提权
    final cap = hasCriticalPermission ? policyMax : NotifyLevel.clamp(policyMax, NotifyLevel.important);
    final effective = NotifyLevel.clamp(requested, cap);
    final reason = effective == requested ? null : '按用户策略或权限降级：$requested → $effective';
    return (level: effective, reason: reason);
  }

  /// 发布或更新通知；返回记录与是否需要前台弹窗
  ({HostNotification notification, bool shouldPopup}) publish(
    NotifyRequest req, {
    required String workspaceId,
    required bool hasPublishPermission,
    required bool hasCriticalPermission,
    required List<NotificationCategory> declaredCategories,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();

    // 1. 基础权限与字段限制：未知类别直接拒绝，不能动态创建已授权的紧急来源
    if (!hasPublishPermission) {
      throw HostException.denied('调用方未获通知发布权限：${req.installationId}');
    }
    if (req.title.length > maxTitleLength) {
      throw HostException(ErrorCode.resourceLimit, '标题超过 $maxTitleLength 字符上限');
    }
    if (req.body.length > maxBodyLength) {
      throw HostException(ErrorCode.resourceLimit, '正文超过 $maxBodyLength 字符上限');
    }
    if (req.actionCount > maxActions) {
      throw HostException(ErrorCode.resourceLimit, '动作数量超过 $maxActions 上限');
    }
    final category = declaredCategories.where((c) => c.id == req.category).firstOrNull;
    if (category == null) {
      throw HostException(ErrorCode.unknownCategory, '通知类别未在清单登记：${req.category}');
    }
    if (!NotifyLevel.isValid(req.requestedLevel)) {
      throw HostException(ErrorCode.contractMismatch, '非法通知等级：${req.requestedLevel}');
    }

    // 2. 等级计算：先按清单请求上限收敛，再按用户策略与实际权限降级
    final policy = policyOf(
      workspaceId: workspaceId,
      installationId: req.installationId,
      sourceId: req.sourceId,
      category: req.category,
    );
    final policyMax = NotifyLevel.clamp(
      policy?.maxLevel ?? NotifyLevel.normal,
      category.requestedMaxLevel,
    );
    final resolved = resolveLevel(
      requested: req.requestedLevel,
      policyMax: policyMax,
      hasCriticalPermission: hasCriticalPermission && policy != null,
    );

    // 3. 紧急提醒必须给出有效期，且有效窗口不能超过 5 分钟
    final wantsCritical = req.requestedLevel == NotifyLevel.critical;
    if (wantsCritical && req.expiresAt == null) {
      throw const HostException(ErrorCode.contractMismatch, '紧急提醒必须提供 expiresAt');
    }
    if (req.expiresAt != null && req.expiresAt!.difference(at) > criticalWindow) {
      throw const HostException(ErrorCode.resourceLimit, '有效期超过 5 分钟上限');
    }

    // 4. 去重：同键更高修订才更新；同修订同内容返回既有结果；同修订不同内容拒绝
    final existing = _notifications.where((n) => n.workspaceId == workspaceId &&
        n.installationId == req.installationId &&
        n.sourceId == req.sourceId &&
        n.eventId == req.eventId).firstOrNull;
    if (existing != null && req.revision < existing.revision) {
      throw const HostException(ErrorCode.contractMismatch, '较低修订不能覆盖更新状态');
    }
    if (existing != null && req.revision == existing.revision) {
      if (existing.title == req.title && existing.body == req.body) {
        return (notification: existing, shouldPopup: false);
      }
      throw const HostException(ErrorCode.contractMismatch, '同修订号但内容不同，拒绝');
    }

    // 5. 已过期或被撤回的事件不得复活：撤回记录保留到原有效期结束，防止重放
    if (existing != null && existing.state == NotifyState.withdrawn && !existing.isExpiredAt(at)) {
      throw const HostException(ErrorCode.notFound, '事件已撤回且未过期，不允许重新发布：${req.eventId}');
    }
    if (req.expiresAt != null && !req.expiresAt!.isAfter(at)) {
      throw const HostException(ErrorCode.resourceExpired, '事件已过期，不能作为新提醒发布');
    }

    // 6. 前台与限流：不在前台只记录 received，回前台后再重新判断
    final effectiveLevel = resolved.level;
    var state = NotifyState.received;
    String? reason = resolved.reason;
    var shouldPopup = false;
    if (effectiveLevel == NotifyLevel.critical) {
      if (!foreground) {
        reason = '应用不在前台，无法展示紧急弹窗（FOREGROUND_REQUIRED）';
      } else if (!_consumeRateLimit(at)) {
        state = NotifyState.received;
        reason = '触发限流：每来源每分钟最多 $rateLimitPerMinute 条紧急提醒';
      } else {
        state = NotifyState.displayed;
        shouldPopup = true;
      }
    } else if (effectiveLevel == NotifyLevel.important) {
      state = foreground ? NotifyState.displayed : NotifyState.received;
    }

    // 7. 写入或按更高修订更新既有记录
    if (existing != null) {
      existing
        ..revision = req.revision
        ..requestedLevel = req.requestedLevel
        ..effectiveLevel = effectiveLevel
        ..title = req.title
        ..body = req.body
        ..occurredAt = req.occurredAt
        ..expiresAt = req.expiresAt
        ..state = state
        ..reason = reason;
      if (shouldPopup) existing.popupCount++;
      return (notification: existing, shouldPopup: shouldPopup);
    }
    final notification = HostNotification(
      id: 'n-${(++_seq).toString().padLeft(4, '0')}',
      workspaceId: workspaceId,
      installationId: req.installationId,
      sourceId: req.sourceId,
      eventId: req.eventId,
      category: req.category,
      revision: req.revision,
      requestedLevel: req.requestedLevel,
      effectiveLevel: effectiveLevel,
      title: req.title,
      body: req.body,
      occurredAt: req.occurredAt,
      expiresAt: req.expiresAt,
      state: state,
      reason: reason,
      popupCount: shouldPopup ? 1 : 0,
    );
    _notifications.add(notification);
    return (notification: notification, shouldPopup: shouldPopup);
  }

  /// 撤回通知；需要更高修订，且保留终止记录直到事件原有效期结束
  HostNotification withdraw({
    required String workspaceId,
    required String installationId,
    required String sourceId,
    required String eventId,
    required int revision,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final target = _notifications.where((n) => n.workspaceId == workspaceId &&
        n.installationId == installationId &&
        n.sourceId == sourceId &&
        n.eventId == eventId).firstOrNull;
    if (target == null) throw HostException(ErrorCode.notFound, '通知不存在：$eventId');
    if (revision <= target.revision) {
      throw const HostException(ErrorCode.contractMismatch, '撤回需要更高修订号');
    }
    target
      ..revision = revision
      ..state = NotifyState.withdrawn
      ..reason = '来源已撤回';
    return target;
  }

  /// 用户确认已看到；仅由可信宿主界面调用，插件与 Agent 无代确认权限
  HostNotification acknowledge({required String workspaceId, required String notificationId, DateTime? now}) {
    final target = _notifications.where((n) => n.workspaceId == workspaceId && n.id == notificationId).firstOrNull;
    if (target == null) throw HostException(ErrorCode.notFound, '通知不存在：$notificationId');
    if (target.state == NotifyState.withdrawn) {
      throw const HostException(ErrorCode.contractMismatch, '已撤回的通知不能确认');
    }
    target.state = NotifyState.acknowledged;
    return target;
  }

  /// 把过期通知批量标记为 expired；未展示的记录不会被写成已展示
  int sweepExpired({DateTime? now}) {
    final at = now ?? DateTime.now();
    var n = 0;
    for (final notification in _notifications) {
      if (notification.state == NotifyState.withdrawn || notification.state == NotifyState.acknowledged) continue;
      if (notification.isExpiredAt(at)) {
        notification.state = NotifyState.expired;
        n++;
      }
    }
    return n;
  }

  /// 停用来来源时撤销其待处理通知，历史记录保留可查
  int revokeSource({required String workspaceId, required String installationId, DateTime? now}) {
    var n = 0;
    for (final notification in _notifications) {
      if (notification.workspaceId != workspaceId || notification.installationId != installationId) continue;
      if (notification.state == NotifyState.received || notification.state == NotifyState.displayed) {
        notification.state = NotifyState.withdrawn;
        notification.reason = '来源已停用，待处理通知撤销';
        n++;
      }
    }
    return n;
  }

  /// 某调用方有权查看的通知列表
  List<HostNotification> list({required String workspaceId, required String installationId}) => _notifications
      .where((n) => n.workspaceId == workspaceId && n.installationId == installationId)
      .toList();

  /// 限流检查：返回 false 表示本次不允许弹出
  bool _consumeRateLimit(DateTime at) {
    _criticalPopups.removeWhere((t) => at.difference(t) > const Duration(minutes: 1));
    if (_criticalPopups.length >= rateLimitPerMinute) return false;
    _criticalPopups.add(at);
    return true;
  }
}
