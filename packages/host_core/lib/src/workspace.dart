// 文件职责：本地工作区、插件安装记录与权限授权表——宿主隔离与授权的基本单位

import 'errors.dart';
import 'loader.dart';
import 'manifest.dart';

/// 安装记录状态机：discovered → validated → disabled → active，失败进入 failed
class InstallState {
  static const discovered = 'discovered'; // 已发现源目录，尚未校验
  static const validated = 'validated';   // 校验通过，等待用户授权
  static const active = 'active';         // 已授权并激活
  static const disabled = 'disabled';     // 用户停用，数据保留
  static const failed = 'failed';         // 加载或迁移失败，需重新校验
}

/// 插件安装：工作区内授权的最小单位，包摘要与离线约束随记录锁定
class PluginInstallation {
  final String id;                       // 安装 ID，权限判断只认它，不认清单自述 ID
  final String workspaceId;              // 所属工作区
  final String pluginId;                 // 清单自述 ID，仅用于依赖解析
  final String version;                  // 已锁定版本
  final String sourceLabel;              // 来源描述（本地目录/包路径），用于界面展示
  final String digest;                   // 包内容整体摘要，判断内容是否变化
  final StagedPackage package;           // 只读快照，激活后从它读取入口与 schema
  final bool offlineOnly;                // M1 恒为 true：离线安装永久保持无网络出口
  String state;                          // 当前状态，见 InstallState
  final List<String> grantedPermissions; // 用户实际授予的权限（清单声明的子集）

  PluginInstallation({
    required this.id,
    required this.workspaceId,
    required this.pluginId,
    required this.version,
    required this.sourceLabel,
    required this.digest,
    required this.package,
    this.offlineOnly = true,
    this.state = InstallState.validated,
    this.grantedPermissions = const [],
  });

  PluginManifest get manifest => package.manifest;

  /// 通知来源 ID：由宿主安装记录生成，不接受插件在正文里自报来源
  String get sourceId => 'source-$id';
}

/// 权限授权记录：按调用方与用途授权，可设有效期并可被撤销
class PermissionGrant {
  final String workspaceId;              // 授权所属工作区
  final String caller;                   // 调用方安装 ID 或 "agent:<sessionId>"
  final String operation;                // 权限名，取自 knownPermissions
  final String resourceScope;            // 资源范围，'workspace' 或 'resource:<handleId>'
  final String purpose;                  // 用途说明，用于界面回显与审计
  final DateTime? expiresAt;             // 到期时间，null 表示不自动到期
  DateTime? revokedAt;                   // 撤销时间，非空即失效

  PermissionGrant({
    required this.workspaceId,
    required this.caller,
    required this.operation,
    this.resourceScope = 'workspace',
    this.purpose = '',
    this.expiresAt,
  });

  /// 在给定时刻该授权是否仍然有效
  bool isValidAt(DateTime now) => revokedAt == null && (expiresAt == null || expiresAt!.isAfter(now));

  /// 资源范围是否覆盖目标句柄：workspace 级覆盖一切，否则必须精确命中
  bool coversScope(String scope) => resourceScope == 'workspace' || resourceScope == scope;
}

/// 授权表：所有 host.* 调用都要先经过它，越权一律拒绝而不是静默降级
class PermissionBroker {
  final List<PermissionGrant> _grants = [];

  /// 新增授权；同一 (workspace, caller, operation, scope) 重复授权时返回既有记录
  PermissionGrant grant(PermissionGrant g) {
    final existing = _grants.where((e) => e.workspaceId == g.workspaceId &&
        e.caller == g.caller &&
        e.operation == g.operation &&
        e.resourceScope == g.resourceScope && e.revokedAt == null);
    if (existing.isNotEmpty) return existing.first;
    _grants.add(g);
    return g;
  }

  /// 撤销某调用方的全部授权，返回撤销条数
  int revokeAllOf(String caller) {
    var n = 0;
    for (final g in _grants) {
      if (g.caller == caller && g.revokedAt == null) {
        g.revokedAt = DateTime.now();
        n++;
      }
    }
    return n;
  }

  /// 判断是否放行；不放行时抛 CAPABILITY_DENIED，由分发层转成业务错误
  void require({
    required String workspaceId,
    required String caller,
    required String operation,
    String scope = 'workspace',
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    for (final g in _grants) {
      if (g.workspaceId == workspaceId &&
          g.caller == caller &&
          g.operation == operation &&
          g.coversScope(scope) &&
          g.isValidAt(at)) {
        return;
      }
    }
    throw HostException.denied('调用方 $caller 未获授权：$operation（范围 $scope）',
        detail: {'operation': operation, 'scope': scope});
  }

  /// 只查询不抛异常的版本，供 discover 之类需要"降级而不是失败"的场景使用
  bool allows({
    required String workspaceId,
    required String caller,
    required String operation,
    String scope = 'workspace',
    DateTime? now,
  }) {
    try {
      require(workspaceId: workspaceId, caller: caller, operation: operation, scope: scope, now: now);
      return true;
    } on HostException {
      return false;
    }
  }

  /// 当前有效授权快照，便于界面展示和演示输出
  List<PermissionGrant> get activeGrants => _grants.where((g) => g.revokedAt == null).toList();
}
